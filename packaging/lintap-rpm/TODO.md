# Task: Add RHEL8 RPM Support for Lintap

> **Historical task record.** The checklist below reflects the initial RPM
> implementation and may not describe current validation status. Use the
> canonical [package build and test guide](../README.md) for active procedures.

## Status: Initial implementation complete

## Goals
- Create a robust `build-rpm.sh` script in `packaging/lintap-rpm/`.
- Support RHEL 8 `x86_64` first.
- Generate valid RPM `.spec` files and packages via `rpmbuild`.
- Ensure parity with the Debian packaging logic (eBPF, systemd, environment files).

## Completed
- [x] Created `packaging/lintap-rpm/` directory.
- [x] Initialized `packaging/lintap-rpm/build-rpm.sh` from Debian template.
- [x] Added RHEL 8 x86_64 `build-rpm.sh` implementation using `rpmbuild`.
- [x] Added `lintap.service` and `/etc/lintap/lintap.env` external config parity with the Ubuntu package.
- [x] Added README and BUILD_AND_TEST usage, runtime layout, and package inspection docs.

## To Do
- [ ] Verify full `rpmbuild` build for `x86_64` on a host with `rpm-build` installed.
- [ ] Install and smoke-test on a RHEL 8 x86_64 host.
- [ ] Decide whether to add `aarch64` after x86_64 validation.

## Context
The Debian script handles staging a filesystem and then running `dpkg-deb --build`. The RPM script now:
1. Stage files into a directory structure.
2. Generate a `.spec` file.
3. Archive the staged root as `Source0`.
4. Run `rpmbuild -bb <spec_file>` for the requested target arch.
