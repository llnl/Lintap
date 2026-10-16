# Running Lintap (dotnet version)

## Prerequisites

- Linux system with root access
- Sufficient disk space for data collection
- eBPF Tools
- DotNet 8.0 Core
- Python
- DuckDB for local TeleTap summaries
- Git repos for: Wintap and Lintap

## Ubuntu with Multipass

The fastest and easiest way to get up and running is using [Multipass](https://canonical.com/multipass). This method leverages Multipass to install and manage a local Ubuntu VM. We provide a script that will build out the environment and be ready to use.

* Get multipass itself running: [Multipass](https://canonical.com/multipass)
* Build the Lintap-ready-instance: [Detailed Instructions](../Multipass.md)

### Build Commands

```sh
cd /home/ubuntu/git/wintap/wintap/platform/linux/sensor/ebpf/tracers/
make clean
make all
make test
cd /home/ubuntu/git/wintap/wintap/
dotnet build Lintap.csproj
dotnet run --project Lintap.csproj
```

### Data output

New Lintap/Wintap output should already include canonical raw sensor parquet:

```text
<dataset>/raw_sensor/<event>/dayPK=YYYYMMDD/hourPK=HH/<file>.parquet
<dataset>/raw_sensor/raw_process_conn_incr/dayPK=YYYYMMDD/hourPK=HH/protoPK=tcp|udp/<file>.parquet
```

The old `merged -> raw_sensor` conversion step has been removed. `mergedtoraw.py` is no longer part of the workflow.

### Full ETL with DBT

The canonical full ETL is in `Wintap-PyUtil/wintap_dbt`, not in this TeleTap directory.

Example:

```sh
cd ~/git/Wintap-PyUtil

WINTAP_DBT_DATABASE=/tmp/lintap.duckdb \
DBT_VARS='{dataset: /path/to/parquet, start_day: 20260520, end_day: 20260520}' \
make dbt-build
```

### Local TeleTap sanity check

The TeleTap scripts are a small development scaffold for loading a subset of raw data plus pidstat metrics into DuckDB and visualizing simple counts/resource usage.

#### Gather data

Example shape:

```sh
export WINTAP_DATA_ROOT=~/data/lintap/lintap-dev
export PIDSTAT_DATA_PATH=$WINTAP_DATA_ROOT/pidstat
mkdir -p "$PIDSTAT_DATA_PATH"
cp /home/ubuntu/git/Lintap/mydata.tsv "$PIDSTAT_DATA_PATH/"
# Copy or collect raw_sensor under $WINTAP_DATA_ROOT/raw_sensor
```

`WINTAP_RAW_SENSOR_ROOT` can be set instead of `WINTAP_DATA_ROOT` when raw parquet lives somewhere other than `$WINTAP_DATA_ROOT/raw_sensor`.

#### Load into DuckDB

```sh
cd /home/ubuntu/git/Lintap/teletap
export WINTAP_DATA_ROOT=~/data/lintap/lintap-dev
export PIDSTAT_DATA_PATH=$WINTAP_DATA_ROOT/pidstat
./process-data.sh [sample.db]
```

This runs SQL files to load a small subset of raw data, including `pidstat`, into a local database and displays a simple summary.

#### Visualize

```sh
uv run marimo run grokdata_marimo.py
```

The Marimo notebook locates the database from `TELETAP_DATABASE`, `WINTAP_TELETAP_DATABASE`, `WINTAP_DBT_DATABASE`, or `$WINTAP_DATA_ROOT/duckdb/wintap.duckdb`. The legacy Streamlit app is still available with `streamlit run grokdata.py`.

The app shows simple time-series such as CPU/memory use and Process/File/Network event counts.

#### Dev Tools

VS Code should be able to connect using remote SSH. Open a workspace on the Wintap or Lintap repo.

Note: run the shell as a terminal window from VS Code. There were issues with `code` not being in the path when just SSH'd in.

```sh
cd /home/ubuntu/git/Lintap/teletap
cat vscode-remote-extensions.txt | xargs -n 1 code --install-extension
```

#### Now the real work...

This scaffolding supports ongoing development and debugging of the sensor itself. Use the DBT pipeline in `Wintap-PyUtil` for full post-processing.
