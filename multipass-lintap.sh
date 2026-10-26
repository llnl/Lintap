#!/usr/bin/env bash

# Build a base Ubuntu image suitable for running Lintap sensor experiments and
# process-creation validation against Lintap, Tetragon, Tracee, and Sysdig.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Configuration file location
CONFIG_FILE="${CONFIG_FILE:-multipass-config.env}"

# Defaults
INSTANCE_NAME="${INSTANCE_NAME:-lintap-dev}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-8G}"
DISK="${DISK:-50G}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
WINTAP_BRANCH="${WINTAP_BRANCH:-develop}"
CHECKOUT_WINTAP_BRANCH="${CHECKOUT_WINTAP_BRANCH:-false}"
RUN_POSTCREATE_CHECKS="${RUN_POSTCREATE_CHECKS:-true}"
BUILD_WINTAP="${BUILD_WINTAP:-false}"
RUN_VALIDATION_MOCKS="${RUN_VALIDATION_MOCKS:-false}"
CLOUD_INIT_STRICT="${CLOUD_INIT_STRICT:-true}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Load configuration file if it exists
if [ -f "${CONFIG_FILE}" ]; then
    log "Loading configuration from ${CONFIG_FILE}"
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
else
    warn "Configuration file '${CONFIG_FILE}' not found"
    warn "Creating example configuration file: ${CONFIG_FILE}.example"
    
    cat > "${CONFIG_FILE}.example" <<'CONFIGEOF'
# Multipass Instance Configuration
# Copy this file to multipass-config.env and customize for your environment

# Instance settings
INSTANCE_NAME="lintap-dev"
CPUS=4
MEMORY="8G"
DISK="50G"
UBUNTU_VERSION="24.04"

# Current Wintap/Lintap branch used by the eBPF validation work.
# The script will not force checkout unless CHECKOUT_WINTAP_BRANCH=true.
WINTAP_BRANCH="develop"
CHECKOUT_WINTAP_BRANCH=false

# Optional post-create checks. These run inside the VM after cloud-init.
RUN_POSTCREATE_CHECKS=true
BUILD_WINTAP=false
RUN_VALIDATION_MOCKS=false
CLOUD_INIT_STRICT=true

# Mount configuration
# Format: "host_path:instance_path[:options]"
# Options: ro (read-only), rw (read-write, default)
MOUNTS=(
    "${HOME}/git/LLNL:/home/ubuntu/git"
    "${HOME}/data/lintap:/home/ubuntu/data/lintap"
)
CONFIGEOF
    
    error "Please create '${CONFIG_FILE}' based on '${CONFIG_FILE}.example'"
fi

