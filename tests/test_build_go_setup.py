"""Exercise the build-tool installer with fake downloads, never system installs."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile

import pytest


INSTALLER = Path(__file__).resolve().parents[1] / "packaging/install-build-go.sh"


@pytest.mark.parametrize("machine,arch", [("x86_64", "amd64"), ("aarch64", "arm64")])
@pytest.mark.parametrize("corrupt", [False, True])
def test_verified_native_install(tmp_path, machine, arch, corrupt):
    archive = tmp_path / "archive.tar.gz"
    program = b'#!/bin/bash\necho go1.27.3\n'
    with tarfile.open(archive, "w:gz") as tar:
        item = tarfile.TarInfo("go/bin/go")
        item.mode = 0o755
        item.size = len(program)
        tar.addfile(item, io.BytesIO(program))
    checksum = "0" * 64 if corrupt else hashlib.sha256(archive.read_bytes()).hexdigest()
    metadata = tmp_path / "metadata.json"
    metadata.write_text(json.dumps([{"version": "go1.27.3", "files": [{
        "filename": f"go1.27.3.linux-{arch}.tar.gz", "sha256": checksum,
    }]}]))
    tools = tmp_path / "tools"
    tools.mkdir()
    for name, text in {
        "uname": f'#!/bin/bash\nif [[ "$1" == -m ]]; then echo {machine}; else echo Linux; fi\n',
        "curl": '''#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    *mode=json*) source="$METADATA" ;;
    *.tar.gz) source="$ARCHIVE" ;;
  esac
done
while [[ "$1" != -o ]]; do shift; done
cp "$source" "$2"
''',
        "sha256sum": '#!/usr/bin/env python3\nimport hashlib,sys\nline=sys.stdin.read().strip(); digest,path=line.split(None,1)\nsys.exit(hashlib.sha256(open(path,"rb").read()).hexdigest()!=digest)\n',
    }.items():
        path = tools / name
        path.write_text(text)
        path.chmod(0o755)
    root = tmp_path / "install"
    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
               METADATA=str(metadata), ARCHIVE=str(archive), LINTAP_GO_INSTALL_ROOT=str(root))
    result = subprocess.run(["bash", str(INSTALLER)], env=env, text=True, capture_output=True)
    assert (result.returncode != 0) == corrupt, result.stderr
    assert (root / "1.27.3/bin/go").exists() == (not corrupt)
    if not corrupt:
        # Existing valid installation does not require another download.
        (tools / "curl").write_text("#!/bin/bash\nexit 91\n")
        assert subprocess.run(["bash", str(INSTALLER)], env=env, capture_output=True).returncode == 0


def test_invalid_existing_install_is_preserved(tmp_path):
    root = tmp_path / "install"
    existing = root / "1.27.3"
    existing.mkdir(parents=True)
    sentinel = existing / "keep"
    sentinel.write_text("operator work")
    env = dict(os.environ, LINTAP_GO_INSTALL_ROOT=str(root))
    # Fake Linux identity for tests run on macOS.
    tools = tmp_path / "tools"
    tools.mkdir()
    uname = tools / "uname"
    uname.write_text('#!/bin/bash\nif [[ "$1" == -m ]]; then echo amd64; else echo Linux; fi\n')
    uname.chmod(0o755)
    env["PATH"] = f"{tools}:{env['PATH']}"
    result = subprocess.run(["bash", str(INSTALLER)], env=env, capture_output=True, text=True)
    assert result.returncode != 0
    assert "existing Go installation is invalid" in result.stderr
    assert sentinel.read_text() == "operator work"
