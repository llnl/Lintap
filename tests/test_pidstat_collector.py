from __future__ import annotations

import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "pidstat-collector.py"
SPEC = importlib.util.spec_from_file_location("pidstat_collector", MODULE_PATH)
assert SPEC and SPEC.loader
pidstat_collector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pidstat_collector
SPEC.loader.exec_module(pidstat_collector)


class FakeSampler:
    def __init__(self, rows):
        self.rows = list(rows)
        self.calls = 0

    def sample(self, _captured_at=None):
        self.calls += 1
        return list(self.rows)


@pytest.fixture()
def collector_env(tmp_path, monkeypatch):
    data_root = tmp_path / "data"
    runtime_root = tmp_path / "runtime"
    monkeypatch.setenv("WINTAP_DATA_ROOT", str(data_root))
    monkeypatch.setenv("WINTAP_RUNTIME_ROOT", str(runtime_root))
    monkeypatch.delenv("PIDSTAT_PARQUET_ROOT", raising=False)
    monkeypatch.delenv("PIDSTAT_SPOOL_DIR", raising=False)
    monkeypatch.setenv("PIDSTAT_HOSTNAME", "testhost")
    monkeypatch.setenv("PIDSTAT_INTERVAL_SEC", "1")
    monkeypatch.setenv("PIDSTAT_ROTATE_INTERVAL_SEC", "300")
    monkeypatch.setenv("PIDSTAT_MIN_ROTATE_INTERVAL_SEC", "1")
    monkeypatch.setenv("PIDSTAT_PARQUET_COMPRESSION", "ZSTD")
    monkeypatch.setenv("PIDSTAT_DUCKDB_THREADS", "1")
    monkeypatch.setenv("PIDSTAT_MAX_UNSHIPPED_BYTES", "0")
    monkeypatch.setenv("PIDSTAT_MAX_UNSHIPPED_AGE_SEC", "0")
    return pidstat_collector.Config.from_env()


def test_default_collector_roots_split_data_and_runtime(tmp_path, monkeypatch):
    data_root = tmp_path / "data"
    runtime_root = tmp_path / "runtime"
    monkeypatch.setenv("WINTAP_DATA_ROOT", str(data_root))
    monkeypatch.setenv("WINTAP_RUNTIME_ROOT", str(runtime_root))
    monkeypatch.delenv("PIDSTAT_PARQUET_ROOT", raising=False)
    monkeypatch.delenv("PIDSTAT_SPOOL_DIR", raising=False)

    config = pidstat_collector.Config.from_env()

    assert config.parquet_root == data_root
    assert config.raw_sensor_dir == data_root / "raw_sensor" / "pidstat"
    assert config.spool_dir == runtime_root / "pidstat-spool"


def make_row(date_col="2026-08-12", sample_time="07:50:00", pid=128259, command="Lintap"):
    return pidstat_collector.SampleRow(
        date_col=date_col,
        sample_time=sample_time,
        uid=0,
        pid=pid,
        usr_percent=285.98,
        system_percent=140.19,
        guest_percent=0.0,
        wait_percent=0.0,
        cpu_percent=426.17,
        cpu_core=0,
        minflt_per_sec=4317.76,
        majflt_per_sec=0.0,
        vsz_kb=814169220,
        rss_kb=1892724,
        mem_percent=0.48,
        kb_read_per_sec=-1.0,
        kb_write_per_sec=-1.0,
        kb_cancelled_write_per_sec=-1.0,
        iodelay_ticks=0,
        context_switch_per_sec=0.0,
        nonvoluntary_context_switch_per_sec=0.0,
        command=command,
        hostname="testhost",
        cgroup_path="/user.slice/user-1000.slice/session-1.scope",
        pid_ns_inode=4026531836,
        container_runtime=None,
        container_id=None,
    )


