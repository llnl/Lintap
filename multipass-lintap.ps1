<#
Build a base Ubuntu image suitable for running Lintap sensor experiments and
process-creation validation against Lintap, Tetragon, Tracee, and Sysdig.

This is the PowerShell equivalent of multipass-lintap.sh. It intentionally
accepts the same multipass-config.env format, including Bash-style MOUNTS=(...).
#>

$ErrorActionPreference = 'Stop'

function Get-EnvOrDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Default
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Error "[ERROR] $Message"
    exit 1
}

function ConvertTo-BoolFlag {
    param([AllowNull()][string]$Value)

    return $Value -match '^(?i:true|1|yes|y)$'
}

function Expand-ConfigPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = $Path.Trim()
    if ($expanded -eq '~') {
        $expanded = $HOME
    }
    elseif ($expanded.StartsWith('~/') -or $expanded.StartsWith('~\')) {
        $expanded = Join-Path $HOME $expanded.Substring(2)
    }
    $expanded = $expanded.Replace('${HOME}', $HOME).Replace('$HOME', $HOME)
    return [Environment]::ExpandEnvironmentVariables($expanded)
}

function Split-MountSpec {
    param([Parameter(Mandatory = $true)][string]$Mount)

    if ($Mount -notmatch '^(?<host>.*?):(?<instance>/[^:]*)(?::(?<options>.*))?$') {
        Write-Fail "Invalid mount entry '$Mount'. Expected host_path:instance_path[:options]."
    }

    return [pscustomobject]@{
        HostPath = $Matches['host']
        InstancePath = $Matches['instance']
        Options = if ($Matches.ContainsKey('options')) { $Matches['options'] } else { '' }
    }
}

function Normalize-ConfigValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }

    return $trimmed
}

function Read-LintapConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $config = @{}
    $mounts = New-Object System.Collections.Generic.List[string]
    $inMounts = $false

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        if ($inMounts) {
            if ($trimmed -eq ')') {
                $inMounts = $false
                continue
            }

            $mount = Normalize-ConfigValue $trimmed
            if (-not [string]::IsNullOrWhiteSpace($mount)) {
                $mounts.Add($mount)
            }
            continue
        }

        if ($trimmed -match '^MOUNTS\s*=\s*\($') {
            $inMounts = $true
            continue
        }

        if ($trimmed -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $config[$Matches[1]] = Normalize-ConfigValue $Matches[2]
        }
    }

    if ($mounts.Count -gt 0) {
        $config['MOUNTS'] = @($mounts)
    }

    return $config
}

function New-ExampleConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $example = @'
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
WINTAP_BRANCH="grantj-ebf-fixes"
CHECKOUT_WINTAP_BRANCH=false

# Optional post-create checks. These run inside the VM after cloud-init.
RUN_POSTCREATE_CHECKS=true
BUILD_WINTAP=false
RUN_VALIDATION_MOCKS=false
CLOUD_INIT_STRICT=false

# Mount configuration
# Format: "host_path:instance_path[:options]"
# Options: ro (read-only), rw (read-write, default)
MOUNTS=(
    "${HOME}/git/LLNL:/home/ubuntu/git"
    "${HOME}/data/lintap:/home/ubuntu/data/lintap"
)
'@

    Set-Content -LiteralPath $Path -Value $example -Encoding UTF8
}

function Invoke-InInstance {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$Command
    )

    & multipass exec $InstanceName -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed in instance '$InstanceName': $Command"
    }
}

function Add-SshConfigBlock {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$InstanceIp
    )

    $sshDir = Join-Path $HOME '.ssh'
    $configFile = Join-Path $sshDir 'config'

    if (-not (Test-Path -LiteralPath $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir | Out-Null
    }

    if (-not (Test-Path -LiteralPath $configFile)) {
        New-Item -ItemType File -Path $configFile | Out-Null
        Write-Log "Created new SSH config file: $configFile"
    }

    $content = Get-Content -LiteralPath $configFile -Raw -ErrorAction SilentlyContinue
    if ($null -eq $content) {
        $content = ''
    }

    $entry = @"
Host $InstanceName
  Hostname $InstanceIp
  User ubuntu
  LocalForward 4213 localhost:4213
"@

    $pattern = "(?ms)^Host\s+$([Regex]::Escape($InstanceName))\s*\r?\n.*?(?=^Host\s+|\z)"
    if ($content -match $pattern) {
        $content = [Regex]::Replace($content, $pattern, $entry.TrimEnd() + [Environment]::NewLine)
        Set-Content -LiteralPath $configFile -Value $content -NoNewline -Encoding UTF8
        Write-Log "Updated existing '$InstanceName' entry in SSH config with IP: $InstanceIp"
    }
    else {
        if ($content.Length -gt 0 -and -not $content.EndsWith([Environment]::NewLine)) {
            $content += [Environment]::NewLine
        }
        $content += [Environment]::NewLine + $entry.TrimEnd() + [Environment]::NewLine
        Set-Content -LiteralPath $configFile -Value $content -NoNewline -Encoding UTF8
        Write-Log "Added new '$InstanceName' entry to SSH config with IP: $InstanceIp"
    }
}

