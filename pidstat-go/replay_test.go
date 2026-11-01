package main

import (
	"encoding/json"
	"math"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReplayUsesRawInputsNotNormalizedSnapshots(t *testing.T) {
	text := func(value string) *string { return &value }
	reads := func(user int64) map[string]*string {
		return map[string]*string{
			"/proc/1/stat": text(statFixture(1, 10, user, 0, 0)), "/proc/1/status": text("Uid: 0\n"),
			"/proc/1/io": nil, "/proc/1/schedstat": nil, "/proc/1/cgroup": nil,
		}
	}
	samples := []map[string]any{}
	for index, user := range []int64{100, 200} {
		samples = append(samples, map[string]any{
			"captured_at": 1793420400 + index, "reads": reads(user), "pid_ns_links": map[string]*string{"/proc/1/ns/pid": nil},
			"proc_pid_enumerations": [][]string{{"1"}}, "snapshots": []any{"deliberately-wrong"}, "output_rows": 999,
		})
	}
	capture := map[string]any{"initial_reads": map[string]*string{"/proc/meminfo": text("MemTotal: 1000 kB")}, "clock_ticks": 100, "page_size_bytes": 4096, "hostname": "host", "samples": samples, "golden.tsv": "fabricated-unused"}
	replay := func() (sampleBatch, error) {
		data, _ := json.Marshal(capture)
		return replayRaw(strings.NewReader(string(data)), time.UTC)
	}
	rows, err := replay()
	if err != nil || len(rows.Rows) != 1 || strings.Split(rows.Rows[0], "\t")[4] != "100.00" {
		t.Fatal(rows, err)
	}
	samples[1]["reads"] = reads(300)
	rows, err = replay()
	if err != nil || strings.Split(rows.Rows[0], "\t")[4] != "200.00" {
		t.Fatal("raw counter change not propagated", rows, err)
	}
	delete(samples[1]["reads"].(map[string]*string), "/proc/1/io")
	if _, err := replay(); err == nil || !strings.Contains(err.Error(), "uncaptured") {
		t.Fatal("uncaptured input accepted", err)
	}
}

func TestReplayValidationAndDiagnosticBoundaries(t *testing.T) {
	for _, input := range []string{"{}", "{bad}", "{} {}"} {
		if _, err := replayRaw(strings.NewReader(input), time.UTC); err == nil {
			t.Fatal(input)
		}
	}
	for _, count := range []int{0, 1, 13} {
		if _, _, err := sampleLive(count, time.UTC, config{Interval: 1}); err == nil {
			t.Fatal(count)
		}
	}
	if _, _, err := sampleLive(2, time.UTC, config{Interval: 31}); err == nil {
		t.Fatal("unbounded interval")
	}
}

func TestPythonTimestampRoundingAndSourceWindow(t *testing.T) {
	zone, err := time.LoadLocation("America/Phoenix")
	if err != nil {
		t.Fatal(err)
	}
	epoch := 1793429999.9999998
	wall := wallFromEpoch(epoch, zone)
	if wall.Format("2006-01-02 15:04:05.000000") != "2026-10-31 00:00:00.000000" {
		t.Fatal(wall)
	}
	if windowForEpoch(int64(epoch), 300) != 1793429700 {
		t.Fatal("source epoch window changed")
	}
	if wallFromEpoch(-0.00000075, time.UTC).UnixMicro() != -1 {
		t.Fatal("negative epoch rounding")
	}
	if windowForEpoch(1793429999, math.MaxInt64) != 0 {
		t.Fatal("rotation addition overflow")
	}
	fields := fixture()
	fields[0], fields[1], fields[22] = "2026-10-31", "00:00:00", "host"
	batch := sampleBatch{Rows: []string{strings.Join(fields, "\t")}, Epochs: []int64{int64(epoch)}}
	root := filepath.Join(t.TempDir(), "output")
	if n, err := encodeSampleRows(batch, root, zone, 300); err != nil || n != 1 {
		t.Fatal(n, err)
	}
	files, _ := filepath.Glob(filepath.Join(root, "raw_sensor/pidstat/dayPK=20261030/hourPK=23/host+pidstat+1793429700.parquet"))
	if len(files) != 1 {
		t.Fatal("rounded timestamp changed partition", files)
	}
	if _, err := encodeWithEpochs(strings.NewReader(batch.Rows[0]+"\n"), filepath.Join(t.TempDir(), "bad"), zone, 300, []int64{}); err == nil {
		t.Fatal("missing source epoch accepted")
	}
}
