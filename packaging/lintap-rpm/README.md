# Lintap RPM Package

Build, inspection, installation, upgrade, and smoke-test instructions are
maintained in the canonical
[Lintap package build and test guide](../README.md). Use
`build-rpm.sh --help` for the authoritative option list.

## Go setup on a RHEL 8 build host

Use native **x86_64**, pinned **Go 1.27.3**, and the current sibling checkouts.
Go is needed only to build pidstat, not on hosts installing the RPM. Do not assume
RHEL's `golang` package supplies the pinned version.

From the directory containing `Lintap/` and `wintap/`, after approval to download
and install build tools:

```bash
sudo bash Lintap/packaging/install-build-go.sh
source /etc/profile.d/lintap-go.sh
"$GO" version
GOTOOLCHAIN=local "$GO" env GOVERSION GOHOSTOS GOHOSTARCH
source Lintap/packaging/pidstat-common.sh
lintap_require_pidstat_go
```

Expected: `go1.27.3`, host OS `linux`, host architecture `amd64`. The installer
verifies the official archive checksum and uses `/opt/lintap-go/1.27.3` without
replacing system Go. Keep `GO` exported in the shell running `build-rpm.sh`.
For a non-root, user-local installation, see the canonical guide's build prerequisites.

Required download endpoints include `go.dev`/its archive redirects and, for module
resolution, the configured Go module proxy/checksum service. Fix CA/proxy trust or
use an operator-verified cache on restricted hosts; do not disable TLS or permit
automatic toolchain upgrades (`GOTOOLCHAIN=local`).

The installer does not supply Clang/libbpf/bpftool or kernel BTF. A readable
`/sys/kernel/btf/vmlinux` and native RPM build/installed-runtime checks remain
separate prerequisites and qualification gates.

## Installed package quick reference

- Supported target: RHEL 8 compatible `x86_64`
- Application: `/usr/lib/lintap/`
- Launcher: `/usr/bin/lintap`
- eBPF objects: `/usr/lib/lintap/tracers/`
- Service configuration: `/etc/lintap/lintap.env`
- Units: `lintap.service` and optional `lintap-pidstat.service`
- pidstat: static Go `/usr/lib/lintap/pidstat-collector --collect`; no runtime bootstrap
- Build host: pinned Go 1.27.3 (`GO=/path/to/go` supported)
- Durable output: `/var/log/lintap/data/raw_sensor/`
- Runtime state and logs: `/var/log/lintap/runtime/`

The services are enabled but not started automatically. Review the environment
file before first start. The RHEL 8 package sets uncompressed Parquet for glibc
compatibility. Clone collection is enabled by default; set
`WINTAP_ENABLE_CLONE_SENSOR=false` to opt out. Inspect HOST runtime capability
receipts for actual attach outcomes and fallback limitations.

Periodic Refresh defaults to one hour. For repeated-exec qualification, set
`WINTAP_PROCESS_REFRESH_ENABLED=true`,
`WINTAP_PROCESS_REFRESH_INTERVAL_MINUTES=1`, and
`WINTAP_PROCESS_REFRESH_OFFSET_MINUTES=0` in `/etc/lintap/lintap.env` before
starting the service.

See [Paths and Configuration](../PATHS_AND_CONFIGURATION.md) for root overrides
and shared-volume guidance.
