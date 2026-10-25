#!/usr/bin/env bash
# Shared SDK selection for package builds. Source this file; do not execute it.

lintap_require_dotnet_sdk() {
  local directory sdk_file selected
  LINTAP_DOTNET_PROJECT_DIR=$(cd -- "$1" && pwd) || return 1
  directory="$LINTAP_DOTNET_PROJECT_DIR"
  while [[ ! -f "$directory/global.json" && "$directory" != / ]]; do
    directory=$(dirname -- "$directory")
  done
  sdk_file="$directory/global.json"
  if [[ ! -f "$sdk_file" ]]; then
    echo "ERROR: no global.json above Lintap project; cannot qualify SDK selection" >&2
    return 1
  fi
  LINTAP_DOTNET_SDK_VERSION=$(python3 - "$sdk_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1]) as source:
    version = json.load(source)["sdk"]["version"]
if not isinstance(version, str) or not re.fullmatch(r"10\.0\.\d+", version):
    raise SystemExit("ERROR: packaging requires a stable .NET 10 SDK baseline in global.json")
if version != "10.0.402":
    raise SystemExit("ERROR: qualified package SDK is 10.0.402; review any global.json baseline change before packaging")
print(version)
PY
  ) || return 1
  # Resolve the SDK from the project, not from the caller's working directory.
  selected=$(lintap_dotnet --version) || {
    echo "ERROR: install/select SDK $LINTAP_DOTNET_SDK_VERSION from $sdk_file" >&2
    return 1
  }
  if [[ "$selected" != "$LINTAP_DOTNET_SDK_VERSION" ]]; then
    echo "ERROR: package build requires SDK $LINTAP_DOTNET_SDK_VERSION; selected $selected (latestPatch is not an exact qualification pin)" >&2
    return 1
  fi
  echo "==> Qualified .NET SDK: $selected"
}

lintap_dotnet() (
  cd -- "${LINTAP_DOTNET_PROJECT_DIR:?SDK preflight must run first}" || exit 1
  command dotnet "$@"
)

lintap_validate_runtimeconfig() {
  python3 - "$1" "${2:-}" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as source:
        options = json.load(source)["runtimeOptions"]
    if options.get("tfm") != "net10.0":
        raise ValueError("expected net10.0")
    if sys.argv[2] == "true" and not options.get("includedFrameworks"):
        raise ValueError("self-contained package requires includedFrameworks")
    if sys.argv[2] == "false" and options.get("includedFrameworks"):
        raise ValueError("framework-dependent package must not use includedFrameworks")
    frameworks = options.get("frameworks", options.get("includedFrameworks", []))
    if "framework" in options:
        frameworks = [options["framework"]]
    if not frameworks or any(not item.get("version", "").startswith("10.0.") for item in frameworks):
        raise ValueError("expected .NET 10.0 runtime frameworks")
except (OSError, ValueError, KeyError, TypeError) as error:
    raise SystemExit(f"ERROR: invalid .NET 10 package runtime configuration {sys.argv[1]}: {error}")
PY
}
