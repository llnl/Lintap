# Lintap RPM Package Build and Smoke-Test Guide

This guide explains how to build, inspect, install, and smoke-test the RHEL 8 `x86_64` RPM package for the Lintap Linux sensor.

## What this package is

This package installs the Lintap sensor app, its eBPF tracer object files, a default external config file, and a systemd service.

Installed layout:

```text
/usr/lib/lintap/                 Lintap application files
/usr/lib/lintap/tracers/*.bpf.o  eBPF tracer objects
/usr/bin/lintap                  launcher for /usr/lib/lintap/Lintap
/etc/lintap/lintap.env           service environment/config override
/var/lib/lintap/data/            default shared data root
/var/lib/lintap/runtime/         default host-local runtime root
/usr/lib/systemd/system/lintap.service
```

The systemd service is enabled on install, but it is not started automatically. Start it manually after reviewing `/etc/lintap/lintap.env`.

## 1. Prepare a RHEL 8 x86_64 build host

Install required build tools. Package names may vary depending on your configured repositories:

```sh
sudo dnf install -y rpm-build dotnet-sdk-8.0 clang llvm make bpftool libbpf-devel elfutils-libelf-devel kernel-devel
```

If `dotnet-sdk-8.0` is unavailable, configure the Microsoft RHEL package repository first.

## 2. Build the RPM

From the mounted or cloned LLNL repo root:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8
```

Expected output ends with something like:

```text
==> Package built: /path/to/artifacts/lintap-rpm/x86_64/lintap-0.1.0-1.el8.x86_64.rpm
```

The final RPM is written under `artifacts/lintap-rpm`, but build intermediates, MCP publish output, and `dotnet publish` output are written to native `/var/tmp/lintap-rpm-build` by default. This is intentional for VM shared-mount builds and avoids small `/tmp` tmpfs limits. Override with `--work-root` or `LINTAP_RPM_WORK_ROOT` if needed.

### Cross-build from a non-x86 host

To build the same RHEL 8 `x86_64` RPM from a non-x86 host, such as Fedora `aarch64`, keep the target architecture and .NET runtime explicit:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --arch x86_64 \
  --runtime linux-x64
```

The .NET SDK must be able to restore/publish the `linux-x64` runtime pack. If using `--publish-dir`, the directory must already contain `linux-x64` output.

The RPM build disables ReadyToRun publishing because crossgen is expensive and unreliable during cross-architecture packaging.

## 3. Development build from existing output

If NuGet access is unavailable, package an existing build output as a framework-dependent smoke-test package:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --framework-dependent \
  --publish-dir wintap/wintap/bin/Debug/net8.0
```

The framework-dependent package declares `aspnetcore-runtime-8.0` as an RPM dependency.

## 4. Inspect the package before installing

```sh
rpm -qpi artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
rpm -qpl artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm | grep -E '(/usr/lib/lintap/Lintap$|/usr/lib/lintap/tracers/.*\.bpf\.o$|lintap.service|lintap.env|/usr/bin/lintap$)'
rpm -qp --scripts artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
```

Check RHEL 8 glibc compatibility:

```sh
rpm -qp --requires artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm | grep 'GLIBC_'
```

RHEL 8 provides glibc 2.28. If the RPM requires `GLIBC_2.29` or newer, a bundled native dependency must be replaced or rebuilt for RHEL 8 before installing on a RHEL 8 host.

## Current Build Result

On 2026-06-09, this command was run from a Fedora 44 `aarch64` VM and successfully cross-built the RHEL 8-tagged `x86_64` RPM:

```sh
TMPDIR=/var/tmp Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --arch x86_64 \
  --runtime linux-x64
