"""Build-host pidstat release contract; no services, VM or runtime downloads."""
from pathlib import Path
import os
import hashlib
import json
import struct
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'packaging/pidstat-common.sh'


@pytest.mark.parametrize('dirty', [False, True])
def test_manifest_uses_python36_subprocess_api(tmp_path, monkeypatch, dirty):
    # Execute the shipping manifest code with a Python 3.6-compatible API shim.
    code = HELPER.read_text().split('<<\'PY\'')[-1].split('\nPY')[0]
    binary = tmp_path / 'pidstat-collector'
    binary.write_bytes(b'fixture binary')
    (tmp_path / 'go.mod').write_text('fixture module')
    (tmp_path / 'go.sum').write_text('fixture sums')
    calls = []

    def check_output(args, *, universal_newlines=False):
        assert universal_newlines is True
        calls.append(args)
        return 'fixture-revision\n' if args[1] == 'rev-parse' else ' M collector.go\n' if dirty else ''

    monkeypatch.setattr(subprocess, 'check_output', check_output)
    monkeypatch.setattr(sys, 'argv', ['manifest', str(binary), 'amd64'])
    monkeypatch.chdir(tmp_path)
    exec(compile(code, str(HELPER), 'exec'), {})
    manifest = json.loads(binary.with_suffix('.build.json').read_text())
    assert manifest['source_revision'] == 'fixture-revision'
    assert manifest['source_dirty'] is dirty
    assert manifest['binary_sha256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
    assert manifest['go_mod_sha256'] == hashlib.sha256((tmp_path / 'go.mod').read_bytes()).hexdigest()
    assert manifest['go_sum_sha256'] == hashlib.sha256((tmp_path / 'go.sum').read_bytes()).hexdigest()
    assert len(calls) == 2


def shell(code, *args, env=None):
    return subprocess.run(['bash', '-c', 'source "$1"; ' + code, 'test', str(HELPER),
                           *map(str, args)], text=True, capture_output=True, env=env)


@pytest.mark.parametrize('arch,rid,expected', [
    ('amd64', 'linux-x64', 'amd64'), ('x86_64', 'linux-x64', 'amd64'),
    ('arm64', 'linux-arm64', 'arm64'), ('aarch64', 'linux-arm64', 'arm64'),
])
def test_architecture_mapping(arch, rid, expected):
    result = shell('lintap_pidstat_arch "$2" "$3"', arch, rid)
    assert result.returncode == 0
    assert result.stdout.strip() == expected


@pytest.mark.parametrize('arch,rid', [
    ('arm64', 'linux-x64'), ('amd64', 'linux-arm64'), ('i386', 'linux-x86'),
])
def test_architecture_mismatch_fails(arch, rid):
    result = shell('lintap_pidstat_arch "$2" "$3"', arch, rid)
    assert result.returncode != 0
    assert 'unsupported' in result.stderr


@pytest.mark.parametrize('version,passes', [('go1.27.3', True), ('go1.27.4', False)])
def test_exact_toolchain_pin(tmp_path, version, passes):
    go = tmp_path / 'fake go'
    go.write_text(f'#!/bin/bash\necho {version}\n')
    go.chmod(0o755)
    result = shell('lintap_require_pidstat_go', env={**os.environ, 'GO': str(go)})
    assert (result.returncode == 0) == passes


def elf(path, machine=62, ptype=1, tag=0):
    data = bytearray(136)
    data[:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HH', data, 16, 2, machine)
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<I', data, 64, ptype)
    struct.pack_into('<Q', data, 72, 120)
    struct.pack_into('<Q', data, 96, 16)
    struct.pack_into('<q', data, 120, tag)
    path.write_bytes(data)
    path.chmod(0o755)


@pytest.mark.parametrize('machine,arch', [(62, 'amd64'), (183, 'arm64')])
def test_static_elf_passes(tmp_path, machine, arch):
    binary = tmp_path / 'collector'
    elf(binary, machine)
    result = shell('lintap_validate_pidstat_binary "$2" "$3"', binary, arch)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize('case', ['machine', 'interpreter', 'needed', 'truncated', 'permissions'])
def test_invalid_binary_fails(tmp_path, case):
    binary = tmp_path / 'collector'
    elf(binary, machine=183 if case == 'machine' else 62,
        ptype=3 if case == 'interpreter' else 2 if case == 'needed' else 1,
        tag=1 if case == 'needed' else 0)
    if case == 'truncated':
        binary.write_bytes(binary.read_bytes()[:80])
    if case == 'permissions':
        binary.chmod(0o644)
    result = shell('lintap_validate_pidstat_binary "$2" "$3"', binary, 'amd64')
    assert result.returncode != 0


def test_staging_retires_only_python_package_payload(tmp_path):
    build = tmp_path / 'build'
    root = tmp_path / 'root'
    build.mkdir()
    payload = root / 'usr/lib/lintap'
    payload.mkdir(parents=True)
    (root / 'usr/share/doc/lintap').mkdir(parents=True)
    elf(build / 'pidstat-collector')
    (build / 'pidstat-collector.build.json').write_text('{}')
    retired = ['pidstat-collector.py', 'pidstat-collector-launch.sh',
               'pidstat-collector-bootstrap.sh']
    for name in retired + ['unrelated.py']:
        (payload / name).write_text('keep unless retired')
    result = shell('lintap_stage_pidstat "$2" "$3" amd64 linux-x64', build, root)
    assert result.returncode == 0, result.stderr
    assert all(not (payload / name).exists() for name in retired)
    assert (payload / 'unrelated.py').exists()
    assert (payload / 'pidstat-collector').stat().st_mode & 0o111
    assert (root / 'usr/share/doc/lintap/pidstat-collector.build.json').exists()


@pytest.mark.parametrize('format', ['deb', 'rpm'])
def test_package_go_contract(format):
    directory = ROOT / f'packaging/lintap-{format}'
    builder = (directory / f'build-{format}.sh').read_text()
    unit = (directory / 'lintap-pidstat.service').read_text()
    env = (directory / 'lintap.env').read_text()
    assert builder.index('lintap_require_pidstat_go') < builder.index('if [[ "$CLEAN" == true ]]')
    assert 'lintap_build_pidstat "$SCRIPT_DIR/../../pidstat-go"' in builder
    assert (directory / '../../pidstat-go/go.mod').is_file()
    assert 'lintap_stage_pidstat' in builder
    assert 'ExecStart=/usr/lib/lintap/pidstat-collector --collect' in unit
    assert 'EnvironmentFile=-/etc/lintap/lintap.env' in unit
    assert 'User=root' in unit
    for key in ('PIDSTAT_VENV_DIR', 'PIDSTAT_DUCKDB_THREADS', 'PIDSTAT_BOOTSTRAP_PYTHON'):
        assert key not in env
    assert 'systemctl start' not in builder.replace('then start with: sudo systemctl start', '')
    assert 'sudo bash /usr/lib/lintap/pidstat-collector-bootstrap.sh' not in builder
    assert ('/etc/lintap/lintap.env' if format == 'deb' else '%config(noreplace) /etc/lintap/lintap.env') in builder