def write_rows(path: Path, rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(row.to_tsv())
            handle.write("\n")


def test_oracle_parser_parses_single_line():
    raw_line = "09:05:05        0         1    0.00    0.00    0.00    0.00    0.00    12      0.00      0.00  242192   14800   0.00     -1.00     -1.00     -1.00       0      0.59      0.00  systemd"
    rows = pidstat_collector.PidstatOracle.parse_line(raw_line, "2026-08-12")
    assert len(rows) == 1
    assert rows[0].sample_time == "09:05:05"
    assert rows[0].pid == 1
    assert rows[0].command == "systemd"


def test_oracle_parser_splits_glued_records():
    raw_chunk = "09:14:33 0 1391556 0.00 0.00 0.00 0.00 0.00 22 0.00 0.00 0 0 0.00 -1.00 -1.00 -1.00 0 0.00 0.0009:14:33 0 1391647 0.00 0.00 0.00 0.00 0.00 12 0.00 0.00 0 0 0.00 -1.00 -1.00 -1.00 0 0.00 0.00 kworker/12:1-cgroup_destroy"
    rows = pidstat_collector.PidstatOracle.parse_line(raw_chunk, "2026-08-12")
    assert [row.pid for row in rows] == [1391556, 1391647]
    assert rows[1].command == "kworker/12:1-cgroup_destroy"


def test_oracle_parser_keeps_valid_leading_record_on_malformed_tail():
    raw_chunk = "09:14:33 0 1391556 0.00 0.00 0.00 0.00 0.00 22 0.00 0.00 0 0 0.00 -1.00 -1.00 -1.00 0 0.00 0.0009:14:33 broken tail"
    rows = pidstat_collector.PidstatOracle.parse_line(raw_chunk, "2026-08-12")
    assert len(rows) == 1
    assert rows[0].pid == 1391556


def test_short_rotation_is_clamped_by_default(tmp_path, monkeypatch):
    data_root = tmp_path / "data"
    monkeypatch.setenv("WINTAP_DATA_ROOT", str(data_root))
    monkeypatch.setenv("PIDSTAT_ROTATE_INTERVAL_SEC", "10")
    monkeypatch.delenv("PIDSTAT_MIN_ROTATE_INTERVAL_SEC", raising=False)
    config = pidstat_collector.Config.from_env()
    assert config.rotate_interval_sec == 300


def test_short_rotation_can_be_explicitly_allowed(tmp_path, monkeypatch):
    data_root = tmp_path / "data"
    monkeypatch.setenv("WINTAP_DATA_ROOT", str(data_root))
    monkeypatch.setenv("PIDSTAT_ROTATE_INTERVAL_SEC", "10")
    monkeypatch.setenv("PIDSTAT_MIN_ROTATE_INTERVAL_SEC", "1")
    config = pidstat_collector.Config.from_env()
    assert config.rotate_interval_sec == 10


def test_convert_spool_to_partitioned_parquet(collector_env):
    collector = pidstat_collector.Collector(collector_env, sampler=FakeSampler([]))
    pending_spool = collector.config.spool_dir / "pending-1754985000-1-1.tsv"
    pending_meta = collector.config.spool_dir / "pending-1754985000-1-1.meta"
    rows = [make_row(pid=128259, command="Lintap"), make_row(pid=1330372, command="opencode")]
    write_rows(pending_spool, rows)
    collector.write_meta_file(pending_meta, int(time.mktime(time.strptime("2026-08-12 07:50:00", "%Y-%m-%d %H:%M:%S"))))
    assert collector.convert_spool_to_parquet(pending_spool, pending_meta)
    parquet_files = list(collector.config.raw_sensor_dir.glob("dayPK=20260812/hourPK=07/*.parquet"))
    assert len(parquet_files) == 1
    connection = pidstat_collector.duckdb.connect()
    try:
        row_count = connection.execute(f"select count(*) from read_parquet('{parquet_files[0]}')").fetchone()[0]
        hostname = connection.execute(f"select min(hostname) from read_parquet('{parquet_files[0]}')").fetchone()[0]
        cgroup_path = connection.execute(f"select cgroup_path from read_parquet('{parquet_files[0]}') limit 1").fetchone()[0]
    finally:
        connection.close()
    assert row_count == 2
    assert hostname == "testhost"
    assert cgroup_path == "/user.slice/user-1000.slice/session-1.scope"


def test_midnight_rows_keep_window_start_date(collector_env):
    collector = pidstat_collector.Collector(collector_env, sampler=FakeSampler([]))
    pending_spool = collector.config.spool_dir / "pending-midnight.tsv"
    pending_meta = collector.config.spool_dir / "pending-midnight.meta"
    write_rows(pending_spool, [make_row(date_col="2026-08-12", sample_time="23:59:59")])
    collector.write_meta_file(pending_meta, int(time.mktime(time.strptime("2026-08-12 23:55:00", "%Y-%m-%d %H:%M:%S"))))
    assert collector.convert_spool_to_parquet(pending_spool, pending_meta)
    parquet_file = next(collector.config.raw_sensor_dir.glob("dayPK=20260812/hourPK=23/*.parquet"))
    connection = pidstat_collector.duckdb.connect()
    try:
        value = connection.execute(f"select strftime(time, '%Y-%m-%d %H:%M:%S') from read_parquet('{parquet_file}')").fetchone()[0]
    finally:
        connection.close()
    assert value == "2026-08-12 23:59:59"


def test_salvages_leftover_current_spool(collector_env):
    collector = pidstat_collector.Collector(collector_env, sampler=FakeSampler([]))
    write_rows(collector.current_spool_path(), [make_row()])
    collector.write_meta_file(collector.current_meta_path(), int(time.mktime(time.strptime("2026-08-12 07:50:00", "%Y-%m-%d %H:%M:%S"))))
    collector.salvage_spool_files()
    assert list(collector.config.raw_sensor_dir.glob("dayPK=20260812/hourPK=07/*.parquet"))
    assert not collector.current_spool_path().exists()
    assert not collector.current_meta_path().exists()


def test_byte_cap_drops_oldest_files(collector_env):
    collector = pidstat_collector.Collector(collector_env, sampler=FakeSampler([]))
    collector.config.raw_sensor_dir.mkdir(parents=True, exist_ok=True)
    base_dir = collector.config.raw_sensor_dir / "dayPK=20260812" / "hourPK=07"
    base_dir.mkdir(parents=True)
    files = [base_dir / f"testhost+pidstat+{suffix}.parquet" for suffix in (1, 2, 3)]
    for parquet_file in files:
        parquet_file.write_bytes(b"0" * 60)
    os.utime(files[0], (1, 1))
    os.utime(files[1], (2, 2))
    os.utime(files[2], (3, 3))
    collector.config = collector.config.__class__(
        data_root=collector.config.data_root,
        interval_sec=collector.config.interval_sec,
        rotate_interval_sec=collector.config.rotate_interval_sec,
        min_rotate_interval_sec=collector.config.min_rotate_interval_sec,
        parquet_root=collector.config.parquet_root,
        spool_dir=collector.config.spool_dir,
        parquet_compression=collector.config.parquet_compression,
        duckdb_threads=collector.config.duckdb_threads,
        max_unshipped_bytes=100,
        max_unshipped_age_sec=collector.config.max_unshipped_age_sec,
        hostname=collector.config.hostname,
    )
    collector.enforce_accumulation_guard()
    assert not files[0].exists()
    assert not files[1].exists()
    assert files[2].exists()


def test_age_cap_drops_stale_files(collector_env):
    collector = pidstat_collector.Collector(collector_env, sampler=FakeSampler([]))
    base_dir = collector.config.raw_sensor_dir / "dayPK=20260812" / "hourPK=07"
    base_dir.mkdir(parents=True)
    stale_file = base_dir / "testhost+pidstat+10.parquet"
    fresh_file = base_dir / "testhost+pidstat+11.parquet"
    stale_file.write_bytes(b"1" * 32)
    fresh_file.write_bytes(b"2" * 32)
    old_time = time.time() - 3600
    os.utime(stale_file, (old_time, old_time))
    collector.config = collector.config.__class__(
        data_root=collector.config.data_root,
        interval_sec=collector.config.interval_sec,
        rotate_interval_sec=collector.config.rotate_interval_sec,
        min_rotate_interval_sec=collector.config.min_rotate_interval_sec,
        parquet_root=collector.config.parquet_root,
        spool_dir=collector.config.spool_dir,
        parquet_compression=collector.config.parquet_compression,
        duckdb_threads=collector.config.duckdb_threads,
        max_unshipped_bytes=collector.config.max_unshipped_bytes,
        max_unshipped_age_sec=60,
        hostname=collector.config.hostname,
    )
    collector.enforce_accumulation_guard()
    assert not stale_file.exists()
    assert fresh_file.exists()


def test_live_collector_run_writes_rows(collector_env, monkeypatch):
    monkeypatch.setenv("PIDSTAT_ROTATE_INTERVAL_SEC", "2")
    config = pidstat_collector.Config.from_env()
    process = subprocess.Popen([sys.executable, str(MODULE_PATH)], env=os.environ.copy())
    try:
        time.sleep(5)
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=15)
    finally:
        if process.poll() is None:
            process.kill()
    parquet_files = list(config.raw_sensor_dir.rglob("*.parquet"))
    assert parquet_files
    connection = pidstat_collector.duckdb.connect()
    try:
        row_count = connection.execute(f"select count(*) from read_parquet('{config.raw_sensor_dir}/**/*.parquet')").fetchone()[0]
        distinct_commands = connection.execute(f"select count(distinct command) from read_parquet('{config.raw_sensor_dir}/**/*.parquet')").fetchone()[0]
    finally:
        connection.close()
    assert row_count > 0
    assert distinct_commands > 1


