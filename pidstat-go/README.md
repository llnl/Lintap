# pidstat Go collector — unpackaged fpc-03 checkpoint

**Not packaged or release-qualified.** fpc-01 proved captured
Python TSV encoding and static binaries and was approved by the human. fpc-02 adds
the proc sampler, Linux configuration resolution, raw-input replay and bounded live
diagnostics. The existing Python collector, launch/bootstrap scripts and services
remain unchanged. fpc-01/fpc-02 are human-approved; fpc-03 adds durable collector,
spool/recovery and writer integration and awaits acceptance. Package/service,
paired-live, comparative-resource and canonical DBT qualification remain separate.
The operator reports the binary running on RHEL 8/amd64; native host evidence has
not been inspected as part of this checkpoint.

## Build/test

Use **Go 1.27.3**, pinned in go.mod. No installed-host Go/Python/uv/DuckDB dependency
is introduced by the binary; those tools are development/reference-test tools only.

```sh
make test
make build
```

If Go is not on PATH, pass `GO=/absolute/path/to/go`. Dependencies are pinned in
go.mod/go.sum. The build cross-compiles Linux arm64 and baseline amd64 (`GOAMD64=v1`)
with `CGO_ENABLED=0`. Inspect the actual ELF artifacts and run arm64 on the approved
Ubuntu guest; cross-build alone is not RHEL/native amd64 proof. Outputs live in
ignored `bin/` and are not installed by any existing package builder.

## Encode recorded Python rows

```sh
bin/pidstat-parquet-spike-linux-arm64 \
  --input /isolated/reference/golden.tsv \
  --output /isolated/new/go-output --timezone America/Phoenix --rotation 300
```

`--timezone` must match the Python reference's IANA timezone; the example is the
first guest's setting, not a universal default. It controls window epochs and local
day/hour partition names. Parquet `time` retains naive local wall-clock fields,
microsecond storage and `isAdjustedToUTC=false`; it is not normalized to UTC.
Timezone data is embedded in the binary. All columns remain OPTIONAL, rates FLOAT,
UID/PID/core/iodelay signed INT32, VSZ/RSS/namespace signed INT64, and text UTF8.
Integer/text legacy annotations match DuckDB's reference writer rather than merely
being reader-compatible. `--input` TSV rates are already rounded. Raw replay uses
the Go sampler and matches Python's two-decimal formatting before FLOAT storage.

The spike requires a new output root, preserves row multiplicity and source TSV,
uses in-process pure-Go ZSTD, closes `.active` files before publishing `.parquet`,
and rejects malformed numeric/date records. The older diagnostic `--input`, `--replay`
and `--sample-count` modes still group input in memory, require a new output directory
and are NOT the durable collector path below. Failed diagnostic encoding may retain
its own `.active` evidence.

## Durable collector / recovery (explicit modes only)

```sh
PIDSTAT_PARQUET_ROOT=/isolated/data PIDSTAT_SPOOL_DIR=/isolated/runtime/spool \
  bin/pidstat-parquet-spike-linux-arm64 --collect --timezone America/Phoenix
PIDSTAT_PARQUET_ROOT=/isolated/data PIDSTAT_SPOOL_DIR=/isolated/runtime/spool \
  bin/pidstat-parquet-spike-linux-arm64 --recover --timezone America/Phoenix
```

The binary name remains temporary; no service/unit/package changes are included.
Collector mode uses configured roots, validates hostname/cadence/compression and
requires the spool outside uploader-swept `raw_sensor`. An advisory `collector.lock`
is held exclusively for its lifetime; competing Go collectors on that spool fail.
**The old Python collector does not honor this lock: never share a spool with it.**
`--spool-replay capture.json` uses raw sampler replay through this same durable path,
not TSV grouping; it requires matching PIDSTAT_HOSTNAME and roots/configuration.

Legacy `current.tsv/current.meta` and `pending-*.tsv/.meta` are retained. Metadata is
`window_start_epoch=INTEGER\n`; valid metadata, not rounded rows or row hostnames,
selects one output window and configured hostname selects the filename. Missing
or invalid metadata is inferred from the first row like Python; absent metadata cannot
reconstruct original sub-microsecond/DST-fold sample provenance. Malformed/truncated
inputs (including missing final newline) are retained and reported, never salvaged by
discarding tails. Empty windows are skipped. Source changes after a publication
receipt are rejected; operator repair must inspect source and receipt, not blindly
delete state. `--recover` returns nonzero for retained failures; live collection logs
them and continues valid new windows, with nonzero exit if shutdown conversion fails.

Go's `seal.json` journal makes TSV/meta sealing restartable. Per-pending
`.publish.json` receipts record source SHA256, uniquely reserved `*.active` path,
destination and closed-Parquet SHA256/publication state. The writer consumes rows
incrementally through the frozen schema adapter, closes successfully and syncs before
atomic no-overwrite hard-link installation of `.parquet` on the same filesystem.
Receipt/state are synced before source deletion. Recovery recognizes an existing
publication by owned inode+hash, not content alone; identical independent rows retain
multiplicity. Collision filenames keep legacy `-NUMBER-PID` suffix (allocation
advances the number if the same-second name exists). Unowned stale active files stay
untouched. Filesystems must support hard links, advisory flock and directory fsync.

