# LinTap Incremental Loading - Deployment Guide

**Historical prototype guide:** the production recommendations below were not
validated. See [README.md](README.md) for current status and known gaps; examples
contain historical machine-specific paths. Canonical analytics uses Wintap-PyUtil DBT.

## Overview of Patterns

| Pattern | Use Case | Pros | Cons |
|---------|----------|------|------|
| **Continuous Polling** | Development, small-scale | Simple, reliable | CPU overhead from constant polling |
| **Hourly Cron** | Production batch jobs | Standard, resource-efficient | Less real-time |
| **File Watcher** | Real-time ingestion | Instant response | Local filesystem only |
| **Smart Incremental** | Large historical datasets | Fast, efficient | Requires partition structure |
| **Backfill** | Historical data loads | One-time catch-up | Not for continuous use |

---

## 1. Continuous Polling (Development/Testing)

### Usage
```bash
# Poll every 5 minutes (300 seconds)
python lintap-incremental-patterns.py --mode continuous --interval 300

# Poll every 10 minutes
python lintap-incremental-patterns.py --mode continuous --interval 600
```

### Run as Background Process
```bash
# Using nohup
nohup python lintap-incremental-patterns.py --mode continuous --interval 300 > lintap-continuous.log 2>&1 &

# Check it's running
ps aux | grep lintap-incremental

# Stop it
pkill -f lintap-incremental-patterns.py
```

### Run as systemd Service (Linux)

Create `/etc/systemd/system/lintap-continuous.service`:

```ini
[Unit]
Description=LinTap Continuous Data Ingestion
After=network.target

[Service]
Type=simple
User=johnson30
WorkingDirectory=/Users/johnson30/hbd2025/git/Lintap/dlt
Environment="PATH=/Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin"
ExecStart=/Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin/python lintap-incremental-patterns.py --mode continuous --interval 300
Restart=always
RestartSec=10
StandardOutput=append:/var/log/lintap-continuous.log
StandardError=append:/var/log/lintap-continuous.log

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable lintap-continuous
sudo systemctl start lintap-continuous

# Check status
sudo systemctl status lintap-continuous

# View logs
sudo journalctl -u lintap-continuous -f
```

---

## 2. Scheduled Hourly Runs (Production Recommended)

### Using Cron

Edit crontab:
```bash
crontab -e
```

Add this line (runs at :05 past every hour):
```cron
5 * * * * cd /Users/johnson30/hbd2025/git/Lintap/dlt && /Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin/python lintap-incremental-patterns.py --mode hourly >> /var/log/lintap-hourly.log 2>&1
```

### Other Cron Schedules

```cron
# Every 15 minutes
*/15 * * * * cd ... && python ... --mode smart --lookback-hours 1

# Every 30 minutes
*/30 * * * * cd ... && python ... --mode smart --lookback-hours 2

# Twice per hour (at :00 and :30)
0,30 * * * * cd ... && python ... --mode hourly

# Every 4 hours
0 */4 * * * cd ... && python ... --mode smart --lookback-hours 5

# Once per day at 2 AM
0 2 * * * cd ... && python ... --mode smart --lookback-hours 24
```

### Using systemd Timer (Better than Cron)

Create `/etc/systemd/system/lintap-hourly.service`:
```ini
[Unit]
Description=LinTap Hourly Data Load

[Service]
Type=oneshot
User=johnson30
WorkingDirectory=/Users/johnson30/hbd2025/git/Lintap/dlt
Environment="PATH=/Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin"
ExecStart=/Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin/python lintap-incremental-patterns.py --mode hourly
StandardOutput=append:/var/log/lintap-hourly.log
StandardError=append:/var/log/lintap-hourly.log
```

Create `/etc/systemd/system/lintap-hourly.timer`:
```ini
[Unit]
Description=Run LinTap Hourly Load

[Timer]
OnCalendar=hourly
OnCalendar=*:05:00
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable lintap-hourly.timer
sudo systemctl start lintap-hourly.timer

# Check timer status
sudo systemctl list-timers lintap-hourly.timer

# Manually trigger now (for testing)
sudo systemctl start lintap-hourly.service
```

---

## 3. File Watcher (Real-time, Local Only)

### Install watchdog
```bash
pip install watchdog
```

### Run as systemd Service

