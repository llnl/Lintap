package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// procSource lets captured raw reads exercise the SAME parser/rate builder as live
// /proc. Unavailable optional reads remain unavailable, not fabricated counters.
type procSource interface {
	read(string) (string, bool)
	link(string) (string, bool)
	pids() ([]string, error)
}

type diskProc struct{ root string }

func (d diskProc) read(name string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(d.root, name))
	if err != nil {
		return "", false
	}
	return strings.ToValidUTF8(string(b), "\uFFFD"), true
}
func (d diskProc) link(name string) (string, bool) {
	s, err := os.Readlink(filepath.Join(d.root, name))
	return s, err == nil
}
func (d diskProc) pids() ([]string, error) {
	entries, err := os.ReadDir(d.root)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names, nil
}

type containerInfo struct {
	path        string
	namespace   *int64
	runtime, id string
}
type identity struct{ pid, start int64 }
type snapshot struct {
	uid, pid, start, user, system, guest, minfault, majfault                    int64
	vsz, rss, read, write, cancelled, delay, voluntary, involuntary, wait, core int64
	command                                                                     string
	memory                                                                      float64
	// rates use elapsed time; output uses the independent local wall clock.
	elapsed   float64
	wall      time.Time
	container containerInfo
}
type sampler struct {
	source                  procSource
	host                    string
	ticks, pageKB, memTotal int64
	previous                map[int64]snapshot
	cache                   map[identity]containerInfo
}

func newSampler(source procSource, host string, ticks, pageBytes int64) (*sampler, error) {
	if ticks <= 0 || pageBytes < 1024 || pageBytes%1024 != 0 {
		return nil, fmt.Errorf("invalid kernel clock/page context")
	}
	text, ok := source.read("meminfo")
	if !ok {
		return nil, fmt.Errorf("could not read MemTotal")
	}
	var total int64
	found := false
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "MemTotal:") {
			parts := strings.Fields(line)
			if len(parts) < 2 {
				return nil, fmt.Errorf("malformed MemTotal")
			}
			var err error
			total, err = strconv.ParseInt(parts[1], 10, 64)
			if err != nil || total < 0 {
				return nil, fmt.Errorf("invalid MemTotal")
			}
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("could not read MemTotal")
	}
	return &sampler{source: source, host: host, ticks: ticks, pageKB: pageBytes / 1024, memTotal: total,
		previous: make(map[int64]snapshot), cache: make(map[identity]containerInfo)}, nil
}

