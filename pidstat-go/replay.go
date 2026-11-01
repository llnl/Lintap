package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type captureSample struct {
	CapturedAt   float64            `json:"captured_at"`
	Reads        map[string]*string `json:"reads"`
	Links        map[string]*string `json:"pid_ns_links"`
	Enumerations [][]string         `json:"proc_pid_enumerations"`
}
type rawCapture struct {
	InitialReads map[string]*string `json:"initial_reads"`
	Samples      []captureSample    `json:"samples"`
	Hostname     string             `json:"hostname"`
	ClockTicks   int64              `json:"clock_ticks"`
	PageBytes    int64              `json:"page_size_bytes"`
}

type sampleBatch struct {
	Rows   []string
	Epochs []int64
}
type replayProc struct {
	reads, links map[string]*string
	names        []string
	missing      []string
}

func (r *replayProc) read(name string) (string, bool) {
	v, ok := r.reads["/proc/"+name]
	if !ok {
		r.missing = append(r.missing, "read:"+name)
	}
	if v == nil {
		return "", false
	}
	return *v, true
}
func (r *replayProc) link(name string) (string, bool) {
	v, ok := r.links["/proc/"+name]
	if !ok {
		r.missing = append(r.missing, "link:"+name)
	}
	if v == nil {
		return "", false
	}
	return *v, true
}
func (r *replayProc) pids() ([]string, error) { return append([]string(nil), r.names...), nil }

func wallFromEpoch(epoch float64, location *time.Location) time.Time {
	seconds, fraction := math.Modf(epoch)
	// datetime.fromtimestamp rounds to microseconds, including second carry.
	// Keep the unrounded source epoch separately for rotation-window membership.
	return time.Unix(int64(seconds), int64(math.RoundToEven(fraction*1e6))*1000).In(location)
}
func replayRaw(input io.Reader, location *time.Location) (sampleBatch, error) {
	var capture rawCapture
	decoder := json.NewDecoder(input)
	if err := decoder.Decode(&capture); err != nil {
		return sampleBatch{}, err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return sampleBatch{}, fmt.Errorf("unexpected trailing capture content")
	}
	if len(capture.Samples) < 2 {
		return sampleBatch{}, fmt.Errorf("capture needs baseline and subsequent samples")
	}
	proc := &replayProc{reads: capture.InitialReads}
	s, err := newSampler(proc, capture.Hostname, capture.ClockTicks, capture.PageBytes)
	if err != nil {
		return sampleBatch{}, err
	}
	all := sampleBatch{}
	for index, sample := range capture.Samples {
		if len(sample.Enumerations) != 1 {
			return sampleBatch{}, fmt.Errorf("sample %d needs exactly one observed PID enumeration", index)
		}
		if math.IsNaN(sample.CapturedAt) || math.IsInf(sample.CapturedAt, 0) {
			return sampleBatch{}, fmt.Errorf("invalid sample time")
		}
		proc.reads, proc.links, proc.names = sample.Reads, sample.Links, sample.Enumerations[0]
		rows, err := s.sample(sample.CapturedAt, wallFromEpoch(sample.CapturedAt, location))
		if err != nil {
			return sampleBatch{}, err
		}
		if len(proc.missing) > 0 {
			return sampleBatch{}, fmt.Errorf("sample %d requests uncaptured raw inputs: %v", index, proc.missing)
		}
		all.Rows = append(all.Rows, rows...)
		for range rows {
			all.Epochs = append(all.Epochs, int64(sample.CapturedAt))
		}
	}
	return all, nil
}

// Bounded diagnostics only: no default daemon, durable spool, caps or services.
func sampleLive(count int, location *time.Location, c config) (sampleBatch, map[string]int64, error) {
	if count < 2 || count > 12 || c.Interval > 30 {
		return sampleBatch{}, nil, fmt.Errorf("diagnostic samples must be 2..12 and interval 1..30s")
	}
	ticks, page, err := kernelContext()
	if err != nil {
		return sampleBatch{}, nil, err
	}
	s, err := newSampler(diskProc{"/proc"}, c.Hostname, ticks, page)
	if err != nil {
		return sampleBatch{}, nil, err
	}
	origin := time.Now()
	all := sampleBatch{}
	for i := 0; i < count; i++ {
		stamp := time.Now()
		rows, err := s.sample(stamp.Sub(origin).Seconds(), wallFromEpoch(float64(stamp.Unix())+float64(stamp.Nanosecond())/1e9, location))
		if err != nil {
			return sampleBatch{}, nil, err
		}
		all.Rows = append(all.Rows, rows...)
		for range rows {
			all.Epochs = append(all.Epochs, stamp.Unix())
		}
		if i+1 < count {
			// Monotonic scheduling; wall-clock adjustments do not alter rate time.
			next := origin.Add(time.Duration(i+1) * time.Duration(c.Interval) * time.Second)
			if delay := time.Until(next); delay > 0 {
				time.Sleep(delay)
			}
		}
	}
	return all, map[string]int64{"clock_ticks": ticks, "page_size_bytes": page, "mem_total_kb": s.memTotal, "live_identities": int64(len(s.previous)), "cache_entries": int64(len(s.cache))}, nil
}

func encodeSampleRows(batch sampleBatch, output string, location *time.Location, rotation int64) (int, error) {
	tsv := strings.Join(batch.Rows, "\n") + "\n"
	n, err := encodeWithEpochs(strings.NewReader(tsv), output, location, rotation, batch.Epochs)
	if err != nil {
		return 0, err
	}
	// Isolated diagnostic artifact, NOT a production recovery spool.
	if err := os.WriteFile(filepath.Join(output, "golden.tsv"), []byte(tsv), 0600); err != nil {
		return 0, err
	}
	return n, nil
}
