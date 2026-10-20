## Lintap RHEL8 Status + Handoff (2026-06-19)

Last updated: 2026-06-20

This document captures the current RHEL8 on-host build/validate status, what is working, what is failing, and the most likely causes/fixes. This is intended as a pragmatic handoff for the next engineering session.

### Environment

- Host OS: RHEL 8.10
- Kernel: `4.18.0-553.132.1.el8_10.x86_64`
- BTF: `/sys/kernel/btf/vmlinux` present
- Data root: `/var/log/lintap`
- Service: `systemctl status lintap` is active/running during tests

### Current RPM / Deploy

- Built and installed: `lintap-0.1.0-19.el8.x86_64`
- Built via: `bash Lintap/packaging/lintap-rpm/build-rpm.sh --version 0.1.0 --release 19.el8 --arch x86_64 --runtime linux-x64 --skip-mcp`

### What We Changed Since Prior Working Build

#### 1) FileOpsSensor eBPF attachment robustness

Problem:

- `file_ops_tracer.bpf.o` contains multiple programs. Program name lookup via libbpf can fail because BPF program names are limited to 15 chars (`BPF_OBJ_NAME_LEN-1`). Long C function names can be truncated, causing `bpf_object__find_program_by_name()` to miss.

Fix implemented:

- Shortened BPF program function names to <= 15 characters.
- Updated the C# loader to attach the new shortened names.

Files:

- `wintap/wintap/platform/linux/sensor/ebpf/tracers/file_ops_tracer.bpf.c`
- `wintap/wintap/platform/linux/sensor/ebpf/tracers/file_ops_tracepoint.bpf.c`
- `wintap/wintap/platform/linux/sensor/ebpf/FileOpsSensor.cs`

Runtime confirmation:

- `/var/log/lintap/Logs/Lintap.log` shows FileOps starts and attaches all programs:
  - `FileOps attached 't_openat_ent'`, `t_read_ent`, `t_write_ent`, `t_close`, `t_mmap`, `t_unlinkat`, `t_unlink`.

#### 2) File read byte counts

Problem:

- File read events emitted `bytes=0`.

Fix implemented:

- Emit `bytes=(u32)count` for `sys_enter_read`.

Files:

- `wintap/wintap/platform/linux/sensor/ebpf/tracers/file_ops_tracer.bpf.c`
- `wintap/wintap/platform/linux/sensor/ebpf/tracers/file_ops_tracepoint.bpf.c`

#### 3) File pseudo-path filtering + counters

Problem:

- Pseudo-filesystems are extremely high volume on real hosts (especially `/sys`, `/proc`, `/dev`) and can starve the file serializer / destroy signal quality.

Fix implemented:

- Filter out file events whose normalized path starts with `/sys/`, `/proc/`, or `/dev/`.
- Maintain per-prefix drop counters.
- Emit a log message once per minute with the counts, then reset.

Files:

- `wintap/wintap/platform/linux/sensor/ebpf/FileOpsSensor.cs`

Runtime confirmation:

- `/var/log/lintap/Logs/Lintap.log` shows periodic counter logs, e.g.:
  - `FileOps filtered pseudo-path file events (last ~60s): /sys=59 /proc=2055 /dev=2315 total=4429`

### Validation Runs (10-minute smoke loops)

We ran two 10-minute “full smoke” loops (process + network + file). Logs captured under `/tmp/opencode`.

#### Run 1

- Artifacts: `/tmp/opencode/full-test-10m-1781917074/`
- Network smoke: PASS
- Process smoke: FAIL
- File smoke: FAIL

#### Run 2

- Artifacts: `/tmp/opencode/full-test-10m-1781927853/`
- Network smoke: PASS
- Process smoke: FAIL
- File smoke: FAIL (with `--timeout 600`)

Notes:

- `journalctl -u lintap --since @<start>` captured no entries in the run artifacts because the service primarily logs to `/var/log/lintap/Logs/Lintap.log`.

### What Is Working

#### Network telemetry

- Network smoke test passes reliably and captures TCP/UDP traffic for expected ports (53/80/443).

Evidence:

- `network_capture_smoke_test.py` reports captured remote port rows.

#### FileOps sensor is attached and producing file parquet

- FileOps eBPF programs are attached.
- File parquet output exists and has a diverse ActivityType mix in aggregate (Read/Write/Open/Close/Delete).

Evidence:

- `Lintap.log` shows FileOps attached programs.
- `raw_sensor/raw_process_file` contains many parquet partitions.
- Example aggregate counts (one partition): `read`, `write`, `open`, `close`, `delete` all present.

### Known Failures (We Are Putting Process Issues On Hold)

#### A) Process smoke test failure: parent pid hash mismatch

Symptom:

