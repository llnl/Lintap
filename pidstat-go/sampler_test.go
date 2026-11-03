package main

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
	"time"
)

type testProc struct {
	texts map[string]string
	links map[string]string
	names []string
}

func (p *testProc) read(n string) (string, bool) { v, ok := p.texts[n]; return v, ok }
func (p *testProc) link(n string) (string, bool) { v, ok := p.links[n]; return v, ok }
func (p *testProc) pids() ([]string, error)      { return append([]string(nil), p.names...), nil }
func statFixture(pid, start, user, system, guest int64) string {
	f := make([]string, 41)
	for i := range f {
		f[i] = "0"
	}
	f[0] = "S"
	for index, n := range map[int]int64{7: 20, 9: 3, 11: user, 12: system, 19: start, 20: 8192, 21: 10, 36: 3, 39: 7, 40: guest} {
		f[index] = integer(n)
	}
	return fmt.Sprintf("%d (worker (nested) name) %s\n", pid, strings.Join(f, " "))
}
func TestSamplerRatesBaselineReuseMissingAndCacheBound(t *testing.T) {
	p := &testProc{texts: map[string]string{"meminfo": "MemTotal: 1000 kB\n", "123/stat": statFixture(123, 10, 100, 20, 0), "123/status": "Uid: 1000 1000\nvoluntary_ctxt_switches: 5\nnonvoluntary_ctxt_switches: 2\n", "123/io": "read_bytes: 1024\nwrite_bytes: 2048\n", "123/schedstat": "0 1000000000 2\n", "123/cgroup": "0::/user.slice"}, links: map[string]string{"123/ns/pid": "pid:[4026531836]"}, names: []string{"self", "123"}}
	s, err := newSampler(p, "host", 100, 4096)
	if err != nil {
		t.Fatal(err)
	}
	stamp := time.Date(2026, 10, 30, 21, 0, 0, 0, time.UTC)
	rows, err := s.sample(0, stamp)
	if err != nil || len(rows) != 0 {
		t.Fatal(rows, err)
	}
	p.texts["123/stat"] = statFixture(123, 10, 320, 50, 20)
	p.texts["123/status"] = "Uid: 1001\nvoluntary_ctxt_switches: 15\nnonvoluntary_ctxt_switches: 8\n"
	p.texts["123/io"] = "read_bytes: 3072\nwrite_bytes: 6144\ncancelled_write_bytes: 1024\n"
	p.texts["123/schedstat"] = "0 1500000000 2"
	rows, err = s.sample(1, stamp.Add(time.Second))
	if err != nil || len(rows) != 1 {
		t.Fatal(rows, err)
	}
	f := strings.Split(rows[0], "\t")
	for column, want := range map[int]string{2: "1001", 4: "200.00", 5: "30.00", 6: "20.00", 7: "50.00", 8: "250.00", 13: "40", 14: "4.00", 15: "2.00", 16: "4.00", 17: "1.00", 19: "10.00", 20: "6.00", 21: "worker (nested) name", 24: "4026531836"} {
		if f[column] != want {
			t.Fatalf("column%d=%s want%s", column, f[column], want)
		}
	}
	// Attribution is cached for a live identity even when its cgroup read changes.
	p.texts["123/cgroup"] = "0::/different"
	delete(p.texts, "123/io")
	p.texts["123/schedstat"] = "malformed"
	rows, err = s.sample(2, stamp.Add(2*time.Second))
	if err != nil || len(rows) != 1 {
		t.Fatal(err)
	}
	if strings.Split(rows[0], "\t")[23] != "/user.slice" {
		t.Fatal("cache semantics")
	}
	p.texts["123/stat"] = statFixture(123, 11, 0, 0, 0)
	rows, _ = s.sample(3, stamp)
	if len(rows) != 0 || len(s.cache) != 1 {
		t.Fatal("PID reuse/cache pruning")
	}
	delete(p.texts, "123/status")
	rows, _ = s.sample(4, stamp)
	if len(rows) != 0 || len(s.cache) != 1 || len(s.previous) != 0 {
		t.Fatal("exit/permissions")
	}
	p.names = nil
	_, _ = s.sample(5, stamp)
	if len(s.cache) != 0 {
		t.Fatal("exited PID retained in cache")
	}
}
func TestSamplerCounterResetAndMonotonicWallSeparation(t *testing.T) {
	s := sampler{ticks: 100, host: "host"}
	a := snapshot{elapsed: 10, user: 100, system: 20, guest: 10, read: 1024, wait: 100}
	b := snapshot{elapsed: 11, user: 90, system: 10, guest: 5, read: 0, wall: time.Date(2026, 10, 29, 0, 0, 0, 0, time.UTC), container: containerInfo{path: "/"}}
	f := strings.Split(s.row(a, b), "\t")
	for _, column := range []int{4, 5, 6, 7, 8, 15} {
		if f[column] != "0.00" {
			t.Fatal(column, f[column])
		}
	}
	b.user = 300
	f = strings.Split(s.row(a, b), "\t")
	if f[4] != "200.00" || f[0] != "2026-10-29" {
		t.Fatal("wall jump changed elapsed rate")
	}
	b.elapsed = 10
	f = strings.Split(s.row(a, b), "\t")
	if f[4] != "200000.00" {
		t.Fatal("minimum interval")
	}
	if decimal(12.345) != "12.35" || decimal(250.125) != "250.12" || decimal(-0.0) != "0.00" {
		t.Fatal("decimal formatting")
	}
}
func TestMalformedOptionalCountersSkipped(t *testing.T) {
	p := &testProc{texts: map[string]string{"meminfo": "MemTotal: 1000 kB", "1/stat": statFixture(1, 1, 1, 1, 0), "1/status": "Uid: 0", "1/io": "read_bytes: not-a-number"}, names: []string{"1"}}
	s, err := newSampler(p, "host", 100, 4096)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := s.readSnapshot(1, 0, time.Now()); ok {
		t.Fatal("malformed process accepted")
	}
	for _, bad := range []string{"invalid", "1 (name) S 0", "1 (name) " + strings.Repeat("bad ", 41)} {
		p.texts["1/stat"] = bad
		if _, ok := s.readSnapshot(1, 0, time.Now()); ok {
			t.Fatal(bad)
		}
	}
	if _, err := newSampler(p, "host", 0, 4096); err == nil {
		t.Fatal("clock assumption")
	}
	delete(p.texts, "meminfo")
	if _, err := newSampler(p, "host", 100, 4096); err == nil {
		t.Fatal("missing memory context")
	}
}
func TestCgroupsRuntimePatternsAndNamespace(t *testing.T) {
	id := strings.Repeat("a", 64)
	for _, test := range []struct{ text, runtime string }{
		{"0::/docker/" + id, "docker"}, {"2:cpu:/system.slice/docker-" + id + ".scope", "docker"},
		{"0::/libpod-" + id + ".scope", "podman"}, {"0::/cri-containerd-" + id + ".scope", "containerd"},
		{"0::/containerd/" + id, "containerd"}, {"0::/crio-" + id + ".scope", "crio"},
	} {
		x := parseContainer(test.text, "pid:[4026531836]")
		if x.runtime != test.runtime || x.id != id || x.namespace == nil || *x.namespace != 4026531836 {
			t.Fatal(test, x)
		}
	}
	x := parseContainer("0::/\n2:cpu:/long/path\n3:memory:/short", "invalid")
	if x.path != "/long/path" || x.namespace != nil || x.runtime != "" {
		t.Fatal(x)
	}
	if parseContainer("0::/docker/SHORT", "pid:[5]").runtime != "" {
		t.Fatal("invalid runtime ID")
	}
}
func TestAuxvClockTicksNoHardcodedFallback(t *testing.T) {
	for _, width := range []int{4, 8} {
		for _, order := range []binary.ByteOrder{binary.LittleEndian, binary.BigEndian} {
			data := make([]byte, 6*width)
			put := func(offset int, value uint64) {
				if width == 4 {
					order.PutUint32(data[offset:], uint32(value))
				} else {
					order.PutUint64(data[offset:], value)
				}
			}
			put(0, 6)
			put(width, 4096)
			put(2*width, 17)
			put(3*width, 250)
			n, err := clockTicksFromAuxv(data, width, order)
			if err != nil || n != 250 {
				t.Fatal(width, n, err)
			}
			put(2*width, 0)
			if _, err := clockTicksFromAuxv(data, width, order); err == nil {
				t.Fatal("missing tick fallback")
			}
		}
	}
	if _, err := clockTicksFromAuxv([]byte{1}, 8, binary.LittleEndian); err == nil {
		t.Fatal("truncated vector")
	}
}
func TestLinuxConfigPrecedenceDefaultsAndValidation(t *testing.T) {
	env := map[string]string{}
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
	c, err := configFromEnv(lookup, "host.example.org")
	if err != nil {
		t.Fatal(err)
	}
	if c.DataRoot != "/var/log/lintap/data" || c.SpoolDir != "/var/log/lintap/runtime/pidstat-spool" || c.Hostname != "host" || c.Interval != 5 || c.Rotation != 300 || c.MaxBytes != 1073741824 || c.MaxAge != 0 {
		t.Fatal(c)
	}
	env["WINTAP_ETL_UPLOAD_INTERVAL_SEC"] = "600"
	c, _ = configFromEnv(lookup, "host")
	if c.Rotation != 600 {
		t.Fatal(c)
	}
	env["PIDSTAT_ROTATE_INTERVAL_SEC"] = "20"
	c, _ = configFromEnv(lookup, "host")
	if c.Rotation != 300 {
		t.Fatal(c)
	}
	env["PIDSTAT_MIN_ROTATE_INTERVAL_SEC"] = "10"
	env["WINTAP_DATA_ROOT"] = "/isolated/data"
	env["WINTAP_RUNTIME_ROOT"] = "/isolated/runtime"
	c, _ = configFromEnv(lookup, "host")
	if c.Rotation != 20 || c.ParquetRoot != "/isolated/data" || c.SpoolDir != "/isolated/runtime/pidstat-spool" {
		t.Fatal(c)
	}
	for _, key := range []string{"PIDSTAT_INTERVAL_SEC", "PIDSTAT_ROTATE_INTERVAL_SEC", "PIDSTAT_MIN_ROTATE_INTERVAL_SEC", "PIDSTAT_DUCKDB_THREADS"} {
		env[key] = "0"
		if _, err := configFromEnv(lookup, "host"); err == nil {
			t.Fatal(key)
		}
		delete(env, key)
	}
	for _, key := range []string{"PIDSTAT_MAX_UNSHIPPED_BYTES", "PIDSTAT_MAX_UNSHIPPED_AGE_SEC"} {
		env[key] = "-1"
		if _, err := configFromEnv(lookup, "host"); err == nil {
			t.Fatal(key)
		}
		delete(env, key)
	}
}

func TestPythonCompatibleConfigNumbersAndLexicalPaths(t *testing.T) {
	for text, want := range map[string]int64{"1_024": 1024, "  +5 ": 5, "１２３": 123, "١٢٣": 123, "-0": 0} {
		got, err := pythonDecimalInt(text)
		if err != nil || got != want {
			t.Fatal(text, got, err)
		}
	}
	for _, text := range []string{"_5", "5_", "1__2", "+_2", "0x10", "", "9223372036854775808"} {
		if _, err := pythonDecimalInt(text); err == nil {
			t.Fatal(text)
		}
	}
	for input, want := range map[string]string{"/isolated/a/../data": "/isolated/a/../data", "//root///data/./": "//root/data", "///root": "/root", "": ".", "./relative/": "relative"} {
		if got := pythonPath(input); got != want {
			t.Fatal(input, got, want)
		}
	}
}
