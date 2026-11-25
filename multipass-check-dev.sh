#!/usr/bin/env bash
# Run as ubuntu inside the guest. Both host launchers send this over stdin.
set -euo pipefail
source /etc/profile.d/wintap-dotnet.sh
source /etc/profile.d/lintap-python.sh

echo "kernel=$(uname -r) arch=$(uname -m)"
export GO=/opt/lintap-go/1.27.3/bin/go
export GOTOOLCHAIN=local
test "$("$GO" env GOVERSION)" = go1.27.3
"$GO" version
dotnet --list-runtimes | grep -E '^Microsoft.NETCore.App 10\.0\.'
dotnet --list-runtimes | grep -E '^Microsoft.AspNetCore.App 10\.0\.'
if [ -f /home/ubuntu/git/wintap/global.json ]; then
    source /home/ubuntu/git/Lintap/packaging/dotnet-common.sh
    lintap_require_dotnet_sdk /home/ubuntu/git/wintap/wintap
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
