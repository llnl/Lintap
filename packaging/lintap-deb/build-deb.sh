#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build an Ubuntu .deb package for the Lintap sensor.

Usage:
  Lintap/packaging/lintap-deb/build-deb.sh [options]

Options:
  --version VERSION       Debian package version. Default: git-derived or 0.1.0
  --revision REVISION     Debian package revision. Default: 1
  --runtime RID           .NET runtime identifier. Default: auto from dpkg arch
  --arch ARCH             Debian architecture. Default: dpkg --print-architecture
  --project-dir DIR       Lintap .NET project directory. Default: auto-detect
  --skip-mcp              Do not publish/package the MCP server helper
  --framework-dependent   Publish framework-dependent and depend on aspnetcore-runtime-8.0
  --configuration CONFIG   dotnet publish configuration. Default: Release
  --no-restore            Pass --no-restore to dotnet publish
  --publish-dir DIR       Skip dotnet publish and stage an existing publish/build directory
  --host-arch ARCH        Build host architecture. Default: uname -m
  --work-root DIR         Native filesystem work root. Default: /var/tmp/lintap-deb-build
  --no-clean              Do not remove previous packaging work directory
  -h, --help              Show this help

Environment overrides:
  LINTAP_VERSION, LINTAP_REVISION, LINTAP_RUNTIME, LINTAP_ARCH,
  LINTAP_PROJECT_DIR, LINTAP_SELF_CONTAINED=true|false, LINTAP_OUTPUT_DIR,
  LINTAP_CONFIGURATION, LINTAP_NO_RESTORE=true|false, LINTAP_SKIP_MCP=true|false,
  LINTAP_DEB_WORK_ROOT, LINTAP_EXISTING_PUBLISH_DIR
USAGE
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)

PACKAGE_NAME=lintap
MAINTAINER="LLNL TeleTap Team <grantj@llnl.gov>"
REVISION=${LINTAP_REVISION:-1}
DEB_ARCH=${LINTAP_ARCH:-}
RUNTIME=${LINTAP_RUNTIME:-}
SELF_CONTAINED=${LINTAP_SELF_CONTAINED:-true}
CONFIGURATION=${LINTAP_CONFIGURATION:-Release}
NO_RESTORE=${LINTAP_NO_RESTORE:-false}
SKIP_MCP=${LINTAP_SKIP_MCP:-false}
EXISTING_PUBLISH_DIR=${LINTAP_EXISTING_PUBLISH_DIR:-}
PROJECT_DIR=${LINTAP_PROJECT_DIR:-}
CLEAN=true
OUTPUT_ROOT=${LINTAP_OUTPUT_DIR:-"$REPO_ROOT/artifacts/lintap-deb"}
WORK_ROOT=${LINTAP_DEB_WORK_ROOT:-"/var/tmp/lintap-deb-build"}
VERSION=${LINTAP_VERSION:-}
HOST_ARCH=${LINTAP_HOST_ARCH:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION=${2:?--version requires a value}
      shift 2
      ;;
    --revision)
      REVISION=${2:?--revision requires a value}
      shift 2
      ;;
    --runtime)
      RUNTIME=${2:?--runtime requires a value}
      shift 2
      ;;
    --arch)
      DEB_ARCH=${2:?--arch requires a value}
      shift 2
      ;;
    --project-dir)
      PROJECT_DIR=${2:?--project-dir requires a value}
      shift 2
      ;;
    --skip-mcp)
      SKIP_MCP=true
      shift
      ;;
    --framework-dependent)
      SELF_CONTAINED=false
      shift
      ;;
    --configuration)
      CONFIGURATION=${2:?--configuration requires a value}
      shift 2
      ;;
    --no-restore)
      NO_RESTORE=true
      shift
      ;;
    --publish-dir)
      EXISTING_PUBLISH_DIR=${2:?--publish-dir requires a value}
      shift 2
      ;;
    --host-arch)
      HOST_ARCH=${2:?--host-arch requires a value}
      shift 2
      ;;
    --work-root)
      WORK_ROOT=${2:?--work-root requires a value}
      shift 2
      ;;
    --no-clean)
      CLEAN=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

require_cmd dotnet
require_cmd make
require_cmd dpkg-deb
require_cmd dpkg
require_cmd clang
require_cmd bpftool
require_cmd ldd

