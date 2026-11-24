// Feasibility diagnostics: TSV encoding, raw sampler replay and bounded live
// sampling. Not a durable production collector or package/service replacement.
package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata" // Keep the test binary independent of installed zoneinfo.

	"github.com/parquet-go/parquet-go"
	"github.com/parquet-go/parquet-go/compress/zstd"
)

type windowKey struct {
	host  string
	epoch int64
}

// parseRow reads the production 27-field TSV. Its decimal rates have ALREADY
// undergone Python's two-decimal rounding; this spike does not port that math.
func parseRow(fields []string, location *time.Location, rotation int64) (parquet.Row, windowKey, error) {
	return parseTSV(fields, location, rotation, true)
}

func parseTSV(fields []string, location *time.Location, rotation int64, hostOwnsPath bool) (parquet.Row, windowKey, error) {
	if len(fields) != 27 {
		return nil, windowKey{}, fmt.Errorf("expected 27 TSV fields, got %d", len(fields))
	}
	stamp := fields[0] + " " + fields[1]
	wall, err := time.Parse("2006-01-02 15:04:05", stamp)
	if err != nil {
		return nil, windowKey{}, err
	}
	local, err := time.ParseInLocation("2006-01-02 15:04:05", stamp, location)
	if err != nil {
		return nil, windowKey{}, err
	}
	host := fields[22]
	if hostOwnsPath && (host == "" || host == "." || host == ".." || strings.ContainsAny(host, "/\\\x00")) {
		return nil, windowKey{}, fmt.Errorf("invalid hostname for output path")
	}
	epoch := local.Unix()
	window := windowForEpoch(epoch, rotation)
	key := windowKey{host: host, epoch: window}
	row := make(parquet.Row, 26)
	row[0] = parquet.Int64Value(wall.UnixMicro()).Level(0, 1, 0)
	for column := 1; column < 26; column++ {
		text := fields[column+1]
		if text == "" {
			row[column] = parquet.NullValue().Level(0, 0, column)
			continue
		}
		var value parquet.Value
		switch column {
		case 1, 2, 8, 17:
			var n int64
			n, err = strconv.ParseInt(text, 10, 32)
			value = parquet.Int32Value(int32(n))
		case 11, 12, 23:
			var n int64
			n, err = strconv.ParseInt(text, 10, 64)
			value = parquet.Int64Value(n)
		case 20, 21, 22, 24, 25:
			value = parquet.ByteArrayValue([]byte(text))
		default:
			var n float64
			n, err = strconv.ParseFloat(text, 32)
			if err == nil && (math.IsNaN(n) || math.IsInf(n, 0)) {
				err = fmt.Errorf("non-finite metric")
			}
			value = parquet.FloatValue(float32(n))
		}
		if err != nil {
			return nil, windowKey{}, fmt.Errorf("column %d: %w", column, err)
		}
		row[column] = value.Level(0, 1, column)
	}
	return row, key, nil
}

func encode(input io.Reader, output string, location *time.Location, rotation int64) (int, error) {
	return encodeWithEpochs(input, output, location, rotation, nil)
}

func windowForEpoch(epoch, rotation int64) int64 {
	remainder := epoch % rotation
	start := epoch - remainder
	if remainder < 0 {
		start -= rotation
	}
	return start
}

func encodeWithEpochs(input io.Reader, output string, location *time.Location, rotation int64, epochs []int64) (int, error) {
	if rotation <= 0 {
		return 0, fmt.Errorf("rotation must be positive")
	}
	reader := csv.NewReader(input)
	reader.Comma, reader.FieldsPerRecord, reader.LazyQuotes = '\t', 27, true
	groups := make(map[windowKey][]parquet.Row)
	count := 0
	for {
		fields, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, fmt.Errorf("TSV row %d: %w", count+1, err)
		}
		row, key, err := parseRow(fields, location, rotation)
		if err != nil {
			return 0, fmt.Errorf("TSV row %d: %w", count+1, err)
		}
		if epochs != nil {
			if count >= len(epochs) {
				return 0, fmt.Errorf("missing source sample epoch")
			}
			key.epoch = windowForEpoch(epochs[count], rotation)
		}
		groups[key] = append(groups[key], row)
		count++
	}
	if count == 0 {
		return 0, fmt.Errorf("input contains no rows")
	}
	if epochs != nil && count != len(epochs) {
		return 0, fmt.Errorf("sample epoch/row count mismatch")
	}
	// New test root only. Never touch a production spool or overwrite old evidence.
	if err := os.Mkdir(output, 0700); err != nil {
		return 0, err
	}
	keys := make([]windowKey, 0, len(groups))
	for key := range groups {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].epoch != keys[j].epoch {
			return keys[i].epoch < keys[j].epoch
		}
		return keys[i].host < keys[j].host
	})
	for _, key := range keys {
		stamp := time.Unix(key.epoch, 0).In(location)
		dir := filepath.Join(output, "raw_sensor", "pidstat", "dayPK="+stamp.Format("20060102"), "hourPK="+stamp.Format("15"))
		if err := os.MkdirAll(dir, 0700); err != nil {
			return 0, err
		}
		path := filepath.Join(dir, fmt.Sprintf("%s+pidstat+%d.parquet", key.host, key.epoch))
		if err := writeWindow(path, groups[key]); err != nil {
			return 0, err
		}
	}
	return count, nil
}