function Configure-SshAccess {
    param([Parameter(Mandatory = $true)][string]$InstanceName)

    $sshKeyFile = Get-EnvOrDefault -Name 'LINTAP_SSHKEY' -Default (Join-Path $HOME '.ssh\id_ed25519.pub')
    if (-not (Test-Path -LiteralPath $sshKeyFile -PathType Leaf)) {
        Write-Fail "SSH key file '$sshKeyFile' not found. Set LINTAP_SSHKEY to a public key path."
    }

    $sshKey = (Get-Content -LiteralPath $sshKeyFile -Raw).Trim()
    Write-Log "Configuring SSH authorized_keys for $InstanceName"

    $escapedKey = $sshKey.Replace("'", "'\''")
    & multipass exec $InstanceName -- sh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s`n' '$escapedKey' >> ~/.ssh/authorized_keys"
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to configure ubuntu authorized_keys"
    }

    $rootCommand = "sudo mkdir -p /root/.ssh && printf '%s`n' '$escapedKey' | sudo tee -a /root/.ssh/authorized_keys >/dev/null"
    & multipass exec $InstanceName -- sh -c $rootCommand
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to configure root authorized_keys"
    }

    $infoJson = & multipass info $InstanceName --format json
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to read Multipass instance info for $InstanceName"
    }

    $info = $infoJson | ConvertFrom-Json
    $instanceInfo = $info.info.PSObject.Properties[$InstanceName].Value
    $instanceIp = $instanceInfo.ipv4[0]
    if ([string]::IsNullOrWhiteSpace($instanceIp)) {
        Write-Fail "Could not determine IPv4 address for $InstanceName"
    }

    Write-Log "$InstanceName IP: $instanceIp"
    Add-SshConfigBlock -InstanceName $InstanceName -InstanceIp $instanceIp
    return $instanceIp
}

$configFile = Get-EnvOrDefault -Name 'CONFIG_FILE' -Default 'multipass-config.env'

$settings = @{
    INSTANCE_NAME = Get-EnvOrDefault -Name 'INSTANCE_NAME' -Default 'lintap-dev'
    CPUS = Get-EnvOrDefault -Name 'CPUS' -Default '4'
    MEMORY = Get-EnvOrDefault -Name 'MEMORY' -Default '8G'
    DISK = Get-EnvOrDefault -Name 'DISK' -Default '50G'
    UBUNTU_VERSION = Get-EnvOrDefault -Name 'UBUNTU_VERSION' -Default '24.04'
    WINTAP_BRANCH = Get-EnvOrDefault -Name 'WINTAP_BRANCH' -Default 'grantj-ebf-fixes'
    CHECKOUT_WINTAP_BRANCH = Get-EnvOrDefault -Name 'CHECKOUT_WINTAP_BRANCH' -Default 'false'
    RUN_POSTCREATE_CHECKS = Get-EnvOrDefault -Name 'RUN_POSTCREATE_CHECKS' -Default 'true'
    BUILD_WINTAP = Get-EnvOrDefault -Name 'BUILD_WINTAP' -Default 'false'
    RUN_VALIDATION_MOCKS = Get-EnvOrDefault -Name 'RUN_VALIDATION_MOCKS' -Default 'false'
    CLOUD_INIT_STRICT = Get-EnvOrDefault -Name 'CLOUD_INIT_STRICT' -Default 'false'
}

if (Test-Path -LiteralPath $configFile -PathType Leaf) {
    Write-Log "Loading configuration from $configFile"
    $fileConfig = Read-LintapConfig -Path $configFile
    foreach ($key in $fileConfig.Keys) {
        $settings[$key] = $fileConfig[$key]
    }
}
else {
    Write-Warn "Configuration file '$configFile' not found"
    Write-Warn "Creating example configuration file: $configFile.example"
    New-ExampleConfig -Path "$configFile.example"
    Write-Fail "Please create '$configFile' based on '$configFile.example'"
}

if (-not $settings.ContainsKey('MOUNTS') -or @($settings['MOUNTS']).Count -eq 0) {
    Write-Fail "MOUNTS array not defined or empty in $configFile"
}

if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
    Write-Fail "Multipass is not installed. Install from https://multipass.run/"
}

$instanceName = [string]$settings['INSTANCE_NAME']
$existingInstances = & multipass list
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to list Multipass instances"
}

