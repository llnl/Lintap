#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build a RHEL 8 x86_64 RPM package for the Lintap sensor.

Usage:
  Lintap/packaging/lintap-rpm/build-rpm.sh [options]

Options:
  --version VERSION       RPM package version. Default: git-derived or 0.1.0
  --release RELEASE       RPM package release. Default: 1.el8
  --runtime RID           .NET runtime identifier. Default: linux-x64
  --arch ARCH             Target RPM architecture. Default: x86_64
  --project-dir DIR       Lintap .NET project directory. Default: auto-detect
  --skip-mcp              Do not publish/package the MCP server helper
  --framework-dependent   Publish framework-dependent and require aspnetcore-runtime-8.0
  --configuration CONFIG  dotnet publish configuration. Default: Release
  --no-restore            Pass --no-restore to dotnet publish
  --publish-dir DIR       Skip dotnet publish and stage an existing publish/build directory
  --host-arch ARCH        Build host architecture. Default: uname -m
  --work-root DIR         Native filesystem work root. Default: /var/tmp/lintap-rpm-build
  --no-clean              Do not remove previous packaging work directory
  -h, --help              Show this help

Environment overrides:
  LINTAP_VERSION, LINTAP_RELEASE, LINTAP_RUNTIME, LINTAP_ARCH,
  LINTAP_PROJECT_DIR, LINTAP_SELF_CONTAINED=true|false, LINTAP_SKIP_MCP=true|false, LINTAP_OUTPUT_DIR,
  LINTAP_RPM_WORK_ROOT, LINTAP_CONFIGURATION, LINTAP_NO_RESTORE=true|false,
  LINTAP_EXISTING_PUBLISH_DIR
USAGE
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)

PACKAGE_NAME=lintap
SUMMARY="Lintap Linux sensor"
LICENSE="MIT License"
URL="https://github.com/LLNL/Wintap"
RELEASE=${LINTAP_RELEASE:-'1.el8'}
RPM_ARCH=${LINTAP_ARCH:-x86_64}
RUNTIME=${LINTAP_RUNTIME:-linux-x64}
HOST_ARCH=${LINTAP_HOST_ARCH:-}
SELF_CONTAINED=${LINTAP_SELF_CONTAINED:-true}
CONFIGURATION=${LINTAP_CONFIGURATION:-Release}
NO_RESTORE=${LINTAP_NO_RESTORE:-false}
SKIP_MCP=${LINTAP_SKIP_MCP:-false}
EXISTING_PUBLISH_DIR=${LINTAP_EXISTING_PUBLISH_DIR:-}
PROJECT_DIR=${LINTAP_PROJECT_DIR:-}
CLEAN=true
OUTPUT_ROOT=${LINTAP_OUTPUT_DIR:-"$REPO_ROOT/artifacts/lintap-rpm"}
WORK_ROOT=${LINTAP_RPM_WORK_ROOT:-"/var/tmp/lintap-rpm-build"}
VERSION=${LINTAP_VERSION:-}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION=${2:?--version requires a value}
      shift 2
      ;;
    --release)
      RELEASE=${2:?--release requires a value}
      shift 2
      ;;
    --runtime)
      RUNTIME=${2:?--runtime requires a value}
      shift 2
      ;;
    --arch)
      RPM_ARCH=${2:?--arch requires a value}
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
    --host-arch)
      HOST_ARCH=${2:?--host-arch requires a value}
      shift 2
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
require_cmd rpmbuild
require_cmd tar
require_cmd clang
require_cmd bpftool

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

if [[ -z "$HOST_ARCH" ]]; then
  HOST_ARCH=$(uname -m)
fi

case "$RPM_ARCH:$RUNTIME" in
  # The eBPF build uses __TARGET_ARCH_x86 (not x86_64).
  x86_64:linux-x64) EBPF_TARGET_ARCH=x86 ;;
  *)
    echo "ERROR: this RPM builder currently targets RHEL 8 x86_64 only" >&2
    echo "       supported pair: x86_64/linux-x64" >&2
    exit 1
    ;;
esac

if [[ "$HOST_ARCH" != "$RPM_ARCH" ]]; then
  echo "==> Cross-building target RPM arch '$RPM_ARCH' / RID '$RUNTIME' from host arch '$HOST_ARCH'"
  echo "==> The .NET SDK must be able to restore/publish runtime pack '$RUNTIME' on this host"
else
  echo "==> Building native target RPM arch '$RPM_ARCH' / RID '$RUNTIME'"
fi

if [[ -z "$VERSION" ]]; then
  if git -C "$REPO_ROOT" describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 | sed 's/^v//')
  else
    short_sha=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)
    if [[ -n "$short_sha" ]]; then
      VERSION="0.1.0.git$short_sha"
    else
      VERSION="0.1.0"
    fi
  fi
fi

if [[ ! "$VERSION" =~ ^[A-Za-z0-9._+]+$ ]]; then
  echo "ERROR: RPM version must contain only letters, digits, dot, underscore, or plus: $VERSION" >&2
  exit 1
