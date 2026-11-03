"""
Load Hive-partitioned LinTap data with automatic partition column extraction
"""
import dlt
from dlt.sources.filesystem import filesystem, read_parquet
from typing import Iterator, Any
from dlt.sources.filesystem import FileItemDict
import pyarrow.parquet as pq
from pathlib import Path


# Base path for partitioned data
RAW_SENSOR_DIR = Path.home() / "data/lintap/lintap-dev/raw_sensor"


def parse_table_name_from_filename(file_url: str) -> str:
    """
    Extract table name from filename.
    Example: lintap-dev+raw_process+134086674273871146.parquet -> raw_process
    """
    # Handle URL encoding (+ becomes %2B in URLs)
    file_url = file_url.replace("%2B", "+")
    filename = file_url.split("/")[-1]
    
    try:
        if "+" in filename:
            parts = filename.split("+")
            if len(parts) >= 2:
                return parts[1]  # e.g., raw_process, raw_file, raw_host_sensor
        return "unknown"
    except Exception as e:
        print(f"Error parsing {filename}: {e}")
        return "unknown"


def extract_partitions_from_path(file_url: str) -> dict:
    """
    Extract partition values from Hive-style path.
    
    Example path:
    .../raw_process/dayPK=20251126/hourPK=21/proto=tcp/file.parquet
    
    Returns: {"dayPK": "20251126", "hourPK": "21", "proto": "tcp"}
    """
    partitions = {}
    parts = file_url.split("/")
    
    for part in parts:
        if "=" in part:
            key, value = part.split("=", 1)
            partitions[key] = value
    
    return partitions


@dlt.transformer(standalone=True)
def read_parquet_with_partitions(items: Iterator[FileItemDict]) -> Iterator[Any]:
    """
    Read parquet files and add:
    1. Partition columns (dayPK, hourPK, proto)
    2. Table routing based on filename
    """
    for file_item in items:
        # Determine table name
        table_name = parse_table_name_from_filename(file_item["file_url"])
        
        # Extract partition values from path
        partitions = extract_partitions_from_path(file_item["file_url"])
        
        print(f"Processing: {file_item['file_name']} -> {table_name}, partitions={partitions}")
        
        # Read parquet file - use read_table() not read_parquet()
        with file_item.open() as f:
            table = pq.read_table(f)
            
            # Convert to list of dicts
            records = table.to_pylist()
            
            # Add partition columns and route to correct table
            for record in records:
                # Add partition columns to each record
                record.update(partitions)
                
                # Route to correct table
                yield dlt.mark.with_table_name(record, table_name)


def load_all_sensors():
    """
    Load all sensor data from partitioned structure.
    Uses glob pattern to recursively find all parquet files.
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap_partitioned",
        destination="duckdb",
        dataset_name="lintap_telemetry",
        export_schema_path="lintap_schemas/export"
    )
    
    # Load all parquet files recursively
    files = (
        filesystem(
            bucket_url=f"file://{RAW_SENSOR_DIR}",
            file_glob="**/*.parquet"  # Recursive search
        )
        | read_parquet_with_partitions()
    )
    
    info = pipeline.run(files)
    
    print("\n" + "="*60)
    print("Partitioned Data Loaded Successfully!")
    print("="*60)
    print(f"Tables created: {list(info.load_packages[0].schema_update.keys())}")
    
    return info


def load_specific_sensor(sensor_name: str):
    """
    Load a specific sensor type (e.g., raw_process, raw_host).
    
    Args:
        sensor_name: Directory name under raw_sensor/ (e.g., "raw_process")
    """
    pipeline = dlt.pipeline(
        pipeline_name=f"lintap_{sensor_name}",
        destination="duckdb",
        dataset_name="lintap_telemetry"
    )
    
    sensor_path = RAW_SENSOR_DIR / sensor_name
    
    files = (
        filesystem(
            bucket_url=f"file://{sensor_path}",
            file_glob="**/*.parquet"
        )
        | read_parquet_with_partitions()
    )
    
    info = pipeline.run(files)
    
    print(f"\n{sensor_name} loaded: {list(info.load_packages[0].schema_update.keys())}")
    return info


def load_by_date_range(start_day: str, end_day: str = None):
    """
    Load data for specific date range using partition filtering.
    
    Args:
        start_day: Start date in format YYYYMMDD (e.g., "20251126")
        end_day: Optional end date, defaults to start_day
    """
    from datetime import datetime, timedelta
    
    if end_day is None:
        end_day = start_day
    
    # Convert to datetime for range generation
    start = datetime.strptime(start_day, "%Y%m%d")
    end = datetime.strptime(end_day, "%Y%m%d")
    
    # Generate list of days
    day_list = []
    current = start
    while current <= end:
        day_list.append(current.strftime("%Y%m%d"))
        current += timedelta(days=1)
    
    pipeline = dlt.pipeline(
        pipeline_name="lintap_date_range",
        destination="duckdb",
        dataset_name="lintap_telemetry"
    )
    
    # Build glob pattern for specific days
    # This loads all sensors for the specified date range
    day_patterns = [f"**/dayPK={day}/**/*.parquet" for day in day_list]
    
    all_sources = []
    for pattern in day_patterns:
        files = (
            filesystem(
                bucket_url=f"file://{RAW_SENSOR_DIR}",
                file_glob=pattern
            )
            | read_parquet_with_partitions()
        )
        all_sources.append(files)
    
    info = pipeline.run(all_sources)
    
    print(f"\nLoaded data for days: {day_list}")
    print(f"Tables: {list(info.load_packages[0].schema_update.keys())}")
    
    return info


def load_incremental_by_date():
    """
    Incremental loading: only load new partitions based on modification date.
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap_incremental",
        destination="duckdb",
        dataset_name="lintap_telemetry"
    )
    
    # Setup filesystem resource with incremental loading
    files = filesystem(
        bucket_url=f"file://{RAW_SENSOR_DIR}",
        file_glob="**/*.parquet"
    )
    
    # Apply incremental hint
    files.apply_hints(incremental=dlt.sources.incremental("modification_date"))
    
    # Pipe through transformer
    parquet_source = files | read_parquet_with_partitions()
    
    info = pipeline.run(parquet_source)
    
    print("\nIncremental load completed!")
    print(f"Only new/modified files were processed")
    
    return info


