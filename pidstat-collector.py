#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional

try:
    import duckdb
except ImportError as exc:  # pragma: no cover - exercised in runtime startup
    duckdb = None
    DUCKDB_IMPORT_ERROR = exc
else:
    DUCKDB_IMPORT_ERROR = None


TIMESTAMP_RE = re.compile(r"^\d{2}:\d{2}:\d{2}$")
PID_NS_RE = re.compile(r"pid:\[(\d+)\]")
CONTAINER_PATTERNS = (
    ("docker", re.compile(r"(?:^|/|:)docker[-/](?P<id>[0-9a-f]{12,64})(?:\.scope)?(?:/|$)")),
    ("podman", re.compile(r"(?:^|/|:)libpod[-/](?P<id>[0-9a-f]{12,64})(?:\.scope)?(?:/|$)")),
    ("containerd", re.compile(r"(?:^|/|:)(?:cri-containerd|containerd)[-/](?P<id>[0-9a-f]{12,64})(?:\.scope)?(?:/|$)")),
    ("crio", re.compile(r"(?:^|/|:)crio[-/](?P<id>[0-9a-f]{12,64})(?:\.scope)?(?:/|$)")),
)

TSV_COLUMNS = (
    "date_col",
    "sample_time",
    "uid",
    "pid",
    "usr_percent",
    "system_percent",
    "guest_percent",
    "wait_percent",
    "cpu_percent",
    "cpu_core",
    "minflt_per_sec",
    "majflt_per_sec",
    "vsz_kb",
    "rss_kb",
    "mem_percent",
    "kb_read_per_sec",
    "kb_write_per_sec",
    "kb_cancelled_write_per_sec",
    "iodelay_ticks",
    "context_switch_per_sec",
    "nonvoluntary_context_switch_per_sec",
    "command",
    "hostname",
    "cgroup_path",
    "pid_ns_inode",
    "container_runtime",
    "container_id",
)

# cpu_percent is retained for raw pidstat compatibility. It is process CPU
# summed across cores: 100 means one fully occupied logical CPU and values can
# exceed 100 on multicore hosts.


def log(message: str) -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{timestamp} - {message}", file=sys.stderr, flush=True)


def fail(message: str) -> "NoReturn":
    log(f"ERROR: {message}")
    raise SystemExit(1)


