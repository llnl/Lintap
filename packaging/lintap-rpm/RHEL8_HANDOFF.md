## Lintap RHEL 8 RPM Migration Handoff

Last updated: 2026-06-20

This document is the handoff for moving from the current cross-build/development workflow to building and validating the Lintap RPM on a real RHEL 8 `x86_64` system.

### Current State Summary

1. RPM installs via `dnf` successfully.
1. `libbpf` is present on the target and the service starts.
1. Esper EPL context is deployed once; duplicate context warnings are no longer expected.
1. Network telemetry is flowing with populated tuples:
   - TCP: `TcpIpConnect`, `TcpIpSend`, `TcpIpRecv`, `TcpIpDisconnect`
   - UDP: `UdpIpSend`, `UdpIpRecv` (recv peer tuple fixed; see known issues)
1. Process telemetry is present (PidHash populated), but there are known parent attribution inconsistencies in some process start rows; treat process smoke failures as a known issue for now.
1. File events are plentiful. High-volume pseudo-path noise (`/sys`, `/proc`, `/dev`) has been filtered at the FileOps sensor to protect pipeline health, with periodic counters emitted to logs.
1. Runtime config from `/etc/lintap/lintap.env` is honored (env overrides packaged ETLConfig).

### What Changed In Packaging Since Yesterday

These changes were made to accommodate drift in `wintap/wintap` and to make cross-building from non-x86 hosts possible.

1. eBPF build arch mapping: for `x86_64/linux-x64` the eBPF Makefile expects `TARGET_ARCH=x86` (which produces `__TARGET_ARCH_x86`). Packaging was updated to match.
1. Cross-build eBPF mode: cross-build packaging forces tracepoint-only objects (disables BTF/vmlinux.h generation) to avoid using host-kernel BTF headers.
1. `--skip-mcp`: added to the RPM builder to allow building when NuGet/network access is blocked. When used, the packaged payload contains no `/usr/lib/lintap/mcp/*`.
1. Tracer assertions: RPM staging validation expects the tracepoint fallback objects in cross-build mode.

### Target Environment

1. RHEL 8 `x86_64` (real hardware or VM running a RHEL8-compatible kernel).
1. Build host requirements (for building the RPM on RHEL8):
   - `dotnet-sdk-8.0`
   - `rpm-build`, `rpmbuild`
   - `clang`, `llvm`, `make`, `bpftool`
   - eBPF deps: `libbpf`, `libbpf-devel`, `elfutils-libelf`, `elfutils-libelf-devel`, `kernel-devel`

Example install (package names may vary by repo configuration):

```sh
sudo dnf install -y rpm-build dotnet-sdk-8.0 clang llvm make bpftool \
  libbpf libbpf-devel elfutils-libelf elfutils-libelf-devel kernel-devel
```

### Artifacts

RPM output from the build script is written to:

```text
artifacts/lintap-rpm/x86_64/lintap-<version>-<release>.x86_64.rpm
```

If building with `--skip-mcp`, validate the RPM does not contain `/usr/lib/lintap/mcp/`.

### Build Procedure On RHEL 8 (Preferred)

From the repo root on the RHEL8 `x86_64` build host:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --arch x86_64 \
  --runtime linux-x64
```

If NuGet access is not available on the build host:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --arch x86_64 \
  --runtime linux-x64 \
  --skip-mcp
```

Notes:

1. The script builds eBPF tracers first, then runs `dotnet publish`.
1. Intermediates are written under `/var/tmp/lintap-rpm-build` by default to avoid shared-mount issues.
1. If you need to reuse a prior restore, add `--no-restore`.

### Install/Upgrade On The Target RHEL 8 Host

1. Copy the RPM to the target host.
1. Install/upgrade:

```sh
sudo dnf install -y ./lintap-0.1.0-1.el8.x86_64.rpm
```

3. Inspect config:

```sh
sudo cat /etc/lintap/lintap.env
```

4. Start and tail logs:

```sh
sudo systemctl daemon-reload
sudo systemctl restart lintap
sudo systemctl status lintap --no-pager
sudo journalctl -u lintap -n 200 --no-pager
```

### Runtime Verification Checklist

#### A. Packaging/layout sanity