- `process_capture_smoke_test.py` fails with:
  - `case fork_exec: child parent_pid_hash does not match parent pid_hash`

What we observed:

- The process parquet stream can contain multiple `Start` rows for the same PID with inconsistent `ParentPidHash`.
- Because the smoke test selects a single “latest” row per PID, it can pick an inconsistent duplicate and fail.

One concrete reproduction:

- Generated a fork/exec pair using the same stimulus as the smoke test:
  - parent PID `565404` (bash)
  - child PID `565405` (sleep)
- Querying `/var/log/lintap/runtime/esper_staging/processserializer/*.parquet` shows:
  - parent `PidHash` stable
  - multiple `Start` rows for the child with varying `ParentPidHash`, including one correct value and others incorrect.

Most likely causes:

- Duplicate process start emission from multiple probe sites/sensors.
- Parent hash derivation mismatch (eBPF-derived parent start time vs /proc-derived start time), or rounding error in conversion paths.

Possible fixes (not implemented; listed for future work):

1. Deduplicate process `Start` emission in the producer (only one authoritative Start path).
1. Prefer /proc-derived parent start time when parent exists; fall back to eBPF parent start when /proc is missing.
1. Make `ParentStartNs` -> filetime conversion exact (avoid double math; use integer tick conversion to prevent hash drift).

#### B) File smoke test failure: no matching file rows for /tmp smoke path

Symptom:

- `file_capture_smoke_test.py` fails with:
  - `no matching file rows`
- This persists even with extended wait time.

What we observed (before filtering):

- The exact smoke path under `/tmp/lintap-file-smoke/` never appears in:
  - `raw_sensor/raw_process_file` parquet, nor
  - `fileserializer` parquet.
- Yet file events for the smoke PID do exist, mostly for `/proc` and `/sys` files.

Strong signal:

- File event volume is extremely high for pseudo-filesystems.
- A sample partition breakdown shows the bulk of events under `/sys`, `/dev`, and other non-user paths; `/tmp` is a tiny fraction.

Backpressure evidence:

- `/var/log/lintap/Logs/Lintap.log` shows repeated:
  - `fileserializer: in-memory backlog limit reached (max=10000, policy=DropNewest). Dropping events.`

Hypothesis:

- The file pipeline is saturating, and with `DropNewest`, small/late-arriving smoke events are likely dropped.
- Additionally, noise-heavy sources (/sys, /proc, /dev) dominate and starve the queue.

Candidate fixes (not implemented; listed for future work):

1. Reduce file noise at the source (preferred):
   - In `FileOpsSensor.HandleEvent`, filter out `/sys/`, `/proc/`, `/dev/` (and optionally cgroup paths) to prevent overwhelming the serializer.
1. Adjust serializer buffering:
   - Increase backlog limit for `fileserializer`.
   - Consider `DropOldest` instead of `DropNewest` to preserve new/spot-check events.
1. Reduce event rate:
   - Consider dropping or sampling high-frequency operations (e.g., read/close) when under load.
1. If supported/acceptable: bypass Esper for file events (direct-parquet), avoiding `Serializer.Save` backlog.

Update after pseudo-path filtering:

- The pseudo-path filtering is active and counters show ongoing drops for `/sys`, `/proc`, and `/dev`.
- A manual `/tmp/lintap-file-smoke/...` write/read/append/unlink sequence was observed to land in `raw_sensor/raw_process_file` with expected activity diversity after the next merge/flush window.
- `file_capture_smoke_test.py` still fails in some runs. The strongest remaining hypothesis is that it samples only a limited number of “recent parquet files” and may miss the specific `raw_sensor/raw_process_file` parquet that contains the smoke path, depending on timing.

### Operational Notes / Commands

- Tail service log:
  - `sudo tail -n 200 /var/log/lintap/Logs/Lintap.log`
- Confirm FileOps attachment messages:
  - search for `FileOps attached` entries in `Lintap.log`.
- Run smoke tests (uses uv):
  - `uv run --project wintap/devtools python wintap/devtools/process_capture_smoke_test.py --data-root /var/log/lintap --timeout 180`
  - `uv run --project wintap/devtools python wintap/devtools/network_capture_smoke_test.py --data-root /var/log/lintap --timeout 180`
  - `uv run --project wintap/devtools python wintap/devtools/file_capture_smoke_test.py --data-root /var/log/lintap --timeout 600`

### Next Suggested Work (If Process Issues Stay On Hold)

1. Implement file noise filtering in `FileOpsSensor` for `/sys`, `/proc`, `/dev` and re-run file smoke.
1. If still failing, increase `fileserializer` backlog / adjust drop policy and re-run.
1. Once file smoke is stable, return to process dedupe/parent-hash correctness.