if [[ -z "$PROJECT_DIR" ]]; then
  project_candidates=(
    "$REPO_ROOT/wintap/wintap"
    "$SCRIPT_DIR/../../wintap/wintap"
    "$SCRIPT_DIR/../../../wintap/wintap"
    "$SCRIPT_DIR/../../../../wintap/wintap"
  )
  for candidate in "${project_candidates[@]}"; do
    if [[ -f "$candidate/Lintap.csproj" ]]; then
      PROJECT_DIR=$(cd -- "$candidate" && pwd)
      break
    fi
  done
fi

if [[ -z "$PROJECT_DIR" ]]; then
  echo "ERROR: could not auto-detect Lintap project directory; pass --project-dir or set LINTAP_PROJECT_DIR" >&2
  exit 1
fi

PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd)
PROJECT="$PROJECT_DIR/Lintap.csproj"
EBPF_DIR="$PROJECT_DIR/platform/linux/sensor/ebpf/tracers"
MCP_PROJECT="$PROJECT_DIR/../shared/ai/wintap_mcp_server/wintap_mcp_server.csproj"

if [[ ! -f "$PROJECT" ]]; then
  echo "ERROR: could not find $PROJECT" >&2
  exit 1
fi

if [[ ! -d "$EBPF_DIR" ]]; then
  echo "ERROR: could not find eBPF tracer directory $EBPF_DIR" >&2
  exit 1
fi

if [[ -z "$DEB_ARCH" ]]; then
  DEB_ARCH=$(dpkg --print-architecture)
fi

if [[ -z "$HOST_ARCH" ]]; then
  HOST_ARCH=$(uname -m)
fi

if [[ -z "$RUNTIME" ]]; then
  case "$DEB_ARCH" in
    amd64) RUNTIME=linux-x64 ;;
    arm64) RUNTIME=linux-arm64 ;;
    *)
      echo "ERROR: do not know default .NET RID for Debian arch '$DEB_ARCH'; pass --runtime" >&2
      exit 1
      ;;
  esac
fi

case "$DEB_ARCH:$RUNTIME" in
  # The eBPF build uses __TARGET_ARCH_x86 (not x86_64).
  amd64:linux-x64) EBPF_TARGET_ARCH=x86 ;;
  arm64:linux-arm64) EBPF_TARGET_ARCH=arm64 ;;
  *)
    echo "ERROR: Debian arch '$DEB_ARCH' and .NET runtime '$RUNTIME' are not a supported pair" >&2
    echo "       supported pairs: amd64/linux-x64, arm64/linux-arm64" >&2
    exit 1
    ;;
esac

if [[ "$HOST_ARCH" != aarch64 && "$HOST_ARCH" != x86_64 ]]; then
  echo "ERROR: unsupported build host architecture '$HOST_ARCH'" >&2
  exit 1
fi

if [[ "$HOST_ARCH" == aarch64 && "$DEB_ARCH" == arm64 ]] ||
   [[ "$HOST_ARCH" == x86_64 && "$DEB_ARCH" == amd64 ]]; then
  echo "==> Building native target Debian arch '$DEB_ARCH' / RID '$RUNTIME'"
else
  echo "==> Cross-building target Debian arch '$DEB_ARCH' / RID '$RUNTIME' from host arch '$HOST_ARCH'"
  echo "==> The .NET SDK must be able to restore/publish runtime pack '$RUNTIME' on this host"
fi

if [[ -z "$VERSION" ]]; then
  if git -C "$REPO_ROOT" describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 | sed 's/^v//')
  else
    short_sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)
    if [[ -n "$short_sha" ]]; then
      VERSION="0.1.0~git$short_sha"
    else
      VERSION="0.1.0"
    fi
  fi
fi

