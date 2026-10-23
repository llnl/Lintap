# Lintap Debian Packaging Review

> **Historical review record.** This file preserves the findings and their
> disposition; it is not an active build guide. Use
> [Building and Testing Lintap Packages](README.md) for current procedures.

Review scope: `Lintap/packaging/lintap-deb`, the package docs, the systemd unit/env file, and the existing `artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb` artifact.

This classifies the current findings into immediate fixes, should-do improvements, and nice-to-have cleanup.

## Immediate

These are likely to block repeatable packaging or cause misleading test results.

### 1. Fix package script repo-path assumptions — resolved

In the current checkout, the .NET project is a sibling repo/path:

```text
/home/ubuntu/git/wintap/wintap/Lintap.csproj
```

Implemented: `build-deb.sh` now supports `--project-dir` / `LINTAP_PROJECT_DIR` and auto-detects the sibling checkout layout. Packaging docs now use the actual script path for this checkout:

```sh
Lintap/packaging/lintap-deb/build-deb.sh
```

rather than assuming `packaging/lintap-deb/build-deb.sh` exists at the working directory root.

### 2. Do not treat `--publish-dir bin/Debug/net8.0` packages as release-quality — resolved for smoke-test packaging

The existing `.deb` artifact appears to include build-output pollution such as:

```text
/usr/lib/lintap/obj/...
/usr/lib/lintap/core/etl/.fuse_hidden...
/usr/lib/lintap/runtimes/win-...
/usr/lib/lintap/runtimes/osx-...
/usr/lib/lintap/runtimes/browser-wasm/...
/usr/lib/lintap/amd64/msdia140.dll
/usr/lib/lintap/arm64/msdia140.dll
```

This is understandable for a smoke-test escape hatch, but it makes the package large and non-deterministic. It can also accidentally package stale files, source/build metadata, temporary files, or platform-specific native assets that are irrelevant to the target Debian architecture.

Implemented: `--publish-dir` remains documented as dev/smoke-test only, fresh `dotnet publish` remains the preferred release path, and the script now filters common build/VCS/temp pollution before staging.

Minimum denylist candidates:

```text
obj/
bin/
.git/
.venv/
.fuse_hidden*
```

Optional release filtering:

```text
*.pdb
runtimes/win*
runtimes/osx*
runtimes/browser*
runtimes/* not matching target RID
```

### 3. Verify self-contained package behavior with MCP server — resolved

The main app defaults to self-contained packaging, but `Lintap.csproj` publishes the MCP server with:

```xml
--self-contained false
```

If the Debian package is built without `--framework-dependent`, the control file will not depend on `aspnetcore-runtime-8.0`, yet the packaged MCP helper may still require a system .NET runtime.

Implemented: `Lintap.csproj` now publishes the MCP helper with `--self-contained $(SelfContained)`, matching the main package mode.

## Should do

These are important before calling the package production/release-ready, but they do not necessarily block the current smoke test.

### 1. Make eBPF tracer packaging complete and validated — resolved

The package currently includes these eBPF objects:

```text
clone_tracer.bpf.o
execve_tracer.bpf.o
exit_tracer.bpf.o
file_ops_tracer.bpf.o
network_ops_tracer.bpf.o
```

However, the source tree also contains `openat_tracer.bpf.c`, and `OpenAtSensor.cs` references:

```text
openat_tracer.bpf.o
```

The current Linux subscription manager appears to use `FileOpsSensor`, not `OpenatSensor`, so this may be dead/legacy code. Still, it should be resolved explicitly.

Implemented: `openat_tracer.bpf.o` was added to the eBPF `Makefile` and to package validation/docs.

### 2. Tighten architecture handling for eBPF builds — resolved

The Debian script accepts `--arch` and `--runtime`, but the eBPF Makefile detects the build host architecture with:

```make
ARCH := $(shell uname -m)
```

This is fine for native builds, but misleading for cross-builds. For example, `--arch arm64 --runtime linux-arm64` on an x86_64 host would still compile eBPF with the host-derived target unless the Makefile is taught otherwise.

Implemented: `build-deb.sh` now maps `amd64/linux-x64` to `TARGET_ARCH=x86_64`, maps `arm64/linux-arm64` to `TARGET_ARCH=arm64`, passes that to `make`, and fails fast on unsupported Debian arch/RID pairings.

### 3. Add package-content assertions to the build script — resolved

