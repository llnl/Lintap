# Lintap RPM Package

Build, inspection, installation, upgrade, and smoke-test instructions are
maintained in the canonical
[Lintap package build and test guide](../README.md). Use
`build-rpm.sh --help` for the authoritative option list.

## Installed package quick reference

- Supported target: RHEL 8 compatible `x86_64`
- Application: `/usr/lib/lintap/`
- Launcher: `/usr/bin/lintap`
- eBPF objects: `/usr/lib/lintap/tracers/`
- Service configuration: `/etc/lintap/lintap.env`
- Units: `lintap.service` and optional `lintap-pidstat.service`
- Durable output: `/var/log/lintap/data/raw_sensor/`
- Runtime state and logs: `/var/log/lintap/runtime/`

The services are enabled but not started automatically. Review the environment
file before first start. The RHEL 8 package sets uncompressed Parquet for glibc
compatibility. Clone collection is enabled by default; set
`WINTAP_ENABLE_CLONE_SENSOR=false` to opt out. Inspect HOST runtime capability
receipts for actual attach outcomes and fallback limitations.

See [Paths and Configuration](../PATHS_AND_CONFIGURATION.md) for root overrides
and shared-volume guidance.
