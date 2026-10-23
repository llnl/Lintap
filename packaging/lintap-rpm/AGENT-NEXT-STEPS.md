# Agent Next Steps: Lintap RPM Packaging

> **Historical handoff.** This snapshot is retained for provenance and is not
> the current task list or build procedure. Use the canonical
> [package build and test guide](../README.md).

## Context

- `packaging/lintap-rpm/build-rpm.sh` now implements the initial RHEL 8 `x86_64` RPM workflow, including cross-builds from non-x86 hosts when the .NET SDK can publish `linux-x64`.
- The RPM mirrors the Ubuntu package layout: `/usr/lib/lintap`, `/usr/bin/lintap`, `/usr/lib/systemd/system/lintap.service`, `/var/log/lintap`, and external config at `/etc/lintap/lintap.env`.
- `/etc/lintap/lintap.env` is emitted as `%config(noreplace)` to preserve local edits across upgrades when possible.
- The packaged `/etc/lintap/lintap.env` enables the stable Linux sensors by default and leaves `CloneSensor` disabled.
- The script stages a filesystem root, packages it as `Source0`, generates a `.spec`, and runs `rpmbuild -bb`.
- The final RPM is written under `artifacts/lintap-rpm`; intermediates and `dotnet publish` output default to native `/var/tmp/lintap-rpm-build` to avoid shared-mount apphost mmap failures and small `/tmp` tmpfs limits.
- A Fedora 44 `aarch64` VM successfully cross-built `/home/grantj/git/LLNL/artifacts/lintap-rpm/x86_64/lintap-0.1.0-1.el8.x86_64.rpm` on 2026-06-09.
- The built RPM was inspected with `rpm -qpi`, `rpm -qpl`, `rpm -qpc`, `rpm -qp --scripts`, and `rpm -qp --requires`.
- The previous RHEL 8 blocker was a `GLIBC_2.29` requirement from bundled `/var/tmp/lintap-rpm-build/publish/linux-x64/libnironcompress.so`. The current RPM excludes that library and sets `WINTAP_PARQUET_COMPRESSION=Uncompressed`; rebuilt package validation showed no `GLIBC_2.29` requirement.
- This environment does not currently have `rpmbuild`, so only shell syntax and help-path validation were run here.

## Remaining Tasks On A RHEL 8 x86_64 Host

1. Install build dependencies:

   ```sh
   sudo dnf install -y rpm-build dotnet-sdk-8.0 clang llvm make bpftool libbpf-devel elfutils-libelf-devel kernel-devel
   ```

2. Build the RPM, explicitly targeting RHEL 8 x86_64 when cross-building:

   ```sh
   Lintap/packaging/lintap-rpm/build-rpm.sh --version 0.1.0 --release 1.el8 --arch x86_64 --runtime linux-x64
   ```

3. Inspect package metadata, contents, and scripts:

   ```sh
   rpm -qpi artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
   rpm -qpl artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
   rpm -qp --scripts artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
   ```

4. Install and smoke-test:

   ```sh
   sudo dnf install ./artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm
   cat /etc/lintap/lintap.env
   systemctl cat lintap
   sudo systemctl start lintap
   systemctl status lintap --no-pager
   sudo journalctl -u lintap -n 100 --no-pager
   ```

5. If RHEL dependency names differ, adjust `Requires:` in the generated spec section of `build-rpm.sh`.

6. Before installing on RHEL 8, check for `GLIBC_2.29` or newer requirements:

   ```sh
   rpm -qp --requires artifacts/lintap-rpm/x86_64/lintap-*.x86_64.rpm | grep 'GLIBC_'
   ```

   RHEL 8 provides glibc 2.28. A newer requirement means one of the bundled native libraries is not RHEL 8-compatible.