SIGTERM/SIGINT stop scheduling, seal current rows, process pending inputs and release
the lock. Restart seals leftover current then retries pending windows; no external
sampling/conversion child process is invoked. Compression matches DuckDB's accepted
case-insensitive ZSTD, SNAPPY, GZIP, LZ4/LZ4_RAW, BROTLI and UNCOMPRESSED values;
invalid values fail before touching spool contents. Oldest-first byte/age eviction
touches only completed pidstat Parquet, skips symlinks/active/spool/other sensors and
tolerates uploader deletion. Caps do not evict failing TSV spools.

**Guarantee limits:** deterministic process-crash transitions and native SIGKILL
recovery are tested; file/directory fsync strengthens persistence but full power-loss,
storage failure and network-filesystem durability are unqualified. An uploader that
removes a just-linked file before the published receipt is durable can make a crash
ambiguous: recovery may replay that window (at-least-once, not exactly-once delivery).
No end-to-end upload receipt exists. Do not roll back by running Python over outstanding
Go journals: first use Go recovery and inspect/drain state, because Python does not
interpret the journals. The four-hour sensor-on Ubuntu arm64 soak measured median
RSS about 17 MiB (peak 44.86 MiB) and median CPU 0.47% of one core at default 5s/300s
cadence. This is one workload, not a general memory bound or Python resource
comparison; see the Analytics `soak_review.md` in the feature directory below.

## Sampler replay and bounded live diagnostics

```sh
bin/pidstat-parquet-spike-linux-arm64 \
  --replay /isolated/reference/capture.json \
  --output /isolated/new/replayed-output --timezone America/Phoenix
bin/pidstat-parquet-spike-linux-arm64 --kernel-context
bin/pidstat-parquet-spike-linux-arm64 --show-config
PIDSTAT_INTERVAL_SEC=1 bin/pidstat-parquet-spike-linux-arm64 \
  --sample-count 4 --output /isolated/new/live-output --timezone America/Phoenix
```

Select exactly one mode. Replay consumes observed raw reads, PID enumeration and
captured times/kernel context, **not normalized snapshots or golden rows**. Missing
uncaptured inputs are errors; explicitly unavailable optional inputs retain Python's
defaults. The shared sampler parses stat/status/io/schedstat/cgroup/ns, skips first
and reused-PID baselines, excludes guest ticks from user CPU and preserves total
core-summed CPU. Caches are bounded to enumerated live identities and replaced on
observed starttime reuse. Temporarily unreadable but enumerated PIDs retain cached
attribution; their next valid snapshot is baseline-only.

Live mode is Linux-only and bounded to2..12 samples at1..30s, using kernel
AT_CLKTCK from `/proc/self/auxv` and `os.Getpagesize()`, without cgo or child commands.
Rates/scheduling use monotonic elapsed time; output uses local wall time. Replay uses
captured Python elapsed times, including its0.001s clamp. Wall timestamps round to
microseconds like Python, while rotation uses the **original sample epoch**, so a
rounded midnight timestamp may correctly remain in the preceding partition/window.
Raw replay retains DST-fold window provenance; bare TSV encoding cannot recover it.

`--show-config` resolves Linux path/cadence/hostname/compression/cap overrides with
Python-compatible precedence/minimum rotation, lexical POSIX paths (including `..`)
and decimal separators/Unicode digits. It creates no directories. Diagnostics write
only their explicit new `--output` root; no configured production root is used.
`PIDSTAT_DUCKDB_THREADS` is validated/reported for compatibility only and has no Go
writer/runtime meaning; explicit package-era deprecation is later work. Config/counters
use signed64-bit bounds rather than Python arbitrary-sized integers.

Declared fault-handling delta: malformed optional integer counters skip the process
instead of raising Python ValueError and terminating sampling. Missing fields retain
the old zero/default semantics. Monotonic live scheduling intentionally differs from
Python's wall-clock duration during clock jumps. Neither delta licenses unrelated
metric/schema changes; durable-mode recovery/error policy is described above.

## Evidence and dependency choice

Analytics owns commands/skill and the deterministic utility at
`../Wintap-Analytics/validation/pidstat-loop/`; its feature record is
`../Wintap-Analytics/wiki/work/fix-pidstat-collector/verification.md`.
Use actual Python `/proc` captures as the oracle, not only controlled fixtures.
Inspect all columns/types, nulls, duplicate/missing rows, partitions/window epochs
and decoded datasets. All three real raw-input replays (266/705/1640 rows),17config
cases and two52-row controlled sampler cases (100Hz/4KiB and250Hz/16KiB) pass;
native arm64 raw replay passes and a four-sample diagnostic emits411rows. These
are same-session technical evidence, not independently reviewed acceptance or
paired-live sampler equivalence. Durable service/package/DBT qualification remains
later work; no RHEL/native amd64 runtime claim is made.

Writer: `github.com/parquet-go/parquet-go v0.32.0`, Apache-2.0; ZSTD implementation
comes from `github.com/klauspost/compress v1.17.9`, BSD-3-Clause, through parquet-go.
Go is BSD-3-Clause. No DuckDB binding/cgo is linked. Transitive versions/checksums
are recorded by Go's module files; release-time third-party license/notice and
security review is still required before distribution. This is not a package or
security qualification claim. No source in the Python reference is retired here.
