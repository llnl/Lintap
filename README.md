<p align="center"><img src="lintap-logo-dev.png" alt="Lintap Logo" width="200" height="200"></p>

# Lintap

Lintap is a proof-of-concept host-based event sensor for Linux that implements Wintap-like functionality for Linux environments. It collects system telemetry data and transforms it into the semantic Wintap data model for analysis.

## Getting Started

Clone the repository to review the project and contribute:

```sh
git clone https://github.com/LLNL/Lintap.git
cd Lintap
```

Lintap now has 2 parallel implementations:

* Lintap (TeleTap-based) is the new version using eBPF for telemetry and tightly coupled with TeleTap, which is the `dotnet core` used by Wintap. This version is still in its infancy as we get the core components running and working together. The code for this version has all been moved into the Wintap repository. There is still some initial code for post-processing data in this repository as we sort things out.

[Running Lintap](teletap/README.md)

For Linux packages, use the canonical [build and test guide](packaging/README.md).
Before starting an installed service, also review the
[paths and configuration guide](packaging/PATHS_AND_CONFIGURATION.md), which
documents the data/runtime split and the `WINTAP_DATA_ROOT` and
`WINTAP_RUNTIME_ROOT` environment variables.

* Lintap (sysdig) is the original and extremely simple implementation built using `sysdig` for telemetry. This implementation will continue to be useful as a very simple, flexible playground for testing ideas and morphing to new challenges and goals very quickly. However, it isn't really intended for larger deployments or long-term collects.

## Running Lintap (sysdig)

The first phase of this project focuses on proving that we can collect the necessary telemetry data and transform it into the Wintap data model. To achieve this quickly and simply, we're following this approach:

### 1. Collect Event-Based Telemetry from eBPF

We're using `sysdig` as our primary data collection tool because it's robust, simple, and extensible with LUA. Sysdig runs continuously, writing TSV files of events for processes, files, and network activity. While it uses a combination of sources, which may or may not include eBPF depending on the sysdig version and OS, it proves the point of getting high-volume, low-level telemetry.

We've also added experimental support for collecting and processing SELinux activity using auditd. SELinux features are optional.

> **Note:** Core sysdig is completely open source and works well for almost any Linux system. While internet searches may lead to their commercial offerings, we're using the open-source version.

### 2. Convert Raw Sysdig Data to Raw Wintap Format

After collection, we convert the raw TSV files to the raw Wintap format. This allows us to leverage the existing, mature Wintap post-processing pipeline for the final ETL stages.

### 3. Run the Wintap ETL Pipeline

The existing pipeline ingests the raw Wintap format data and produces silver and gold final datasets for analysis.

## Prerequisites

- Linux system with root access
- Sufficient disk space for data collection
- `uv` plus any host Python 3.11+ for the managed pidstat collector
- DuckDB for data processing
- `pidstat` from `sysstat` for the managed pidstat collector

## Quick Start

### Managed pidstat collector

`pidstat-collect.sh` remains the simple example collector. For long-running
host monitoring, use `pidstat-collector.py` instead.

The managed collector:

- samples `/proc` every 5 seconds by default, with no steady-state child
  processes
- writes typed parquet under
  `$WINTAP_DATA_ROOT/raw_sensor/pidstat/dayPK=YYYYMMDD/hourPK=HH/`
- rotates on `PIDSTAT_ROTATE_INTERVAL_SEC` (default `300`, matching
  `WINTAP_ETL_UPLOAD_INTERVAL_SEC` when set)
- clamps rotation to `PIDSTAT_MIN_ROTATE_INTERVAL_SEC` (default `300`) to
  avoid frequent DuckDB parquet conversions becoming observable process noise
- uses a persistent DuckDB connection with `PIDSTAT_DUCKDB_THREADS` (default
  `1`) for conversion, reducing short-lived DuckDB worker-thread churn
- keeps the active spool outside `raw_sensor/` so only completed parquet files
  are visible to the uploader sweep
- adds `hostname`, `cgroup_path`, `pid_ns_inode`, `container_runtime`, and
  `container_id` columns to each parquet row
- records `cpu_percent` as **core-summed process CPU percent**: `100` means one
  fully occupied logical CPU and values can exceed `100` on multicore hosts.
  Divide by the host's logical CPU count to compare with host-normalized runtime
  counters such as `.NET System.Runtime cpu-usage`.

Example:

```bash
UV_PROJECT_ENVIRONMENT=/tmp/lintap-venv uv run python ./pidstat-collector.py
```

Useful environment variables:

