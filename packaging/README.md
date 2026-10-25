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
| RPM (qualification pending) | RHEL 9 `x86_64` | native RHEL 9 `x86_64` with BTF | same RPM layout, explicitly use an `.el9` release |

Native builds are preferred because they can compile and validate CO-RE eBPF
objects against the host BTF. The Debian builder deliberately limits
cross-builds to the tracepoint-fallback tier; validate those packages on the
target kernel before release. The current RPM builder must run natively on an
`x86_64` host with readable BTF; see the RPM limitation below.

## Build prerequisites

Both formats require the **.NET 10 SDK, qualified version `10.0.402`**, Clang/LLVM, GNU Make, bpftool, libbpf
development headers, libelf development headers, and Linux kernel/BTF support
appropriate to the target.

Python 3 is also required for SDK-baseline and staged-runtimeconfig validation.

The SDK source of truth is the sibling [`wintap/global.json`](../../wintap/global.json).
It specifies `10.0.402`, `rollForward: latestPatch`, and no prereleases. For repeatable
package qualification, require the exact version, not merely any .NET 10 SDK.
`latestPatch` permits newer patches during ordinary development; it is not an exact
release-build pin. SDK `10.0.402` is distinct from the bundled runtime's version;
record the generated `Lintap.runtimeconfig.json` rather than calling the runtime
`10.0.402`.

Ubuntu package names:

```sh
sudo apt update
sudo apt install -y clang llvm make bpftool \
  libbpf-dev libelf-dev zlib1g-dev dpkg-dev fakeroot
```

RHEL 8 package names vary by enabled repositories. A typical set is:

```sh
sudo dnf install -y rpm-build clang llvm make bpftool \
  libbpf libbpf-devel elfutils-libelf elfutils-libelf-devel kernel-devel
```

Verify `/sys/kernel/btf/vmlinux` before expecting a native CO-RE build. The
builders always require and validate the tracepoint fallback objects.

### Install/select the pinned SDK

Distribution package names `dotnet-sdk-10.0` select a version available in the
enabled repositories, **not necessarily `10.0.402`**. On RHEL 9, .NET 10 is supplied
by Red Hat AppStream; do not add a second vendor's RPM feed to fix a version mismatch.
Check available versions before choosing a package-manager installation. If the
exact SDK is unavailable, use an approved official SDK archive or the isolated
installation below, with network access and local software-installation approval.
Do not replace an existing system SDK or virtual environment.

From the parent directory containing both checkouts:

```bash
SDK_VERSION=$(python3 -c 'import json; print(json.load(open("wintap/global.json"))["sdk"]["version"])')
test "$SDK_VERSION" = 10.0.402 || { echo "SDK baseline changed; review qualification before continuing"; exit 1; }
export DOTNET_ROOT="$HOME/.dotnet/wintap-sdk-$SDK_VERSION"
mkdir -p "$DOTNET_ROOT"
curl --fail --location https://dot.net/v1/dotnet-install.sh -o "$DOTNET_ROOT/dotnet-install.sh"
# Inspect/approve the downloaded installer before running it; do not curl | bash.
bash "$DOTNET_ROOT/dotnet-install.sh" --version "$SDK_VERSION" --install-dir "$DOTNET_ROOT" --no-path
export PATH="$DOTNET_ROOT:$PATH"
test "$(dotnet --version)" = "$SDK_VERSION" || { echo "Wrong SDK selected"; exit 1; }
(cd wintap && test "$(dotnet --version)" = "$SDK_VERSION") || { echo "Wintap SDK selection differs"; exit 1; }
dotnet --info
dotnet --list-runtimes
```

