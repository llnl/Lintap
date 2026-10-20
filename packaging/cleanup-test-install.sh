#!/usr/bin/env bash
# Remove test-only Lintap state before manually installing a new package.
# This script is intentionally not invoked by package maintainer scripts.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: sudo packaging/cleanup-test-install.sh --yes

Stops Lintap services and irreversibly removes test-only state from:
  /var/lib/lintap                 legacy root
  /var/log/lintap                 current data and runtime roots
  /opt/lintap/pidstat-collector  managed pidstat virtual environment

It does not remove the installed package or /etc/lintap/lintap.env. The
pidstat service is disabled because its venv is removed; rerun
/usr/lib/lintap/pidstat-collector-bootstrap.sh and enable it explicitly after
installing a package if pidstat collection is wanted.
USAGE
}

if [[ ${1:-} != "--yes" || $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (for example: sudo $0 --yes)." >&2
  exit 1
fi

systemctl stop lintap-pidstat.service lintap.service 2>/dev/null || true
systemctl disable lintap-pidstat.service 2>/dev/null || true

rm -rf -- \
  /var/lib/lintap \
  /var/log/lintap \
  /opt/lintap/pidstat-collector

systemctl reset-failed lintap-pidstat.service 2>/dev/null || true
echo "Removed test-only Lintap state. Install the new package, then start lintap.service."
