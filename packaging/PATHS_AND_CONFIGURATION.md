# Lintap Paths and Configuration

This is the operator reference for choosing where Lintap writes shared sensor
data and host-local runtime state.

## Default layout

The Linux packages set these variables in `/etc/lintap/lintap.env`:

```text
WINTAP_DATA_ROOT=/var/lib/lintap/data
WINTAP_RUNTIME_ROOT=/var/lib/lintap/runtime
```

The data root directly contains the durable sensor dataset:

```text
/var/lib/lintap/data/
└── raw_sensor/
    └── <event>/dayPK=YYYYMMDD/hourPK=HH/...
```

The runtime root contains host-local, disposable, or operational state:

```text
/var/lib/lintap/runtime/
├── esper_staging/       # serializer and merge input parquet
├── Logs/                # Lintap logs
├── event_store/         # local DuckDB/event state
├── pidstat-spool/       # active pidstat spool
├── csv/
├── recordings/
├── diag/
└── ai/
```

Esper staging is never the canonical data source. Finalized sensor parquet is
published under `WINTAP_DATA_ROOT/raw_sensor/`.

## Changing the roots

Edit the package environment file before starting or restarting the services:

```sh
sudoedit /etc/lintap/lintap.env
sudo systemctl daemon-reload
sudo systemctl restart lintap lintap-pidstat
```

Example: put durable data on a mounted shared volume while keeping runtime
state local to the host:

```text
WINTAP_DATA_ROOT=/mnt/wintap-data
WINTAP_RUNTIME_ROOT=/var/lib/lintap/runtime
```

Finalized files then land in `/mnt/wintap-data/raw_sensor/`; they are **not**
written to `/mnt/wintap-data/parquet/raw_sensor/`.

Create and permission the mounted data directory before starting the service.
Ensure it is mounted before the service starts; otherwise the service may write
to the empty mount point.

## Environment-variable behavior

`WINTAP_DATA_ROOT` and `WINTAP_RUNTIME_ROOT` are the supported operator
overrides. The systemd environment file is the recommended persistent setting.
For a one-shot foreground run, set them on the command line:

```sh
sudo env WINTAP_DATA_ROOT=/mnt/wintap-data \
  WINTAP_RUNTIME_ROOT=/var/lib/lintap/runtime /usr/bin/lintap
```

The application resolves each root independently. A configured or programmatic
root takes precedence over a platform default; the package environment file is
the normal deployment-level override. Do not set both roots to the same
directory unless a mixed tree is intentional.

The Linux package defaults are equivalent to the application Linux defaults.
The cross-platform application defaults are:

| Platform | Data root | Runtime root |
|---|---|---|
| Linux | `/var/lib/lintap/data` | `/var/lib/lintap/runtime` |
| Windows | `%ProgramData%\\Wintap\\data` | `%ProgramData%\\Wintap\\runtime` |
| macOS | `/Library/Application Support/Mactap/data` | `/Library/Application Support/Mactap/runtime` |

## Related pidstat variables

The managed pidstat collector follows the same split by default:

- completed parquet: `WINTAP_DATA_ROOT/raw_sensor/pidstat/`
- active spool: `WINTAP_RUNTIME_ROOT/pidstat-spool/`

Use `PIDSTAT_PARQUET_ROOT` or `PIDSTAT_SPOOL_DIR` only when pidstat must be
located independently from the sensor roots.

## Verify an installation

```sh
grep -E '^(WINTAP_DATA_ROOT|WINTAP_RUNTIME_ROOT)=' /etc/lintap/lintap.env
sudo journalctl -u lintap -b --no-pager | grep -E 'Data root|Runtime root|Esper staging path'
sudo find /var/lib/lintap/data /var/lib/lintap/runtime -maxdepth 2 -type d | sort
```

The startup log should report both resolved roots and the Esper staging path.