# Validate MOUNTS array exists
if [ -z "${MOUNTS+x}" ] || [ ${#MOUNTS[@]} -eq 0 ]; then
    error "MOUNTS array not defined or empty in ${CONFIG_FILE}"
fi

# Check if multipass is installed
if ! command -v multipass &> /dev/null; then
    error "Multipass is not installed. Install from https://multipass.run/"
fi

# Check if instance already exists
if multipass list | grep -q "^${INSTANCE_NAME}"; then
    log "Instance '${INSTANCE_NAME}' already exists"
    read -p "Delete and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Stopping and deleting existing instance..."
        multipass stop "${INSTANCE_NAME}" 2>/dev/null || true
        multipass delete --purge "${INSTANCE_NAME}"
    else
        log "Using existing instance"
        exit 0
    fi
fi

bool_is_true() {
    case "${1:-}" in
        true|TRUE|1|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

# Build mount arguments
MOUNT_ARGS=()
for mount in "${MOUNTS[@]}"; do
    IFS=':' read -r host_path instance_path opts <<< "$mount"
    
    # Expand home directory
    host_path="${host_path/#\~/$HOME}"
    
    # Check if host path exists
    if [ ! -e "$host_path" ]; then
        log "Creating host path: $host_path"
        mkdir -p "$host_path"
    fi
    
    # Add mount argument
    if [ -n "$opts" ]; then
        MOUNT_ARGS+=("--mount" "${host_path}:${instance_path}:${opts}")
    else
        MOUNT_ARGS+=("--mount" "${host_path}:${instance_path}")
    fi
done

# Create instance with mounts
log "Creating Multipass instance: ${INSTANCE_NAME}"
log "  CPUs: ${CPUS}"
log "  Memory: ${MEMORY}"
log "  Disk: ${DISK}"
log "  Ubuntu: ${UBUNTU_VERSION}"
log "  Mounts: ${#MOUNTS[@]}"
log "  Wintap branch target: ${WINTAP_BRANCH}"

multipass launch "${UBUNTU_VERSION}" \
    --name "${INSTANCE_NAME}" \
    --cpus "${CPUS}" \
    --memory "${MEMORY}" \
    --disk "${DISK}" \
    --timeout 1800 \
    "${MOUNT_ARGS[@]}" \
    --cloud-init - <<'EOF'
#cloud-init
package_update: true
package_upgrade: true
packages:
  # Base dev/admin tools
  - build-essential
  - git
  - curl
  - wget
  - vim
  - htop
  - net-tools
  - unzip
  - tree
  - jq
  - ripgrep
  - tmux
  - ca-certificates
  - gnupg
  - lsb-release
  - pkg-config
  - cmake
  - python3
  - python3-venv
  - python3-pip
  - python3-dev
  - pipx
  - sqlite3
  # For eBPF
  - libbpf-dev
  - libbpf1
  - linux-headers-generic
  - clang
  - llvm
  - libelf-dev
  - zlib1g-dev
  - libicu-dev
  - libssl-dev
  - libkrb5-3
  - linux-tools-common
  - linux-tools-generic
  # For packaging and smoke-test packages
  - dpkg-dev
  - fakeroot
  - devscripts
  # Reference sensor tooling prerequisites / diagnostics
  - tcpdump
  - strace
  - sysstat


runcmd:

  # Headers aren't always where simple eBPF examples expect them. Create an
  # architecture-appropriate asm include symlink if it is missing.
  - |
    set -x
    if [ ! -e /usr/include/asm ]; then
      arch="$(uname -m)"
      case "$arch" in
        aarch64|arm64) asm_dir=/usr/include/aarch64-linux-gnu/asm ;;
        x86_64|amd64) asm_dir=/usr/include/x86_64-linux-gnu/asm ;;
        *) asm_dir="" ;;
      esac
      if [ -n "$asm_dir" ] && [ -d "$asm_dir" ]; then
        ln -s "$asm_dir" /usr/include/asm
      fi
    fi

  # Install the qualified SDK into stable native storage, not the mounted home.
  - |
    set -ex
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y libicu-dev libssl-dev libkrb5-3 libstdc++6 zlib1g
    sdk_version=10.0.402
    sdk_root="/opt/wintap-sdk/$sdk_version"
    mkdir -p "$sdk_root"
    curl --fail --location --retry 3 https://dot.net/v1/dotnet-install.sh -o "$sdk_root/dotnet-install.sh"
    bash "$sdk_root/dotnet-install.sh" --version "$sdk_version" --install-dir "$sdk_root" --no-path
    test "$("$sdk_root/dotnet" --version)" = "$sdk_version"
    ln -s "$sdk_root/dotnet" /usr/local/bin/dotnet
    printf 'export DOTNET_ROOT=%s\nexport PATH=%s:$PATH\n' "$sdk_root" "$sdk_root" > /etc/profile.d/wintap-dotnet.sh

  # Ubuntu's bpftool wrapper needs tools for the running kernel, which may
  # differ from linux-tools-generic after package_upgrade.
  - |
    set -ex
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y bpftool || \
      apt-get install -y "linux-tools-$(uname -r)"
    bpftool version
  
  # Match the qualified Python/native engine rather than following CLI latest.
  - |
    set -ex
    curl --fail --location --retry 3 https://install.duckdb.org -o /tmp/install-duckdb.sh
    sudo -u ubuntu -H env DUCKDB_VERSION=1.5.6 bash /tmp/install-duckdb.sh
    install -m 0755 /home/ubuntu/.duckdb/cli/1.5.6/duckdb /usr/local/bin/duckdb

  # Install uv for the validation harness and Wintap devtools.
  - |
    set -ex
    curl --fail --location --retry 3 https://astral.sh/uv/install.sh -o /tmp/install-uv.sh
    sudo -u ubuntu -H sh /tmp/install-uv.sh
    ln -sf /home/ubuntu/.local/bin/uv /usr/local/bin/uv

  # Native VM storage avoids reusing a mounted macOS/Windows Python environment.
  - |
    set -ex
    sudo -u ubuntu -H uv venv /home/ubuntu/.venvs/lintap-dev --python /usr/bin/python3
    sudo -u ubuntu -H uv pip install --python /home/ubuntu/.venvs/lintap-dev/bin/python \
      'duckdb==1.5.6' 'pytest>=8.4,<9' psutil jinja2
    printf 'export PATH=/home/ubuntu/.venvs/lintap-dev/bin:$PATH\n' > /etc/profile.d/lintap-python.sh

  # Make mounted repos easier to use from tools that care about ownership.
  - |
    set -x
    git config --system --add safe.directory /home/ubuntu/git/wintap || true
    git config --system --add safe.directory /home/ubuntu/git/Wintap-Analytics || true
    git config --system --add safe.directory /home/ubuntu/git/Lintap || true
    git config --system --add safe.directory /home/ubuntu/git/Wintappy || true

  # Convenience directories for validation output.
  - mkdir -p /home/ubuntu/data/lintap /tmp/validation-runs
  - chown -R ubuntu:ubuntu /home/ubuntu/data /tmp/validation-runs

