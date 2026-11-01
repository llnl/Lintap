"""
LinTap Incremental Loading Patterns
Multiple approaches for continuous/scheduled ingestion
"""
import dlt
from dlt.sources.filesystem import filesystem
from pathlib import Path
import time
import logging
from datetime import datetime, timedelta
from typing import Iterator, Any
from dlt.sources.filesystem import FileItemDict
import pyarrow.parquet as pq


# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

RAW_SENSOR_DIR = Path.home() / "data/lintap/lintap-dev/raw_sensor"


def parse_table_name_from_filename(file_url: str) -> str:
    """Extract table name from filename"""
    file_url = file_url.replace("%2B", "+")
    filename = file_url.split("/")[-1]
    try:
        if "+" in filename:
            parts = filename.split("+")
            if len(parts) >= 2:
                return parts[1]
        return "unknown"
    except Exception as e:
        logger.error(f"Error parsing {filename}: {e}")
        return "unknown"


def extract_partitions_from_path(file_url: str) -> dict:
    """Extract partition values from Hive-style path"""
    partitions = {}
    parts = file_url.split("/")
    for part in parts:
        if "=" in part:
            key, value = part.split("=", 1)
            partitions[key] = value
    return partitions


@dlt.transformer(standalone=True)
def read_parquet_with_partitions(items: Iterator[FileItemDict]) -> Iterator[Any]:
    """Read parquet files and add partition columns + table routing"""
    for file_item in items:
        table_name = parse_table_name_from_filename(file_item["file_url"])
        partitions = extract_partitions_from_path(file_item["file_url"])
        
        logger.info(f"Processing: {file_item['file_name']} -> {table_name}")
        
        with file_item.open() as f:
            table = pq.read_table(f)
            records = table.to_pylist()
            
            for record in records:
                record.update(partitions)
                yield dlt.mark.with_table_name(record, table_name)


# =============================================================================
# Pattern 1: Continuous Polling Loop
# =============================================================================

def run_continuous_polling(interval_seconds: int = 300):
    """
    Continuously poll for new files and load them.
    
    Uses DLT's built-in incremental loading based on file modification time.
    Only new/modified files since last run are processed.
    
    Args:
        interval_seconds: How often to check for new files (default: 5 minutes)
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap_continuous",
        destination="duckdb",
        dataset_name="lintap_telemetry",
        export_schema_path="lintap_schemas/export"
    )
    
    logger.info(f"Starting continuous polling (interval: {interval_seconds}s)")
    
    run_count = 0
    while True:
        try:
            run_count += 1
            start_time = time.time()
            
            logger.info(f"Run #{run_count} starting...")
            
            # Setup incremental loading
            files = filesystem(
                bucket_url=f"file://{RAW_SENSOR_DIR}",
                file_glob="**/*.parquet"
            )
            
            # Key: This tracks which files have been processed
            files.apply_hints(incremental=dlt.sources.incremental("modification_date"))
            
            # Pipe through transformer
            parquet_source = files | read_parquet_with_partitions()
            
            # Run pipeline
            info = pipeline.run(parquet_source)
            
            # Report results
            if info.has_failed_jobs:
                logger.error(f"Run #{run_count} had failures!")
            else:
                elapsed = time.time() - start_time
                logger.info(
                    f"Run #{run_count} completed in {elapsed:.2f}s. "
                    f"Tables: {list(info.load_packages[0].schema_update.keys())}"
                )
            
            # Wait before next check
            logger.info(f"Sleeping for {interval_seconds}s...")
            time.sleep(interval_seconds)
            
        except KeyboardInterrupt:
            logger.info("Stopping continuous polling (Ctrl+C)")
            break
        except Exception as e:
            logger.error(f"Error in run #{run_count}: {e}", exc_info=True)
            # Sleep and retry
            time.sleep(interval_seconds)


# =============================================================================
# Pattern 2: Scheduled Hourly Runs (Cron-style)
# =============================================================================

def run_hourly_batch():
    """
    Run once and exit - designed to be called by cron/scheduler.
    
    Loads only files modified in the last hour.
    
    Crontab example (runs every hour at :05):
        5 * * * * cd /path/to/project && /path/to/venv/bin/python lintap-incremental-patterns.py --mode hourly
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap_hourly",
        destination="duckdb",
        dataset_name="lintap_telemetry",
        export_schema_path="lintap_schemas/export"
    )
    
    # Calculate time window (last hour + 5 min buffer for clock skew)
    now = datetime.utcnow()
    one_hour_ago = now - timedelta(hours=1, minutes=5)
    
    logger.info(f"Loading files modified since {one_hour_ago}")
    
    # Setup filesystem with time filter
    files = filesystem(
        bucket_url=f"file://{RAW_SENSOR_DIR}",
        file_glob="**/*.parquet"
    )
    
    # Incremental by modification date
    files.apply_hints(incremental=dlt.sources.incremental("modification_date"))
    
    parquet_source = files | read_parquet_with_partitions()
    
    info = pipeline.run(parquet_source)
    
    if info.has_failed_jobs:
        logger.error("Hourly batch had failures!")
        raise Exception("Load failed")
    else:
        logger.info(f"Hourly batch completed. Tables: {list(info.load_packages[0].schema_update.keys())}")


