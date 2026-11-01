"""
LinTap DLT Pipeline - Load parquet files into DuckDB/PostgreSQL
"""
import dlt
from pathlib import Path
import pyarrow.parquet as pq
from typing import Iterator, Dict, Any


# Configuration
DATA_DIR = Path.home() / "data/lintap/lintap-dev"
DESTINATION = "duckdb"  # or "postgres", "bigquery", etc.
DATASET_NAME = "lintap_dev"


def load_parquet_files(directory: Path, pattern: str = "*.parquet") -> Iterator[Dict[str, Any]]:
    """
    Generator that yields records from parquet files in a directory.
    
    Args:
        directory: Path to directory containing parquet files
        pattern: Glob pattern for parquet files
    """
    for parquet_file in directory.glob(pattern):
        print(f"Processing: {parquet_file.name}")
        table = pq.read_table(parquet_file)
        
        # Convert to list of dicts for DLT
        for batch in table.to_batches():
            yield from batch.to_pylist()


@dlt.resource(name="raw_process_file", write_disposition="append")
def load_file_events():
    """Load file serializer events"""
    file_dir = DATA_DIR / "fileserializer"
    if file_dir.exists():
        yield from load_parquet_files(file_dir)


@dlt.resource(name="raw_process", write_disposition="append")
def load_process_events():
    """Load process serializer events"""
    process_dir = DATA_DIR / "processserializer"
    if process_dir.exists():
        yield from load_parquet_files(process_dir)


@dlt.resource(name="raw_process_stop", write_disposition="append")
def load_process_stop_events():
    """Load process stop serializer events"""
    stop_dir = DATA_DIR / "processstopserializer"
    if stop_dir.exists():
        yield from load_parquet_files(stop_dir)


@dlt.resource(name="raw_tcp_process_conn_incr", write_disposition="append")
def load_tcp_connection_events():
    """Load TCP connection serializer events"""
    tcp_dir = DATA_DIR / "tcpconnectionserializer"
    if tcp_dir.exists():
        yield from load_parquet_files(tcp_dir)


@dlt.resource(name="raw_udp_process_conn_incr", write_disposition="append")
def load_udp_connection_events():
    """Load UDP connection serializer events"""
    udp_dir = DATA_DIR / "udpconnectionserializer"
    if udp_dir.exists():
        yield from load_parquet_files(udp_dir)


@dlt.resource(name="merged_raw_data", write_disposition="replace")
def load_merged_data():
    """Load pre-merged/aggregated data from merged directory"""
    merged_dir = DATA_DIR / "merged"
    if merged_dir.exists():
        # Group by table type (extracted from filename)
        for parquet_file in merged_dir.glob("*.parquet"):
            # Parse filename: lintap-dev+raw_<table>+<timestamp>.parquet
            parts = parquet_file.stem.split('+')
            if len(parts) >= 2:
#                table_name = parts[1].replace('raw_', '')
                table_name=parts[1]
                
                print(f"Processing merged data: {table_name} from {parquet_file.name}")
                table = pq.read_table(parquet_file)
                
                for batch in table.to_batches():
                    for record in batch.to_pylist():
                        record['_source_file'] = parquet_file.name
                        record['_table_type'] = table_name
                        yield record


@dlt.source
def lintap_telemetry():
    """
    DLT source for LinTap telemetry data.
    Loads from individual serializer directories and merged data.
    """
    return [
        load_file_events(),
        load_process_events(),
        load_process_stop_events(),
        load_tcp_connection_events(),
#        load_merged_data(),
    ]


def run_pipeline(
    destination: str = DESTINATION,
    dataset_name: str = DATASET_NAME,
    full_refresh: bool = False
):
    """
    Run the DLT pipeline to load LinTap telemetry data.
    
    Args:
        destination: DLT destination (duckdb, postgres, bigquery, etc.)
        dataset_name: Name of the dataset/schema to load into
        full_refresh: If True, replace all data. If False, append new data.
    """
    # Create pipeline
    pipeline = dlt.pipeline(
        pipeline_name="lintap",
        destination=destination,
        dataset_name=dataset_name,
    )
    
    # Run the pipeline
    info = pipeline.run(
        lintap_telemetry(),
        write_disposition="replace" if full_refresh else "append"
    )
    
    print("\n" + "="*60)
    print("Pipeline completed successfully!")
    print("="*60)
    print(f"Destination: {destination}")
    print(f"Dataset: {dataset_name}")
    print(f"Loaded packages: {info.loads_ids}")
    print(f"\nTables loaded:")
    for table_name, table_info in info.load_packages[0].schema_update.items():
        print(f"  - {table_name}")
    
    return info


def inspect_data(destination: str = DESTINATION, dataset_name: str = DATASET_NAME):
    """
    Inspect loaded data using DLT's built-in query capabilities.
    """
    pipeline = dlt.pipeline(
        pipeline_name="lintap",
        destination=destination,
        dataset_name=dataset_name,
    )
    
    # Query examples
    with pipeline.sql_client() as client:
        print("\n" + "="*60)
        print("Data Inspection")
        print("="*60)
        
        # List all tables
        tables = client.execute_sql("SELECT table_name FROM information_schema.tables WHERE table_schema = ?", dataset_name)
        print(f"\nTables in {dataset_name}:")
        for table in tables:
            print(f"  - {table[0]}")
        
        # Sample queries
        queries = [
            ("Process Events Count", "SELECT COUNT(*) as count FROM raw_process"),
            ("File Events Count", "SELECT COUNT(*) as count FROM raw_process_file"),
            ("TCP Connection Events Count", "SELECT COUNT(*) as count FROM raw_tcp_process_conn_incr"),
        ]
        
        for desc, query in queries:
            try:
                result = client.execute_sql(query)
                print(f"\n{desc}: {result[0][0] if result else 0}")
            except Exception as e:
                print(f"\n{desc}: Query failed ({e})")


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="LinTap DLT Pipeline")
    parser.add_argument("--destination", default=DESTINATION, help="DLT destination")
    parser.add_argument("--dataset", default=DATASET_NAME, help="Dataset name")
    parser.add_argument("--full-refresh", action="store_true", help="Replace all data")
    parser.add_argument("--inspect", action="store_true", help="Inspect loaded data")
    
    args = parser.parse_args()
    
    if args.inspect:
        inspect_data(args.destination, args.dataset)
    else:
        run_pipeline(args.destination, args.dataset, args.full_refresh)
