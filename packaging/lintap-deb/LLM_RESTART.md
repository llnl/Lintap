# Lintap Debian Packaging Restart Notes for LLM/Tooling

## Objective

Build and smoke-test an Ubuntu/Debian `.deb` package for the Lintap Linux sensor from this source tree. This is currently a dev/smoke-test packaging effort, not final Debian-policy-clean release packaging.

## Environment facts

- The coding agent may be running on macOS and cannot build/test the Linux package locally.
- Ubuntu VM access is available through:

  ```sh
  ssh lintap-dev
  ```

- In the VM, the mounted repo root is:

  ```text
  /home/ubuntu/git
  ```

- From the macOS/current agent working directory, the repo root corresponds to:

  ```text
  /Users/johnson30/git-lintap
  ```

- Changes made locally are reflected in the VM mount.
- If root is needed in the VM, use `sudo` or `sudo su`.
- SSH currently emits this warning, but commands still run:

  ```text
  bind [::1]:4213: Address already in use
  channel_setup_fwd_listener_tcpip: cannot listen to port: 4213
  Could not request local forwarding.
  ```

## Relevant files added

```text
Lintap/packaging/lintap-deb/build-deb.sh
packaging/lintap-deb/lintap.service
packaging/lintap-deb/lintap.env
packaging/lintap-deb/README.md
packaging/lintap-deb/LLM_RESTART.md
packaging/lintap-deb/BUILD_AND_TEST.md
```

## Source paths

Lintap .NET project:

```text
wintap/wintap/Lintap.csproj
```

eBPF tracer source/build directory:

```text
wintap/wintap/platform/linux/sensor/ebpf/tracers
```

Existing dev build output known to exist in the VM:

```text
wintap/wintap/bin/Debug/net8.0
```

## Package behavior

The package installs:

```text
/usr/lib/lintap/                 Lintap app files
/usr/lib/lintap/tracers/*.bpf.o  compiled eBPF object files
/usr/bin/lintap                  launcher for /usr/lib/lintap/Lintap
/etc/lintap/lintap.env           systemd environment file
/var/log/lintap/                 default data root
/usr/lib/systemd/system/lintap.service
/usr/share/doc/lintap/README.md
```

Default service environment:

```text
WINTAP_DATA_ROOT=/var/log/lintap
```

The package enables the systemd service during install but intentionally does **not** start it automatically.

## Publish and restore guidance

A release candidate must use a fresh `dotnet publish`. The builder places
intermediate files under `/var/tmp/lintap-deb-build` by default, which avoids
publish failures caused by the mounted repository filesystem. If restore is
unavailable, use `--publish-dir` only for a development/smoke package:

## Arm64 build command

From the VM:

```sh
cd /home/ubuntu/git
Lintap/packaging/lintap-deb/build-deb.sh \
  --version 0.1.0 \
  --revision 1 \
  --host-arch aarch64
```

Known output:

```text
artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb
```

The VM architecture is `arm64`, and the eBPF Makefile compiles with:

```text
-D__TARGET_ARCH_arm64
```

## Previously validated package contents

This worked:

```sh
cd /home/ubuntu/git
dpkg-deb --info artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb
dpkg-deb --contents artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb | \
  grep -E '(/usr/lib/lintap/Lintap$|/usr/lib/lintap/tracers/.*\.bpf\.o$|lintap.service|lintap.env|/usr/bin/lintap$)'
```

Expected key files include the tracepoint tier:

```text
/etc/lintap/lintap.env
/usr/lib/systemd/system/lintap.service
/usr/lib/lintap/Lintap
/usr/lib/lintap/tracers/clone_tracer.bpf.o
/usr/lib/lintap/tracers/execve_tracepoint.bpf.o
/usr/lib/lintap/tracers/exit_tracepoint.bpf.o
/usr/lib/lintap/tracers/file_ops_tracepoint.bpf.o
/usr/lib/lintap/tracers/network_tracepoint.bpf.o
/usr/lib/lintap/tracers/openat_tracer.bpf.o
```

## Smoke-test install sequence

Use this when the user is ready to install/test:

```sh
ssh lintap-dev
cd /home/ubuntu/git
sudo apt install ./artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb
systemctl status lintap --no-pager
sudo systemctl start lintap
sleep 5
systemctl status lintap --no-pager
sudo journalctl -u lintap -n 100 --no-pager
sudo ls -la /var/log/lintap
sudo find /var/log/lintap -maxdepth 4 -type f | head -50
```

If dependency resolution complains about `aspnetcore-runtime-8.0`, check what runtimes are already installed:

```sh
dotnet --list-runtimes
```

For this dev package, installing the missing runtime may be enough if network/package sources permit:

```sh
sudo apt-get update
sudo apt-get install -y aspnetcore-runtime-8.0
```

If the runtime is installed but the package dependency cannot be satisfied due package-source metadata, install with `dpkg` only as a temporary smoke-test workaround:

```sh
sudo dpkg -i artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb
sudo apt-get -f install
```

Only suggest force options if the user accepts broken dependency risk.

## Useful debug commands

Package metadata/content:

```sh
dpkg-deb --info artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb
dpkg-deb --contents artifacts/lintap-deb/lintap_0.1.0-1_arm64.deb | less
```

Installed files:

```sh
dpkg -L lintap
ls -la /usr/lib/lintap
ls -la /usr/lib/lintap/tracers
cat /etc/lintap/lintap.env
systemctl cat lintap
```

Service logs:

```sh
sudo journalctl -u lintap -n 200 --no-pager
sudo tail -n 200 /var/log/lintap/Logs/Lintap.log
```

Manual run test:

```sh
cd /usr/lib/lintap
sudo env WINTAP_DATA_ROOT=/var/log/lintap ./Lintap
```

Cleanup:

```sh
sudo systemctl stop lintap || true
sudo apt remove lintap
# Data is intentionally preserved:
sudo ls -la /var/log/lintap
```

Purge package config only:

```sh
sudo apt purge lintap
```

Data under `/var/log/lintap` is intentionally preserved even on purge unless manually removed.

## Implementation notes

- `build-deb.sh` supports normal release publish, but it currently depends on NuGet/network working:

  ```sh
  Lintap/packaging/lintap-deb/build-deb.sh --version 0.1.0 --revision 1
  ```

- For dev/smoke testing, use `--publish-dir` to avoid NuGet.
- `--framework-dependent` sets package dependency on `aspnetcore-runtime-8.0`.
- Default package build is self-contained if `--framework-dependent` is not supplied.
- The service file uses:

  ```ini
  Type=notify
  WorkingDirectory=/usr/lib/lintap
  ExecStart=/usr/lib/lintap/Lintap
  LimitMEMLOCK=infinity
  ```

- Lintap code searches for eBPF objects in `AppContext.BaseDirectory/tracers`, which maps to `/usr/lib/lintap/tracers` after install.
- Lintap Linux data root defaults to `/var/log/lintap`, and `/etc/lintap/lintap.env` sets `WINTAP_DATA_ROOT=/var/log/lintap` explicitly.

## Next likely task

Help the user install and smoke-test the generated package. Expect runtime/systemd/eBPF issues rather than packaging-file issues. Capture exact errors from:

```sh
systemctl status lintap --no-pager
sudo journalctl -u lintap -n 200 --no-pager
sudo tail -n 200 /var/log/lintap/Logs/Lintap.log
```
