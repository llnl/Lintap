#!/usr/bin/env bash
# Build-host-only Go collector release contract. Source this file.

lintap_require_pidstat_go() {
  LINTAP_PIDSTAT_GO=${GO:-go}
  local selected
  selected=$(GOTOOLCHAIN=local "$LINTAP_PIDSTAT_GO" env GOVERSION) || {
    echo 'ERROR: install Go 1.27.3 on the build host (or set GO to its executable)' >&2
    return 1
  }
  if [[ "$selected" != go1.27.3 ]]; then
    echo "ERROR: pidstat packaging requires Go 1.27.3; selected $selected" >&2
    return 1
  fi
}

lintap_pidstat_arch() {
  case "$1:$2" in
    amd64:linux-x64|x86_64:linux-x64) echo amd64 ;;
    arm64:linux-arm64|aarch64:linux-arm64) echo arm64 ;;
    *) echo "ERROR: unsupported pidstat package architecture/runtime: $1/$2" >&2; return 1 ;;
  esac
}

lintap_validate_pidstat_binary() {
  python3 - "$1" "$2" <<'PY'
import os
import struct
import sys

path, arch = sys.argv[1:]
try:
    with open(path, 'rb') as source:
        data = source.read()
    if not os.access(path, os.X_OK):
        raise ValueError('not executable')
    if data[:7] != b'\x7fELF\x02\x01\x01':
        raise ValueError('expected ELF64 little-endian executable')
    kind, machine = struct.unpack_from('<HH', data, 16)
    if kind not in (2, 3) or machine != {'amd64': 62, 'arm64': 183}[arch]:
        raise ValueError('wrong ELF type or target architecture')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    phsize, phnum = struct.unpack_from('<HH', data, 54)
    if phsize < 56 or not phnum or phoff + phsize * phnum > len(data):
        raise ValueError('invalid program headers')
    for i in range(phnum):
        offset = phoff + i * phsize
        ptype, = struct.unpack_from('<I', data, offset)
        if ptype == 3:
            raise ValueError('dynamic interpreter is forbidden')
        if ptype == 2:
            start, = struct.unpack_from('<Q', data, offset + 8)
            size, = struct.unpack_from('<Q', data, offset + 32)
            if size % 16 or start + size > len(data):
                raise ValueError('invalid dynamic segment')
            for entry in range(start, start + size, 16):
                tag, = struct.unpack_from('<q', data, entry)
                if tag == 0:
                    break
                if tag == 1:
                    raise ValueError('shared-library dependency is forbidden')
except (OSError, ValueError, KeyError, struct.error) as error:
    raise SystemExit(f'ERROR: invalid static pidstat binary {path}: {error}')
PY
}

lintap_stage_pidstat() (
  set -euo pipefail
  local build=$1 root=$2 arch
  arch=$(lintap_pidstat_arch "$3" "$4")
  lintap_validate_pidstat_binary "$build/pidstat-collector" "$arch"
  # A supplied development publish directory may still carry the Python payload.
  # Remove only these retired package files, never source or operator environments.
  rm -f -- "$root/usr/lib/lintap/pidstat-collector.py" \
    "$root/usr/lib/lintap/pidstat-collector-launch.sh" \
    "$root/usr/lib/lintap/pidstat-collector-bootstrap.sh"
  install -m 0755 "$build/pidstat-collector" "$root/usr/lib/lintap/pidstat-collector"
  install -m 0644 "$build/pidstat-collector.build.json" "$root/usr/share/doc/lintap/pidstat-collector.build.json"
)

lintap_build_pidstat() (
  set -euo pipefail
  local module=$1 output=$2 arch
  arch=$(lintap_pidstat_arch "$3" "$4")
  lintap_require_pidstat_go
  mkdir -p -- "$output"
  output=$(cd -- "$output" && pwd)
  cd -- "$module"
  GOTOOLCHAIN=local "$LINTAP_PIDSTAT_GO" mod verify
  GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOAMD64=v1 \
    "$LINTAP_PIDSTAT_GO" build -trimpath -buildvcs=false -o "$output/pidstat-collector" .
  lintap_validate_pidstat_binary "$output/pidstat-collector" "$arch"
  python3 - "$output/pidstat-collector" "$arch" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

binary = pathlib.Path(sys.argv[1])
manifest = {
    'go': '1.27.3', 'os': 'linux', 'arch': sys.argv[2], 'cgo_enabled': False,
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], universal_newlines=True).strip(),
    'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain', '--', '.'], universal_newlines=True)),
    'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'go_mod_sha256': hashlib.sha256(pathlib.Path('go.mod').read_bytes()).hexdigest(),
    'go_sum_sha256': hashlib.sha256(pathlib.Path('go.sum').read_bytes()).hexdigest(),
}
binary.with_suffix('.build.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f"==> Static pidstat {sys.argv[2]} SHA-256: {manifest['binary_sha256']}")
PY
)