```

Output artifact:

```text
/home/grantj/git/LLNL/artifacts/lintap-rpm/x86_64/lintap-0.1.0-1.el8.x86_64.rpm
```

Package metadata was verified with `rpm -qpi`:

```text
Name        : lintap
Version     : 0.1.0
Release     : 1.el8
Architecture: x86_64
Summary     : Lintap Linux sensor
```

Key payload paths were verified with `rpm -qpl`:

```text
/etc/lintap/lintap.env
/usr/bin/lintap
/usr/lib/lintap/Lintap
/usr/lib/lintap/mcp/wintap_mcp_server
/usr/lib/lintap/tracers/clone_tracer.bpf.o
/usr/lib/lintap/tracers/execve_tracer.bpf.o
/usr/lib/lintap/tracers/exit_tracer.bpf.o
/usr/lib/lintap/tracers/file_ops_tracer.bpf.o
/usr/lib/lintap/tracers/network_ops_tracer.bpf.o
/usr/lib/lintap/tracers/openat_tracer.bpf.o
/usr/lib/systemd/system/lintap.service
```

External config behavior was verified with `rpm -qpc`:

```text
/etc/lintap/lintap.env
```

Previous RHEL 8 blocker fixed in the current RPM build:

```text
libm.so.6(GLIBC_2.29)(64bit)
```

The newer glibc requirement was traced to bundled IronCompress native code:

```text
/var/tmp/lintap-rpm-build/publish/linux-x64/libnironcompress.so
```

RHEL 8 provides glibc 2.28. The current RPM build excludes `libnironcompress.so` and sets `WINTAP_PARQUET_COMPRESSION=Uncompressed` in `/etc/lintap/lintap.env`, avoiding the Snappy/IronCompress path by default. Rebuilt package validation showed no `GLIBC_2.29` requirement and no `libnironcompress.so` payload entry.

You should see:

```text
/etc/lintap/lintap.env
/usr/lib/systemd/system/lintap.service
/usr/lib/lintap/Lintap
/usr/lib/lintap/tracers/clone_tracer.bpf.o
/usr/lib/lintap/tracers/execve_tracer.bpf.o
/usr/lib/lintap/tracers/exit_tracer.bpf.o
/usr/lib/lintap/tracers/file_ops_tracer.bpf.o
/usr/lib/lintap/tracers/network_ops_tracer.bpf.o
/usr/lib/lintap/tracers/openat_tracer.bpf.o
/usr/bin/lintap
```

## 5. Install the package

```sh
sudo dnf install ./artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
```

If your package filename differs, list it first:

```sh
ls -lh artifacts/lintap-rpm/x86_64/*.rpm
```

## Quickstart: Install On A Target RHEL 8 Host

Copy the RPM to the RHEL 8 `x86_64` host, then install it:

```sh
sudo dnf install ./lintap-0.1.0-1.el8.x86_64.rpm
```

Review the external config before first start:

```sh
sudoedit /etc/lintap/lintap.env
```

Default config:

```text
WINTAP_DATA_ROOT=/var/lib/lintap/data
WINTAP_RUNTIME_ROOT=/var/lib/lintap/runtime
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
- Runtime logs, DuckDB, diagnostics, and state default under `/var/lib/lintap/runtime`; raw sensor output defaults under `/var/lib/lintap/data/raw_sensor`.
- The stable Linux sensors are enabled by default; `CloneSensor` remains disabled because `sched_process_fork` attach failed during Fedora bring-up.
- The RPM defaults `WINTAP_PARQUET_COMPRESSION=Uncompressed` for RHEL 8 glibc compatibility. Snappy remains the application default outside this package.
- The service is enabled during install, but not started automatically.

Start and inspect:

```sh
sudo systemctl start lintap
systemctl status lintap --no-pager
sudo journalctl -u lintap -n 100 --no-pager
systemctl cat lintap
```

Check output paths:

```sh
sudo find /var/lib/lintap/data /var/lib/lintap/runtime -maxdepth 4 -type f | sort
curl -fsS http://localhost:8099/ || true
```

After config changes:

```sh
sudoedit /etc/lintap/lintap.env
sudo systemctl restart lintap
```

## 6. Review installed config and service

```sh
cat /etc/lintap/lintap.env
systemctl cat lintap
```

Default config:

```text
WINTAP_DATA_ROOT=/var/lib/lintap/data
WINTAP_RUNTIME_ROOT=/var/lib/lintap/runtime
```

Data and logs should go under:

```text
/var/lib/lintap/data
/var/lib/lintap/data/raw_sensor
/var/lib/lintap/runtime
/var/lib/lintap/runtime/Logs
```

The RPM marks `/etc/lintap/lintap.env` as `%config(noreplace)` so local edits are preserved across upgrades when possible.

## 7. Start and inspect the service

```sh
sudo systemctl start lintap
systemctl status lintap --no-pager
sudo journalctl -u lintap -n 100 --no-pager
```

Follow logs live if needed:

```sh
sudo journalctl -u lintap -f
```

Check Lintap file logs:

```sh
sudo find /var/lib/lintap/data /var/lib/lintap/runtime -maxdepth 4 -type f | sort
sudo tail -n 100 /var/lib/lintap/runtime/Logs/Lintap.log
```

## 8. Basic runtime checks

Check the web host:

```sh
curl -fsS http://localhost:8099/ || true
```

Check eBPF object files:

```sh
ls -lh /usr/lib/lintap/tracers/*.bpf.o
```

Check for dotnet coredumps after startup testing:

```sh
coredumpctl list dotnet --no-pager
```

## 9. Uninstall

```sh
sudo dnf remove lintap
```

The package preserves `/var/lib/lintap` data and runtime state by default. Remove it manually if desired.
