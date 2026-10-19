# Lintap RPM Package

This directory contains RPM packaging for the Lintap Linux sensor. The initial target is RHEL 8 on `x86_64`.

The RPM layout intentionally matches the Ubuntu package layout where possible.

## Quickstart

Build on a RHEL 8 compatible `x86_64` host with the .NET 8 SDK and eBPF tooling installed:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh --version 0.1.0 --release 1.el8
```

Note: if `build-rpm.sh` is not marked executable in your checkout, invoking via `bash ...` avoids a `Permission denied` failure.

The default build is self-contained .NET for `linux-x64`. Output is written under:

```text
artifacts/lintap-rpm/x86_64/lintap-<version>-<release>.x86_64.rpm
```

Build intermediates, MCP publish output, and `dotnet publish` output are written to native storage by default:

```text
/var/tmp/lintap-rpm-build
```

This avoids .NET apphost mmap failures and runtime-codegen issues when the source repo is on a VM shared mount. Override with `--work-root` or `LINTAP_RPM_WORK_ROOT` if needed.

## Cross-Build From A Non-x86 Host

The script can also produce the `x86_64` RPM from a non-x86 host, such as a Fedora `aarch64` VM, because `rpmbuild` only packages the staged payload and the script builds the eBPF objects with `TARGET_ARCH=x86_64`.

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --arch x86_64 \
  --runtime linux-x64
```

Cross-build requirements:

- The .NET SDK on the build host must be able to restore/publish the `linux-x64` runtime pack.
- If using `--publish-dir`, that directory must already contain `linux-x64` output, not host-architecture output.
- The eBPF tracer Makefile must support `TARGET_ARCH=x86_64` on the host.
- The RPM build disables ReadyToRun publishing because crossgen is expensive and unreliable during cross-architecture packaging.

## Development Build From Existing Output

If NuGet access is unavailable, package an existing build output as a framework-dependent smoke-test package:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --framework-dependent \
  --publish-dir wintap/wintap/bin/Debug/net8.0