func parseKV(text string) map[string]string {
	values := make(map[string]string)
	for _, line := range strings.Split(text, "\n") {
		key, value, ok := strings.Cut(line, ":")
		if ok {
			values[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return values
}

var runtimePatterns = []struct {
	name    string
	pattern *regexp.Regexp
}{
	{"docker", regexp.MustCompile(`(?:^|/|:)docker[-/]([0-9a-f]{12,64})(?:\.scope)?(?:/|$)`)},
	{"podman", regexp.MustCompile(`(?:^|/|:)libpod[-/]([0-9a-f]{12,64})(?:\.scope)?(?:/|$)`)},
	{"containerd", regexp.MustCompile(`(?:^|/|:)(?:cri-containerd|containerd)[-/]([0-9a-f]{12,64})(?:\.scope)?(?:/|$)`)},
	{"crio", regexp.MustCompile(`(?:^|/|:)crio[-/]([0-9a-f]{12,64})(?:\.scope)?(?:/|$)`)},
}
var namespacePattern = regexp.MustCompile(`pid:\[(\d+)\]`)

func parseContainer(text, link string) containerInfo {
	info := containerInfo{path: "/"}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		path := line
		if _, raw, ok := strings.Cut(line, ":"); ok {
			_, path, _ = strings.Cut(raw, ":")
			if path == "" {
				path = raw
			}
		}
		path = strings.TrimSpace(path)
		if path == "" {
			path = "/"
		}
		if path != "/" && (info.path == "/" || len(path) > len(info.path)) {
			info.path = path
		}
		for _, runtime := range runtimePatterns {
			if match := runtime.pattern.FindStringSubmatch(path); match != nil {
				info.path, info.runtime, info.id = path, runtime.name, match[1]
				break
			}
		}
		if info.runtime != "" {
			break
		}
	}
	if match := namespacePattern.FindStringSubmatch(link); match != nil {
		if inode, err := strconv.ParseInt(match[1], 10, 64); err == nil {
			info.namespace = &inode
		}
	}
	return info
}

func (s *sampler) readSnapshot(pid int64, elapsed float64, wall time.Time) (snapshot, bool) {
	base := strconv.FormatInt(pid, 10) + "/"
	stat, statOK := s.source.read(base + "stat")
	statusText, statusOK := s.source.read(base + "status")
	if !statOK || !statusOK {
		return snapshot{}, false
	}
	open, close := strings.IndexByte(stat, '('), strings.LastIndexByte(stat, ')')
	if open < 0 || close <= open || close+2 > len(stat) {
		return snapshot{}, false
	}
	if _, err := strconv.ParseInt(strings.TrimSpace(stat[:open]), 10, 64); err != nil {
		return snapshot{}, false
	}
	fields := strings.Fields(stat[close+2:])
	if len(fields) < 41 {
		return snapshot{}, false
	}
	x := snapshot{pid: pid, command: stat[open+1 : close], elapsed: elapsed, wall: wall}
	for _, field := range []struct {
		index int
		dest  *int64
	}{
		{7, &x.minfault}, {9, &x.majfault}, {11, &x.user}, {12, &x.system}, {19, &x.start},
		{20, &x.vsz}, {21, &x.rss}, {36, &x.core}, {39, &x.delay}, {40, &x.guest},
	} {
		value, err := strconv.ParseInt(fields[field.index], 10, 64)
		if err != nil {
			return snapshot{}, false
		}
		*field.dest = value
	}
	// Python integer floor division for the (normally nonnegative) vsize value.
	x.vsz = floorDivide(x.vsz, 1024)
	x.rss *= s.pageKB
	status := parseKV(statusText)
	uids := strings.Fields(status["Uid"])
	if len(uids) == 0 {
		return snapshot{}, false
	}
	var err error
	x.uid, err = strconv.ParseInt(uids[0], 10, 64)
	if err != nil {
		return snapshot{}, false
	}
	ioText, _ := s.source.read(base + "io")
	ioValues := parseKV(ioText)
	sched, _ := s.source.read(base + "schedstat")
	if parts := strings.Fields(sched); len(parts) >= 2 {
		value, err := strconv.ParseInt(parts[1], 10, 64)
		if err == nil {
			x.wait = value
		}
	}
	for _, field := range []struct {
		values map[string]string
		key    string
		dest   *int64
	}{
		{ioValues, "read_bytes", &x.read}, {ioValues, "write_bytes", &x.write}, {ioValues, "cancelled_write_bytes", &x.cancelled},
		{status, "voluntary_ctxt_switches", &x.voluntary}, {status, "nonvoluntary_ctxt_switches", &x.involuntary},
	} {
		text, ok := field.values[field.key]
		if !ok {
			text = "0"
		}
		value, err := strconv.ParseInt(text, 10, 64)
		// The Python reference raises on malformed optional counters. Skip that
		// malformed process instead of terminating the run; valid/missing values
		// retain the reference's zero/default behavior.
		if err != nil {
			return snapshot{}, false
		}
		*field.dest = value
	}
	key := identity{pid, x.start}
	info, cached := s.cache[key]
	if !cached {
		text, _ := s.source.read(base + "cgroup")
		link, _ := s.source.link(base + "ns/pid")
		info = parseContainer(text, link)
		s.cache[key] = info
	}
	x.container = info
	if s.memTotal != 0 {
		x.memory = (float64(x.rss) / float64(s.memTotal)) * 100
	}
	return x, true
}

func floorDivide(n, d int64) int64 {
	q := n / d
	if n%d < 0 {
		q--
	}
	return q
}
func positiveDelta(a, b int64) int64 {
	if a < b {
		return 0
	}
	return a - b
}
func decimal(n float64) string { return strconv.FormatFloat(n, 'f', 2, 64) }
func integer(n int64) string   { return strconv.FormatInt(n, 10) }
func sanitize(text string) string {
	return strings.NewReplacer("\t", " ", "\r", " ", "\n", " ").Replace(text)
}

func (s *sampler) row(previous, current snapshot) string {
	interval := current.elapsed - previous.elapsed
	if interval < 0.001 {
		interval = 0.001
	}
	guest := positiveDelta(current.guest, previous.guest)
	user := positiveDelta(current.user-previous.user, guest)
	system := positiveDelta(current.system, previous.system)
	fields := []string{current.wall.Format("2006-01-02"), current.wall.Format("15:04:05"), integer(current.uid), integer(current.pid),
		decimal((float64(user) / float64(s.ticks)) / interval * 100),
		decimal((float64(system) / float64(s.ticks)) / interval * 100),
		decimal((float64(guest) / float64(s.ticks)) / interval * 100),
		decimal((float64(positiveDelta(current.wait, previous.wait)) / 1e9) / interval * 100),
		decimal((float64(user+system+guest) / float64(s.ticks)) / interval * 100), integer(current.core),
		decimal(float64(positiveDelta(current.minfault, previous.minfault)) / interval),
		decimal(float64(positiveDelta(current.majfault, previous.majfault)) / interval), integer(current.vsz), integer(current.rss), decimal(current.memory),
		decimal(float64(positiveDelta(current.read, previous.read)) / 1024 / interval),
		decimal(float64(positiveDelta(current.write, previous.write)) / 1024 / interval),
		decimal(float64(positiveDelta(current.cancelled, previous.cancelled)) / 1024 / interval), integer(positiveDelta(current.delay, previous.delay)),
		decimal(float64(positiveDelta(current.voluntary, previous.voluntary)) / interval),
		decimal(float64(positiveDelta(current.involuntary, previous.involuntary)) / interval),
		sanitize(current.command), sanitize(s.host), sanitize(current.container.path), "", sanitize(current.container.runtime), sanitize(current.container.id)}
	if current.container.namespace != nil {
		fields[24] = integer(*current.container.namespace)
	}
	return strings.Join(fields, "\t")
}

func (s *sampler) sample(elapsed float64, wall time.Time) ([]string, error) {
	names, err := s.source.pids()
	if err != nil {
		return nil, err
	}
	sort.Strings(names) // Python sorts lexical proc entry names, not numeric PIDs.
	current := make(map[int64]snapshot)
	seen := make(map[int64]bool)
	rows := []string{}
	for _, name := range names {
		if name == "" || strings.Trim(name, "0123456789") != "" {
			continue
		}
		pid, err := strconv.ParseInt(name, 10, 64)
		if err != nil {
			continue
		}
		seen[pid] = true
		x, ok := s.readSnapshot(pid, elapsed, wall)
		if !ok {
			continue
		}
		current[pid] = x
		if old, ok := s.previous[pid]; ok && old.start == x.start {
			rows = append(rows, s.row(old, x))
		}
	}
	s.previous = current
	for key := range s.cache {
		// An enumerated PID with a temporarily unreadable snapshot may still be
		// the same live identity. Retain attribution until it disappears or a
		// successfully parsed starttime proves reuse; never retain exited PIDs.
		x, ok := current[key.pid]
		if !seen[key.pid] || (ok && x.start != key.start) {
			delete(s.cache, key)
		}
	}
	return rows, nil
}
