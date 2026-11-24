#!/usr/bin/env bash
# Fedora first-pass setup steps
#
# Historical Fedora 44 / .NET 8 draft, retained for reference. It is not the
# current Lintap provisioning recipe (.NET 10); see ../wintap/BUILD_AND_TEST.md.
# Package failures are suppressed below, so completion is not setup validation.
# Reviewed for Bash syntax only; no host provisioning was performed at commit time.
#
# This script translates the Ubuntu cloud-init actions from multipass-lintap.sh
# into commands suitable for an interactive Fedora 44 developer VM (UTM).
# It's intended to be run step-by-step by a developer (or run as a whole with sudo).
#
# Usage (interactive):
#   1) Copy this file to the Fedora VM (or run via ssh)
#   2) Run commands manually, or run: sudo bash fedora-setup-first-pass.sh
#
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script should be run with sudo (it will re-run sudo'd actions as needed)."
  echo "Run: sudo bash $0"
fi

# Determine the non-root user to run user-scoped installers under.
# Prefer SUDO_USER when script is invoked via sudo. If not present, prefer
# a "grantj" user (shared mount owner) if it exists, otherwise fall back to
# the non-root USER environment value, finally root.
if [ -n "${SUDO_USER-}" ]; then
  DEVELOPER_USER="$SUDO_USER"
elif id -u grantj &>/dev/null; then
  DEVELOPER_USER=grantj
elif [ -n "${USER-}" ] && [ "${USER-}" != "root" ]; then
  DEVELOPER_USER="$USER"
else
  DEVELOPER_USER=root
fi
DEVELOPER_HOME="/home/${DEVELOPER_USER}"

echo "Using developer user: ${DEVELOPER_USER} (home: ${DEVELOPER_HOME})"

echo "1) System update"
dnf -y update

echo "2) Install development tools and common utilities"
# Use dnf5-compatible group subcommand: `dnf group install` (not `groupinstall`).
dnf -y group install development-tools

dnf -y install \
  git curl wget vim htop net-tools unzip tree \
  clang llvm bpftool libbpf-devel elfutils-libelf-devel \
  kernel-headers kernel-devel || true

echo "3) Optional: create asm symlink for aarch64 toolchains if present"
if [ "$(uname -m)" = "aarch64" ]; then
  if [ -d /usr/include/aarch64-linux-gnu/asm ] && [ ! -e /usr/include/asm ]; then
    echo "Creating /usr/include/asm -> /usr/include/aarch64-linux-gnu/asm"
    ln -s /usr/include/aarch64-linux-gnu/asm /usr/include/asm
  else
    echo "No aarch64 asm headers found, skipping symlink"
  fi
fi

echo "4) Install Microsoft .NET packages (Fedora)
Note: this adds the Microsoft yum repository and installs dotnet-sdk-8.0 and runtime."
rpm -Uvh https://packages.microsoft.com/config/fedora/44/packages-microsoft-prod.rpm || true
dnf -y update || true
dnf -y install dotnet-sdk-8.0 aspnetcore-runtime-8.0 || true

echo "5) Install DuckDB CLI for the developer user"
# The DuckDB installer typically installs into the invoking user's home.
if id "${DEVELOPER_USER}" &>/dev/null; then
  sudo -u "${DEVELOPER_USER}" -H bash -c 'curl -L https://install.duckdb.org | bash'
  if [ -f "${DEVELOPER_HOME}/.duckdb/cli/latest/duckdb" ]; then
    cp "${DEVELOPER_HOME}/.duckdb/cli/latest/duckdb" /usr/local/bin/duckdb
    chmod a+rx /usr/local/bin/duckdb
  else
    echo "DuckDB CLI not found in ${DEVELOPER_HOME}/.duckdb - installer may have changed."
  fi
else
  echo "Developer user ${DEVELOPER_USER} not found; skipping DuckDB install"
fi

echo
echo "=== Fedora first-pass setup complete ==="
echo "Check the following manually if needed:"
echo " - Confirm dotnet with: dotnet --info"
echo " - Confirm bpftool: bpftool version"
echo " - Confirm duckdb: duckdb --version"
echo
echo "Mounted repositories are available under /home/grantj/git as you mentioned."

exit 0