```sh
rpm -qpl ./lintap-*.rpm | egrep '(/usr/lib/lintap/|/usr/lib/lintap/tracers/|/etc/lintap/lintap.env|/usr/lib/systemd/system/lintap.service|/usr/bin/lintap)'
```

Confirm `libbpf` availability:

```sh
rpm -q libbpf
ldconfig -p | grep -E 'libbpf\.so\.(0|1)' || true
```

#### B. eBPF sensor startup

In the log you should see each sensor searching candidates and then loading one.

Expected on RHEL8 (depending on BTF availability):

1. CO-RE path: loads `*_tracer.bpf.o`.
1. Fallback path: if CO-RE objects are not present or do not load, it should load `*_tracepoint.bpf.o`.

If you still see `Unable to load shared library 'libbpf.so.1'` on RHEL8, that indicates either:

1. `libbpf` is missing on the target, or
1. the deployed build predates the runtime resolver fallback fix.

#### C. EPL duplicate context warnings

Previously observed warning:

```text
Context by name 'Every10Seconds' already exists
```

Status: expected to be resolved; if it reappears, treat it as a regression.

#### D. Data outputs

Default data paths are controlled by `/etc/lintap/lintap.env` and the runtime. Verify parquet output is created:

```sh
sudo find /var/log/lintap -maxdepth 4 -type f | sort | tail -n 100
sudo find /tmp/lintap-data -maxdepth 4 -type f | sort | tail -n 100 || true
```

Note: On this deployment, the highest-signal runtime log is typically `/var/log/lintap/Logs/Lintap.log`. `journalctl -u lintap` can be sparse.

### Known Issues / Investigation Threads

#### 1) Network data is spotty (missing most IpAddr values)

Previous symptoms observed:

1. TCP connect/send/recv/disconnect were incomplete or missing.
1. UDP recv peer tuple could be missing (remote 0).

Likely causes (and fixes applied during RHEL8 bring-up):

1. Incomplete program attachment: `network_ops_tracer.bpf.o` contains multiple programs; relying on program-name strings is brittle (name truncation). The NetworkSensor now attaches all programs in the object.
1. UDP recv tuple extraction: for `recvfrom`/`recvmsg`, emit on `udp_recvmsg` return and read the peer sockaddr written into user memory; avoid emitting partial rows from syscall tracepoints.
1. TCP lifecycle events: emit `TcpIpConnect` from successful `tcp_*_connect` returns and `TcpIpDisconnect` from `tcp_close`.

Suggested next checks:

```sh
sudo journalctl -u lintap -n 400 --no-pager | egrep -i 'Network|bpf|libbpf|attach|tracepoint|kprobe|failed'
sudo bpftool prog list | grep -i wintap || true
sudo bpftool link list | grep -i wintap || true
```

If the target has BTF (`/sys/kernel/btf/vmlinux` exists), prefer packaging CO-RE objects for that target and validate that `network_ops_tracer.bpf.o` loads successfully.

Additional quick validation of TCP event coverage:

```sh
# raw_sensor (canonical partition layout)
sudo find /var/log/lintap/data/raw_sensor/raw_process_conn_incr -type f -name '*raw_tcp_process_conn_incr*.parquet' | tail -n 3

# serializer parquet (Esper -> parquet)
ls -lt /var/log/lintap/runtime/esper_staging/tcpconnectionserializer | head
```

#### 2) Process telemetry review

Not yet deeply validated in the last deploy. Recommended minimum checks:

1. Verify process parquet files are being written and contain expected columns.
1. Confirm parent/child relationships look plausible.

#### 3) File events

Currently: plentiful. Pseudo-filesystem paths (`/sys`, `/proc`, `/dev`) are filtered in `FileOpsSensor` to reduce noise and prevent serializer starvation; the sensor logs per-minute drop counters.

### Recommended Next Steps (Sequenced)

1. Build the RPM directly on the real RHEL8 `x86_64` build host (avoid cross-build artifacts).
1. Deploy to the real RHEL8 target and validate eBPF sensors start without fallback-only limitations (if BTF available).
1. Re-evaluate network telemetry with CO-RE objects present:
   - confirm which `.bpf.o` is loaded for Network.
   - confirm whether `IpAddr` fields populate.
1. If network remains spotty:
   - capture `bpftool prog/link` output,
   - capture the service logs around sensor startup,
   - inspect the network tracer code paths for field extraction differences between CO-RE and tracepoint modes.