final_message: "LinTap dev environment is ready. Connect with: multipass shell <instance-name>"
EOF

log "Waiting for instance to be ready..."
if ! multipass exec "${INSTANCE_NAME}" -- sudo cloud-init status --wait; then
    warn "cloud-init reported an error. Recent cloud-init output follows."
    multipass exec "${INSTANCE_NAME}" -- sudo cloud-init status --long || true
    multipass exec "${INSTANCE_NAME}" -- sudo tail -n 120 /var/log/cloud-init-output.log || true
    if bool_is_true "${CLOUD_INIT_STRICT}"; then
        error "cloud-init failed and CLOUD_INIT_STRICT=true"
    fi
    warn "Continuing because CLOUD_INIT_STRICT is not true. Post-create checks may still fail if setup is incomplete."
fi

# Get instance IP for SSH
INSTANCE_IP=$(multipass info "${INSTANCE_NAME}" | grep IPv4 | awk '{print $2}')

log "Instance created successfully!"

run_in_instance() {
    multipass exec "${INSTANCE_NAME}" -- bash -lc "$1"
}

if bool_is_true "${RUN_POSTCREATE_CHECKS}"; then
    log "Running post-create checks"
    multipass exec "${INSTANCE_NAME}" -- bash -s < "$SCRIPT_DIR/multipass-check-dev.sh"
fi

if bool_is_true "${CHECKOUT_WINTAP_BRANCH}"; then
    log "Checking out Wintap branch ${WINTAP_BRANCH} inside VM"
    run_in_instance "cd /home/ubuntu/git/wintap && git fetch origin && git checkout '${WINTAP_BRANCH}'"
fi

if bool_is_true "${BUILD_WINTAP}"; then
    log "Building Wintap/Lintap inside VM"
    run_in_instance 'cd /home/ubuntu/git/wintap/wintap && make build_ebpf && make build_dotnet NATIVE_BUILD_ROOT=/home/ubuntu/.local/share/lintap-build DOTNET_BUILD_FLAGS="-p:NativeBuildRoot=/home/ubuntu/.local/share/lintap-build/ -p:OutputPath=/home/ubuntu/.local/share/lintap-build/bin/Debug/net10.0/"'
fi

if bool_is_true "${RUN_VALIDATION_MOCKS}"; then
    log "Running Wintap-Analytics validation harness mock tests inside VM"
    run_in_instance 'cd /home/ubuntu/git/Wintap-Analytics/validation/process-creation && export UV_PROJECT_ENVIRONMENT=/home/ubuntu/.venvs/process-creation && uv run --extra dev pytest && uv run wpv-mock-run --run-dir /tmp/validation-runs/wpv-mock --run-id multipass-mock'
fi

log "Configuring ~/.ssh/config"
LINTAP_INSTANCE=${INSTANCE_NAME} bash "$SCRIPT_DIR/config-ssh.sh"

echo
echo -e "${BLUE}=== Connection Information ===${NC}"
echo "Instance Name: ${INSTANCE_NAME}"
echo "IP Address: ${INSTANCE_IP}"
echo
echo "Shell access:"
echo "  multipass shell ${INSTANCE_NAME}"
echo "  ssh ${INSTANCE_NAME}"
echo
echo "Useful VM checks:"
echo "  ssh ${INSTANCE_NAME} 'uname -a; test -r /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING'"
echo "  See Multipass.md for native-output builds and guest-local validation environments."
echo
echo "Lintap process smoke test inside VM:"
echo "  See Multipass.md for the native-output build and process smoke commands."
echo
echo "VS Code Remote SSH:"
echo "  1. Install 'Remote - SSH' extension"
echo
echo "  2. Connect to '${INSTANCE_NAME}' in VS Code"
echo
echo -e "${BLUE}=== Mounted Paths ===${NC}"
for mount in "${MOUNTS[@]}"; do
    IFS=':' read -r host_path instance_path opts <<< "$mount"
    echo "  ${host_path} -> ${instance_path} ${opts:+($opts)}"
done