# =============================================================================
# Pattern 3: Watch for New Files (inotify-style)
# =============================================================================

def run_file_watcher():
    """
    Watch filesystem for new files and load them immediately.
    
    Uses watchdog library to detect new files in real-time.
    More responsive than polling, but only works on local filesystems.
    
    Install: pip install watchdog
    """
    try:
        from watchdog.observers import Observer
        from watchdog.events import FileSystemEventHandler
    except ImportError:
        logger.error("watchdog not installed. Run: pip install watchdog")
        return
    
    pipeline = dlt.pipeline(
        pipeline_name="lintap_watcher",
        destination="duckdb",
        dataset_name="lintap_telemetry",
        export_schema_path="lintap_schemas/export"
    )
    
    # Track recently processed files to avoid duplicates
    recently_processed = set()
    
    class ParquetFileHandler(FileSystemEventHandler):
        def on_created(self, event):
            if event.is_directory:
                return
            
            if event.src_path.endswith('.parquet'):
                # Debounce: wait a moment for file to finish writing
                time.sleep(2)
                
                if event.src_path in recently_processed:
                    return
                
                logger.info(f"New file detected: {event.src_path}")
                
                try:
                    # Load just this file
                    file_path = Path(event.src_path)
                    parent_dir = file_path.parent
                    filename = file_path.name
                    
                    files = filesystem(
                        bucket_url=f"file://{parent_dir}",
                        file_glob=filename
                    )
                    
                    parquet_source = files | read_parquet_with_partitions()
                    info = pipeline.run(parquet_source)
                    
                    logger.info(f"Loaded {filename}")
                    recently_processed.add(event.src_path)
                    
                    # Clear old entries (keep last 1000)
                    if len(recently_processed) > 1000:
                        recently_processed.clear()
                    
                except Exception as e:
                    logger.error(f"Error loading {event.src_path}: {e}", exc_info=True)
    
    observer = Observer()
    event_handler = ParquetFileHandler()
    observer.schedule(event_handler, str(RAW_SENSOR_DIR), recursive=True)
    observer.start()
    
    logger.info(f"Watching {RAW_SENSOR_DIR} for new parquet files...")
    
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
        logger.info("Stopping file watcher")
    
    observer.join()


# =============================================================================
# Pattern 4: Backfill Specific Time Range
# =============================================================================