def test_container_parser_handles_v1_and_v2_formats():
    docker_v1 = "10:memory:/docker/1234567890abcdef1234567890abcdef\n9:cpu:/docker/1234567890abcdef1234567890abcdef\n"
    info_v1 = pidstat_collector.parse_cgroup_text(docker_v1, "pid:[4026533001]")
    assert info_v1.container_runtime == "docker"
    assert info_v1.container_id == "1234567890abcdef1234567890abcdef"
    assert info_v1.pid_ns_inode == 4026533001

    podman_v2 = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/libpod-abcdef0123456789.scope\n"
    info_v2 = pidstat_collector.parse_cgroup_text(podman_v2, "pid:[4026533002]")
    assert info_v2.container_runtime == "podman"
    assert info_v2.container_id == "abcdef0123456789"


@pytest.mark.skipif(sys.platform != "linux", reason="requires Linux /proc and pidstat")
def test_proc_sampler_matches_pidstat_oracle_within_tolerance():
    sampler = pidstat_collector.ProcSampler(hostname="testhost")
    workload_script = (
        "import os, tempfile, time\n"
        "path = tempfile.mkstemp(prefix='pidstat-oracle-', suffix='.bin')[1]\n"
        "end = time.time() + 2.2\n"
        "with open(path, 'wb', buffering=0) as handle:\n"
        "    payload = b'x' * 4096\n"
        "    while time.time() < end:\n"
        "        sum(i * i for i in range(5000))\n"
        "        handle.write(payload)\n"
        "        handle.flush()\n"
        "        os.fsync(handle.fileno())\n"
    )
    with tempfile.TemporaryDirectory() as _tmp:
        workload = subprocess.Popen([sys.executable, "-c", workload_script])
        try:
            time.sleep(0.2)
            sampler.sample(time.time())
            oracle_rows = pidstat_collector.PidstatOracle.capture_once(1, pids=str(workload.pid))
            proc_rows = sampler.sample(time.time())
        finally:
            workload.wait(timeout=10)
    proc_row = next(row for row in proc_rows if row.pid == workload.pid)
    oracle_row = next(row for row in oracle_rows if row.pid == workload.pid)
    assert abs(proc_row.cpu_percent - oracle_row.cpu_percent) <= 35.0
    assert abs(proc_row.rss_kb - oracle_row.rss_kb) <= max(oracle_row.rss_kb * 0.25, 4096)
    assert abs(proc_row.kb_write_per_sec - oracle_row.kb_write_per_sec) <= max(oracle_row.kb_write_per_sec * 0.5, 4096)


@pytest.mark.skipif(sys.platform != "linux", reason="requires Linux /proc")
def test_collector_steady_state_has_no_children(collector_env):
    process = subprocess.Popen([sys.executable, str(MODULE_PATH)], env=os.environ.copy())
    try:
        time.sleep(3)
        children_text = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text(encoding="utf-8")
    finally:
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=15)
    assert children_text.strip() == ""