def parse_positive_int(value: str, env_name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(f"{env_name} must be a positive integer") from exc
    if parsed <= 0:
        raise ValueError(f"{env_name} must be a positive integer")
    return parsed


def parse_nonnegative_int(value: str, env_name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise ValueError(f"{env_name} must be a non-negative integer") from exc
    if parsed < 0:
        raise ValueError(f"{env_name} must be a non-negative integer")
    return parsed


def short_hostname() -> str:
    return socket.gethostname().split(".", 1)[0]


def window_start_for_epoch(epoch: int, rotate_interval_sec: int) -> int:
    return epoch - (epoch % rotate_interval_sec)


def sample_date_from_epoch(epoch: int) -> str:
    return datetime.fromtimestamp(epoch).strftime("%Y-%m-%d")


def duckdb_escape_literal(value: str) -> str:
    return value.replace("'", "''")


def sanitize_field(value: str) -> str:
    return value.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def read_optional_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except (FileNotFoundError, ProcessLookupError, PermissionError, OSError):
        return None


def parse_kv_file(text: Optional[str]) -> dict[str, str]:
    if text is None:
        return {}
    result: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip()
    return result


def format_float(value: float) -> str:
    return f"{value:.2f}"


@dataclass(frozen=True)
class ContainerInfo:
    cgroup_path: str
    pid_ns_inode: Optional[int]
    container_runtime: Optional[str]
    container_id: Optional[str]


@dataclass(frozen=True)
class ProcSnapshot:
    captured_at: float
    uid: int
    pid: int
    command: str
    starttime: int
    utime_ticks: int
    stime_ticks: int
    guest_ticks: int
    minflt: int
    majflt: int
    vsz_kb: int
    rss_kb: int
    mem_percent: float
    read_bytes: int
    write_bytes: int
    cancelled_write_bytes: int
    blkio_ticks: int
    voluntary_context_switches: int
    nonvoluntary_context_switches: int
    run_delay_ns: int
    cpu_core: int
    container_info: ContainerInfo


@dataclass(frozen=True)
class SampleRow:
    date_col: str
    sample_time: str
    uid: int
    pid: int
    usr_percent: float
    system_percent: float
    guest_percent: float
    wait_percent: float
    cpu_percent: float
    cpu_core: int
    minflt_per_sec: float
    majflt_per_sec: float
    vsz_kb: int
    rss_kb: int
    mem_percent: float
    kb_read_per_sec: float
    kb_write_per_sec: float
    kb_cancelled_write_per_sec: float
    iodelay_ticks: int
    context_switch_per_sec: float
    nonvoluntary_context_switch_per_sec: float
    command: str
    hostname: str
    cgroup_path: str
    pid_ns_inode: Optional[int]
    container_runtime: Optional[str]
    container_id: Optional[str]

    def to_tsv(self) -> str:
        fields = [
            self.date_col,
            self.sample_time,
            str(self.uid),
            str(self.pid),
            format_float(self.usr_percent),
            format_float(self.system_percent),
            format_float(self.guest_percent),
            format_float(self.wait_percent),
            format_float(self.cpu_percent),
            str(self.cpu_core),
            format_float(self.minflt_per_sec),
            format_float(self.majflt_per_sec),
            str(self.vsz_kb),
            str(self.rss_kb),
            format_float(self.mem_percent),
            format_float(self.kb_read_per_sec),
            format_float(self.kb_write_per_sec),
            format_float(self.kb_cancelled_write_per_sec),
            str(self.iodelay_ticks),
            format_float(self.context_switch_per_sec),
            format_float(self.nonvoluntary_context_switch_per_sec),
            sanitize_field(self.command),
            sanitize_field(self.hostname),
            sanitize_field(self.cgroup_path),
            "" if self.pid_ns_inode is None else str(self.pid_ns_inode),
            "" if self.container_runtime is None else sanitize_field(self.container_runtime),
            "" if self.container_id is None else sanitize_field(self.container_id),
        ]
        return "\t".join(fields)


@dataclass(frozen=True)
class Config:
    data_root: Path
    interval_sec: int
    rotate_interval_sec: int
    min_rotate_interval_sec: int
    parquet_root: Path
    spool_dir: Path
    parquet_compression: str
    duckdb_threads: int
    max_unshipped_bytes: int
    max_unshipped_age_sec: int
    hostname: str

    @property
    def raw_sensor_dir(self) -> Path:
        return self.parquet_root / "raw_sensor" / "pidstat"

    @classmethod
    def from_env(cls) -> "Config":
        if duckdb is None:
            fail(f"duckdb Python module import failed: {DUCKDB_IMPORT_ERROR}")

        data_root = Path(os.environ.get("WINTAP_DATA_ROOT", f"{Path.home()}/data/lintap/lintap-dev"))
        interval_sec = parse_positive_int(os.environ.get("PIDSTAT_INTERVAL_SEC", "5"), "PIDSTAT_INTERVAL_SEC")
        rotate_interval_sec = parse_positive_int(
            os.environ.get("PIDSTAT_ROTATE_INTERVAL_SEC", os.environ.get("WINTAP_ETL_UPLOAD_INTERVAL_SEC", "300")),
            "PIDSTAT_ROTATE_INTERVAL_SEC",
        )
        min_rotate_interval_sec = parse_positive_int(
            os.environ.get("PIDSTAT_MIN_ROTATE_INTERVAL_SEC", "300"),
            "PIDSTAT_MIN_ROTATE_INTERVAL_SEC",
        )
        if rotate_interval_sec < min_rotate_interval_sec:
            log(
                "WARN: PIDSTAT_ROTATE_INTERVAL_SEC="
                f"{rotate_interval_sec}s is below PIDSTAT_MIN_ROTATE_INTERVAL_SEC="
                f"{min_rotate_interval_sec}s; using {min_rotate_interval_sec}s. "
                "Short rotation intervals amplify DuckDB conversion thread churn "
                "and Lintap process-event noise."
            )
            rotate_interval_sec = min_rotate_interval_sec
        runtime_root = Path(os.environ.get("WINTAP_RUNTIME_ROOT", f"{Path.home()}/data/lintap/lintap-dev-runtime"))
        parquet_root = Path(os.environ.get("PIDSTAT_PARQUET_ROOT", str(data_root)))
        spool_dir = Path(os.environ.get("PIDSTAT_SPOOL_DIR", str(runtime_root / "pidstat-spool")))
        duckdb_threads = parse_positive_int(os.environ.get("PIDSTAT_DUCKDB_THREADS", "1"), "PIDSTAT_DUCKDB_THREADS")
        max_unshipped_bytes = parse_nonnegative_int(
            os.environ.get("PIDSTAT_MAX_UNSHIPPED_BYTES", "1073741824"),
            "PIDSTAT_MAX_UNSHIPPED_BYTES",
        )
        max_unshipped_age_sec = parse_nonnegative_int(
            os.environ.get("PIDSTAT_MAX_UNSHIPPED_AGE_SEC", "0"),
            "PIDSTAT_MAX_UNSHIPPED_AGE_SEC",
        )
        hostname = os.environ.get("PIDSTAT_HOSTNAME", short_hostname())
        parquet_compression = os.environ.get("PIDSTAT_PARQUET_COMPRESSION", "ZSTD")

        config = cls(
            data_root=data_root,
            interval_sec=interval_sec,
            rotate_interval_sec=rotate_interval_sec,
            min_rotate_interval_sec=min_rotate_interval_sec,
            parquet_root=parquet_root,
            spool_dir=spool_dir,
            parquet_compression=parquet_compression,
            duckdb_threads=duckdb_threads,
            max_unshipped_bytes=max_unshipped_bytes,
            max_unshipped_age_sec=max_unshipped_age_sec,
            hostname=hostname,
        )
        config.spool_dir.mkdir(parents=True, exist_ok=True)
        config.raw_sensor_dir.mkdir(parents=True, exist_ok=True)
        return config


def parse_container_runtime(path: str) -> tuple[Optional[str], Optional[str]]:
    for runtime, pattern in CONTAINER_PATTERNS:
        match = pattern.search(path)
        if match:
            return runtime, match.group("id")
    return None, None


def parse_cgroup_text(text: Optional[str], pid_ns_link: Optional[str]) -> ContainerInfo:
    best_path = "/"
    container_runtime: Optional[str] = None
    container_id: Optional[str] = None
    if text:
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            if ":" in line:
                _, _, raw_path = line.partition(":")
                _, _, cgroup_path = raw_path.partition(":")
                cgroup_path = cgroup_path or raw_path
            else:
                cgroup_path = line
            cgroup_path = cgroup_path.strip() or "/"
            if cgroup_path != "/" and (best_path == "/" or len(cgroup_path) > len(best_path)):
                best_path = cgroup_path
            runtime, container = parse_container_runtime(cgroup_path)
            if runtime is not None:
                best_path = cgroup_path
                container_runtime = runtime
                container_id = container
                break

    pid_ns_inode = None
    if pid_ns_link:
        match = PID_NS_RE.search(pid_ns_link)
        if match:
            pid_ns_inode = int(match.group(1))

    return ContainerInfo(
        cgroup_path=best_path,
        pid_ns_inode=pid_ns_inode,
        container_runtime=container_runtime,
        container_id=container_id,
    )


class ProcSampler:
    def __init__(self, hostname: str, proc_root: Path = Path("/proc")) -> None:
        self.hostname = hostname
        self.proc_root = proc_root
        self.clock_ticks = os.sysconf("SC_CLK_TCK")
        self.page_size_kb = os.sysconf("SC_PAGE_SIZE") // 1024
        self.mem_total_kb = self._read_mem_total_kb()
        self.previous: dict[int, ProcSnapshot] = {}
        self.container_cache: dict[tuple[int, int], ContainerInfo] = {}

    def _read_mem_total_kb(self) -> int:
        meminfo = read_optional_text(self.proc_root / "meminfo")
        for line in (meminfo or "").splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1])
        fail(f"could not read MemTotal from {self.proc_root / 'meminfo'}")

    def _read_container_info(self, pid: int, starttime: int) -> ContainerInfo:
        cache_key = (pid, starttime)
        cached = self.container_cache.get(cache_key)
        if cached is not None:
            return cached
        cgroup_text = read_optional_text(self.proc_root / str(pid) / "cgroup")
        try:
            pid_ns_link = os.readlink(self.proc_root / str(pid) / "ns" / "pid")
        except (FileNotFoundError, PermissionError, OSError):
            pid_ns_link = None
        container_info = parse_cgroup_text(cgroup_text, pid_ns_link)
        self.container_cache[cache_key] = container_info
        return container_info

    @staticmethod
    def _parse_stat_text(text: str) -> dict[str, int | str]:
        open_paren = text.find("(")
        close_paren = text.rfind(")")
        if open_paren < 0 or close_paren < 0 or close_paren <= open_paren:
            raise ValueError("malformed /proc stat record")
        pid = int(text[:open_paren].strip())
        command = text[open_paren + 1 : close_paren]
        fields = text[close_paren + 2 :].split()
        if len(fields) < 41:
            raise ValueError("short /proc stat record")
        return {
            "pid": pid,
            "command": command,
            "minflt": int(fields[7]),
            "majflt": int(fields[9]),
            "utime_ticks": int(fields[11]),
            "stime_ticks": int(fields[12]),
            "starttime": int(fields[19]),
            "vsize_kb": int(fields[20]) // 1024,
            "rss_kb": int(fields[21]) * (os.sysconf("SC_PAGE_SIZE") // 1024),
            "cpu_core": int(fields[36]),
            "blkio_ticks": int(fields[39]),
            "guest_ticks": int(fields[40]),
        }

    def _read_snapshot(self, pid: int, captured_at: float) -> Optional[ProcSnapshot]:
        proc_dir = self.proc_root / str(pid)
        stat_text = read_optional_text(proc_dir / "stat")
        status_text = read_optional_text(proc_dir / "status")
        if stat_text is None or status_text is None:
            return None

        try:
            stat_fields = self._parse_stat_text(stat_text)
        except (ValueError, IndexError):
            return None

        status = parse_kv_file(status_text)
        uid_value = status.get("Uid")
        if not uid_value:
            return None
        try:
            uid = int(uid_value.split()[0])
        except (ValueError, IndexError):
            return None

        io = parse_kv_file(read_optional_text(proc_dir / "io"))
        schedstat_text = read_optional_text(proc_dir / "schedstat")
        run_delay_ns = 0
        if schedstat_text:
            sched_parts = schedstat_text.split()
            if len(sched_parts) >= 2:
                try:
                    run_delay_ns = int(sched_parts[1])
                except ValueError:
                    run_delay_ns = 0

        try:
            starttime = int(stat_fields["starttime"])
        except (ValueError, TypeError):
            return None

        container_info = self._read_container_info(pid, starttime)
        rss_kb = int(stat_fields["rss_kb"])
        mem_percent = (rss_kb / self.mem_total_kb) * 100 if self.mem_total_kb else 0.0

        return ProcSnapshot(
            captured_at=captured_at,
            uid=uid,
            pid=pid,
            command=str(stat_fields["command"]),
            starttime=starttime,
            utime_ticks=int(stat_fields["utime_ticks"]),
            stime_ticks=int(stat_fields["stime_ticks"]),
            guest_ticks=int(stat_fields["guest_ticks"]),
            minflt=int(stat_fields["minflt"]),
            majflt=int(stat_fields["majflt"]),
            vsz_kb=int(stat_fields["vsize_kb"]),
            rss_kb=rss_kb,
            mem_percent=mem_percent,
            read_bytes=int(io.get("read_bytes", "0")),
            write_bytes=int(io.get("write_bytes", "0")),
            cancelled_write_bytes=int(io.get("cancelled_write_bytes", "0")),
            blkio_ticks=int(stat_fields["blkio_ticks"]),
            voluntary_context_switches=int(status.get("voluntary_ctxt_switches", "0")),
            nonvoluntary_context_switches=int(status.get("nonvoluntary_ctxt_switches", "0")),
            run_delay_ns=run_delay_ns,
            cpu_core=int(stat_fields["cpu_core"]),
            container_info=container_info,
        )

    def sample(self, captured_at: Optional[float] = None) -> list[SampleRow]:
        sample_time = captured_at if captured_at is not None else time.time()
        current: dict[int, ProcSnapshot] = {}
        rows: list[SampleRow] = []

        for entry in sorted(os.scandir(self.proc_root), key=lambda item: item.name):
            if not entry.name.isdigit():
                continue
            snapshot = self._read_snapshot(int(entry.name), sample_time)
            if snapshot is None:
                continue
            current[snapshot.pid] = snapshot
            previous = self.previous.get(snapshot.pid)
            if previous is None or previous.starttime != snapshot.starttime:
                continue
            rows.append(self._build_row(previous, snapshot))

        self.previous = current
        return rows

    def _build_row(self, previous: ProcSnapshot, current: ProcSnapshot) -> SampleRow:
        interval = max(current.captured_at - previous.captured_at, 0.001)
        delta_guest = max(current.guest_ticks - previous.guest_ticks, 0)
        delta_user = max((current.utime_ticks - previous.utime_ticks) - delta_guest, 0)
        delta_system = max(current.stime_ticks - previous.stime_ticks, 0)
        timestamp = datetime.fromtimestamp(current.captured_at)

        return SampleRow(
            date_col=timestamp.strftime("%Y-%m-%d"),
            sample_time=timestamp.strftime("%H:%M:%S"),
            uid=current.uid,
            pid=current.pid,
            usr_percent=(delta_user / self.clock_ticks) / interval * 100.0,
            system_percent=(delta_system / self.clock_ticks) / interval * 100.0,
            guest_percent=(delta_guest / self.clock_ticks) / interval * 100.0,
            wait_percent=(max(current.run_delay_ns - previous.run_delay_ns, 0) / 1_000_000_000.0) / interval * 100.0,
            cpu_percent=((delta_user + delta_system + delta_guest) / self.clock_ticks) / interval * 100.0,
            cpu_core=current.cpu_core,
            minflt_per_sec=max(current.minflt - previous.minflt, 0) / interval,
            majflt_per_sec=max(current.majflt - previous.majflt, 0) / interval,
            vsz_kb=current.vsz_kb,
            rss_kb=current.rss_kb,
            mem_percent=current.mem_percent,
            kb_read_per_sec=max(current.read_bytes - previous.read_bytes, 0) / 1024.0 / interval,
            kb_write_per_sec=max(current.write_bytes - previous.write_bytes, 0) / 1024.0 / interval,
            kb_cancelled_write_per_sec=max(current.cancelled_write_bytes - previous.cancelled_write_bytes, 0) / 1024.0 / interval,
            iodelay_ticks=max(current.blkio_ticks - previous.blkio_ticks, 0),
            context_switch_per_sec=max(
                current.voluntary_context_switches - previous.voluntary_context_switches,
                0,
            )
            / interval,
            nonvoluntary_context_switch_per_sec=max(
                current.nonvoluntary_context_switches - previous.nonvoluntary_context_switches,
                0,
            )
            / interval,
            command=current.command,
            hostname=self.hostname,
            cgroup_path=current.container_info.cgroup_path,
            pid_ns_inode=current.container_info.pid_ns_inode,
            container_runtime=current.container_info.container_runtime,
            container_id=current.container_info.container_id,
        )


class PidstatOracle:
    @staticmethod
    def split_tokens(line: str) -> list[str]:
        raw_tokens = line.split()
        tokens: list[str] = []
        for token in raw_tokens:
            match = re.match(r"^(.+?)(\d{2}:\d{2}:\d{2})$", token)
            if match and not TIMESTAMP_RE.fullmatch(token):
                tokens.append(match.group(1))
                tokens.append(match.group(2))
            else:
                tokens.append(token)
        return tokens

    @classmethod
    def parse_line(cls, line: str, sample_date: str) -> list[SampleRow]:
        stripped = line.strip()
        if not stripped or stripped.startswith("Linux") or stripped.startswith("#") or stripped.startswith("Average:"):
            return []

        tokens = cls.split_tokens(stripped)
        rows: list[SampleRow] = []
        start = 0
        while len(tokens) - start >= 21:
            if not TIMESTAMP_RE.fullmatch(tokens[start]):
                break
            next_start = len(tokens)
            for index in range(start + 20, len(tokens)):
                if TIMESTAMP_RE.fullmatch(tokens[index]) and len(tokens) - index >= 21:
                    next_start = index
                    break
            command = " ".join(tokens[start + 20 : next_start])
            rows.append(
                SampleRow(
                    date_col=sample_date,
                    sample_time=tokens[start],
                    uid=int(tokens[start + 1]),
                    pid=int(tokens[start + 2]),
                    usr_percent=float(tokens[start + 3]),
                    system_percent=float(tokens[start + 4]),
                    guest_percent=float(tokens[start + 5]),
                    wait_percent=float(tokens[start + 6]),
                    cpu_percent=float(tokens[start + 7]),
                    cpu_core=int(tokens[start + 8]),
                    minflt_per_sec=float(tokens[start + 9]),
                    majflt_per_sec=float(tokens[start + 10]),
                    vsz_kb=int(tokens[start + 11]),
                    rss_kb=int(tokens[start + 12]),
                    mem_percent=float(tokens[start + 13]),
                    kb_read_per_sec=float(tokens[start + 14]),
                    kb_write_per_sec=float(tokens[start + 15]),
                    kb_cancelled_write_per_sec=float(tokens[start + 16]),
                    iodelay_ticks=int(float(tokens[start + 17])),
                    context_switch_per_sec=float(tokens[start + 18]),
                    nonvoluntary_context_switch_per_sec=float(tokens[start + 19]),
                    command=command,
                    hostname="",
                    cgroup_path="",
                    pid_ns_inode=None,
                    container_runtime=None,
                    container_id=None,
                )
            )
            start = next_start
        return rows

    @classmethod
    def parse_output(cls, output: str, sample_date: str) -> list[SampleRow]:
        rows: list[SampleRow] = []
        for line in output.splitlines():
            rows.extend(cls.parse_line(line, sample_date))
        return rows

    @classmethod
    def capture_once(cls, interval_sec: int, pids: str = "ALL") -> list[SampleRow]:
        command = ["pidstat", "-u", "-d", "-r", "-w", "-h", "-p", str(pids), str(interval_sec), "1"]
        environment = os.environ.copy()
        environment["S_TIME_FORMAT"] = "ISO"
        completed = subprocess.run(command, capture_output=True, text=True, check=True, env=environment)
        return cls.parse_output(completed.stdout, sample_date_from_epoch(int(time.time())))


class Collector:
    def __init__(self, config: Config, sampler: Optional[ProcSampler] = None) -> None:
        self.config = config
        self.sampler = sampler or ProcSampler(hostname=config.hostname)
        self.stop_event = threading.Event()
        self._duckdb_connection = None

    def close(self) -> None:
        if self._duckdb_connection is not None:
            self._duckdb_connection.close()
            self._duckdb_connection = None

    def duckdb_connection(self):
        if self._duckdb_connection is None:
            self._duckdb_connection = duckdb.connect(config={"threads": str(self.config.duckdb_threads)})
            self._duckdb_connection.execute(f"SET threads TO {self.config.duckdb_threads}")
        return self._duckdb_connection

    def current_spool_path(self) -> Path:
        return self.config.spool_dir / "current.tsv"

    def current_meta_path(self) -> Path:
        return self.config.spool_dir / "current.meta"

    @staticmethod
    def meta_path_for_spool(spool_path: Path) -> Path:
        return spool_path.with_suffix(".meta")

    def write_meta_file(self, meta_path: Path, window_start_epoch: int) -> None:
        meta_path.write_text(f"window_start_epoch={window_start_epoch}\n", encoding="utf-8")

    @staticmethod
    def read_window_start_from_meta(meta_path: Path) -> Optional[int]:
        text = read_optional_text(meta_path)
        if text is None:
            return None
        for line in text.splitlines():
            key, _, value = line.partition("=")
            if key == "window_start_epoch":
                try:
                    return int(value)
                except ValueError:
                    return None
        return None

    def infer_window_start_from_spool(self, spool_path: Path) -> Optional[int]:
        text = read_optional_text(spool_path)
        if not text:
            return None
        first_line = text.splitlines()[0]
        fields = first_line.split("\t", 2)
        if len(fields) < 2:
            return None
        try:
            epoch = int(datetime.strptime(f"{fields[0]} {fields[1]}", "%Y-%m-%d %H:%M:%S").timestamp())
        except ValueError:
            return None
        return window_start_for_epoch(epoch, self.config.rotate_interval_sec)

    def ensure_meta_for_spool(self, spool_path: Path, meta_path: Path) -> bool:
        if self.read_window_start_from_meta(meta_path) is not None:
            return True
        inferred = self.infer_window_start_from_spool(spool_path)
        if inferred is None:
            return False
        self.write_meta_file(meta_path, inferred)
        return True

    def initialize_current_window(self, window_start_epoch: int) -> None:
        self.config.spool_dir.mkdir(parents=True, exist_ok=True)
        self.current_spool_path().write_text("", encoding="utf-8")
        self.write_meta_file(self.current_meta_path(), window_start_epoch)

    def append_rows(self, rows: Iterable[SampleRow]) -> None:
        with self.current_spool_path().open("a", encoding="utf-8") as handle:
            for row in rows:
                handle.write(row.to_tsv())
                handle.write("\n")

    def seal_current_spool(self) -> None:
        current_spool = self.current_spool_path()
        current_meta = self.current_meta_path()
        if not current_spool.exists():
            return
        if current_spool.stat().st_size == 0:
            current_spool.unlink(missing_ok=True)
            current_meta.unlink(missing_ok=True)
            return
        window_start_epoch = self.read_window_start_from_meta(current_meta)
        if window_start_epoch is None:
            window_start_epoch = self.infer_window_start_from_spool(current_spool)
        if window_start_epoch is None:
            fail(f"could not determine window start for {current_spool}")
        pending_base = self.config.spool_dir / f"pending-{window_start_epoch}-{int(time.time())}-{os.getpid()}"
        pending_spool = pending_base.with_suffix(".tsv")
        pending_meta = pending_base.with_suffix(".meta")
        os.replace(current_spool, pending_spool)
        os.replace(current_meta, pending_meta)

    def rotate_current_window_if_needed(self, sample_epoch: int) -> None:
        desired_window_start = window_start_for_epoch(sample_epoch, self.config.rotate_interval_sec)
        current_meta = self.current_meta_path()
        if not current_meta.exists():
            self.initialize_current_window(desired_window_start)
            return
        active_window_start = self.read_window_start_from_meta(current_meta)
        if active_window_start != desired_window_start:
            self.seal_current_spool()
            self.initialize_current_window(desired_window_start)
            self.process_pending_spools()

    def build_destination_file(self, window_start_epoch: int) -> Path:
        dt = datetime.fromtimestamp(window_start_epoch)
        output_dir = self.config.raw_sensor_dir / f"dayPK={dt.strftime('%Y%m%d')}" / f"hourPK={dt.strftime('%H')}"
        output_dir.mkdir(parents=True, exist_ok=True)
        destination = output_dir / f"{self.config.hostname}+pidstat+{window_start_epoch}.parquet"
        if destination.exists():
            destination = output_dir / f"{self.config.hostname}+pidstat+{window_start_epoch}-{int(time.time())}-{os.getpid()}.parquet"
        return destination

    def convert_spool_to_parquet(self, spool_path: Path, meta_path: Path) -> bool:
        if not spool_path.exists() or spool_path.stat().st_size == 0:
            return True
        if not self.ensure_meta_for_spool(spool_path, meta_path):
            fail(f"missing meta for {spool_path}")
        window_start_epoch = self.read_window_start_from_meta(meta_path)
        if window_start_epoch is None:
            fail(f"could not read meta for {spool_path}")
        destination = self.build_destination_file(window_start_epoch)
        temp_destination = destination.with_name(destination.name + ".active")
        temp_destination.unlink(missing_ok=True)

        escaped_spool = duckdb_escape_literal(str(spool_path))
        escaped_temp = duckdb_escape_literal(str(temp_destination))
        escaped_compression = duckdb_escape_literal(self.config.parquet_compression)

        sql = f"""
COPY (
    SELECT
        CAST(date_col || ' ' || sample_time AS TIMESTAMP) AS time,
        CAST(uid AS INTEGER) AS uid,
        CAST(pid AS INTEGER) AS pid,
        CAST(usr_percent AS REAL) AS usr_percent,
        CAST(system_percent AS REAL) AS system_percent,
        CAST(guest_percent AS REAL) AS guest_percent,
        CAST(wait_percent AS REAL) AS wait_percent,
        CAST(cpu_percent AS REAL) AS cpu_percent,
        CAST(cpu_core AS INTEGER) AS cpu_core,
        CAST(minflt_per_sec AS REAL) AS minflt_per_sec,
        CAST(majflt_per_sec AS REAL) AS majflt_per_sec,
        CAST(vsz_kb AS BIGINT) AS vsz_kb,
        CAST(rss_kb AS BIGINT) AS rss_kb,
        CAST(mem_percent AS REAL) AS mem_percent,
        CAST(kb_read_per_sec AS REAL) AS kb_read_per_sec,
        CAST(kb_write_per_sec AS REAL) AS kb_write_per_sec,
        CAST(kb_cancelled_write_per_sec AS REAL) AS kb_cancelled_write_per_sec,
        CAST(iodelay_ticks AS INTEGER) AS iodelay_ticks,
        CAST(context_switch_per_sec AS REAL) AS context_switch_per_sec,
        CAST(nonvoluntary_context_switch_per_sec AS REAL) AS nonvoluntary_context_switch_per_sec,
        CAST(command AS VARCHAR) AS command,
        CAST(hostname AS VARCHAR) AS hostname,
        CAST(cgroup_path AS VARCHAR) AS cgroup_path,
        CAST(NULLIF(pid_ns_inode, '') AS BIGINT) AS pid_ns_inode,
        CAST(NULLIF(container_runtime, '') AS VARCHAR) AS container_runtime,
        CAST(NULLIF(container_id, '') AS VARCHAR) AS container_id
    FROM read_csv(
        '{escaped_spool}',
        delim='\t',
        header=false,
        auto_detect=false,
        columns={{
            'date_col': 'VARCHAR',
            'sample_time': 'VARCHAR',
            'uid': 'VARCHAR',
            'pid': 'VARCHAR',
            'usr_percent': 'VARCHAR',
            'system_percent': 'VARCHAR',
            'guest_percent': 'VARCHAR',
            'wait_percent': 'VARCHAR',
            'cpu_percent': 'VARCHAR',
            'cpu_core': 'VARCHAR',
            'minflt_per_sec': 'VARCHAR',
            'majflt_per_sec': 'VARCHAR',
            'vsz_kb': 'VARCHAR',
            'rss_kb': 'VARCHAR',
            'mem_percent': 'VARCHAR',
            'kb_read_per_sec': 'VARCHAR',
            'kb_write_per_sec': 'VARCHAR',
            'kb_cancelled_write_per_sec': 'VARCHAR',
            'iodelay_ticks': 'VARCHAR',
            'context_switch_per_sec': 'VARCHAR',
            'nonvoluntary_context_switch_per_sec': 'VARCHAR',
            'command': 'VARCHAR',
            'hostname': 'VARCHAR',
            'cgroup_path': 'VARCHAR',
            'pid_ns_inode': 'VARCHAR',
            'container_runtime': 'VARCHAR',
            'container_id': 'VARCHAR'
        }}
    )
) TO '{escaped_temp}' (FORMAT PARQUET, COMPRESSION '{escaped_compression}');
"""

        try:
            self.duckdb_connection().execute(sql)
            os.replace(temp_destination, destination)
            spool_path.unlink(missing_ok=True)
            meta_path.unlink(missing_ok=True)
            log(f"wrote {destination}")
            self.enforce_accumulation_guard()
            return True
        except Exception:
            temp_destination.unlink(missing_ok=True)
            log(f"ERROR: parquet conversion failed for {spool_path}\n{traceback.format_exc()}")
            return False

    def process_pending_spools(self) -> None:
        pending_spools = sorted(self.config.spool_dir.glob("pending-*.tsv"))
        for pending_spool in pending_spools:
            pending_meta = self.meta_path_for_spool(pending_spool)
            if not self.convert_spool_to_parquet(pending_spool, pending_meta):
                log(f"WARN: parquet conversion failed for {pending_spool}; leaving spool in place for retry")

    def enforce_accumulation_guard(self) -> None:
        parquet_files = sorted(self.config.raw_sensor_dir.rglob("*.parquet"), key=lambda path: path.stat().st_mtime)
        now = time.time()

        if self.config.max_unshipped_age_sec > 0:
            for parquet_file in list(parquet_files):
                age = now - parquet_file.stat().st_mtime
                if age > self.config.max_unshipped_age_sec:
                    log(f"dropping stale unshipped pidstat parquet {parquet_file}")
                    parquet_file.unlink(missing_ok=True)
            parquet_files = sorted(self.config.raw_sensor_dir.rglob("*.parquet"), key=lambda path: path.stat().st_mtime)

        if self.config.max_unshipped_bytes <= 0:
            return
        total_bytes = sum(path.stat().st_size for path in parquet_files)
        for parquet_file in parquet_files:
            if total_bytes <= self.config.max_unshipped_bytes:
                break
            log(f"dropping unshipped pidstat parquet to respect byte cap {parquet_file}")
            total_bytes -= parquet_file.stat().st_size
            parquet_file.unlink(missing_ok=True)

    def salvage_spool_files(self) -> None:
        current_spool = self.current_spool_path()
        current_meta = self.current_meta_path()
        if current_spool.exists():
            if current_spool.stat().st_size > 0:
                log(f"salvaging leftover active spool {current_spool}")
                if not current_meta.exists() and not self.ensure_meta_for_spool(current_spool, current_meta):
                    fail(f"could not infer meta for {current_spool}")
                self.seal_current_spool()
            else:
                current_spool.unlink(missing_ok=True)
                current_meta.unlink(missing_ok=True)
        self.process_pending_spools()

    def request_stop(self, _signum: int, _frame: object) -> None:
        self.stop_event.set()

    def run_forever(self) -> None:
        signal.signal(signal.SIGINT, self.request_stop)
        signal.signal(signal.SIGTERM, self.request_stop)
        log(
            "starting pidstat-collector.py: "
            f"interval={self.config.interval_sec}s "
            f"rotate={self.config.rotate_interval_sec}s "
            f"min_rotate={self.config.min_rotate_interval_sec}s "
            f"duckdb_threads={self.config.duckdb_threads} "
            f"parquet_root={self.config.parquet_root}"
        )
        try:
            self.salvage_spool_files()

            while not self.stop_event.is_set():
                loop_started = time.time()
                rows = self.sampler.sample(loop_started)
                if rows:
                    self.rotate_current_window_if_needed(int(loop_started))
                    self.append_rows(rows)
                sleep_remaining = self.config.interval_sec - (time.time() - loop_started)
                if sleep_remaining > 0:
                    self.stop_event.wait(sleep_remaining)

            log("received shutdown signal; sealing current pidstat spool")
            self.seal_current_spool()
            self.process_pending_spools()
        finally:
            self.close()


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Collect /proc process metrics into raw_sensor parquet partitions")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    build_arg_parser().parse_args(argv)
    collector = Collector(Config.from_env())
    collector.run_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