func writeWindow(path string, rows []parquet.Row) error {
	active := path + ".active"
	file, err := os.OpenFile(active, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	writer := parquet.NewWriter(file, pythonSchema(), parquet.Compression(&zstd.Codec{}))
	n, writeErr := writer.WriteRows(rows)
	closeErr := writer.Close()
	fileErr := file.Close()
	if writeErr != nil || n != len(rows) || closeErr != nil || fileErr != nil {
		return fmt.Errorf("Parquet write failed: rows=%d/%d write=%v close=%v file=%v", n, len(rows), writeErr, closeErr, fileErr)
	}
	return os.Rename(active, path)
}

func run(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("pidstat-parquet-spike", flag.ContinueOnError)
	flags.SetOutput(stderr)
	input := flags.String("input", "", "captured production Python golden.tsv (required)")
	output := flags.String("output", "", "new isolated output directory (required)")
	zone := flags.String("timezone", "Local", "IANA timezone of the Python reference for window partitioning")
	rotation := flags.Int64("rotation", 300, "reference rotation interval in seconds")
	replay := flags.String("replay", "", "captured raw capture.json for sampler replay (instead of --input)")
	sampleCount := flags.Int("sample-count", 0, "bounded live diagnostic: 2..12 samples; PIDSTAT_INTERVAL_SEC <= 30")
	showConfig := flags.Bool("show-config", false, "print resolved Linux configuration without writing directories")
	showKernel := flags.Bool("kernel-context", false, "print native Linux AT_CLKTCK and page size")
	collect := flags.Bool("collect", false, "run durable Linux collector using PIDSTAT configuration (not packaged)")
	recover := flags.Bool("recover", false, "recover/seal configured current and pending spools, then exit")
	spoolReplay := flags.String("spool-replay", "", "replay captured raw inputs through durable spool/writer, then exit")
	flags.Usage = func() {
		fmt.Fprintln(stderr, "pidstat Go collector and compatibility diagnostics; not packaged or deployed")
		flags.PrintDefaults()
	}
	if err := flags.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("no positional arguments")
	}
	modes := 0
	for _, selected := range []bool{*input != "", *replay != "", *sampleCount != 0, *showConfig, *showKernel, *collect, *recover, *spoolReplay != ""} {
		if selected {
			modes++
		}
	}
	if modes != 1 {
		return fmt.Errorf("select exactly one of --input, --replay, --sample-count, --show-config, --kernel-context")
	}
	if *showKernel {
		ticks, page, err := kernelContext()
		if err != nil {
			return err
		}
		return json.NewEncoder(stdout).Encode(map[string]int64{"clock_ticks": ticks, "page_size_bytes": page})
	}
	if *showConfig {
		host, err := os.Hostname()
		if err != nil {
			return err
		}
		c, err := configFromEnv(os.LookupEnv, host)
		if err != nil {
			return err
		}
		return json.NewEncoder(stdout).Encode(c)
	}
	if *collect || *recover || *spoolReplay != "" {
		location, err := time.LoadLocation(*zone)
		if err != nil {
			return err
		}
		host, err := os.Hostname()
		if err != nil {
			return err
		}
		config, err := configFromEnv(os.LookupEnv, host)
		if err != nil {
			return err
		}
		// Prevent time.Duration overflow rather than creating a negative/busy timer.
		if config.Interval > int64(math.MaxInt64)/int64(time.Second) {
			return fmt.Errorf("sample interval exceeds Go timer range")
		}
		c, err := newCollector(config, location, stderr)
		if err != nil {
			return err
		}
		defer c.close()
		if *recover {
			return c.salvage()
		}
		if *spoolReplay != "" {
			f, err := os.Open(*spoolReplay)
			if err != nil {
				return err
			}
			defer f.Close()
			batch, err := replayRaw(f, location)
			if err != nil {
				return err
			}
			if err = c.salvage(); err != nil {
				return err
			}
			for i := 0; i < len(batch.Rows); {
				end := i + 1
				for end < len(batch.Rows) && batch.Epochs[end] == batch.Epochs[i] {
					end++
				}
				if err = c.append(batch.Epochs[i], batch.Rows[i:end]); err != nil {
					return err
				}
				i = end
			}
			if err = c.seal(); err != nil {
				return err
			}
			if err = c.processPending(); err != nil {
				return err
			}
			fmt.Fprintf(stdout, "durably replayed %d raw sampler rows\n", len(batch.Rows))
			return nil
		}
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer stop()
		return c.runLive(ctx)
	}
	if *output == "" {
		return fmt.Errorf("--output is required for encoding/sampling")
	}
	location, err := time.LoadLocation(*zone)
	if err != nil {
		return err
	}
	if *replay != "" {
		file, err := os.Open(*replay)
		if err != nil {
			return err
		}
		defer file.Close()
		rows, err := replayRaw(file, location)
		if err != nil {
			return err
		}
		n, err := encodeSampleRows(rows, *output, location, *rotation)
		if err == nil {
			fmt.Fprintf(stdout, "replayed raw inputs into %d Go sampler rows\n", n)
		}
		return err
	}
	if *sampleCount != 0 {
		host, err := os.Hostname()
		if err != nil {
			return err
		}
		c, err := configFromEnv(os.LookupEnv, host)
		if err != nil {
			return err
		}
		rows, context, err := sampleLive(*sampleCount, location, c)
		if err != nil {
			return err
		}
		n, err := encodeSampleRows(rows, *output, location, c.Rotation)
		if err != nil {
			return err
		}
		return json.NewEncoder(stdout).Encode(map[string]any{"kind": "bounded-live-go-sampler-diagnostic-not-paired-live-parity", "rows": n, "kernel_context": context})
	}
	file, err := os.Open(*input)
	if err != nil {
		return err
	}
	defer file.Close()
	n, err := encode(file, *output, location, *rotation)
	if err == nil {
		fmt.Fprintf(stdout, "encoded %d captured Python rows\n", n)
	}
	return err
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