fi

WORK_DIR="$WORK_ROOT/work/$RPM_ARCH-$RUNTIME"
PUBLISH_DIR="$WORK_ROOT/publish/$RUNTIME"
PKG_ROOT="$WORK_DIR/pkgroot"
RPMBUILD_ROOT="$WORK_DIR/rpmbuild"
MSBUILD_NATIVE_ROOT="$WORK_ROOT/msbuild/$RPM_ARCH-$RUNTIME"
MCP_PUBLISH_ROOT="$WORK_ROOT/mcp-publish/$RPM_ARCH-$RUNTIME"
MCP_OUTPUT_ROOT="$WORK_ROOT/mcp-output/$RPM_ARCH-$RUNTIME"
SPECS_DIR="$RPMBUILD_ROOT/SPECS"
SOURCES_DIR="$RPMBUILD_ROOT/SOURCES"
SPEC_FILE="$SPECS_DIR/$PACKAGE_NAME.spec"
ROOT_TARBALL="$SOURCES_DIR/$PACKAGE_NAME-root.tar.gz"

if [[ "$CLEAN" == true ]]; then
  rm -rf "$WORK_DIR" "$PUBLISH_DIR"
fi
mkdir -p "$OUTPUT_ROOT" "$PUBLISH_DIR" "$PKG_ROOT" "$SPECS_DIR" "$SOURCES_DIR" "$RPMBUILD_ROOT/BUILD" "$RPMBUILD_ROOT/RPMS" "$RPMBUILD_ROOT/SRPMS"

echo "==> RPM output root: $OUTPUT_ROOT"
echo "==> Native work root: $WORK_ROOT"

echo "==> Building eBPF tracers ($EBPF_TARGET_ARCH)"
ebpf_make_args=(clean all TARGET_ARCH="$EBPF_TARGET_ARCH")
if [[ "$HOST_ARCH" != "$RPM_ARCH" ]]; then
  # Cross-build note: CO-RE objects require a vmlinux.h matching the *target* kernel/arch.
  # When cross-building, force tracepoint-only objects by disabling BTF/vmlinux.h generation.
  ebpf_make_args+=(VMLINUX_BTF=/__lintap_crossbuild_no_btf__)
fi
make -C "$EBPF_DIR" "${ebpf_make_args[@]}"

DOTNET_REQUIRES=""
if [[ "$SELF_CONTAINED" != true ]]; then
  DOTNET_REQUIRES="Requires: aspnetcore-runtime-8.0"
fi

if [[ -n "$EXISTING_PUBLISH_DIR" ]]; then
  if [[ ! -d "$EXISTING_PUBLISH_DIR" ]]; then
    echo "ERROR: --publish-dir does not exist or is not a directory: $EXISTING_PUBLISH_DIR" >&2
    exit 1
  fi
  echo "==> Using existing Lintap publish/build directory: $EXISTING_PUBLISH_DIR"
  if [[ "$HOST_ARCH" != "$RPM_ARCH" ]]; then
    echo "==> Cross-build note: --publish-dir must already contain binaries for '$RUNTIME'"
  fi
  rm -rf "$PUBLISH_DIR"
  mkdir -p "$PUBLISH_DIR"
  cp -R "$EXISTING_PUBLISH_DIR"/. "$PUBLISH_DIR/"
else
  echo "==> Publishing Lintap ($RUNTIME, configuration=$CONFIGURATION, self-contained=$SELF_CONTAINED)"
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
      --self-contained true
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
  # Ensure we don't accidentally package stale MCP artifacts from a prior build.
  rm -rf "$PUBLISH_DIR/mcp" "$PUBLISH_DIR/mcp_temp"
fi

# Keep development --publish-dir inputs suitable for packaging.
find "$PUBLISH_DIR" \
  \( -type d \( -name obj -o -name bin -o -name .git -o -name .venv \) -prune \
  -o -type f -name '.fuse_hidden*' \) -exec rm -rf {} +
rm -rf \
  "$PUBLISH_DIR/runtimes/win"* \
  "$PUBLISH_DIR/runtimes/osx"* \
  "$PUBLISH_DIR/runtimes/browser"* \
  "$PUBLISH_DIR/amd64" \
  "$PUBLISH_DIR/arm64"
find "$PUBLISH_DIR" -name 'libnironcompress.so' -delete

echo "==> Staging package filesystem"
rm -rf "$PKG_ROOT"
mkdir -p \
  "$PKG_ROOT/usr/lib/lintap" \
  "$PKG_ROOT/usr/bin" \
  "$PKG_ROOT/etc/lintap" \
  "$PKG_ROOT/var/log/lintap/data" \
  "$PKG_ROOT/var/log/lintap/runtime" \
  "$PKG_ROOT/usr/lib/systemd/system" \
  "$PKG_ROOT/usr/share/doc/lintap"

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
if [[ -f "$SCRIPT_DIR/../PATHS_AND_CONFIGURATION.md" ]]; then
  install -m 0644 "$SCRIPT_DIR/../PATHS_AND_CONFIGURATION.md" "$PKG_ROOT/usr/share/doc/lintap/PATHS_AND_CONFIGURATION.md"