PACKAGE_VERSION="${VERSION}-${REVISION}"
WORK_DIR="$WORK_ROOT/work/$DEB_ARCH-$RUNTIME"
PUBLISH_DIR="$WORK_ROOT/publish/$RUNTIME"
PKG_ROOT="$WORK_DIR/pkgroot"
DEBIAN_DIR="$PKG_ROOT/DEBIAN"
MSBUILD_NATIVE_ROOT="$WORK_ROOT/msbuild/$DEB_ARCH-$RUNTIME"
MCP_PUBLISH_ROOT="$WORK_ROOT/mcp-publish/$DEB_ARCH-$RUNTIME"
MCP_OUTPUT_ROOT="$WORK_ROOT/mcp-output/$DEB_ARCH-$RUNTIME"
DEB_FILE="$OUTPUT_ROOT/${PACKAGE_NAME}_${PACKAGE_VERSION}_${DEB_ARCH}.deb"

if [[ "$CLEAN" == true ]]; then
  rm -rf "$WORK_DIR" "$PUBLISH_DIR" "$MSBUILD_NATIVE_ROOT" "$MCP_PUBLISH_ROOT" "$MCP_OUTPUT_ROOT"
fi
mkdir -p "$OUTPUT_ROOT" "$PUBLISH_DIR" "$DEBIAN_DIR"

echo "==> Debian output root: $OUTPUT_ROOT"
echo "==> Native work root: $WORK_ROOT"

echo "==> Building eBPF tracers ($EBPF_TARGET_ARCH)"
ebpf_make_args=(clean all TARGET_ARCH="$EBPF_TARGET_ARCH")
host_arch=$(uname -m)
if [[ "$HOST_ARCH" != "$host_arch" ]]; then
  echo "ERROR: --host-arch '$HOST_ARCH' does not match uname -m '$host_arch'" >&2
  exit 1
fi
if [[ "$HOST_ARCH" != aarch64 && "$DEB_ARCH" == arm64 ]] ||
   [[ "$HOST_ARCH" != x86_64 && "$DEB_ARCH" == amd64 ]]; then
  ebpf_make_args+=(VMLINUX_BTF=/__lintap_crossbuild_no_btf__)
fi
make -C "$EBPF_DIR" "${ebpf_make_args[@]}"

DOTNET_DEPENDS=""
if [[ "$SELF_CONTAINED" != true ]]; then
  DOTNET_DEPENDS="aspnetcore-runtime-8.0, "
fi

if [[ -n "$EXISTING_PUBLISH_DIR" ]]; then
  if [[ ! -d "$EXISTING_PUBLISH_DIR" ]]; then
    echo "ERROR: --publish-dir does not exist or is not a directory: $EXISTING_PUBLISH_DIR" >&2
    exit 1
  fi
  echo "==> Using existing Lintap publish/build directory: $EXISTING_PUBLISH_DIR"
  rm -rf "$PUBLISH_DIR"
  mkdir -p "$PUBLISH_DIR"
  cp -R "$EXISTING_PUBLISH_DIR"/. "$PUBLISH_DIR/"
else
  echo "==> Publishing Lintap ($RUNTIME, configuration=$CONFIGURATION, self-contained=$SELF_CONTAINED)"
  # Prevent the Lintap project’s post-publish copy target from reusing MCP
  # output left by an earlier build, especially for --skip-mcp.
  rm -rf "$MCP_OUTPUT_ROOT"
  publish_args=(
    publish "$PROJECT"
    -c "$CONFIGURATION"
    -r "$RUNTIME"
    --self-contained "$SELF_CONTAINED"
    -p:RuntimeIdentifier="$RUNTIME"
    -p:NativeBuildRoot="$MSBUILD_NATIVE_ROOT/"
    -p:McpPublishTempDir="$MCP_PUBLISH_ROOT/"
    -p:McpOutputDir="$MCP_OUTPUT_ROOT/"
    -p:EnableMcpServer=false
    -p:PublishReadyToRun=false
    -p:PublishSingleFile=false
    -o "$PUBLISH_DIR"
  )
  if [[ "$NO_RESTORE" == true ]]; then
    publish_args+=(--no-restore)
  fi
  DISABLE_MCP=true dotnet "${publish_args[@]}"

  if [[ "$SKIP_MCP" != true && -f "$MCP_PROJECT" ]]; then
    echo "==> Publishing MCP server separately ($RUNTIME)"
    rm -rf "$MCP_PUBLISH_ROOT"
    mkdir -p "$MCP_PUBLISH_ROOT" "$PUBLISH_DIR/mcp"
    mcp_publish_args=(
      publish "$MCP_PROJECT"
      -c "$CONFIGURATION"
      -r "$RUNTIME"
      --self-contained "$SELF_CONTAINED"
      -p:PublishSingleFile=true
      -p:PublishReadyToRun=false
      -p:UseAppHost=true
      -p:GenerateAssemblyInfo=false
      -p:GenerateTargetFrameworkAttribute=false
      -p:BaseIntermediateOutputPath="$MCP_PUBLISH_ROOT/obj/"
      -p:BaseOutputPath="$MCP_PUBLISH_ROOT/bin/"
      -o "$MCP_PUBLISH_ROOT"
    )
    if [[ "$NO_RESTORE" == true ]]; then
      mcp_publish_args+=(--no-restore)
    fi
    dotnet "${mcp_publish_args[@]}"
    cp -R "$MCP_PUBLISH_ROOT"/. "$PUBLISH_DIR/mcp/"
  fi
