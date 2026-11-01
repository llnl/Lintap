package main

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"
)

type config struct {
	DataRoot            string `json:"data_root"`
	Interval            int64  `json:"interval_sec"`
	Rotation            int64  `json:"rotate_interval_sec"`
	MinimumRotation     int64  `json:"min_rotate_interval_sec"`
	ParquetRoot         string `json:"parquet_root"`
	SpoolDir            string `json:"spool_dir"`
	Compression         string `json:"parquet_compression"`
	LegacyDuckDBThreads int64  `json:"duckdb_threads"` // Compatibility validation ONLY; no Go runtime meaning.
	MaxBytes            int64  `json:"max_unshipped_bytes"`
	MaxAge              int64  `json:"max_unshipped_age_sec"`
	Hostname            string `json:"hostname"`
}

// Resolve without creating directories: fpc-02 diagnostics never write to the
// configured production roots. Durable collector initialization is fpc-03 work.
func configFromEnv(lookup func(string) (string, bool), host string) (config, error) {
	get := func(key, fallback string) string {
		if value, ok := lookup(key); ok {
			return value
		}
		return fallback
	}
	number := func(key, fallback string, minimum int64) (int64, error) {
		text := get(key, fallback)
		n, err := pythonDecimalInt(text)
		if err != nil || n < minimum {
			return 0, fmt.Errorf("%s must be an integer >= %d", key, minimum)
		}
		return n, nil
	}
	c := config{DataRoot: pythonPath(get("WINTAP_DATA_ROOT", "/var/log/lintap/data")),
		Hostname: get("PIDSTAT_HOSTNAME", strings.SplitN(host, ".", 2)[0]), Compression: get("PIDSTAT_PARQUET_COMPRESSION", "ZSTD")}
	var err error
	if c.Interval, err = number("PIDSTAT_INTERVAL_SEC", "5", 1); err != nil {
		return c, err
	}
	if c.Rotation, err = number("PIDSTAT_ROTATE_INTERVAL_SEC", get("WINTAP_ETL_UPLOAD_INTERVAL_SEC", "300"), 1); err != nil {
		return c, err
	}
	if c.MinimumRotation, err = number("PIDSTAT_MIN_ROTATE_INTERVAL_SEC", "300", 1); err != nil {
		return c, err
	}
	if c.Rotation < c.MinimumRotation {
		c.Rotation = c.MinimumRotation
	}
	runtimeRoot := pythonPath(get("WINTAP_RUNTIME_ROOT", "/var/log/lintap/runtime"))
	c.ParquetRoot = pythonPath(get("PIDSTAT_PARQUET_ROOT", c.DataRoot))
	c.SpoolDir = pythonPath(get("PIDSTAT_SPOOL_DIR", runtimeRoot+"/pidstat-spool"))
	if c.LegacyDuckDBThreads, err = number("PIDSTAT_DUCKDB_THREADS", "1", 1); err != nil {
		return c, err
	}
	if c.MaxBytes, err = number("PIDSTAT_MAX_UNSHIPPED_BYTES", "1073741824", 0); err != nil {
		return c, err
	}
	if c.MaxAge, err = number("PIDSTAT_MAX_UNSHIPPED_AGE_SEC", "0", 0); err != nil {
		return c, err
	}
	return c, nil
}

// Match pathlib's lexical POSIX representation: remove redundant '.'/slashes,
// but do not resolve '..' (especially important across symlink directories).
func pythonPath(path string) string {
	prefix := ""
	if strings.HasPrefix(path, "//") && !strings.HasPrefix(path, "///") {
		prefix = "//"
	} else if strings.HasPrefix(path, "/") {
		prefix = "/"
	}
	parts := []string{}
	for _, part := range strings.Split(path, "/") {
		if part != "" && part != "." {
			parts = append(parts, part)
		}
	}
	result := prefix + strings.Join(parts, "/")
	if result == "" {
		return "."
	}
	return result
}

func pythonDecimalInt(text string) (int64, error) {
	text = strings.TrimSpace(text)
	var normalized strings.Builder
	digitBefore := false
	runes := []rune(text)
	for index, r := range runes {
		if index == 0 && (r == '+' || r == '-') {
			normalized.WriteRune(r)
			continue
		}
		if r == '_' {
			if !digitBefore || index+1 == len(runes) || !unicode.IsDigit(runes[index+1]) {
				return 0, fmt.Errorf("invalid decimal separator")
			}
			digitBefore = false
			continue
		}
		digit := -1
		for _, entry := range unicode.Digit.R16 {
			if uint32(r) >= uint32(entry.Lo) && uint32(r) <= uint32(entry.Hi) && (uint32(r)-uint32(entry.Lo))%uint32(entry.Stride) == 0 {
				digit = int((uint32(r)-uint32(entry.Lo))/uint32(entry.Stride)) % 10
				break
			}
		}
		if digit < 0 {
			for _, entry := range unicode.Digit.R32 {
				if uint32(r) >= entry.Lo && uint32(r) <= entry.Hi && (uint32(r)-entry.Lo)%entry.Stride == 0 {
					digit = int((uint32(r)-entry.Lo)/entry.Stride) % 10
					break
				}
			}
		}
		if digit < 0 {
			return 0, fmt.Errorf("invalid decimal digit")
		}
		normalized.WriteByte(byte('0' + digit))
		digitBefore = true
	}
	return strconv.ParseInt(normalized.String(), 10, 64)
}
