#!/usr/bin/env bash
# Explicit build-host setup; never invoked by package installation or services.
set -euo pipefail

version=1.27.3
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) echo 'ERROR: Go build setup supports Linux amd64/arm64 only' >&2; exit 1 ;;
esac
[[ "$(uname -s)" == Linux ]] || { echo 'ERROR: Linux build host required' >&2; exit 1; }
root="${LINTAP_GO_INSTALL_ROOT:-/opt/lintap-go}/$version"
if [[ -e "$root" ]]; then
  [[ -x "$root/bin/go" ]] && [[ "$(GOTOOLCHAIN=local "$root/bin/go" env GOVERSION)" == "go$version" ]] || {
    echo "ERROR: existing Go installation is invalid; inspect $root before retrying" >&2
    exit 1
  }
else
  mkdir -p "$(dirname "$root")"
  temp=$(mktemp -d "$(dirname "$root")/.go-install.XXXXXX")
  trap 'rm -rf -- "$temp"' EXIT
  curl --fail --location --retry 3 'https://go.dev/dl/?mode=json&include=all' -o "$temp/releases.json"
  checksum=$(python3 - "$temp/releases.json" "$version" "$arch" <<'PY'
import json
import re
import sys

path, version, arch = sys.argv[1:]
with open(path) as source:
    releases = json.load(source)
matches = [file["sha256"] for release in releases
           if release["version"] == "go" + version
           for file in release["files"]
           if file["filename"] == f"go{version}.linux-{arch}.tar.gz"]
if len(matches) != 1 or not re.fullmatch(r"[0-9a-f]{64}", matches[0]):
    raise SystemExit("ERROR: pinned Go archive checksum missing from official release metadata")
print(matches[0])
PY
  )
  curl --fail --location --retry 3 "https://go.dev/dl/go$version.linux-$arch.tar.gz" -o "$temp/go.tar.gz"
  printf '%s  %s\n' "$checksum" "$temp/go.tar.gz" | sha256sum --check --status
  tar -xzf "$temp/go.tar.gz" -C "$temp"
  [[ "$(GOTOOLCHAIN=local "$temp/go/bin/go" env GOVERSION)" == "go$version" ]]
  mv "$temp/go" "$root"
fi

# Print an explicit path; callers choose PATH/GO without replacing system Go.
if [[ "${LINTAP_GO_INSTALL_ROOT:-/opt/lintap-go}" == /opt/lintap-go && "$EUID" == 0 ]]; then
  printf 'export GO=%s/bin/go\nexport GOTOOLCHAIN=local\nexport PATH=%s/bin:$PATH\n' "$root" "$root" > /etc/profile.d/lintap-go.sh
fi
echo "==> Go build tool ready: $root/bin/go (go$version, linux/$arch)"