If an approved package-manager installation already selects the exact SDK, omit
the download/install steps and run both version checks. Keep the selected SDK on
`PATH` for every build. Both builders resolve `global.json` above the selected
project, run every `dotnet` command from that project directory, and reject a
selected SDK differing from the exact baseline before cleanup or native compilation.
This applies even with `--publish-dir`; staged output must include a valid
`Lintap.runtimeconfig.json` targeting `net10.0` with .NET 10.0 frameworks.
Its framework-dependent/self-contained shape must match the selected package mode.
Save source commit IDs, SDK/runtime versions, package hash and build logs with the
qualification results. Installer documentation and dependencies:
[Microsoft .NET on RHEL](https://learn.microsoft.com/en-us/dotnet/core/install/linux-rhel),
[scripted installation](https://learn.microsoft.com/en-us/dotnet/core/install/linux-scripted-manual).

## RHEL 9 prerequisites and operator-assisted qualification

**RHEL 9 is not yet qualified with this feature.** Ubuntu results and historical
RHEL 8 handoffs are not RHEL 9 acceptance. Use a designated native `x86_64` host;
the current RPM builder does not support `aarch64` or a tracepoint-only cross-build.
An `.el9` filename identifies this qualification attempt, not a compatibility proof.

Start with read-only inventory and return the output for review before installing
dependencies, changing repositories, building or touching a service:

```bash
cat /etc/os-release
uname -rm
id
dnf repolist --enabled
dnf --showduplicates list dotnet-sdk-10.0 libbpf libbpf-devel bpftool
command -v dotnet && dotnet --info
test -r /sys/kernel/btf/vmlinux && ls -lh /sys/kernel/btf/vmlinux
ldconfig -p | grep -E 'libbpf\.so|libelf\.so|libicu'
getenforce
cat /sys/kernel/security/lockdown 2>/dev/null
systemctl is-active lintap lintap-pidstat
df -h /var/tmp
```

Missing commands/files and unavailable packages are findings; return errors too.
Redact credentials, subscription identifiers and private repository URLs. Keep
SELinux, Secure Boot/lockdown and existing collectors unchanged. BTF presence does
not prove permission to attach every BPF hook.

For a registered RHEL 9 host, confirm BaseOS/AppStream are available. Development
headers may require CodeReady Linux Builder (CRB); enable it only with administrator
approval, using the repository appropriate to the actual architecture/subscription.
For `x86_64`, the usual command is:

```bash
sudo subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms
```

After repository/package review, the expected build/runtime prerequisite set is:

```bash
sudo dnf install -y git curl ca-certificates python3 gcc clang llvm make \
  rpm-build tar gzip binutils file pkgconf-pkg-config bpftool \
  libbpf libbpf-devel elfutils-libelf elfutils-libelf-devel zlib-devel \
  glibc libgcc libstdc++ openssl-libs libicu tzdata krb5-libs
```

Then select SDK `10.0.402` as above. Package availability depends on the enabled
repositories and RHEL minor release; do not substitute arbitrary third-party
libraries. `kernel-devel-$(uname -r)` is needed if building kernel-dependent tooling,
but does not substitute for `/sys/kernel/btf/vmlinux` in this CO-RE build.
Clang must support the BPF target, and bpftool must be able to dump the running
kernel's BTF. The managed resolver tries **`libbpf.so.1`, then `libbpf.so.0`, then
`libbpf.so`** (`wintap/platform/linux/sensor/ebpf/helpers/LibBpf.cs`). Record the
installed version/SONAME and qualify the actual APIs/hooks; successful library
loading alone is not ABI or sensor-attachment acceptance. Do not create a
`.so.0`→`.so.1` symlink or install arbitrary replacement libraries.

Build as an ordinary user on native storage, after verifying both source revisions
and saving unrelated dirty work separately (do not reset it):

```bash
git -C Lintap rev-parse HEAD
git -C wintap rev-parse HEAD
git -C Lintap status --short
git -C wintap status --short
test "$(dotnet --version)" = 10.0.402 || { echo "Wrong SDK selected"; exit 1; }
bash Lintap/packaging/lintap-rpm/build-rpm.sh \
  --version 0.1.0 --release 2.net10closure.el9 \
  --arch x86_64 --runtime linux-x64 \
  --work-root /var/tmp/lintap-rpm-net10closure-2
```

Use a fresh release/work root for subsequent attempts; the builder cleans its
chosen work/publish directories and runs `make clean` in the tracer source directory.
The command intentionally retains the default self-contained runtime and separate
MCP helper. If using `--skip-mcp`, label that qualification as excluding MCP.
The builder retains uncompressed Parquet; do not change compression or experiment
flags just to make RHEL 9 tests pass. Its legacy glibc warning is RHEL 8-specific,
not a RHEL 9 rejection criterion.

Inspect **before installation**:

```bash
RPM=artifacts/lintap-rpm/x86_64/lintap-0.1.0-2.net10closure.el9.x86_64.rpm
sha256sum "$RPM"
rpm -qpi "$RPM"
rpm -qpl "$RPM"
rpm -qp --scripts "$RPM"
rpm -qp --requires "$RPM"
getconf GNU_LIBC_VERSION
```

RHEL 9 uses glibc 2.34; compare all native requirements against the actual host,
not the builder's RHEL 8/2.28 warning. Self-contained .NET still requires OS native
libraries. Verify no initialized developer AgentId, foreign-OS libraries or build
debris is packaged, and that Clone CO-RE and fallback objects are included.
Stop on unresolved dependencies, missing BTF/ABI or build/payload failures.

Once installation/service changes are approved, follow **Install and configure**
and **Package and service smoke test** below. Report package installation, host-only
runtime, BPF attachment, independent process/file/bidirectional TCP checks, shutdown
and fresh DBT results separately. Use host-isolated capture roots, preserve identity
state/history, and obtain explicit approval before stopping an existing collector.
Do not bootstrap pidstat unless requested; the managed `/proc` collector needs
`uv` and its own Python 3.12 environment with DuckDB pinned to `1.5.6`. `sysstat`
is optional for independent `pidstat` comparisons, not a bootstrap requirement.

Operator-assisted sequence: inventory → prerequisite review → fresh build/package
inspection → approved installation → bounded capture/shutdown → downstream checks.
Return one batch's complete output and errors before advancing. Long-duration
collection and experimental-control/default-policy acceptance are separate gates.

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

The default package is self-contained. `--framework-dependent` now declares
`aspnetcore-runtime-10.0` in both Debian and RPM metadata. Both modes validate
the main staged app's .NET 10 runtimeconfig; exact-SDK, caller-directory and stale
payload regressions are in `tests/test_dotnet_packaging.py`. Fresh Linux package
build/inspection and installed-runtime acceptance remain qualification gates;
source/test alignment alone is not release certification. The corrective inventory
and results are in [the shared wiki](../../Wintap-Analytics/wiki/work/wintap-telemetry-identity-and-data-quality/runtime_alignment_plan.md).
The main app is always
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
- `--framework-dependent`: publish a .NET 10 app requiring system
  `aspnetcore-runtime-10.0`; qualify this mode separately from self-contained output.
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

# RHEL 8, or RHEL 9 after the qualification review above
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
- **libbpf load/API failure:** inspect `ldconfig -p` and the installed distribution
  runtime. The resolver supports `.so.1`/`.so.0`/`.so`, but required symbols and
  hook behavior must still be verified; do not fake a SONAME with a symlink.
- **RHEL glibc requirement newer than 2.28:** inspect bundled native libraries;
  do not deploy that RPM to RHEL 8. For RHEL 9, compare against its actual glibc
  (normally 2.34); an RHEL 8 warning is not itself a RHEL 9 failure.
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