if ($existingInstances -match "(?m)^$([Regex]::Escape($instanceName))\s") {
    Write-Log "Instance '$instanceName' already exists"
    $reply = Read-Host 'Delete and recreate? (y/N)'
    if ($reply -match '^[Yy]$') {
        Write-Log 'Stopping and deleting existing instance...'
        & multipass stop $instanceName 2>$null
        & multipass delete $instanceName
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to delete existing instance '$instanceName'"
        }
        & multipass purge
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'Failed to purge deleted Multipass instances'
        }
    }
    else {
        Write-Log 'Using existing instance'
        exit 0
    }
}

$mountArgs = New-Object System.Collections.Generic.List[string]
$resolvedMounts = New-Object System.Collections.Generic.List[object]
foreach ($mount in @($settings['MOUNTS'])) {
    $mountSpecParts = Split-MountSpec ([string]$mount)
    $hostPath = Expand-ConfigPath $mountSpecParts.HostPath
    $instancePath = $mountSpecParts.InstancePath
    $options = $mountSpecParts.Options

    if (-not (Test-Path -LiteralPath $hostPath)) {
        Write-Log "Creating host path: $hostPath"
        New-Item -ItemType Directory -Path $hostPath | Out-Null
    }

    $mountSpec = if ([string]::IsNullOrWhiteSpace($options)) {
        "${hostPath}:${instancePath}"
    }
    else {
        "${hostPath}:${instancePath}:${options}"
    }

    $mountArgs.Add('--mount')
    $mountArgs.Add($mountSpec)
    $resolvedMounts.Add([pscustomobject]@{ HostPath = $hostPath; InstancePath = $instancePath; Options = $options })
}

$cloudInit = @'
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
    curl --fail --location https://dot.net/v1/dotnet-install.sh -o "$sdk_root/dotnet-install.sh"
    bash "$sdk_root/dotnet-install.sh" --version "$sdk_version" --install-dir "$sdk_root" --no-path
    test "$("$sdk_root/dotnet" --version)" = "$sdk_version"
    ln -s "$sdk_root/dotnet" /usr/local/bin/dotnet
    printf 'export DOTNET_ROOT=%s\nexport PATH=%s:$PATH\n' "$sdk_root" "$sdk_root" > /etc/profile.d/wintap-dotnet.sh

  # Install bpftool best-effort. On Ubuntu ARM images the package may be
  # provided by linux-tools-* rather than a standalone bpftool package.
  - |
    set -x
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y bpftool || \
      apt-get install -y "linux-tools-$(uname -r)" || \
      apt-get install -y linux-tools-generic || \
      true

  # Install DuckDB CLI. The default installer detects the right OS/arch, but installs only for the current user. Sigh.
  - |
    set -x
    sudo -u ubuntu -H bash -c 'curl -L https://install.duckdb.org | bash'
    cp /home/ubuntu/.duckdb/cli/latest/duckdb /usr/local/bin/duckdb

  # Install uv for the validation harness and Wintap devtools.
  - |
    set -x
    sudo -u ubuntu -H bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    ln -sf /home/ubuntu/.local/bin/uv /usr/local/bin/uv

  # Make mounted repos easier to use from tools that care about ownership.
  - |
    set -x
    git config --system --add safe.directory /home/ubuntu/git/wintap || true
    git config --system --add safe.directory /home/ubuntu/git/Wintap-Analytics || true
    git config --system --add safe.directory /home/ubuntu/git/Lintap || true

  # Convenience directories for validation output.
  - mkdir -p /home/ubuntu/data/lintap /tmp/validation-runs
  - chown -R ubuntu:ubuntu /home/ubuntu/data /tmp/validation-runs

final_message: "LinTap dev environment is ready. Connect with: multipass shell <instance-name>"
'@

Write-Log "Creating Multipass instance: $instanceName"
Write-Log "  CPUs: $($settings['CPUS'])"
Write-Log "  Memory: $($settings['MEMORY'])"
Write-Log "  Disk: $($settings['DISK'])"
Write-Log "  Ubuntu: $($settings['UBUNTU_VERSION'])"
Write-Log "  Mounts: $(@($settings['MOUNTS']).Count)"
Write-Log "  Wintap branch target: $($settings['WINTAP_BRANCH'])"

$launchArgs = @(
    'launch', [string]$settings['UBUNTU_VERSION'],
    '--name', $instanceName,
    '--cpus', [string]$settings['CPUS'],
    '--memory', [string]$settings['MEMORY'],
    '--disk', [string]$settings['DISK']
) + @($mountArgs) + @('--cloud-init', '-')

$cloudInit | & multipass @launchArgs
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Failed to launch Multipass instance '$instanceName'"
}

