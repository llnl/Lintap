"""SDK/TFM packaging regressions using fake tools, never services or real builds."""
from pathlib import Path
import json
import os
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "packaging/dotnet-common.sh"
WINTAP = ROOT.parent / "wintap"


@pytest.fixture
def sdk_environment(tmp_path, monkeypatch):
    repo = tmp_path / "source repo"
    project = repo / "wintap"
    project.mkdir(parents=True)
    (repo / "global.json").write_text(json.dumps({"sdk": {"version": "10.0.402"}}))
    (project / "Lintap.csproj").write_text("<Project />")
    (project / "platform/linux/sensor/ebpf/tracers").mkdir(parents=True)
    tools = tmp_path / "tools"
    tools.mkdir()
    calls = tmp_path / "calls"
    monkeypatch.setenv("PATH", str(tools) + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("SDK_CALLS", str(calls))
    monkeypatch.setenv("FAKE_SDK", "10.0.402")
    dotnet = tools / "dotnet"
    dotnet.write_text('''#!/bin/bash
printf '%s|%s\n' "$PWD" "$*" >> "$SDK_CALLS"
if [[ "$1" == --version ]]; then echo "$FAKE_SDK"; fi
''')
    dotnet.chmod(0o755)
    return repo, project, tools, calls


def shell(command, *args, cwd=None):
    return subprocess.run(["bash", "-c", command, "test", *map(str, args)],
                          cwd=cwd, text=True, capture_output=True)


def test_sdk_selection_and_publish_use_project_directory(sdk_environment, tmp_path):
    _, project, _, calls = sdk_environment
    result = shell('source "$1"; lintap_require_dotnet_sdk "$2" && lintap_dotnet publish sample',
                   HELPER, project, cwd=tmp_path)
    assert result.returncode == 0, result.stderr
    assert calls.read_text().splitlines() == [f"{project}|--version", f"{project}|publish sample"]


@pytest.mark.parametrize("version", ["8.0.122", "10.0.113", "10.0.403", "10.0.402-preview.1"])
def test_exact_sdk_mismatch_fails(sdk_environment, monkeypatch, version):
    _, project, _, _ = sdk_environment
    monkeypatch.setenv("FAKE_SDK", version)
    result = shell('source "$1"; lintap_require_dotnet_sdk "$2"', HELPER, project)
    assert result.returncode != 0
    assert "requires SDK 10.0.402" in result.stderr


@pytest.mark.parametrize("kind", ["missing", "malformed", "old-version", "unqualified-net10"])
def test_invalid_sdk_baseline_fails(sdk_environment, kind):
    repo, project, _, _ = sdk_environment
    baseline = repo / "global.json"
    if kind == "missing":
        baseline.unlink()
    elif kind == "malformed":
        baseline.write_text("not json")
    elif kind == "old-version":
        baseline.write_text(json.dumps({"sdk": {"version": "8.0.122"}}))
    else:
        baseline.write_text(json.dumps({"sdk": {"version": "10.0.113"}}))
    assert shell('source "$1"; lintap_require_dotnet_sdk "$2"', HELPER, project).returncode != 0


@pytest.mark.parametrize("format", ["deb", "rpm"])
def test_builder_sdk_failure_precedes_cleanup_or_make(sdk_environment, tmp_path, monkeypatch, format):
    _, project, tools, _ = sdk_environment
    monkeypatch.setenv("FAKE_SDK", "10.0.403")
    for name in ("make", "dpkg", "dpkg-deb", "rpmbuild", "clang", "bpftool", "ldd"):
        stub = tools / name
        stub.write_text('#!/bin/bash\necho "unexpected tool call" >&2\nexit 91\n')
        stub.chmod(0o755)
    work = tmp_path / "work"
    sentinel = work / "work" / ("amd64-linux-x64" if format == "deb" else "x86_64-linux-x64") / "keep"
    sentinel.parent.mkdir(parents=True)
    sentinel.write_text("not cleaned")
    result = subprocess.run([
        "bash", str(ROOT / f"packaging/lintap-{format}/build-{format}.sh"),
        "--project-dir", str(project), "--work-root", str(work), "--version", "0.1.0",
        "--arch", "amd64" if format == "deb" else "x86_64", "--runtime", "linux-x64",
    ], cwd=tmp_path, text=True, capture_output=True)
    assert result.returncode != 0
    assert "requires SDK 10.0.402" in result.stderr
    assert "unexpected tool call" not in result.stderr
    assert sentinel.read_text() == "not cleaned"


@pytest.mark.parametrize("key", ["frameworks", "includedFrameworks", "framework"])
def test_runtimeconfig_net10_modes_pass(tmp_path, key):
    framework = {"name": "Microsoft.NETCore.App", "version": "10.0.13"}
    options = {"tfm": "net10.0", key: framework if key == "framework" else [framework]}
    path = tmp_path / "runtimeconfig.json"
    path.write_text(json.dumps({"runtimeOptions": options}))
    result = shell('source "$1"; lintap_validate_runtimeconfig "$2"', HELPER, path)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("options", [
    {"tfm": "net8.0", "framework": {"version": "8.0.1"}},
    {"tfm": "net10.0", "framework": {"version": "8.0.1"}},
    {"tfm": "net10.0"},
])
def test_runtimeconfig_old_or_incomplete_fails(tmp_path, options):
    path = tmp_path / "runtimeconfig.json"
    path.write_text(json.dumps({"runtimeOptions": options}))
    assert shell('source "$1"; lintap_validate_runtimeconfig "$2"', HELPER, path).returncode != 0


def test_runtimeconfig_missing_file_fails(tmp_path):
    assert shell('source "$1"; lintap_validate_runtimeconfig "$2"', HELPER, tmp_path / "missing").returncode != 0


@pytest.mark.parametrize("mode,key", [("true", "frameworks"), ("false", "includedFrameworks")])
def test_runtimeconfig_must_match_requested_package_mode(tmp_path, mode, key):
    path = tmp_path / "runtimeconfig.json"
    path.write_text(json.dumps({"runtimeOptions": {"tfm": "net10.0", key: [
        {"name": "Microsoft.NETCore.App", "version": "10.0.13"}]}}))
    result = shell('source "$1"; lintap_validate_runtimeconfig "$2" "$3"', HELPER, path, mode)
    assert result.returncode != 0


def test_both_builders_declare_runtime10_and_validate_payload():
    for format in ("deb", "rpm"):
        text = (ROOT / f"packaging/lintap-{format}/build-{format}.sh").read_text()
        assert "aspnetcore-runtime-10.0" in text
        assert "aspnetcore-runtime-8.0" not in text
        assert 'lintap_validate_runtimeconfig "$PUBLISH_DIR/Lintap.runtimeconfig.json" "$SELF_CONTAINED"' in text
        assert 'lintap_dotnet "${publish_args[@]}"' in text
        assert 'lintap_dotnet "${mcp_publish_args[@]}"' in text


def test_provisioning_sdk_matches_source_baseline():
    version = json.loads((WINTAP / "global.json").read_text())["sdk"]["version"]
    for name in ("multipass-lintap.sh", "multipass-lintap.ps1"):
        text = (ROOT / name).read_text()
        assert f"sdk_version={version}" in text
        assert "dotnet-sdk-8.0" not in text
        assert "net8.0" not in text
