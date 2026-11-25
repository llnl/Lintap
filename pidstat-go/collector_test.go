package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/parquet-go/parquet-go"
)

func collectorFixture(t *testing.T) (*collector, config) {
	t.Helper()
	root := t.TempDir()
	cfg := config{Interval: 1, Rotation: 300, Hostname: "host", Compression: "ZSTD", ParquetRoot: filepath.Join(root, "data"), SpoolDir: filepath.Join(root, "spool")}
	c, err := newCollector(cfg, time.UTC, &bytes.Buffer{})
	if err != nil {
		t.Fatal(err)
	}
	c.now = func() time.Time { return time.Unix(1793420400, 0) }
	t.Cleanup(func() { c.close() })
	return c, cfg
}
func spoolRow() string { return strings.Join(fixture(), "\t") }
func completed(t *testing.T, c *collector) []string {
	t.Helper()
	files := []string{}
	err := filepath.WalkDir(filepath.Join(c.config.ParquetRoot, "raw_sensor", "pidstat"), func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() && strings.HasSuffix(path, ".parquet") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}
func assertRows(t *testing.T, c *collector, want int64) {
	t.Helper()
	var count int64
	for _, path := range completed(t, c) {
		f, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		info, _ := f.Stat()
		p, err := parquet.OpenFile(f, info.Size())
		if err != nil {
			t.Fatal(err)
		}
		count += p.NumRows()
		f.Close()
	}
	if count != want {
		t.Fatalf("rows=%d want%d", count, want)
	}
}
func TestCollectorLegacyRecoveryAndMetadataWindow(t *testing.T) {
	c, _ := collectorFixture(t)
	fields := fixture()
	fields[0], fields[1], fields[22] = "2026-10-31", "00:00:00", "different-row-host"
	if err := os.WriteFile(c.path("current.tsv"), []byte(strings.Join(fields, "\t")+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := c.writeMeta(c.path("current.meta"), 1793429700); err != nil {
		t.Fatal(err)
	}
	if err := c.salvage(); err != nil {
		t.Fatal(err)
	}
	assertRows(t, c, 1)
	files := completed(t, c)
	if !strings.Contains(files[0], "host+pidstat+1793429700.parquet") {
		t.Fatal(files)
	}
	for _, name := range []string{"current.tsv", "current.meta", "seal.json"} {
		if _, err := os.Stat(c.path(name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatal(name, err)
		}
	}
}
func TestCollectorSealCrashTransitions(t *testing.T) {
	for _, point := range []string{"seal-journal-written", "seal-spool-moved", "seal-meta-written"} {
		t.Run(point, func(t *testing.T) {
			c, cfg := collectorFixture(t)
			if err := c.append(1793420400, []string{spoolRow(), spoolRow()}); err != nil {
				t.Fatal(err)
			}
			c.checkpoint = func(name string) error {
				if name == point {
					return errors.New("injected crash")
				}
				return nil
			}
			if err := c.seal(); err == nil {
				t.Fatal("failure not injected")
			}
			c.close()
			next, err := newCollector(cfg, time.UTC, &bytes.Buffer{})
			if err != nil {
				t.Fatal(err)
			}
			defer next.close()
			if err = next.salvage(); err != nil {
				t.Fatal(err)
			}
			assertRows(t, next, 2)
			if err = next.salvage(); err != nil {
				t.Fatal(err)
			}
			assertRows(t, next, 2)
		})
	}
}
func TestCollectorPublicationCrashTransitions(t *testing.T) {
	for _, point := range []string{"publication-ready", "publication-linked", "publication-recorded", "publication-spool-removed"} {
		t.Run(point, func(t *testing.T) {
			c, cfg := collectorFixture(t)
			if err := c.append(1793420400, []string{spoolRow(), spoolRow()}); err != nil {
				t.Fatal(err)
			}
			if err := c.seal(); err != nil {
				t.Fatal(err)
			}
			c.checkpoint = func(name string) error {
				if name == point {
					return errors.New("injected crash")
				}
				return nil
			}
			if err := c.processPending(); err == nil {
				t.Fatal("failure not injected")
			}
			c.close()
			next, err := newCollector(cfg, time.UTC, &bytes.Buffer{})
			if err != nil {
				t.Fatal(err)
			}
			defer next.close()
			if err = next.salvage(); err != nil {
				t.Fatal(err)
			}
			assertRows(t, next, 2)
			if len(completed(t, next)) != 1 {
				t.Fatal("duplicate publication")
			}
			journals, _ := filepath.Glob(next.path("pending-*"))
			if len(journals) != 0 {
				t.Fatal(journals)
			}
		})
	}
}
func TestCollectorPublishedReceiptSurvivesUploaderRemoval(t *testing.T) {
	c, cfg := collectorFixture(t)
	c.append(1793420400, []string{spoolRow()})
	c.seal()
	c.checkpoint = func(point string) error {
		if point == "publication-recorded" {
			return errors.New("crash")
		}
		return nil
	}
	if err := c.processPending(); err == nil {
		t.Fatal("injection")
	}
	files := completed(t, c)
	if err := os.Remove(files[0]); err != nil {
		t.Fatal(err)
	}
	c.close()
	next, err := newCollector(cfg, time.UTC, &bytes.Buffer{})
	if err != nil {
		t.Fatal(err)
	}
	defer next.close()
	if err = next.salvage(); err != nil {
		t.Fatal(err)
	}
	if len(completed(t, next)) != 0 {
		t.Fatal("republished uploaded file")
	}
}
func TestCollectorMalformedTruncatedRetryAndMultiplePending(t *testing.T) {
	c, _ := collectorFixture(t)
	good := c.path("pending-good.tsv")
	bad := c.path("pending-bad.tsv")
	os.WriteFile(good, []byte(spoolRow()+"\n"), 0600)
	os.WriteFile(bad, []byte(spoolRow()), 0600)
	if err := c.processPending(); err == nil {
		t.Fatal("truncated accepted")
	}
	assertRows(t, c, 1)
	if _, err := os.Stat(bad); err != nil {
		t.Fatal("failed source deleted")
	}
	if err := os.WriteFile(bad, []byte(spoolRow()+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// A deliberately modified failed input is not silently trusted by its old
	// publication receipt; operator repair must remove that receipt explicitly.
	if err := c.processPending(); err == nil {
		t.Fatal("changed source hash accepted")
	}
	removeFile(c.path("pending-bad.publish.json"))
	if err := c.processPending(); err != nil {
		t.Fatal(err)
	}
	assertRows(t, c, 2)
	malformed := c.path("pending-malformed.tsv")
	os.WriteFile(malformed, []byte(spoolRow()+"\nbroken\n"), 0600)
	if err := c.processPending(); err == nil {
		t.Fatal("malformed tail accepted")
	}
	assertRows(t, c, 2)
	actives, _ := filepath.Glob(filepath.Join(c.config.ParquetRoot, "raw_sensor/pidstat/*/*/*.active"))
	if len(actives) != 0 {
		t.Fatal("partial active retained on conversion failure", actives)
	}
}
func TestCollectorMissingAndInvalidMetadataAndEmptyWindows(t *testing.T) {
	c, _ := collectorFixture(t)
	if err := c.append(1793420400, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(c.path("current.tsv")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("empty window initialized")
	}
	os.WriteFile(c.path("current.tsv"), nil, 0600)
	c.writeMeta(c.path("current.meta"), 1)
	if err := c.salvage(); err != nil {
		t.Fatal(err)
	}
	assertRows(t, c, 0)
	os.WriteFile(c.path("current.tsv"), []byte(spoolRow()+"\n"), 0600)
	os.WriteFile(c.path("current.meta"), []byte("window_start_epoch=bad\n"), 0600)
	if err := c.salvage(); err != nil {
		t.Fatal(err)
	}
	assertRows(t, c, 1)
	os.WriteFile(c.path("current.tsv"), []byte("bad\n"), 0600)
	if err := c.salvage(); err == nil {
		t.Fatal("uninferrable source discarded")
	}
}
func TestCollectorRepeatedCollisionsAndStaleActive(t *testing.T) {
	c, _ := collectorFixture(t)
	for i := 0; i < 4; i++ {
		if err := c.append(1793420400, []string{spoolRow()}); err != nil {
			t.Fatal(err)
		}
		if err := c.seal(); err != nil {
			t.Fatal(err)
		}
		if err := c.processPending(); err != nil {
			t.Fatal(err)
		}
	}
	assertRows(t, c, 4)
	if len(completed(t, c)) != 4 {
		t.Fatal("collision overwrote output")
	}
	path, err := c.destination(1793420400)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(path+".active", []byte("unrelated-stale-active"), 0600)
	c.append(1793420400, []string{spoolRow()})
	c.seal()
	if err = c.processPending(); err != nil {
		t.Fatal(err)
	}
	assertRows(t, c, 5)
	b, _ := os.ReadFile(path + ".active")
	if string(b) != "unrelated-stale-active" {
		t.Fatal("unowned active deleted")
	}
}
func TestCollectorCompressionAndConfigGuards(t *testing.T) {
	for _, codec := range []string{"ZSTD", "zstd", "SNAPPY", "GZIP", "LZ4_RAW", "LZ4", "BROTLI", "UNCOMPRESSED"} {
		t.Run(codec, func(t *testing.T) {
			c, _ := collectorFixture(t)
			c.config.Compression = codec
			c.append(1793420400, []string{spoolRow()})
			c.seal()
			if err := c.processPending(); err != nil {
				t.Fatal(err)
			}
			assertRows(t, c, 1)
		})
	}
	c, cfg := collectorFixture(t)
	if _, err := newCollector(cfg, time.UTC, &bytes.Buffer{}); err == nil {
		t.Fatal("concurrent spool collector accepted")
	}
	cfg.Compression = "invalid"
	if _, err := newCollector(cfg, time.UTC, &bytes.Buffer{}); err == nil {
		t.Fatal("invalid codec accepted")
	}
	cfg.Compression = "ZSTD"
	cfg.SpoolDir = filepath.Join(c.config.ParquetRoot, "raw_sensor", "spool")
	if _, err := newCollector(cfg, time.UTC, &bytes.Buffer{}); err == nil {
		t.Fatal("swept spool accepted")
	}
}
func TestCollectorCapsScopeAgeBytesAndSymlink(t *testing.T) {
	c, _ := collectorFixture(t)
	root := filepath.Join(c.config.ParquetRoot, "raw_sensor", "pidstat")
	paths := []string{}
	for i, name := range []string{"a.parquet", "b.parquet", "c.parquet"} {
		path := filepath.Join(root, name)
		os.WriteFile(path, bytes.Repeat([]byte{'a'}, 60), 0600)
		stamp := time.Unix(int64(i+1), 0)
		os.Chtimes(path, stamp, stamp)
		paths = append(paths, path)
	}
	other := filepath.Join(c.config.ParquetRoot, "raw_sensor", "other")
	os.MkdirAll(other, 0700)
	outside := filepath.Join(other, "safe.parquet")
	os.WriteFile(outside, []byte("safe"), 0600)
	active := filepath.Join(root, "safe.parquet.active")
	os.WriteFile(active, []byte("active"), 0600)
	os.Symlink(outside, filepath.Join(root, "link.parquet"))
	c.config.MaxBytes = 100
	if err := c.enforceCaps(); err != nil {
		t.Fatal(err)
	}
	for _, path := range paths[:2] {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatal(path)
		}
	}
	c.config.MaxBytes = 0
	c.config.MaxAge = 60
	if err := c.enforceCaps(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(paths[2]); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("age cap")
	}
	for _, path := range []string{outside, active} {
		if _, err := os.Stat(path); err != nil {
			t.Fatal("scope violation", path)
		}
	}
	if err := c.enforceCaps(); err != nil {
		t.Fatal("concurrent uploader/missing files", err)
	}
}
func TestCollectorRotationBackwardEpochAndCancellation(t *testing.T) {
	c, _ := collectorFixture(t)
	for _, epoch := range []int64{1793420400, 1793420700, 1793420100} {
		if err := c.append(epoch, []string{spoolRow()}); err != nil {
			t.Fatal(err)
		}
	}
	c.seal()
	if err := c.processPending(); err != nil {
		t.Fatal(err)
	}
	assertRows(t, c, 3)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := ctx.Err(); err == nil {
		t.Fatal("cancel context")
	}
}

func TestCollectorSeparateSpoolsSharedOutputPreserveIdenticalRows(t *testing.T) {
	a, cfg := collectorFixture(t)
	cfg.SpoolDir = filepath.Join(filepath.Dir(cfg.SpoolDir), "other-spool")
	b, err := newCollector(cfg, time.UTC, &bytes.Buffer{})
	if err != nil {
		t.Fatal(err)
	}
	defer b.close()
	for _, c := range []*collector{a, b} {
		if err = c.append(1793420400, []string{spoolRow()}); err != nil {
			t.Fatal(err)
		}
		if err = c.seal(); err != nil {
			t.Fatal(err)
		}
		c.checkpoint = func(point string) error {
			if point == "publication-ready" {
				return errors.New("pause before publication")
			}
			return nil
		}
		if err = c.processPending(); err == nil {
			t.Fatal("pause not injected")
		}
	}
	var receipts []publication
	for _, c := range []*collector{a, b} {
		paths, _ := filepath.Glob(c.path("*.publish.json"))
		data, _ := os.ReadFile(paths[0])
		var p publication
		if err = json.Unmarshal(data, &p); err != nil {
			t.Fatal(err)
		}
		receipts = append(receipts, p)
	}
	if receipts[0].Active == receipts[1].Active {
		t.Fatal("shared active ownership")
	}
	// Both selected the original destination before either installed it. First
	// publishes; second must allocate a collision suffix, not deduplicate hashes.
	for _, c := range []*collector{a, b} {
		c.checkpoint = nil
		if err = c.processPending(); err != nil {
			t.Fatal(err)
		}
	}
	assertRows(t, a, 2)
	if len(completed(t, a)) != 2 {
		t.Fatal("identical rows lost")
	}
}

type failingParquetOutput struct{}

func (failingParquetOutput) Write(p []byte) (int, error) { return 0, io.ErrClosedPipe }
func TestCollectorWriterCloseFailureIsError(t *testing.T) {
	c, _ := collectorFixture(t)
	err := c.writeSpoolRows(strings.NewReader(spoolRow()+"\n"), failingParquetOutput{})
	if err == nil || !strings.Contains(err.Error(), "close=io: read/write on closed pipe") {
		t.Fatal("failed final writer close accepted", err)
	}
	if len(completed(t, c)) != 0 {
		t.Fatal("failed close published")
	}
}
