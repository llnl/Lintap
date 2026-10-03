# Lintap Debian package

This directory contains Debian packaging for the Lintap Linux sensor. The
builder supports native amd64 and arm64 builds and keeps intermediate publish
and staging files on a native filesystem under `/var/tmp` by default.

## Quickstart: build packages

Build on Ubuntu, not macOS:

```sh
cd /path/to/git-lintap
```

The default build is self-contained .NET for the host Debian architecture. Output is written to:

```text
artifacts/lintap-deb/lintap_<version>-<revision>_<arch>.deb
```

The main application is published with MCP disabled. Unless `--skip-mcp` is
used, the MCP helper is published separately as a self-contained single-file
helper under `/usr/lib/lintap/mcp`.

### Build for the current host architecture

```sh
Lintap/packaging/lintap-deb/build-deb.sh --version 0.1.0 --revision 1
```

### Build an arm64 package

Use this on an arm64 Ubuntu host, or on a cross-build host with the required .NET runtime packs and eBPF tooling available:

```sh
Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 \
  --revision 3 \
  --arch arm64 \
  --runtime linux-arm64
```

This produces:

```text
artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb
```

### Build an amd64 package

Use this on an amd64 Ubuntu host, or on a cross-build host with the required .NET runtime packs and eBPF tooling available:

```sh
Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 \
  --revision 3 \
  --arch amd64 \
  --runtime linux-x64
```

This produces:

```text
artifacts/lintap-deb/lintap_0.1.0-1_amd64.deb
```

### Development/smoke-test build from existing output

If NuGet access is unavailable, package an existing build output as a framework-dependent smoke-test package:

```sh
Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 \
  --revision 1 \
  --framework-dependent \
  --publish-dir wintap/wintap/bin/Debug/net8.0
```

Useful options:

```sh
Lintap/packaging/lintap-deb/build-deb.sh --framework-dependent
Lintap/packaging/lintap-deb/build-deb.sh --skip-mcp
Lintap/packaging/lintap-deb/build-deb.sh --no-restore
Lintap/packaging/lintap-deb/build-deb.sh --work-root /var/tmp/lintap-deb-build
Lintap/packaging/lintap-deb/build-deb.sh --host-arch aarch64
Lintap/packaging/lintap-deb/build-deb.sh --project-dir /path/to/wintap/wintap
```

`--project-dir` or `LINTAP_PROJECT_DIR` can be used when the Lintap .NET project is outside the auto-detected checkout layouts.

`--publish-dir` is a development escape hatch: it skips `dotnet publish` and packages an existing publish/build output directory. Prefer a fresh `dotnet publish` for release packages. The script applies defensive filtering to this path and fails if forbidden build artifacts such as `obj/`, VCS metadata, `.venv/`, or `.fuse_hidden*` files would be staged.

## Tracer tiers

Every build validates the tracepoint fallback objects:

```text
clone_tracer.bpf.o
openat_tracer.bpf.o
execve_tracepoint.bpf.o
exit_tracepoint.bpf.o
network_tracepoint.bpf.o
file_ops_tracepoint.bpf.o
```

Native builds with readable kernel BTF also validate and package the CO-RE
objects. `selinux_tracer.bpf.o` is staged when present but is never required.
Cross-builds intentionally disable BTF and validate only the tracepoint tier.

## Build prerequisites

The build host needs the .NET 8 SDK and eBPF build tooling, for example:

```sh
sudo apt-get update
sudo apt-get install -y dotnet-sdk-8.0 clang llvm make bpftool libbpf-dev linux-headers-$(uname -r) dpkg-dev fakeroot
```

Package names may vary by Ubuntu release and by how Microsoft .NET packages are configured.

## Runtime layout

The package installs:

```text
/usr/lib/lintap/                 published Lintap app
/usr/lib/lintap/pidstat-collector.py  managed pidstat collector
/usr/lib/lintap/pidstat-collector-launch.sh
/usr/lib/lintap/pidstat-collector-bootstrap.sh
/usr/lib/lintap/tracers/*.bpf.o  eBPF tracer objects
/usr/bin/lintap                  launcher for /usr/lib/lintap/Lintap
/etc/lintap/lintap.env           systemd environment overrides
/var/log/lintap/                 default data root
/usr/lib/systemd/system/lintap.service
/usr/lib/systemd/system/lintap-pidstat.service
```

By default, `/etc/lintap/lintap.env` sets:

```text
WINTAP_DATA_ROOT=/var/log/lintap
PIDSTAT_INTERVAL_SEC=5
PIDSTAT_ROTATE_INTERVAL_SEC=300
PIDSTAT_MIN_ROTATE_INTERVAL_SEC=300
PIDSTAT_DUCKDB_THREADS=1
PIDSTAT_VENV_DIR=/opt/lintap/pidstat-collector/.venv
PIDSTAT_BOOTSTRAP_PYTHON=3.12
```

Lintap logs are expected under `/var/log/lintap/Logs`, parquet/raw sensor output under `/var/log/lintap/parquet`, and the pidstat collector keeps its active spool under `/var/log/lintap/pidstat-spool`.

The pidstat service runs as root for full `/proc` visibility, but it no longer
pins a host Python path. Instead, bootstrap a dedicated `uv`-managed venv and
the service launches `pidstat-collector.py` from that venv.

## Install and run

```sh
sudo apt install ./artifacts/lintap-deb/lintap_*_amd64.deb
sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh
sudo systemctl start lintap lintap-pidstat
sudo systemctl status lintap lintap-pidstat
sudo journalctl -u lintap-pidstat -f
```

The package enables the services on install but does not start them
automatically. An in-place upgrade does not stop or disable an already-running
service. `--work-root` defaults to `/var/tmp/lintap-deb-build`; final packages
remain under `artifacts/lintap-deb/`.
