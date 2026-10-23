# Building and Testing Lintap Packages

This is the canonical operational guide for building, inspecting, installing,
and smoke-testing Lintap Linux packages. Debian- and RPM-specific source files
remain under `lintap-deb/` and `lintap-rpm/`, but build procedures belong here.

For runtime data and state locations, see
[Paths and Configuration](PATHS_AND_CONFIGURATION.md). For every supported
builder option, run the relevant script with `--help`; the script is the
authoritative option reference.

## Source layout and build hosts

The examples assume a parent directory containing sibling checkouts:

```text
git/
├── Lintap/   # packaging scripts
└── wintap/   # Lintap.csproj and eBPF source
```

Run the commands from that parent directory. Use a Linux build host, not macOS.
The builders auto-detect `wintap/wintap/Lintap.csproj`; use `--project-dir`
when the checkouts have a different layout.

Build work defaults to native storage under `/var/tmp`. This avoids .NET
apphost and runtime-code-generation failures seen on VM shared mounts. Final
artifacts are written under `artifacts/` in the parent directory.

## Supported targets

| Format | Target | Preferred build host | Default output |
| --- | --- | --- | --- |
| Debian | Ubuntu/Debian `amd64` | native `x86_64` | `artifacts/lintap-deb/lintap_<version>-<revision>_amd64.deb` |
| Debian | Ubuntu/Debian `arm64` | native `aarch64` | `artifacts/lintap-deb/lintap_<version>-<revision>_arm64.deb` |
| RPM | RHEL 8 compatible `x86_64` | native `x86_64` | `artifacts/lintap-rpm/x86_64/lintap-<version>-<release>.x86_64.rpm` |

Native builds are preferred because they can compile and validate CO-RE eBPF
objects against the host BTF. The Debian builder deliberately limits
cross-builds to the tracepoint-fallback tier; validate those packages on the
target kernel before release. The current RPM builder must run natively on an
`x86_64` host with readable BTF; see the RPM limitation below.

## Build prerequisites

Both formats require the .NET 8 SDK, Clang/LLVM, GNU Make, bpftool, libbpf
development headers, libelf development headers, and Linux kernel/BTF support
appropriate to the target.

Ubuntu package names:

```sh
sudo apt update
sudo apt install -y dotnet-sdk-8.0 clang llvm make bpftool \
  libbpf-dev libelf-dev zlib1g-dev dpkg-dev fakeroot
```

RHEL 8 package names vary by enabled repositories. A typical set is:

```sh
sudo dnf install -y rpm-build dotnet-sdk-8.0 clang llvm make bpftool \
  libbpf libbpf-devel elfutils-libelf elfutils-libelf-devel kernel-devel
```

Verify `/sys/kernel/btf/vmlinux` before expecting a native CO-RE build. The
builders always require and validate the tracepoint fallback objects.

## Build Debian packages

Build for the native host architecture:

```sh
bash Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 \
  --revision 1
```

Specify the target explicitly when needed:

```sh
# Native arm64 host
bash Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 --revision 1 \
  --arch arm64 --runtime linux-arm64

# Native amd64 host
bash Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 --revision 1 \
  --arch amd64 --runtime linux-x64
```

The default package is self-contained. Use `--framework-dependent` only when
the target will provide `aspnetcore-runtime-8.0`. The main app is always
published with embedded MCP disabled; unless `--skip-mcp` is supplied, the MCP
helper is published separately under `/usr/lib/lintap/mcp`.

Inspect the result:

```sh
DEB=artifacts/lintap-deb/lintap_0.1.0-1_$(dpkg --print-architecture).deb
dpkg-deb --info "$DEB"
dpkg-deb --contents "$DEB"
lintian "$DEB" || true
```

## Build the RHEL 8 RPM

The supported RPM target is RHEL 8 compatible `x86_64` / `linux-x64`:

```sh
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 \
  --release 1.el8 \
  --arch x86_64 \
  --runtime linux-x64
```

Use a native `x86_64` build host with readable `/sys/kernel/btf/vmlinux`. The
script contains cross-build setup, but its current staged-payload validation
also unconditionally requires the CO-RE `file_ops_tracer.bpf.o`; because
cross-build mode disables BTF, that path cannot currently pass end to end.
Historical handoffs describe an earlier successful cross-build and must not be
treated as proof for the current builder.

Inspect the result:

```sh
RPM=artifacts/lintap-rpm/x86_64/lintap-0.1.0-1.el8.x86_64.rpm
rpm -qpi "$RPM"
rpm -qpl "$RPM"
rpm -qpc "$RPM"
rpm -qp --scripts "$RPM"
rpm -qp --requires "$RPM"
```

RHEL 8 provides glibc 2.28. Treat a generated requirement for `GLIBC_2.29` or
newer as a release blocker. The packaged RPM environment sets
`WINTAP_PARQUET_COMPRESSION=Uncompressed` to avoid the incompatible bundled
Snappy/IronCompress native library. Debian packages retain the application
default Snappy compression.

## Advanced build modes

Use these only for a specific build or diagnostic need:

- `--skip-mcp`: omit the separately published MCP helper.
- `--framework-dependent`: require the target .NET/ASP.NET Core 8 runtime.
- `--no-restore`: reuse an already restored dependency graph.
- `--publish-dir DIR`: package existing output; intended for development smoke
  tests, not a release artifact.
- `--work-root DIR`: move intermediate work while keeping it on a native
  filesystem.
- `--project-dir DIR`: point directly to the directory containing
  `Lintap.csproj`.