fi

chmod 0755 "$PKG_ROOT/usr/lib/lintap/Lintap" 2>/dev/null || true
if [[ -x "$PKG_ROOT/usr/lib/lintap/mcp/wintap_mcp_server" ]]; then
  chmod 0755 "$PKG_ROOT/usr/lib/lintap/mcp/wintap_mcp_server"
fi

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
  file_ops_tracer.bpf.o
  openat_tracer.bpf.o
  execve_tracepoint.bpf.o
  exit_tracepoint.bpf.o
  network_tracepoint.bpf.o
  file_ops_tracepoint.bpf.o
)
for bpf_object in "${expected_bpf_objects[@]}"; do
  assert_exists "/usr/lib/lintap/tracers/$bpf_object"
done

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

echo "==> Creating RPM source payload"
tar -C "$PKG_ROOT" --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner -czf "$ROOT_TARBALL" .

cat > "$SPEC_FILE" <<EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        $RELEASE
Summary:        $SUMMARY
License:        $LICENSE
URL:            $URL
Source0:        $PACKAGE_NAME-root.tar.gz

%global debug_package %{nil}
%global __strip /usr/bin/true

Requires:       systemd
Requires:       glibc
Requires:       zlib
Requires:       elfutils-libelf
Requires:       libbpf
$DOTNET_REQUIRES

%description
Lintap is the Linux sensor build of Wintap. This package installs the .NET
service, compiled eBPF tracer objects, default external configuration, and a
   systemd unit. Shared sensor data is written under /var/log/lintap/data and
   host-local runtime state under /var/log/lintap/runtime by default.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot}

%post
mkdir -p /var/log/lintap/data /var/log/lintap/runtime
chmod 0750 /var/log/lintap /var/log/lintap/data /var/log/lintap/runtime
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable lintap.service >/dev/null 2>&1 || true
    systemctl enable lintap-pidstat.service >/dev/null 2>&1 || true
fi
echo "Lintap installed. Review /etc/lintap/lintap.env, run: sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh, then start with: sudo systemctl start lintap lintap-pidstat"

%preun
if [ \$1 -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop lintap.service >/dev/null 2>&1 || true
        systemctl disable lintap.service >/dev/null 2>&1 || true
        systemctl stop lintap-pidstat.service >/dev/null 2>&1 || true
        systemctl disable lintap-pidstat.service >/dev/null 2>&1 || true
    fi
fi

%postun
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

%files
%doc /usr/share/doc/lintap/README.md
%doc /usr/share/doc/lintap/PATHS_AND_CONFIGURATION.md
/usr/bin/lintap
/usr/lib/lintap
/usr/lib/systemd/system/lintap.service
/usr/lib/systemd/system/lintap-pidstat.service
%dir /etc/lintap
%config(noreplace) /etc/lintap/lintap.env
%dir %attr(0750,root,root) /var/log/lintap
%dir %attr(0750,root,root) /var/log/lintap/data
%dir %attr(0750,root,root) /var/log/lintap/runtime

%changelog
* Tue Jun 09 2026 LLNL TeleTap Team <grantj@llnl.gov> - $VERSION-$RELEASE
- Build Lintap RPM package for RHEL 8 x86_64.
EOF

echo "==> Building RPM package"
rpmbuild \
  --define "_topdir $RPMBUILD_ROOT" \
  --define "_rpmdir $OUTPUT_ROOT" \
  --target "$RPM_ARCH" \
  -bb "$SPEC_FILE"

RPM_FILE=$(find "$OUTPUT_ROOT" -maxdepth 2 -type f -name "${PACKAGE_NAME}-${VERSION}-${RELEASE}.${RPM_ARCH}.rpm" -print -quit)
if [[ -z "${RPM_FILE:-}" ]]; then
  # Fall back to first match if the expected filename differs.
  RPM_FILE=$(find "$OUTPUT_ROOT" -maxdepth 2 -type f -name "${PACKAGE_NAME}-${VERSION}-*.${RPM_ARCH}.rpm" -print -quit)
fi
echo "==> Package built: ${RPM_FILE:-$OUTPUT_ROOT/$RPM_ARCH}"
echo "==> Inspect with: rpm -qpi '<rpm>' && rpm -qpl '<rpm>'"
if [[ -n "$RPM_FILE" ]] && command -v rpm >/dev/null 2>&1; then
  if rpm -qp --requires "$RPM_FILE" | grep -Eq 'GLIBC_2\.(29|[3-9][0-9])'; then
    echo "WARNING: RPM auto-requires GLIBC newer than RHEL 8's GLIBC_2.28. Inspect native dependencies before installing on RHEL 8." >&2
  fi
fi