fi

if [[ "$SKIP_MCP" == true ]]; then
  rm -rf "$PUBLISH_DIR/mcp" "$PUBLISH_DIR/mcp_temp"
fi

# Defensive cleanup for development builds used with --publish-dir. A normal
# dotnet publish output should not contain these files/directories, but bin/Debug
# trees can. Keep --publish-dir suitable for smoke tests without packaging stale
# intermediates, VCS metadata, FUSE temp files, or native assets for other OSes.
find "$PUBLISH_DIR" \
  \( -type d \( -name obj -o -name bin -o -name .git -o -name .venv \) -prune \
  -o -type f -name '.fuse_hidden*' \) -exec rm -rf {} +
rm -rf \
  "$PUBLISH_DIR/runtimes/win"* \
  "$PUBLISH_DIR/runtimes/osx"* \
  "$PUBLISH_DIR/runtimes/browser"* \
  "$PUBLISH_DIR/amd64" \
  "$PUBLISH_DIR/arm64"

echo "==> Staging package filesystem"
rm -rf "$PKG_ROOT"
mkdir -p \
  "$PKG_ROOT/usr/lib/lintap" \
  "$PKG_ROOT/usr/bin" \
  "$PKG_ROOT/etc/lintap" \
  "$PKG_ROOT/var/log/lintap" \
  "$PKG_ROOT/usr/lib/systemd/system" \
  "$PKG_ROOT/usr/share/doc/lintap" \
  "$DEBIAN_DIR"

cp -R "$PUBLISH_DIR"/. "$PKG_ROOT/usr/lib/lintap/"
install -m 0644 "$SCRIPT_DIR/lintap.service" "$PKG_ROOT/usr/lib/systemd/system/lintap.service"
install -m 0644 "$SCRIPT_DIR/lintap-pidstat.service" "$PKG_ROOT/usr/lib/systemd/system/lintap-pidstat.service"
install -m 0644 "$SCRIPT_DIR/lintap.env" "$PKG_ROOT/etc/lintap/lintap.env"
install -m 0755 "$SCRIPT_DIR/../../pidstat-collector.py" "$PKG_ROOT/usr/lib/lintap/pidstat-collector.py"
install -m 0755 "$SCRIPT_DIR/../../pidstat-collector-launch.sh" "$PKG_ROOT/usr/lib/lintap/pidstat-collector-launch.sh"
install -m 0755 "$SCRIPT_DIR/../../pidstat-collector-bootstrap.sh" "$PKG_ROOT/usr/lib/lintap/pidstat-collector-bootstrap.sh"
cat > "$PKG_ROOT/usr/bin/lintap" <<'EOF'
#!/bin/sh
exec /usr/lib/lintap/Lintap "$@"
EOF
chmod 0755 "$PKG_ROOT/usr/bin/lintap"

if [[ -f "$SCRIPT_DIR/README.md" ]]; then
  install -m 0644 "$SCRIPT_DIR/README.md" "$PKG_ROOT/usr/share/doc/lintap/README.md"
fi

if [[ -x "$PKG_ROOT/usr/lib/lintap/Lintap" ]]; then
  chmod 0755 "$PKG_ROOT/usr/lib/lintap/Lintap"
else
  chmod 0755 "$PKG_ROOT/usr/lib/lintap/Lintap" 2>/dev/null || true