def inspect_partitioned_data():
    """
    Query the loaded data to see partition columns.
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap_partitioned",
        destination="duckdb",
        dataset_name="lintap_telemetry"
    )
    
    with pipeline.sql_client() as client:
        print("\n" + "="*60)
        print("Partitioned Data Inspection")
        print("="*60)
        
        # List tables
        tables = client.execute_sql(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'lintap_telemetry'"
        )
        
        for table in tables:
            table_name = table[0]
            
            # Get record count
            count = client.execute_sql(f"SELECT COUNT(*) FROM {table_name}")[0][0]
            print(f"\n{table_name}: {count:,} records")
            
            # Show distinct partition values
            try:
                # Check if dayPK column exists
                days = client.execute_sql(
                    f"SELECT DISTINCT dayPK FROM {table_name} ORDER BY dayPK"
                )
                if days:
                    print(f"  Days: {[d[0] for d in days]}")
                
                # Check hours
                hours = client.execute_sql(
                    f"SELECT DISTINCT hourPK FROM {table_name} ORDER BY hourPK"
                )
                if hours:
                    print(f"  Hours: {[h[0] for h in hours]}")
                
                # Check proto if exists
                proto = client.execute_sql(
                    f"SELECT DISTINCT proto FROM {table_name}"
                )
                if proto and proto[0][0]:
                    print(f"  Protocols: {[p[0] for p in proto]}")
                    
            except Exception as e:
                print(f"  (Could not query partitions: {e})")
            
            # Sample record
            sample = client.execute_sql(f"SELECT * FROM {table_name} LIMIT 1")
            if sample:
                print(f"  Sample columns: {len(sample[0])} columns")


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Load partitioned LinTap data")
    parser.add_argument("--mode", 
                       choices=["all", "sensor", "date", "incremental", "inspect"],
                       default="all",
                       help="Loading mode")
    parser.add_argument("--sensor", help="Sensor name (for sensor mode)")
    parser.add_argument("--start-day", help="Start day YYYYMMDD (for date mode)")
    parser.add_argument("--end-day", help="End day YYYYMMDD (for date mode)")
    
    args = parser.parse_args()
    
    if args.mode == "all":
        load_all_sensors()
    elif args.mode == "sensor":
        if not args.sensor:
            print("Error: --sensor required for sensor mode")
        else:
            load_specific_sensor(args.sensor)
    elif args.mode == "date":
        if not args.start_day:
            print("Error: --start-day required for date mode")
        else:
            load_by_date_range(args.start_day, args.end_day)
    elif args.mode == "incremental":
        load_incremental_by_date()
    elif args.mode == "inspect":
        inspect_partitioned_data()