Write-Log 'Waiting for instance to be ready...'
& multipass exec $instanceName -- cloud-init status --wait
if ($LASTEXITCODE -ne 0) {
    Write-Warn 'cloud-init reported an error. Recent cloud-init output follows.'
    & multipass exec $instanceName -- sudo cloud-init status --long
    & multipass exec $instanceName -- sudo tail -n 120 /var/log/cloud-init-output.log
    if (ConvertTo-BoolFlag $settings['CLOUD_INIT_STRICT']) {
        Write-Fail 'cloud-init failed and CLOUD_INIT_STRICT=true'
    }
    Write-Warn 'Continuing because CLOUD_INIT_STRICT is not true. Post-create checks may still fail if setup is incomplete.'
}

$instanceIp = (& multipass info $instanceName | Where-Object { $_ -match '^IPv4' } | ForEach-Object { ($_ -split '\s+')[1] } | Select-Object -First 1)

Write-Log 'Instance created successfully!'

if (ConvertTo-BoolFlag $settings['RUN_POSTCREATE_CHECKS']) {
    Write-Log 'Running post-create checks'
    Invoke-InInstance -InstanceName $instanceName -Command 'set -e; echo "kernel=$(uname -r) arch=$(uname -m)"; dotnet --info >/tmp/dotnet-info.txt; clang --version | head -1; bpftool version | head -1 || true; uv --version; duckdb --version; test -r /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING'
}

if (ConvertTo-BoolFlag $settings['CHECKOUT_WINTAP_BRANCH']) {
    Write-Log "Checking out Wintap branch $($settings['WINTAP_BRANCH']) inside VM"
    Invoke-InInstance -InstanceName $instanceName -Command "cd /home/ubuntu/git/wintap && git fetch origin && git checkout '$($settings['WINTAP_BRANCH'])'"
}

if (ConvertTo-BoolFlag $settings['BUILD_WINTAP']) {
    Write-Log 'Building Wintap/Lintap inside VM'
    Invoke-InInstance -InstanceName $instanceName -Command 'cd /home/ubuntu/git/wintap/wintap && make build_ebpf && make build_dotnet'
}

if (ConvertTo-BoolFlag $settings['RUN_VALIDATION_MOCKS']) {
    Write-Log 'Running Wintap-Analytics validation harness mock tests inside VM'
    Invoke-InInstance -InstanceName $instanceName -Command 'cd /home/ubuntu/git/Wintap-Analytics/validation/process-creation && uv run --extra dev pytest && uv run wpv-mock-run --run-dir /tmp/validation-runs/wpv-mock --run-id multipass-mock'
}

Write-Log 'Configuring ~/.ssh/config'
$configuredIp = Configure-SshAccess -InstanceName $instanceName
if (-not [string]::IsNullOrWhiteSpace($configuredIp)) {
    $instanceIp = $configuredIp
}

Write-Host ''
Write-Host '=== Connection Information ===' -ForegroundColor Blue
Write-Host "Instance Name: $instanceName"
Write-Host "IP Address: $instanceIp"
Write-Host ''
Write-Host 'Shell access:'
Write-Host "  multipass shell $instanceName"
Write-Host "  ssh $instanceName"
Write-Host ''
Write-Host 'Useful VM checks:'
Write-Host "  ssh $instanceName 'uname -a; test -r /sys/kernel/btf/vmlinux && echo BTF_OK || echo BTF_MISSING'"
Write-Host "  ssh $instanceName 'cd /home/ubuntu/git/wintap/wintap && make build_ebpf && make build_dotnet'"
Write-Host "  ssh $instanceName 'cd /home/ubuntu/git/Wintap-Analytics/validation/process-creation && uv run --extra dev pytest'"
Write-Host ''
Write-Host 'Lintap process smoke test inside VM:'
Write-Host "  ssh $instanceName 'cd /home/ubuntu/git/wintap && sudo python3 devtools/process_capture_smoke_test.py --start-lintap --lintap-dll /home/ubuntu/git/wintap/wintap/bin/Debug/net10.0/Lintap.dll --timeout 240 --poll-interval 5'"
Write-Host ''
Write-Host 'VS Code Remote SSH:'
Write-Host "  1. Install 'Remote - SSH' extension"
Write-Host ''
Write-Host "  2. Connect to '$instanceName' in VS Code"
Write-Host ''
Write-Host '=== Mounted Paths ===' -ForegroundColor Blue
foreach ($mount in $resolvedMounts) {
    $optionText = if ([string]::IsNullOrWhiteSpace($mount.Options)) { '' } else { " ($($mount.Options))" }
    Write-Host "  $($mount.HostPath) -> $($mount.InstancePath)$optionText"
}
