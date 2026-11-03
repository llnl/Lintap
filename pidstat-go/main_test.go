package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/parquet-go/parquet-go"
	"github.com/parquet-go/parquet-go/deprecated"
)

func fixture() []string {
	return strings.Split("2026-10-30\t21:00:00\t0\t123\t12.35\t0.00\t0.00\t0.00\t250.12\t3\t0.00\t0.00\t814169220\t1892724\t0.48\t-1.00\t12.34\t0.00\t0\t0.00\t0.00\tworker\thost\t/\t4026531836\t\t", "\t")
}

func TestProductionSchema(t *testing.T) {
	schema := pythonSchema()
	names := strings.Split("time uid pid usr_percent system_percent guest_percent wait_percent cpu_percent cpu_core minflt_per_sec majflt_per_sec vsz_kb rss_kb mem_percent kb_read_per_sec kb_write_per_sec kb_cancelled_write_per_sec iodelay_ticks context_switch_per_sec nonvoluntary_context_switch_per_sec command hostname cgroup_path pid_ns_inode container_runtime container_id", " ")
	if len(schema.Fields()) != 26 {
		t.Fatal("column count")
	}
	for i, field := range schema.Fields() {
		if field.Name() != names[i] || !field.Optional() {
			t.Fatalf("column %d: %s", i, field.Name())
		}
		if i != 0 && field.Type().LogicalType() != nil {
			t.Fatalf("unexpected modern annotation: %s", field.Name())
		}
	}
	stamp := schema.Fields()[0].Type().LogicalType().Value
	if !strings.Contains(schema.Fields()[0].Type().String(), "TIMESTAMP") || stamp == nil {
		t.Fatal("timestamp annotation")
	}
	for _, i := range []int{1, 2, 8, 17} {
		field := schema.Fields()[i]
		if field.Type().Kind() != parquet.Int32 || *field.Type().ConvertedType() != deprecated.Int32 {
			t.Fatal(field.Name())
		}
	}
}

func TestCapturedDecimalWidthsNullsAndNaiveTime(t *testing.T) {
	zone, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	row, key, err := parseRow(fixture(), zone, 300)
	if err != nil {
		t.Fatal(err)
	}
	if len(row) != 26 || row[7].Float() != float32(250.12) || row[14].Float() != -1 {
		t.Fatal(row)
	}
	if row[23].Int64() != 4026531836 || !row[24].IsNull() || !row[25].IsNull() {
		t.Fatal("nullable attribution")
	}
	naive, _ := time.Parse("2006-01-02 15:04:05", "2026-10-30 21:00:00")
	if row[0].Int64() != naive.UnixMicro() || key.host != "host" || time.Unix(key.epoch, 0).In(zone).Hour() != 21 {
		t.Fatal("wall time/window")
	}
	fields := fixture()
	fields[21] = ""
	row, _, err = parseRow(fields, zone, 300)
	if err != nil || !row[20].IsNull() {
		t.Fatal("empty CSV text must retain Python null semantics")
	}
}

func TestMalformedInputAndPathSafety(t *testing.T) {
	for _, edit := range []func([]string) []string{
		func(f []string) []string { return f[:26] },
		func(f []string) []string { f[2] = "2147483648"; return f },
		func(f []string) []string { f[4] = "NaN"; return f },
		func(f []string) []string { f[0] = "bad-date"; return f },
		func(f []string) []string { f[22] = "../escape"; return f },
	} {
		if _, _, err := parseRow(edit(fixture()), time.UTC, 300); err == nil {
			t.Fatal("accepted invalid row")
		}
	}
	root := filepath.Join(t.TempDir(), "output")
	if _, err := encode(strings.NewReader("invalid\n"), root, time.UTC, 300); err == nil {
		t.Fatal("invalid input")
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatal("invalid input created output")
	}
	if _, err := encode(strings.NewReader(""), root, time.UTC, 300); err == nil {
		t.Fatal("empty input")
	}
	if _, err := encode(strings.NewReader(""), root, time.UTC, 0); err == nil {
		t.Fatal("zero rotation")
	}
}

func TestEncodeDuplicatesWindowsAndNoOverwrite(t *testing.T) {
	root := filepath.Join(t.TempDir(), "output")
	a, b := fixture(), fixture()
	b[1] = "21:05:00"
	input := strings.Join(a, "\t") + "\n" + strings.Join(a, "\t") + "\n" + strings.Join(b, "\t") + "\n"
	n, err := encode(strings.NewReader(input), root, time.UTC, 300)
	if err != nil || n != 3 {
		t.Fatalf("%d %v", n, err)
	}
	files, _ := filepath.Glob(filepath.Join(root, "raw_sensor/pidstat/dayPK=20261030/hourPK=21/*.parquet"))
	if len(files) != 2 {
		t.Fatal(files)
	}
	var total int64
	for _, path := range files {
		file, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		stat, _ := file.Stat()
		parquetFile, err := parquet.OpenFile(file, stat.Size())
		if err != nil {
			t.Fatal(err)
		}
		total += parquetFile.NumRows()
		for _, group := range parquetFile.Metadata().RowGroups {
			for _, column := range group.Columns {
				if column.MetaData.Codec.String() != "ZSTD" {
					t.Fatal("compression")
				}
			}
		}
		file.Close()
		if _, err := os.Stat(path + ".active"); !os.IsNotExist(err) {
			t.Fatal("active file published")
		}
	}
	if total != 3 {
		t.Fatal(total)
	}
	if _, err := encode(strings.NewReader(input), root, time.UTC, 300); err == nil {
		t.Fatal("overwrote existing output")
	}
}

func TestHelpAndRequiredArguments(t *testing.T) {
	var out, errOut bytes.Buffer
	if err := run([]string{"--help"}, &out, &errOut); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(errOut.String(), "not packaged or deployed") {
		t.Fatal("missing deployment warning")
	}
	if err := run(nil, &out, &errOut); err == nil {
		t.Fatal("missing arguments")
	}
}