- `PIDSTAT_INTERVAL_SEC`
- `PIDSTAT_ROTATE_INTERVAL_SEC`
- `PIDSTAT_MIN_ROTATE_INTERVAL_SEC`
- `PIDSTAT_DUCKDB_THREADS`
- `PIDSTAT_MAX_UNSHIPPED_BYTES`
- `PIDSTAT_MAX_UNSHIPPED_AGE_SEC`
- `PIDSTAT_PARQUET_COMPRESSION`
- `PIDSTAT_HOSTNAME`
- `PIDSTAT_VENV_DIR`
- `PIDSTAT_PYTHON`
- `PIDSTAT_BOOTSTRAP_PYTHON`

`PIDSTAT_BOOTSTRAP_PYTHON` defaults to `3.12`, which keeps the venv inside the
collector's supported `3.11 <= python < 3.13` range while still letting `uv`
download or locate the interpreter for you.

For packaged hosts, bootstrap a dedicated collector venv once with `uv`, then
let systemd run from that venv:

```bash
sudo PIDSTAT_VENV_DIR=/opt/lintap/pidstat-collector/.venv bash ./pidstat-collector-bootstrap.sh
sudo systemctl start lintap-pidstat
```

Run the collector tests with `uv` from a native filesystem path for the virtual
environment. On shared mounts such as Multipass, point the venv at `/tmp`:

```bash
UV_PROJECT_ENVIRONMENT=/tmp/lintap-venv uv run --group dev pytest tests/test_pidstat_collector.py
```

### Installing

#### Ubuntu with Multipass

The fastest and easiest way to get up and running is using [Multipass](https://canonical.com/multipass). This method leverages Multipass to install and manage a local Ubuntu VM. We provide a script that will buildout the environment and be ready to use.

[Detailed Instructions](Multipass.md)

#### Sysdig

Source: https://github.com/draios/sysdig
Cheat Sheet: https://www.scribd.com/document/414390974/Linux-Cheatsheet-FINAL-eBOOK-1-pdf

As `sysdig` requires installing and configuring a kernel module, you'll need root privileges.

**Debian/Ubuntu:**
```bash
sudo apt-get update
sudo apt-get install -y sysdig
```

**RHEL/CentOS/Fedora:**
```bash
sudo yum install -y sysdig
```

**Amazon Linux 2023:**
```bash
# Amazon Linux 2023 may require building from source:
git clone https://github.com/draios/sysdig.git
cd sysdig
mkdir build && cd build
cmake ..
make
sudo make install
```

#### Lintap Collection

1. Clone the repository:
   ```bash
   git clone https://github.com/LLNL/Lintap.git
   cd Lintap
   ```

2. Run the full collection script:
   ```bash
   ./full-capture.sh
   ```
   
   By default, files will be written to `./data/lintap`. Some parsing errors may occur, which can be ignored for now.

3. After collecting enough data (a few minutes is usually sufficient), stop the collection with Ctrl+C.

4. Verify that data files are being generated in the output directory.

## Post-processing

### On Each Host

1. Run the merge script to create combined parquet files:
   ```bash
   ./merge_raw_tsv.sh
   ```
   
   This script combines thousands of tiny TSV files into a single parquet file per day. It must be run on the host to capture the hostname correctly.

2. Transfer the parquet files to a central location for processing. The directory layout is designed to allow easy merging in the central location.

### On the Central Host

The current process requires manual execution of DuckDB SQL scripts in the following order:

_Note: Base file path for data files is defined in a macro `dp()` in the rawtostdview.sql file. Confirm that is correct.

1. `rawtostdview.sql` - Process and file events
2. `lintap-pci.sql` - Network events
3. `selinux.sql` - SELinux data
4. `~/git/foraker-support/foraker-everest/ontology/duckdb/everest-lintap-ddl.sql` - Creates Files and All_Files tables for Lintap data

## Data File Layout

The data is organized in the following structure:

```
Data Path/                      # Top level of all data sets
└── Data Set/                   # Data from a specific environment, time frame and configuration
    ├── raw_sensor_tsv/         # Raw sensor data in TSV format
    │   └── daypk=YYYYMMDD/     # Partitioned by day
    │       └── [hostname]+[event type]+[epoch].tsv  # Files written by chisel, rolling based on time
    └── scap/                   # Sysdig capture format
        └── [hostname]-[epoch].scap[n]  # Files written by sysdig, rolling based on size
```

## Troubleshooting

- **Sysdig Installation Issues**: If you encounter problems installing sysdig, check that you have the appropriate kernel headers installed for your distribution.
- **Data Collection Errors**: Some parsing errors are expected and can be ignored. If no data files are being generated, check that sysdig is running correctly with `sysdig -l`.
- **Processing Errors**: Ensure all paths in the SQL scripts are correctly set to point to your data location.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
contribution workflow and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community
standards.

## License

Lintap is distributed under the [MIT License](LICENSE). All new contributions
must be made under the same license. See [NOTICE](NOTICE) for the LLNL auspice
and disclaimer statements.

SPDX-License-Identifier: MIT

## Release

LLNL-CODE-837816

[Multipass.md]: Multipass.md