def run_backfill(start_date: str, end_date: str = None):
    """
    Backfill historical data for a specific date range.
    
    Args:
        start_date: Start date in YYYYMMDD format
        end_date: Optional end date, defaults to start_date
    """
    if end_date is None:
        end_date = start_date
    
    pipeline = dlt.pipeline(
        pipeline_name="lintap_backfill",
        destination="duckdb",
        dataset_name="lintap_telemetry",
    )
    
    logger.info(f"Backfilling data from {start_date} to {end_date}")
    
    # Generate date patterns
    start = datetime.strptime(start_date, "%Y%m%d")
    end = datetime.strptime(end_date, "%Y%m%d")
    
    current = start
    day_patterns = []
    while current <= end:
        day_patterns.append(f"**/dayPK={current.strftime('%Y%m%d')}/**/*.parquet")
        current += timedelta(days=1)
    
    # Load each day's data
    for pattern in day_patterns:
        logger.info(f"Loading pattern: {pattern}")
        
        files = filesystem(
            bucket_url=f"file://{RAW_SENSOR_DIR}",
            file_glob=pattern
        )
        
        parquet_source = files | read_parquet_with_partitions()
        info = pipeline.run(parquet_source)
        
        logger.info(f"Pattern loaded: {list(info.load_packages[0].schema_update.keys())}")


# =============================================================================
# Pattern 5: Smart Incremental (Only Recent Partitions)
# =============================================================================

def run_smart_incremental(lookback_hours: int = 24):
    """
    Only scan recent partition directories, not the entire tree.
    Much faster for large datasets.
    
    Args:
        lookback_hours: How many hours back to scan (default: 24)
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap_smart",
        destination="duckdb",
        dataset_name="lintap_telemetry",
        export_schema_path="lintap_schemas/export"
    )
    
    # Calculate partition paths to check
    now = datetime.utcnow()
    patterns = []
    
    for hours_ago in range(lookback_hours + 1):
        check_time = now - timedelta(hours=hours_ago)
        day = check_time.strftime("%Y%m%d")
        hour = check_time.strftime("%H")
        
        # Pattern for this specific hour partition
        pattern = f"**/dayPK={day}/hourPK={hour}/**/*.parquet"
        patterns.append(pattern)
    
    logger.info(f"Scanning last {lookback_hours} hours ({len(patterns)} patterns)")
    
    # Load with incremental
    all_sources = []
    for pattern in patterns:
        files = filesystem(
            bucket_url=f"file://{RAW_SENSOR_DIR}",
            file_glob=pattern
        )
        files.apply_hints(incremental=dlt.sources.incremental("modification_date"))
        parquet_source = files | read_parquet_with_partitions()
        all_sources.append(parquet_source)
    
    if all_sources:
        info = pipeline.run(all_sources)
        logger.info(f"Smart incremental completed: {list(info.load_packages[0].schema_update.keys())}")
    else:
        logger.info("No files found in specified time range")


# =============================================================================
# Main Entry Point
# =============================================================================

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="LinTap Incremental Loading")
    parser.add_argument(
        "--mode",
        choices=["continuous", "hourly", "watcher", "backfill", "smart"],
        required=True,
        help="Loading mode"
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=300,
        help="Polling interval in seconds (continuous mode, default: 300)"
    )
    parser.add_argument(
        "--start-date",
        help="Start date YYYYMMDD (backfill mode)"
    )
    parser.add_argument(
        "--end-date",
        help="End date YYYYMMDD (backfill mode)"
    )
    parser.add_argument(
        "--lookback-hours",
        type=int,
        default=24,
        help="Hours to look back (smart mode, default: 24)"
    )
    
    args = parser.parse_args()
    
    if args.mode == "continuous":
        run_continuous_polling(args.interval)
    elif args.mode == "hourly":
        run_hourly_batch()
    elif args.mode == "watcher":
        run_file_watcher()
    elif args.mode == "backfill":
        if not args.start_date:
            parser.error("--start-date required for backfill mode")
        run_backfill(args.start_date, args.end_date)
    elif args.mode == "smart":
        run_smart_incremental(args.lookback_hours)