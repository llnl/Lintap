package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/parquet-go/parquet-go"
	"github.com/parquet-go/parquet-go/compress"
	"github.com/parquet-go/parquet-go/compress/brotli"
	"github.com/parquet-go/parquet-go/compress/gzip"
	"github.com/parquet-go/parquet-go/compress/lz4"
	"github.com/parquet-go/parquet-go/compress/snappy"
	"github.com/parquet-go/parquet-go/compress/uncompressed"
	"github.com/parquet-go/parquet-go/compress/zstd"
)

type collector struct {
	config   config
	location *time.Location
	lock     *os.File
	now      func() time.Time
	log      io.Writer
	// Tests inject interruption after completed durable transitions, not fake rows.
	checkpoint func(string) error
	sequence   uint64
}

func compressionCodec(name string) (compress.Codec, error) {
	switch strings.ToUpper(name) {
	case "ZSTD":
		return &zstd.Codec{}, nil
	case "SNAPPY":
		return &snappy.Codec{}, nil
	case "GZIP":
		return &gzip.Codec{}, nil
	case "LZ4_RAW", "LZ4":
		return &lz4.Codec{}, nil
	case "BROTLI":
		return &brotli.Codec{}, nil
	case "UNCOMPRESSED":
		return &uncompressed.Codec{}, nil
	default:
		return nil, fmt.Errorf("unsupported PIDSTAT_PARQUET_COMPRESSION %q (ZSTD, SNAPPY, GZIP, LZ4/LZ4_RAW, BROTLI, UNCOMPRESSED)", name)
	}
}

