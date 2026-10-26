#!/usr/bin/env bash
# Run as ubuntu inside the guest. Both host launchers send this over stdin.
set -euo pipefail
source /etc/profile.d/wintap-dotnet.sh
source /etc/profile.d/lintap-python.sh

echo "kernel=$(uname -r) arch=$(uname -m)"
test "$(dotnet --version)" = 10.0.402
dotnet --list-runtimes | grep -E '^Microsoft.NETCore.App 10\.0\.'
dotnet --list-runtimes | grep -E '^Microsoft.AspNetCore.App 10\.0\.'
if [ -f /home/ubuntu/git/wintap/global.json ]; then
    expected=$(python3 -c 'import json; print(json.load(open("/home/ubuntu/git/wintap/global.json"))["sdk"]["version"])')
    test "$(cd /home/ubuntu/git/wintap && dotnet --version)" = "$expected"
fi

clang --version
pkg-config --modversion libbpf libelf
bpftool version
test -r /sys/kernel/btf/vmlinux
bpftool btf dump file /sys/kernel/btf/vmlinux format c >/dev/null
object=$(mktemp /tmp/lintap-bpf-check.XXXXXX)
trap 'rm -f "$object"' EXIT
printf 'int check(void) { return 0; }\n' | clang -target bpf -O2 -x c -c -o "$object" -
test -s "$object"
echo BPF_BUILD_OK

uv --version
test "$(duckdb -noheader -csv -c 'select version()')" = v1.5.6
python -c 'import duckdb, jinja2, psutil, pytest; assert duckdb.__version__ == "1.5.6"; print("Python DuckDB", duckdb.__version__)'
echo LINTAP_DEV_DEPENDENCIES_OK