```

`--publish-dir` skips `dotnet publish` and packages an existing publish/build output directory. Prefer a fresh `dotnet publish` for release packages. The script defensively filters stale `obj/`, VCS metadata, `.venv/`, `.fuse_hidden*`, and non-Linux runtime assets.

## Build Prerequisites

Install the .NET 8 SDK, RPM build tools, and eBPF build tooling. Package names vary by repo setup, but a typical RHEL 8 build host needs:

```sh
sudo dnf install -y rpm-build dotnet-sdk-8.0 clang llvm make bpftool libbpf-devel elfutils-libelf-devel kernel-devel
```

If using Microsoft packages for .NET, configure the Microsoft RHEL package repository before installing `dotnet-sdk-8.0`.

## Runtime Layout

See the [paths and configuration guide](../PATHS_AND_CONFIGURATION.md) for
the data/runtime split, environment-variable overrides, shared-mount examples,
and verification commands.

The package installs:

```text
/usr/lib/lintap/                 published Lintap app
/usr/lib/lintap/pidstat-collector.py  managed pidstat collector
/usr/lib/lintap/pidstat-collector-launch.sh
/usr/lib/lintap/pidstat-collector-bootstrap.sh
/usr/lib/lintap/tracers/*.bpf.o  eBPF tracer objects
/usr/bin/lintap                  launcher for /usr/lib/lintap/Lintap
/etc/lintap/lintap.env           systemd environment overrides
/var/log/lintap/data/            default shared data root (contains raw_sensor/)
/var/log/lintap/runtime/         default host-local runtime root
/usr/lib/systemd/system/lintap.service
/usr/lib/systemd/system/lintap-pidstat.service
```

External config parity with the Ubuntu package:

```text
/etc/lintap/lintap.env
```

The RPM marks this file as `%config(noreplace)`, so local edits are preserved across upgrades when possible. By default it sets:

```text
WINTAP_DATA_ROOT=/var/log/lintap/data
WINTAP_RUNTIME_ROOT=/var/log/lintap/runtime
WINTAP_DISABLE_MCP=true
WINTAP_DISABLE_DUCKDB_UI=true
WINTAP_DISABLE_ETL=false
WINTAP_DISABLE_SENSORS=false
WINTAP_ENABLE_EXECVE_SENSOR=true
WINTAP_ENABLE_EXIT_SENSOR=true
WINTAP_ENABLE_NETWORK_SENSOR=true
WINTAP_ENABLE_FILEOPS_SENSOR=true
WINTAP_ENABLE_PROCESS_RUNDOWN_SENSOR=true
WINTAP_ENABLE_CLONE_SENSOR=false
WINTAP_PARQUET_COMPRESSION=Uncompressed
PIDSTAT_INTERVAL_SEC=5
PIDSTAT_ROTATE_INTERVAL_SEC=300
PIDSTAT_MIN_ROTATE_INTERVAL_SEC=300
PIDSTAT_DUCKDB_THREADS=1
PIDSTAT_VENV_DIR=/opt/lintap/pidstat-collector/.venv
PIDSTAT_BOOTSTRAP_PYTHON=3.12
```

Lintap logs are expected under `/var/log/lintap/runtime/Logs`, raw sensor output under `/var/log/lintap/data/raw_sensor`, and the pidstat collector keeps its active spool under `/var/log/lintap/runtime/pidstat-spool`.

The pidstat service runs as root for full `/proc` visibility, but it no longer
pins a host Python path. Instead, bootstrap a dedicated `uv`-managed venv and
the service launches `pidstat-collector.py` from that venv.

## Install And Run

```sh
sudo dnf install ./artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
cat /etc/lintap/lintap.env
sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh
sudo systemctl start lintap lintap-pidstat
sudo systemctl status lintap lintap-pidstat
sudo journalctl -u lintap-pidstat -f
```

The package enables the service on install but does not start it automatically.

## Quickstart: Install On RHEL 8

Copy the RPM to the RHEL 8 `x86_64` target host, then install it:

```sh
sudo dnf install ./lintap-0.1.0-1.el8.x86_64.rpm
```

Before starting the service, review the external config file:

```sh
sudoedit /etc/lintap/lintap.env
```

Default config:

```text
WINTAP_DATA_ROOT=/var/log/lintap/data
WINTAP_RUNTIME_ROOT=/var/log/lintap/runtime
WINTAP_DISABLE_MCP=true
WINTAP_DISABLE_DUCKDB_UI=true
WINTAP_DISABLE_ETL=false
WINTAP_DISABLE_SENSORS=false
WINTAP_ENABLE_EXECVE_SENSOR=true
WINTAP_ENABLE_EXIT_SENSOR=true
WINTAP_ENABLE_NETWORK_SENSOR=true
WINTAP_ENABLE_FILEOPS_SENSOR=true
WINTAP_ENABLE_PROCESS_RUNDOWN_SENSOR=true
WINTAP_ENABLE_CLONE_SENSOR=false
WINTAP_PARQUET_COMPRESSION=Uncompressed
```

Config notes:

- `/etc/lintap/lintap.env` is read by systemd via `EnvironmentFile=-/etc/lintap/lintap.env`.
- The RPM marks `/etc/lintap/lintap.env` as `%config(noreplace)`, so local edits are preserved across upgrades when possible.
- Runtime logs, DuckDB, diagnostics, and state default under `/var/log/lintap/runtime`.
- Shared raw sensor output defaults under `/var/log/lintap/data/raw_sensor`.
- The managed pidstat collector uses the same `/etc/lintap/lintap.env` file and writes to `/var/log/lintap/data/raw_sensor/pidstat/...`.
- The managed pidstat collector resolves its interpreter from `PIDSTAT_VENV_DIR` (default `/opt/lintap/pidstat-collector/.venv`) and is bootstrapped with `uv`, not with a system-wide `pip install`.
- The stable Linux sensors are enabled by default; `CloneSensor` remains disabled because `sched_process_fork` attach failed during Fedora bring-up.
- The RPM defaults `WINTAP_PARQUET_COMPRESSION=Uncompressed` for RHEL 8 glibc compatibility. Snappy remains the application default outside this package.
- The service is enabled during install, but not started automatically.

Start and inspect the service:

```sh
sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh
sudo systemctl start lintap lintap-pidstat
systemctl status lintap lintap-pidstat --no-pager
sudo journalctl -u lintap-pidstat -n 100 --no-pager
```

Verify expected paths:

```sh
systemctl cat lintap
sudo find /var/log/lintap/data /var/log/lintap/runtime -maxdepth 4 -type f | sort
curl -fsS http://localhost:8099/ || true
```

If you need to change runtime settings later, edit `/etc/lintap/lintap.env` and restart:

```sh
sudoedit /etc/lintap/lintap.env
sudo systemctl restart lintap
```

## Inspect Package

```sh
rpm -qpi artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
rpm -qpl artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
rpm -qp --scripts artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
```

Check RHEL 8 glibc compatibility before installing on a RHEL 8 host:

```sh
rpm -qp --requires artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm | grep 'GLIBC_'
```

RHEL 8 provides glibc 2.28. If the RPM requires `GLIBC_2.29` or newer, a bundled native dependency must be replaced or rebuilt for RHEL 8 before the package can be considered RHEL 8 runtime-compatible.

Current validation note: a Fedora 44 `aarch64` VM successfully cross-built `lintap-0.1.0-1.el8.x86_64.rpm` on 2026-06-09. The package payload and `%config(noreplace)` external config were verified. The RPM excludes bundled `libnironcompress.so` and sets `WINTAP_PARQUET_COMPRESSION=Uncompressed` because that native library required `GLIBC_2.29` on this cross-build host while RHEL 8 provides glibc 2.28.