fi
if [[ -x "$PKG_ROOT/usr/lib/lintap/mcp/wintap_mcp_server" ]]; then
  chmod 0755 "$PKG_ROOT/usr/lib/lintap/mcp/wintap_mcp_server"
fi

# Ensure eBPF objects are present even if future project publish rules change.
mkdir -p "$PKG_ROOT/usr/lib/lintap/tracers"
find "$EBPF_DIR" -maxdepth 1 -name '*.bpf.o' -exec install -m 0644 {} "$PKG_ROOT/usr/lib/lintap/tracers/" \;

assert_exists() {
  if [[ ! -e "$PKG_ROOT$1" ]]; then
    echo "ERROR: staged package is missing required path: $1" >&2
    exit 1
  fi
}

assert_not_staged() {
  local pattern=$1
  local found
  found=$(find "$PKG_ROOT" -path "$pattern" -print -quit)
  if [[ -n "$found" ]]; then
    echo "ERROR: staged package contains forbidden path: ${found#$PKG_ROOT/}" >&2
    exit 1
  fi
}

echo "==> Validating staged package contents"
assert_exists /usr/lib/lintap/Lintap
if [[ ! -x "$PKG_ROOT/usr/lib/lintap/Lintap" ]]; then
  echo "ERROR: /usr/lib/lintap/Lintap is not executable" >&2
  exit 1
fi
assert_exists /usr/bin/lintap
if [[ ! -x "$PKG_ROOT/usr/bin/lintap" ]]; then
  echo "ERROR: /usr/bin/lintap launcher is not executable" >&2
  exit 1
fi
assert_exists /usr/lib/systemd/system/lintap.service
assert_exists /usr/lib/systemd/system/lintap-pidstat.service
assert_exists /etc/lintap/lintap.env
assert_exists /usr/lib/lintap/pidstat-collector.py
assert_exists /usr/lib/lintap/pidstat-collector-launch.sh
assert_exists /usr/lib/lintap/pidstat-collector-bootstrap.sh

expected_bpf_objects=(
  clone_tracer.bpf.o
  openat_tracer.bpf.o
  execve_tracepoint.bpf.o
  exit_tracepoint.bpf.o
  network_tracepoint.bpf.o
  file_ops_tracepoint.bpf.o
)
for bpf_object in "${expected_bpf_objects[@]}"; do
  assert_exists "/usr/lib/lintap/tracers/$bpf_object"
done

if [[ "$HOST_ARCH" == aarch64 && "$DEB_ARCH" == arm64 && -r /sys/kernel/btf/vmlinux ]] ||
   [[ "$HOST_ARCH" == x86_64 && "$DEB_ARCH" == amd64 && -r /sys/kernel/btf/vmlinux ]]; then
  for bpf_object in execve_tracer.bpf.o exit_tracer.bpf.o network_ops_tracer.bpf.o file_ops_tracer.bpf.o; do
    assert_exists "/usr/lib/lintap/tracers/$bpf_object"
  done
fi

assert_not_staged '*/obj/*'
assert_not_staged '*/.git/*'
assert_not_staged '*/.venv/*'
assert_not_staged '*/.fuse_hidden*'

if [[ "$SELF_CONTAINED" != true ]]; then
  assert_exists /usr/lib/lintap/Lintap.runtimeconfig.json
  assert_exists /usr/lib/lintap/Lintap.deps.json
else
  if [[ ! -f "$PKG_ROOT/usr/lib/lintap/libhostfxr.so" && ! -f "$PKG_ROOT/usr/lib/lintap/libcoreclr.so" ]]; then
    echo "ERROR: self-contained package is missing expected .NET native runtime files" >&2
    exit 1
  fi
fi

echo "==> Verifying native dependencies with ldd"
LDD_REPORT="$WORK_DIR/ldd.txt"
LDD_OPTIONAL_REPORT="$WORK_DIR/ldd-optional.txt"
: > "$LDD_REPORT"
: > "$LDD_OPTIONAL_REPORT"
ldd "$PKG_ROOT/usr/lib/lintap/Lintap" >> "$LDD_REPORT" 2>&1 || true
while IFS= read -r native_library; do
  if [[ "$(basename "$native_library")" == libcoreclrtraceptprovider.so ]]; then
    ldd "$native_library" >> "$LDD_OPTIONAL_REPORT" 2>&1 || true
  else
    ldd "$native_library" >> "$LDD_REPORT" 2>&1 || true
  fi
