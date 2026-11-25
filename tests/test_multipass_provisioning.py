"""Provisioning failures must stop before builds or host SSH configuration."""
from pathlib import Path
import os
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


def test_cloud_init_uses_mount_safe_python_setup():
    script = (ROOT / "multipass-lintap.sh").read_text()

    assert "-m ensurepip --upgrade" in script
    assert "python -m pip install" in script
    assert "uv pip install" not in script
    assert "chown -R ubuntu:ubuntu /home/ubuntu/data" not in script
    assert (
        "install -d -o ubuntu -g ubuntu /home/ubuntu/data /tmp/validation-runs"
        in script
    )


def test_both_launchers_install_pinned_go_before_checks():
    for name in ("multipass-lintap.sh", "multipass-lintap.ps1"):
        script = (ROOT / name).read_text()
        assert "packaging/install-build-go.sh" in script
        assert script.index("packaging/install-build-go.sh") < script.index("Running post-create checks")
        assert "sudo bash -s" in script
    checks = (ROOT / "multipass-check-dev.sh").read_text()
    assert "GO=/opt/lintap-go/1.27.3/bin/go" in checks
    assert 'env GOVERSION)' in checks
    assert 'lintap_require_dotnet_sdk' in checks


@pytest.mark.parametrize("failure", ["cloud-init", "go-install", "dependencies"])
def test_failed_provisioning_stops_before_build(tmp_path, failure):
    tools = tmp_path / "tools"
    tools.mkdir()
    calls = tmp_path / "calls"
    multipass = tools / "multipass"
    multipass.write_text('''#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  list) exit 0 ;;
  launch) cat > /dev/null; exit 0 ;;
  info) echo 'IPv4: 192.0.2.1'; exit 0 ;;
  exec)
    case "$*" in
      *'cloud-init status --wait')
        [ "$FAILURE" != cloud-init ]; exit $? ;;
       *'-- sudo bash -s')
         cat > /dev/null
         [ "$FAILURE" != go-install ]; exit $? ;;
       *'-- bash -s')
        cat > /dev/null
        [ "$FAILURE" != dependencies ]; exit $? ;;
      *) exit 0 ;;
    esac ;;
esac
exit 1
''')
    multipass.chmod(0o755)
    config = tmp_path / "config.env"
    config.write_text(f'''INSTANCE_NAME=lintap-test
MOUNTS=("{tmp_path}:/home/ubuntu/git")
BUILD_WINTAP=true
RUN_POSTCREATE_CHECKS=true
CLOUD_INIT_STRICT=true
''')
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
               CALLS=str(calls), FAILURE=failure, CONFIG_FILE=str(config))
    result = subprocess.run(["bash", str(ROOT / "multipass-lintap.sh")],
                            cwd=tmp_path, env=env, capture_output=True, text=True)
    assert result.returncode != 0
    commands = calls.read_text()
    assert "cloud-init status --wait" in commands
    assert ("-- bash -s" in commands) == (failure == "dependencies")
    assert "make build" not in commands
    assert "Configuring ~/.ssh/config" not in result.stdout


def test_cloud_init_diagnostics_are_bounded(tmp_path):
    tools = tmp_path / "tools"
    tools.mkdir()
    multipass = tools / "multipass"
    multipass.write_text('''#!/usr/bin/env bash
case "$1" in
  list) exit 0 ;;
  launch) cat > /dev/null; exit 0 ;;
  exec)
    case "$*" in
      *'cloud-init status --wait') exit 1 ;;
      *) exec sleep 30 ;;
    esac ;;
esac
exit 1
''')
    multipass.chmod(0o755)
    config = tmp_path / "config.env"
    config.write_text(f'''INSTANCE_NAME=lintap-test
MOUNTS=("{tmp_path}:/home/ubuntu/git")
CLOUD_INIT_STRICT=true
CLOUD_INIT_DIAGNOSTIC_TIMEOUT=1
''')
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
               CONFIG_FILE=str(config))

    result = subprocess.run(["bash", str(ROOT / "multipass-lintap.sh")],
                            cwd=tmp_path, env=env, capture_output=True,
                            text=True, timeout=8)

    assert result.returncode != 0
    assert "cloud-init reported an error" in result.stdout
    assert "cloud-init failed and CLOUD_INIT_STRICT=true" in result.stderr
