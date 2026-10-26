"""Provisioning failures must stop before builds or host SSH configuration."""
from pathlib import Path
import os
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("failure", ["cloud-init", "dependencies"])
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
