# Lintap Debian Package

Build, inspection, installation, upgrade, and smoke-test instructions are
maintained in the canonical
[Lintap package build and test guide](../README.md). Use
`build-deb.sh --help` for the authoritative option list.

## Installed package quick reference

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
file before first start. Clone collection is enabled by default; set
`WINTAP_ENABLE_CLONE_SENSOR=false` to opt out. Inspect HOST runtime capability
receipts for actual attach outcomes and fallback limitations.

Periodic Refresh defaults to one hour. For repeated-exec qualification, set
`WINTAP_PROCESS_REFRESH_ENABLED=true`,
`WINTAP_PROCESS_REFRESH_INTERVAL_MINUTES=1`, and
`WINTAP_PROCESS_REFRESH_OFFSET_MINUTES=0` in `/etc/lintap/lintap.env` before
starting the service.

See [Paths and Configuration](../PATHS_AND_CONFIGURATION.md) for root overrides
and shared-volume guidance.
