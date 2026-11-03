# DLT ingestion prototypes

These are exploratory alternatives retained from earlier serializer/partitioned
data work. The canonical post-processing pipeline is DBT/DuckDB in
`../Wintap-PyUtil`; these scripts are not wired into collector packaging.

- `load-onhost-lintap.py`: legacy per-serializer directories and optional merged input.
- `load-raw-lintap.py`: Hive-partitioned Parquet loading and filename-based routing.
- `lintap-incremental-patterns.py`: polling, scheduler, watcher and backfill sketches.
- `lintap-incremental-patterns.md`: draft deployment examples; adapt the historical
  user paths and verify the selected pattern before use.

Dependencies are `dlt` with its DuckDB/filesystem support, PyArrow, and optionally
watchdog. They are not pinned or installed by this directory.

Known prototype gaps from source review:

- The hourly pattern calculates a lookback time but does not apply that cutoff;
  it currently relies on DLT's stored modification-date cursor.
- Watcher debounce is not a completed-file/atomic-publication guarantee, and its
  duplicate set is process-local.
- Repeated/backfill loads and separate pipeline cursors need duplicate/accounting
  qualification. Several reports assume `load_packages[0]` exists on an empty run.
- Legacy filename routing and `proto` examples require reconciliation with the
  canonical `raw_sensor` contract (`protoPK` for network partitions).

Commit review checked Python syntax only; no live ingestion, dependency resolution,
scheduled service or destination database was exercised.