The docs show manual checks with `dpkg-deb --contents`, but the build itself does not enforce them.

Implemented: the build script now validates staged package contents before `dpkg-deb --build`:

- `/usr/lib/lintap/Lintap` exists and is executable.
- Expected `.bpf.o` files exist.
- `/usr/bin/lintap` launcher exists and is executable.
- `lintap.service` and `lintap.env` are present.
- No `obj/`, `.git/`, `.venv/`, or `.fuse_hidden*` files are staged.
- For framework-dependent packages, runtimeconfig/deps files are present.
- For self-contained packages, expected native runtime files are present and `aspnetcore-runtime-8.0` is not required unless MCP remains framework-dependent.

### 4. Use `/usr/lib/systemd/system` instead of `/lib/systemd/system` — resolved

The package currently installs:

```text
/lib/systemd/system/lintap.service
```

This works on many Debian/Ubuntu systems, but `/usr/lib/systemd/system` is the more modern vendor unit location. Debian historically also uses `/lib/systemd/system`, so this is not urgent for Ubuntu smoke tests.

Implemented: the package now stages `lintap.service` under `/usr/lib/systemd/system/lintap.service`, and docs were updated accordingly.

### 5. Improve maintainer scripts for upgrade behavior

The current maintainer scripts are simple and reasonable for smoke testing. Before release, consider upgrade semantics:

- `prerm remove` stops and disables the service.
- Upgrades may call maintainer scripts with arguments other than simple `remove`/`configure`.
- A package upgrade should usually not unexpectedly leave the service disabled if it was previously enabled.

Recommended action:

- Handle `upgrade`, `failed-upgrade`, `abort-install`, and `abort-upgrade` cases deliberately.
- Consider using `deb-systemd-helper` / `deb-systemd-invoke` patterns if aiming for Debian-policy-clean packaging.

### 6. Validate dependencies from actual binaries

The control file declares:

```text
libbpf1, libc6, zlib1g, libelf1, systemd
```

and for framework-dependent builds:

```text
aspnetcore-runtime-8.0
```

This is plausible, but should be checked against native dependencies in the final publish output, especially libraries under `runtimes/linux-*/native`.

Recommended checks:

```sh
ldd /usr/lib/lintap/Lintap || true
find /usr/lib/lintap -name '*.so' -exec ldd {} \; | less
```

Then update Debian dependencies if additional native packages are required.

## Nice to have

These are quality-of-life, policy, maintainability, or hardening improvements.

### 1. Add package linting

Run packaging lint tools as a non-blocking or eventually blocking step:

```sh
lintian artifacts/lintap-deb/lintap_*.deb
```

This will catch Debian-policy issues such as permissions, maintainer metadata, documentation compression, changelog/copyright expectations, systemd unit locations, and package naming conventions.

### 2. Generate Debian metadata from templates

Currently `control`, `conffiles`, `postinst`, `prerm`, and `postrm` are generated inline inside `build-deb.sh`.

For a small smoke-test package this is acceptable. For maintainability, consider moving these into template files under something like:

```text
Lintap/packaging/lintap-deb/debian/control.in
Lintap/packaging/lintap-deb/debian/postinst
Lintap/packaging/lintap-deb/debian/prerm
Lintap/packaging/lintap-deb/debian/postrm
```

Then the script only substitutes version/arch/dependency values.

### 3. Package docs more cleanly

The package installs:

```text
/usr/share/doc/lintap/README.md
```

For release-quality Debian packaging, also consider:

```text
/usr/share/doc/lintap/changelog.Debian.gz
/usr/share/doc/lintap/copyright
```

### 4. Revisit service hardening after eBPF requirements are known

The current service intentionally runs permissively:

```ini
User=root
Group=root
NoNewPrivileges=false
LimitMEMLOCK=infinity
```

That is reasonable for initial eBPF validation. Later, evaluate whether any of the following are safe:

```ini
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=
ProtectHome=
PrivateTmp=
RestrictAddressFamilies=
ReadWritePaths=/var/log/lintap /etc/lintap
```

Because eBPF and process/network telemetry often require elevated privileges, this should be tested carefully by Ubuntu/kernel version.

### 5. Add versioning/reproducibility conventions

Current version derivation uses tags or `0.1.0~git<sha>`. That is fine for now, but release packaging should define:

- How package version maps to app version.
- How Debian revision increments