Create `/etc/systemd/system/lintap-watcher.service`:
```ini
[Unit]
Description=LinTap File Watcher (Real-time Ingestion)
After=network.target

[Service]
Type=simple
User=johnson30
WorkingDirectory=/Users/johnson30/hbd2025/git/Lintap/dlt
Environment="PATH=/Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin"
ExecStart=/Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin/python lintap-incremental-patterns.py --mode watcher
Restart=always
RestartSec=10
StandardOutput=append:/var/log/lintap-watcher.log
StandardError=append:/var/log/lintap-watcher.log

[Install]
WantedBy=multi-user.target
```

Start it:
```bash
sudo systemctl enable lintap-watcher
sudo systemctl start lintap-watcher
```

---

## 4. Smart Incremental (Efficient for Large Datasets)

### Usage
```bash
# Load last 24 hours only
python lintap-incremental-patterns.py --mode smart --lookback-hours 24

# Load last 2 hours (for frequent runs)
python lintap-incremental-patterns.py --mode smart --lookback-hours 2

# Load last week
python lintap-incremental-patterns.py --mode smart --lookback-hours 168
```

### Recommended Cron Schedule
```cron
# Run every hour, scan last 2 hours
0 * * * * cd /Users/johnson30/hbd2025/git/Lintap/dlt && /Users/johnson30/apps/miniconda3/envs/lintap-dlt/bin/python lintap-incremental-patterns.py --mode smart --lookback-hours 2 >> /var/log/lintap-smart.log 2>&1
```

---

## 5. Backfill Historical Data

### One-time Backfill
```bash
# Backfill single day
python lintap-incremental-patterns.py --mode backfill --start-date 20251126

# Backfill date range
python lintap-incremental-patterns.py --mode backfill --start-date 20251120 --end-date 20251126

# Backfill last 30 days
python lintap-incremental-patterns.py --mode backfill --start-date 20251101 --end-date 20251130
```

---

## Monitoring & Alerting

### Check DLT State
```python
import dlt

pipeline = dlt.pipeline(
    pipeline_name="lintap_continuous",
    destination="duckdb",
    dataset_name="lintap_telemetry"
)

# Check last run
with pipeline.sql_client() as client:
    last_load = client.execute_sql(
        "SELECT load_id, status, inserted_at FROM _dlt_loads "
        "ORDER BY inserted_at DESC LIMIT 1"
    )
    print(last_load)
```

### Log Monitoring
```bash
# Tail logs in real-time
tail -f /var/log/lintap-continuous.log

# Check for errors
grep ERROR /var/log/lintap-continuous.log

# Count successful runs today
grep "completed" /var/log/lintap-continuous.log | grep $(date +%Y-%m-%d) | wc -l
```

### Slack Notifications (Add to scripts)
```python
import requests

def notify_slack(message: str):
    webhook_url = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
    requests.post(webhook_url, json={"text": message})

# In your pipeline code
try:
    info = pipeline.run(parquet_source)
    notify_slack(f"✅ LinTap load successful: {len(info.load_packages[0].schema_update)} tables")
except Exception as e:
    notify_slack(f"❌ LinTap load failed: {str(e)}")
    raise
```

---

## Recommendations by Use Case

### Development/Testing
**Use:** Continuous polling with 5-10 minute intervals
```bash
python lintap-incremental-patterns.py --mode continuous --interval 300
```

### Production - Low Latency Required (< 1 minute)
**Use:** File watcher
```bash
# Run as systemd service
sudo systemctl start lintap-watcher
```

### Production - Standard Batch (Hourly)
**Use:** Cron with smart incremental
```cron
0 * * * * cd /path && python ... --mode smart --lookback-hours 2
```

### Production - High Volume
**Use:** Multiple parallel pipelines
```bash
# Separate pipeline per sensor type
0 * * * * ... --mode sensor --sensor raw_process
5 * * * * ... --mode sensor --sensor raw_file
10 * * * * ... --mode sensor --sensor raw_host
```

### Catch-up After Downtime
**Use:** Backfill
```bash
python lintap-incremental-patterns.py --mode backfill --start-date 20251120 --end-date 20251126
```

---

## Best Practices

1. **Always use incremental loading** - DLT tracks state automatically
2. **Set up monitoring** - Check `_dlt_loads` table for failures
3. **Use systemd over cron** - Better logging and restart handling
4. **Separate pipelines for large datasets** - One per sensor type
5. **Keep lookback windows reasonable** - 2-24 hours for smart mode
6. **Test with `--mode hourly` first** - Before setting up continuous services
7. **Export schemas** - Use `export_schema_path` to track changes
8. **Monitor disk space** - DuckDB files grow over time