done < <(find "$PKG_ROOT/usr/lib/lintap" -type f -name '*.so' -print)
if [[ -x "$PKG_ROOT/usr/lib/lintap/mcp/wintap_mcp_server" ]]; then
  ldd "$PKG_ROOT/usr/lib/lintap/mcp/wintap_mcp_server" >> "$LDD_REPORT" 2>&1 || true
fi
if grep -q 'not found' "$LDD_REPORT"; then
  echo "ERROR: staged binary has unresolved native dependencies:" >&2
  grep 'not found' "$LDD_REPORT" >&2
  exit 1
fi
if grep -q 'not found' "$LDD_OPTIONAL_REPORT"; then
  echo "WARN: optional .NET diagnostic provider has an unresolved host library; see $LDD_OPTIONAL_REPORT" >&2
fi

cat > "$DEBIAN_DIR/control" <<EOF
Package: $PACKAGE_NAME
Version: $PACKAGE_VERSION
Section: admin
Priority: optional
Architecture: $DEB_ARCH
Maintainer: $MAINTAINER
Depends: ${DOTNET_DEPENDS}libbpf1, libc6, zlib1g, libelf1t64 | libelf1, liblttng-ust1t64 | liblttng-ust1, systemd
Recommends: bpftool
Description: Lintap Linux sensor
 Lintap is the Linux sensor build of Wintap. This package installs the
 .NET service, compiled eBPF tracer objects, default configuration, and a
 systemd unit. Sensor data is written under /var/log/lintap by default.
EOF

cat > "$DEBIAN_DIR/conffiles" <<'EOF'
/etc/lintap/lintap.env
EOF

cat > "$DEBIAN_DIR/postinst" <<'EOF'
#!/bin/sh
set -e

case "${1:-}" in
configure)
    mkdir -p /var/log/lintap /var/log/lintap/Logs /var/log/lintap/parquet
    chmod 0750 /var/log/lintap /var/log/lintap/Logs /var/log/lintap/parquet

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
        systemctl enable lintap.service >/dev/null 2>&1 || true
        systemctl enable lintap-pidstat.service >/dev/null 2>&1 || true
    fi

    echo "Lintap installed. Review /etc/lintap/lintap.env, run: sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh, then start with: sudo systemctl start lintap lintap-pidstat"
    ;;
upgrade|failed-upgrade|abort-install|abort-upgrade)
    # Leave an already-running service running across in-place upgrades.
    ;;
esac

exit 0
EOF

cat > "$DEBIAN_DIR/prerm" <<'EOF'
#!/bin/sh
set -e

case "${1:-}" in
remove|deconfigure)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop lintap.service >/dev/null 2>&1 || true
        systemctl disable lintap.service >/dev/null 2>&1 || true
        systemctl stop lintap-pidstat.service >/dev/null 2>&1 || true
        systemctl disable lintap-pidstat.service >/dev/null 2>&1 || true
    fi
    ;;
upgrade|failed-upgrade|abort-install|abort-upgrade)
    # Do not disable the service during an in-place upgrade.
    ;;
esac

exit 0
EOF

cat > "$DEBIAN_DIR/postrm" <<'EOF'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

case "${1:-}" in
purge)
    rm -rf /etc/lintap
    # Preserve /var/log/lintap sensor data by default. Remove it manually if desired.
    ;;
upgrade|failed-upgrade|abort-install|abort-upgrade|remove|disappear)
    ;;
esac

exit 0
EOF

chmod 0755 "$DEBIAN_DIR/postinst" "$DEBIAN_DIR/prerm" "$DEBIAN_DIR/postrm"

# dpkg-deb expects sane ownership in the archive.
if command -v fakeroot >/dev/null 2>&1; then
  BUILD_CMD=(fakeroot dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB_FILE")
else
  BUILD_CMD=(dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB_FILE")
fi

echo "==> Building Debian package"
"${BUILD_CMD[@]}"

echo "==> Package built: $DEB_FILE"
echo "==> Inspect with: dpkg-deb --info '$DEB_FILE' && dpkg-deb --contents '$DEB_FILE'"