Do not infer cross-build correctness from package creation alone. Debian
cross-builds cannot validate CO-RE objects against the target kernel's BTF, and
the current RPM validation contract blocks its tracepoint-only cross-build.

## Install and configure

Install on a disposable or designated target host:

```sh
# Debian/Ubuntu
sudo apt install ./artifacts/lintap-deb/lintap_*_$(dpkg --print-architecture).deb

# RHEL 8
sudo dnf install ./artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
```

The package enables, but does not automatically start, `lintap.service` and
`lintap-pidstat.service`. Before first start:

1. Review `/etc/lintap/lintap.env`.
2. Confirm `WINTAP_DATA_ROOT` and `WINTAP_RUNTIME_ROOT`; see
   [Paths and Configuration](PATHS_AND_CONFIGURATION.md).
3. Clone collection is enabled by default for fork-before-exec coverage. Set
   `WINTAP_ENABLE_CLONE_SENSOR=false` for explicit opt-out. Review the durable
   HOST runtime receipt for the selected tier and individual hook outcomes;
   fallback thread classification is best-effort if syscall flag hooks fail.
   Upgrades preserve locally edited environment files: check for an old false
   setting rather than assuming the new package overrides administrator choices.
4. Bootstrap pidstat only if it is required:

   ```sh
   sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh
   ```

Start the selected services:

```sh
sudo systemctl daemon-reload
sudo systemctl start lintap
# Optional after bootstrap:
sudo systemctl start lintap-pidstat
```

## Package and service smoke test

Check the installed payload and service configuration:

```sh
test -x /usr/lib/lintap/Lintap
test -x /usr/bin/lintap
find /usr/lib/lintap/tracers -maxdepth 1 -name '*.bpf.o' -print | sort
systemctl cat lintap
grep -E '^(WINTAP_DATA_ROOT|WINTAP_RUNTIME_ROOT|WINTAP_ENABLE_.*_SENSOR)=' \
  /etc/lintap/lintap.env
```

Check startup and eBPF loading:

```sh
sudo systemctl restart lintap
systemctl status lintap --no-pager
sudo journalctl -u lintap -b --no-pager | tail -n 200
sudo tail -n 200 /var/log/lintap/runtime/Logs/Lintap.log
```

The `systemctl status lintap` description includes the installed package
version and release (for example, `Lintap Linux Sensor (0.1.0-1)` on Debian or
`Lintap Linux Sensor (0.1.0-1.el8)` on RPM). For an exact package-manager
query, use `dpkg-query -W -f='${Version}\n' lintap` or
`rpm -q --qf '%{VERSION}-%{RELEASE}\n' lintap`.

The application log is the higher-signal source for sensor attachment,
serializer counters, and final merge status. Confirm that the expected sensors
registered and that each enabled eBPF sensor loaded either its CO-RE object or
its tracepoint fallback.

Generate a bounded process/file/network workload, wait through the serializer
and merge interval, then verify finalized output:

```sh
sudo find /var/log/lintap/data/raw_sensor -type f -name '*.parquet' | sort | tail -n 50
sudo find /var/log/lintap/runtime/esper_staging -type f \
  \( -name '*.active' -o -name '*.parquet' \) | sort
```

For acceptance rather than a basic package smoke, run the current Wintap
`devtools` process, file, and network smoke tests and the Wintappy DBT suite
against an isolated data root. A clean shutdown must report drained serializer
and parquet queues, a successful final merge, and no leftover `.active` files.

## Upgrade, removal, and disposable-host cleanup

Use the package manager for normal upgrades and removal. Local edits to
`/etc/lintap/lintap.env` are intended to survive upgrades.

```sh
# Debian upgrade/removal
sudo apt install ./artifacts/lintap-deb/lintap_<new-version>_$(dpkg --print-architecture).deb
sudo apt remove lintap

# RPM upgrade/removal
sudo dnf upgrade ./artifacts/lintap-rpm/x86_64/lintap-<new-version>.x86_64.rpm
sudo dnf remove lintap
```

Package removal preserves telemetry. Only on a disposable test host, and only
when deleting all Lintap data is intentional, run from a Lintap checkout:

```sh
sudo Lintap/packaging/cleanup-test-install.sh --yes
```

## Troubleshooting

- **Shared-mount publish/apphost failure:** keep the default `/var/tmp` work
  root or choose another native filesystem with `--work-root`.
- **No CO-RE object:** confirm a native target build and readable
  `/sys/kernel/btf/vmlinux`. Debian cross-build mode intentionally packages
  fallback objects; the current RPM validator requires the CO-RE FileOps object
  and therefore needs a native BTF-enabled build.
- **`libbpf.so.1` load failure:** install the target distribution's libbpf
  runtime and inspect `ldconfig -p`.
- **RHEL glibc requirement newer than 2.28:** inspect bundled native libraries;
  do not deploy that RPM to RHEL 8.
- **Sparse journal output:** inspect
  `/var/log/lintap/runtime/Logs/Lintap.log`.
- **No output yet:** verify sensor registration, wait through the serializer and
  merge interval, and check both `runtime/esper_staging` and
  `data/raw_sensor`.

## Supporting records

The files below preserve design/review history; they are not alternate build
guides:

- [Debian packaging review](PACKAGING_REVIEW.md)
- [RHEL 8 migration handoff](lintap-rpm/RHEL8_HANDOFF.md)
- [RHEL 8 status snapshot](lintap-rpm/RHEL8_STATUS_HANDOFF_2026-06-19.md)
- [Debian tooling restart notes](lintap-deb/LLM_RESTART.md)