func syncDir(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
func removeFile(path string) error {
	err := os.Remove(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
func regularFile(path string) (os.FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("refusing nonregular file %s", path)
	}
	return info, nil
}
func atomicFile(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".pidstat-meta-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	_, err = f.Write(data)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(tmp, path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}
func fileHash(path string) (string, error) {
	if _, err := regularFile(path); err != nil {
		return "", err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
func newCollector(c config, zone *time.Location, log io.Writer) (*collector, error) {
	if c.Interval <= 0 || c.Rotation <= 0 || c.MaxBytes < 0 || c.MaxAge < 0 {
		return nil, fmt.Errorf("invalid collector cadence/caps")
	}
	if _, err := compressionCodec(c.Compression); err != nil {
		return nil, err
	}
	if c.Hostname == "" || c.Hostname == "." || c.Hostname == ".." || strings.ContainsAny(c.Hostname, "/\\\x00") {
		return nil, fmt.Errorf("invalid collector hostname")
	}
	if err := os.MkdirAll(c.SpoolDir, 0700); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(c.ParquetRoot, "raw_sensor", "pidstat"), 0700); err != nil {
		return nil, err
	}
	spool, err := filepath.EvalSymlinks(c.SpoolDir)
	if err != nil {
		return nil, err
	}
	raw, err := filepath.EvalSymlinks(filepath.Join(c.ParquetRoot, "raw_sensor"))
	if err != nil {
		return nil, err
	}
	spool, _ = filepath.Abs(spool)
	raw, _ = filepath.Abs(raw)
	rel, err := filepath.Rel(raw, spool)
	if err != nil {
		return nil, err
	}
	if rel == "." || (!strings.HasPrefix(rel, ".."+string(filepath.Separator)) && rel != "..") {
		return nil, fmt.Errorf("spool must stay outside uploader-swept raw_sensor")
	}
	lockPath := filepath.Join(spool, "collector.lock")
	fd, err := syscall.Open(lockPath, syscall.O_RDWR|syscall.O_CREAT|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	lock := os.NewFile(uintptr(fd), lockPath)
	if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, fmt.Errorf("spool already locked: %w", err)
	}
	c.SpoolDir = spool
	return &collector{config: c, location: zone, lock: lock, now: time.Now, log: log}, nil
}
func (c *collector) close() error {
	if c.lock == nil {
		return nil
	}
	err := c.lock.Close()
	c.lock = nil
	return err
}
func (c *collector) point(name string) error {
	if c.checkpoint != nil {
		return c.checkpoint(name)
	}
	return nil
}
func (c *collector) path(name string) string            { return filepath.Join(c.config.SpoolDir, name) }
func (c *collector) message(format string, args ...any) { fmt.Fprintf(c.log, format+"\n", args...) }
func (c *collector) writeMeta(path string, epoch int64) error {
	return atomicFile(path, []byte(fmt.Sprintf("window_start_epoch=%d\n", epoch)))
}
func readMeta(path string) (int64, error) {
	if _, err := regularFile(path); err != nil {
		return 0, err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok && key == "window_start_epoch" {
			return pythonDecimalInt(value)
		}
	}
	return 0, fmt.Errorf("missing window_start_epoch in %s", path)
}
func (c *collector) ensureMeta(spool, meta string) (int64, error) {
	if epoch, err := readMeta(meta); err == nil {
		return epoch, nil
	}
	f, err := os.Open(spool)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	reader := bufio.NewReader(f)
	line, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return 0, err
	}
	fields := strings.SplitN(strings.TrimSuffix(line, "\n"), "\t", 3)
	if len(fields) < 2 {
		return 0, fmt.Errorf("cannot infer window for %s", spool)
	}
	stamp, err := time.ParseInLocation("2006-01-02 15:04:05", fields[0]+" "+fields[1], c.location)
	if err != nil {
		return 0, err
	}
	epoch := windowForEpoch(stamp.Unix(), c.config.Rotation)
	if err = c.writeMeta(meta, epoch); err != nil {
		return 0, err
	}
	return epoch, nil
}

// A seal journal preserves both the pending name and window before moving either
// legacy file. It is replayed while the exclusive spool lock is held.
type sealJournal struct {
	Pending    string
	Epoch      int64
	SourceHash string
}

func (c *collector) finishSeal(j sealJournal) error {
	if filepath.Base(j.Pending) != j.Pending || !strings.HasPrefix(j.Pending, "pending-") || !strings.HasSuffix(j.Pending, ".tsv") {
		return fmt.Errorf("invalid seal journal")
	}
	pending := c.path(j.Pending)
	current := c.path("current.tsv")
	if _, err := regularFile(pending); errors.Is(err, os.ErrNotExist) {
		hash, err := fileHash(current)
		if err != nil {
			return err
		}
		if hash != j.SourceHash {
			return fmt.Errorf("seal source changed")
		}
		if err = os.Rename(current, pending); err != nil {
			return err
		}
		if err = syncDir(c.config.SpoolDir); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}
	if hash, err := fileHash(pending); err != nil || hash != j.SourceHash {
		return fmt.Errorf("seal pending hash mismatch: %v", err)
	}
	if err := c.point("seal-spool-moved"); err != nil {
		return err
	}
	if err := c.writeMeta(strings.TrimSuffix(pending, ".tsv")+".meta", j.Epoch); err != nil {
		return err
	}
	if err := c.point("seal-meta-written"); err != nil {
		return err
	}
	if _, err := os.Lstat(current); err == nil {
		return fmt.Errorf("unexpected current spool during seal recovery")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := removeFile(c.path("current.meta")); err != nil {
		return err
	}
	if err := removeFile(c.path("seal.json")); err != nil {
		return err
	}
	return syncDir(c.config.SpoolDir)
}
func (c *collector) recoverSeal() error {
	path := c.path("seal.json")
	if _, err := regularFile(path); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var j sealJournal
	if err = json.Unmarshal(b, &j); err != nil {
		return err
	}
	return c.finishSeal(j)
}
func (c *collector) seal() error {
	if err := c.recoverSeal(); err != nil {
		return err
	}
	spool := c.path("current.tsv")
	info, err := regularFile(spool)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Size() == 0 {
		if err = removeFile(spool); err != nil {
			return err
		}
		if err = removeFile(c.path("current.meta")); err != nil {
			return err
		}
		return syncDir(c.config.SpoolDir)
	}
	epoch, err := c.ensureMeta(spool, c.path("current.meta"))
	if err != nil {
		return err
	}
	hash, err := fileHash(spool)
	if err != nil {
		return err
	}
	var name string
	for {
		c.sequence++
		name = fmt.Sprintf("pending-%d-%d-%d-%d.tsv", epoch, c.now().Unix(), os.Getpid(), c.sequence)
		if _, err = os.Lstat(c.path(name)); errors.Is(err, os.ErrNotExist) {
			break
		} else if err != nil {
			return err
		}
	}
	j := sealJournal{name, epoch, hash}
	b, _ := json.Marshal(j)
	if err = atomicFile(c.path("seal.json"), b); err != nil {
		return err
	}
	if err = c.point("seal-journal-written"); err != nil {
		return err
	}
	return c.finishSeal(j)
}
func (c *collector) append(epoch int64, rows []string) error {
	if len(rows) == 0 {
		return nil
	}
	if err := c.recoverSeal(); err != nil {
		return err
	}
	desired := windowForEpoch(epoch, c.config.Rotation)
	spool, meta := c.path("current.tsv"), c.path("current.meta")
	info, err := regularFile(spool)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err == nil && info.Size() > 0 {
		active, err := c.ensureMeta(spool, meta)
		if err != nil {
			return err
		}
		if active != desired {
			if err = c.seal(); err != nil {
				return err
			}
			c.processPending()
		}
	}
	if _, err = regularFile(spool); errors.Is(err, os.ErrNotExist) {
		if err = c.writeMeta(meta, desired); err != nil {
			return err
		}
		f, err := os.OpenFile(spool, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return err
		}
		if err = f.Close(); err != nil {
			return err
		}
		if err = syncDir(c.config.SpoolDir); err != nil {
			return err
		}
	} else if err != nil {
		return err
	} else if info, err := os.Stat(spool); err != nil {
		return err
	} else if info.Size() == 0 {
		if err = c.writeMeta(meta, desired); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(spool, os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, row := range rows {
		if strings.ContainsAny(row, "\r\n") {
			return fmt.Errorf("invalid embedded spool newline")
		}
		if _, err = f.WriteString(row + "\n"); err != nil {
			return err
		}
	}
	return f.Sync()
}

type publication struct {
	SourceHash  string
	Destination string
	Active      string
	ParquetHash string
	Published   bool
}

func (c *collector) destination(epoch int64) (string, error) {
	stamp := time.Unix(epoch, 0).In(c.location)
	dir := filepath.Join(c.config.ParquetRoot, "raw_sensor", "pidstat", "dayPK="+stamp.Format("20060102"), "hourPK="+stamp.Format("15"))
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	base := fmt.Sprintf("%s+pidstat+%d", c.config.Hostname, epoch)
	path := filepath.Join(dir, base+".parquet")
	collisionEpoch := c.now().Unix()
	for {
		_, destErr := os.Lstat(path)
		_, activeErr := os.Lstat(path + ".active")
		if errors.Is(destErr, os.ErrNotExist) && errors.Is(activeErr, os.ErrNotExist) {
			return path, nil
		}
		if destErr != nil && !errors.Is(destErr, os.ErrNotExist) {
			return "", destErr
		}
		if activeErr != nil && !errors.Is(activeErr, os.ErrNotExist) {
			return "", activeErr
		}
		path = filepath.Join(dir, fmt.Sprintf("%s-%d-%d.parquet", base, collisionEpoch, os.Getpid()))
		collisionEpoch++ // Preserve two-number legacy suffix without overwriting same-second collisions.
	}
}
func (c *collector) savePublication(path string, p publication) error {
	b, _ := json.Marshal(p)
	return atomicFile(path, b)
}

func reserveActive(destination string) (string, error) {
	f, err := os.CreateTemp(filepath.Dir(destination), filepath.Base(destination)+".*.active")
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err = f.Close(); err != nil {
		return "", err
	}
	return path, nil
}

// Stream one legacy spool to one metadata-selected window (not row timestamps or
// row hostnames). This is the Python writer's destination ownership contract.
func (c *collector) writeSpool(spool, active string) error {
	input, err := os.Open(spool)
	if err != nil {
		return err
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil {
		return err
	}
	if info.Size() > 0 {
		var last [1]byte
		if _, err = input.ReadAt(last[:], info.Size()-1); err != nil {
			return err
		}
		if last[0] != '\n' {
			return fmt.Errorf("truncated spool: missing final newline")
		}
	}
	if _, err := regularFile(active); err != nil {
		return err
	}
	fd, err := syscall.Open(active, syscall.O_WRONLY|syscall.O_TRUNC|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), active)
	encodeErr := c.writeSpoolRows(input, f)
	syncErr := f.Sync()
	fileErr := f.Close()
	if encodeErr != nil || syncErr != nil || fileErr != nil {
		return fmt.Errorf("parquet file failed: encode=%v sync=%v close=%v", encodeErr, syncErr, fileErr)
	}
	return syncDir(filepath.Dir(active))
}

func (c *collector) writeSpoolRows(input io.Reader, output io.Writer) error {
	codec, _ := compressionCodec(c.config.Compression)
	writer := parquet.NewWriter(output, pythonSchema(), parquet.Compression(codec))
	reader := csv.NewReader(input)
	reader.Comma, reader.FieldsPerRecord, reader.LazyQuotes = '\t', 27, true
	var writeErr error
	count := 0
	for {
		fields, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeErr = err
			break
		}
		row, _, err := parseTSV(fields, c.location, c.config.Rotation, false)
		if err != nil {
			writeErr = err
			break
		}
		if n, err := writer.WriteRows([]parquet.Row{row}); err != nil || n != 1 {
			writeErr = fmt.Errorf("row write %d: %v", n, err)
			break
		}
		count++
	}
	closeErr := writer.Close()
	if writeErr != nil || count == 0 || closeErr != nil {
		return fmt.Errorf("conversion failed: rows=%d write=%v close=%v", count, writeErr, closeErr)
	}
	return nil
}
func (c *collector) convert(spool string) error {
	info, err := regularFile(spool)
	if err != nil {
		return err
	}
	meta := strings.TrimSuffix(spool, ".tsv") + ".meta"
	journal := strings.TrimSuffix(spool, ".tsv") + ".publish.json"
	if info.Size() == 0 {
		if err = removeFile(spool); err != nil {
			return err
		}
		if err = removeFile(meta); err != nil {
			return err
		}
		return syncDir(c.config.SpoolDir)
	}
	epoch, err := c.ensureMeta(spool, meta)
	if err != nil {
		return err
	}
	hash, err := fileHash(spool)
	if err != nil {
		return err
	}
	var p publication
	if _, err = regularFile(journal); err == nil {
		b, err := os.ReadFile(journal)
		if err != nil {
			return err
		}
		if err = json.Unmarshal(b, &p); err != nil {
			return err
		}
		if p.SourceHash != hash {
			return fmt.Errorf("publication source hash changed")
		}
		// Never follow an edited journal outside the configured pidstat tree.
		root, _ := filepath.Abs(filepath.Join(c.config.ParquetRoot, "raw_sensor", "pidstat"))
		dest, _ := filepath.Abs(p.Destination)
		rel, err := filepath.Rel(root, dest)
		active, _ := filepath.Abs(p.Active)
		if err != nil || strings.HasPrefix(rel, "..") || !strings.HasSuffix(dest, ".parquet") || filepath.Dir(active) != filepath.Dir(dest) || !strings.HasSuffix(active, ".active") {
			return fmt.Errorf("invalid publication destination")
		}
	} else if errors.Is(err, os.ErrNotExist) {
		p.SourceHash = hash
		p.Destination, err = c.destination(epoch)
		if err != nil {
			return err
		}
		p.Active, err = reserveActive(p.Destination)
		if err != nil {
			return err
		}
		if err = c.savePublication(journal, p); err != nil {
			return err
		}
	} else {
		return err
	}
	active := p.Active
	if !p.Published {
		if destInfo, err := regularFile(p.Destination); err == nil {
			activeInfo, activeErr := regularFile(active)
			// A matching content hash alone is insufficient: two independent
			// spools can contain identical rows that must preserve multiplicity.
			if p.ParquetHash != "" && activeErr == nil && os.SameFile(destInfo, activeInfo) {
				hash, err := fileHash(active)
				if err != nil {
					return err
				}
				if hash != p.ParquetHash {
					return fmt.Errorf("published active hash changed")
				}
				p.Published = true
			} else {
				p.Destination, err = c.destination(epoch)
				if err != nil {
					return err
				}
				if err = c.savePublication(journal, p); err != nil {
					return err
				}
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if !p.Published && p.ParquetHash != "" {
			// An existing owned active may be partial or from a pre-publication
			// interruption. Rewrite it; never remove another collector's active.
			p.ParquetHash = ""
		}
		if !p.Published {
			if _, err = regularFile(active); errors.Is(err, os.ErrNotExist) {
				p.Active, err = reserveActive(p.Destination)
				if err != nil {
					return err
				}
				active = p.Active
			} else if err != nil {
				return err
			}
			if err = c.savePublication(journal, p); err != nil {
				return err
			}
			if err = c.writeSpool(spool, active); err != nil {
				removeFile(active)
				return err
			}
			p.ParquetHash, err = fileHash(active)
			if err != nil {
				return err
			}
			if err = c.savePublication(journal, p); err != nil {
				return err
			}
			if err = c.point("publication-ready"); err != nil {
				return err
			}
			// Hard-link installation is atomic, same-filesystem, no-replace. Keep
			// .active until the published receipt is durable; the uploader ignores it.
			if err = os.Link(active, p.Destination); err != nil {
				return err
			}
			if err = syncDir(filepath.Dir(p.Destination)); err != nil {
				return err
			}
			if err = c.point("publication-linked"); err != nil {
				return err
			}
			p.Published = true
		}
		if err = c.savePublication(journal, p); err != nil {
			return err
		}
	}
	if err = c.point("publication-recorded"); err != nil {
		return err
	}
	if err = removeFile(active); err != nil {
		return err
	}
	if err = removeFile(spool); err != nil {
		return err
	}
	if err = c.point("publication-spool-removed"); err != nil {
		return err
	}
	if err = removeFile(meta); err != nil {
		return err
	}
	if err = removeFile(journal); err != nil {
		return err
	}
	if err = syncDir(c.config.SpoolDir); err != nil {
		return err
	}
	c.message("wrote %s", p.Destination)
	return c.enforceCaps()
}
func (c *collector) processPending() error {
	paths, err := filepath.Glob(c.path("pending-*.tsv"))
	if err != nil {
		return err
	}
	var failures []error
	for _, path := range paths {
		if err = c.convert(path); err != nil {
			c.message("WARN: retained %s for retry: %v", path, err)
			failures = append(failures, err)
		}
	}
	return errors.Join(failures...)
}
func (c *collector) prepareRecovery() error {
	if err := c.recoverSeal(); err != nil {
		return err
	}
	// Finish cleanup after a crash between source unlink and receipt unlink. The
	// durable Published state remains authoritative if the uploader took the file.
	journals, err := filepath.Glob(c.path("pending-*.publish.json"))
	if err != nil {
		return err
	}
	for _, path := range journals {
		spool := strings.TrimSuffix(path, ".publish.json") + ".tsv"
		if _, err := os.Lstat(spool); errors.Is(err, os.ErrNotExist) {
			b, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			var p publication
			if err = json.Unmarshal(b, &p); err != nil {
				return err
			}
			if !p.Published {
				return fmt.Errorf("unpublished receipt without source: %s", path)
			}
			if err = removeFile(strings.TrimSuffix(spool, ".tsv") + ".meta"); err != nil {
				return err
			}
			if err = removeFile(path); err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
	}
	if err := c.seal(); err != nil {
		return err
	}
	return nil
}

func (c *collector) salvage() error {
	if err := c.prepareRecovery(); err != nil {
		return err
	}
	return c.processPending()
}
func (c *collector) enforceCaps() error {
	type entry struct {
		path     string
		size     int64
		modified time.Time
	}
	files := []entry{}
	root := filepath.Join(c.config.ParquetRoot, "raw_sensor", "pidstat")
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if d.Type()&os.ModeSymlink != 0 {
			return nil
		}
		if d.IsDir() || !strings.HasSuffix(path, ".parquet") {
			return nil
		}
		info, err := regularFile(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		files = append(files, entry{path, info.Size(), info.ModTime()})
		return nil
	})
	if err != nil {
		return err
	}
	sort.Slice(files, func(i, j int) bool {
		if files[i].modified.Equal(files[j].modified) {
			return files[i].path < files[j].path
		}
		return files[i].modified.Before(files[j].modified)
	})
	remaining := []entry{}
	var total int64
	for _, f := range files {
		if c.config.MaxAge > 0 && c.now().Sub(f.modified).Seconds() > float64(c.config.MaxAge) {
			if err = removeFile(f.path); err != nil {
				return err
			}
			c.message("dropping stale pidstat %s", f.path)
			continue
		}
		remaining = append(remaining, f)
		total += f.size
	}
	for _, f := range remaining {
		if c.config.MaxBytes <= 0 || total <= c.config.MaxBytes {
			break
		}
		if err = removeFile(f.path); err != nil {
			return err
		}
		total -= f.size
		c.message("dropping pidstat for byte cap %s", f.path)
	}
	return nil
}

func (c *collector) runLive(ctx context.Context) error {
	ticks, page, err := kernelContext()
	if err != nil {
		return err
	}
	s, err := newSampler(diskProc{"/proc"}, c.config.Hostname, ticks, page)
	if err != nil {
		return err
	}
	// A failed pending conversion is retained/reported and does not prevent new
	// valid windows. An ambiguous current/seal transition is fatal, not overwritten.
	if err = c.prepareRecovery(); err != nil {
		return err
	}
	c.processPending()
	origin := time.Now()
	next := origin
	for ctx.Err() == nil {
		stamp := time.Now()
		rows, err := s.sample(stamp.Sub(origin).Seconds(), wallFromEpoch(float64(stamp.Unix())+float64(stamp.Nanosecond())/1e9, c.location))
		if err != nil {
			return err
		}
		if err = c.append(stamp.Unix(), rows); err != nil {
			return err
		}
		next = next.Add(time.Duration(c.config.Interval) * time.Second)
		// Skip expired schedule slots instead of busy-looping to catch up.
		if !next.After(time.Now()) {
			next = time.Now().Add(time.Duration(c.config.Interval) * time.Second)
		}
		timer := time.NewTimer(time.Until(next))
		select {
		case <-ctx.Done():
			timer.Stop()
		case <-timer.C:
		}
	}
	c.message("received shutdown; sealing current spool")
	if err = c.seal(); err != nil {
		return err
	}
	return c.processPending()
}
