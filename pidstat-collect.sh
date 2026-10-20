#!/bin/bash

# Set output path: first argument, then PIDSTAT_DATA_PATH, then
# PIDSTAT_OUTPUT_PATH, then the runtime-root default.
if [[ -z "${WINTAP_RUNTIME_ROOT:-}" ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then
    WINTAP_RUNTIME_ROOT=/var/log/lintap/runtime
  else
    WINTAP_RUNTIME_ROOT="$HOME/data/lintap/lintap-dev-runtime"
  fi
fi
output_path="${1:-${PIDSTAT_DATA_PATH:-${PIDSTAT_OUTPUT_PATH:-$WINTAP_RUNTIME_ROOT/pidstat}}}"

# Create the output directory if it doesn't exist
mkdir -p "$output_path"

# Generate timestamped filename for the CSV output
output_file="$output_path/pidstat_$(date +%Y%m%d_%H%M%S).csv"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Collecting pidstat data to: $output_file"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Press Ctrl+C to stop collection"

# Run pidstat with continuous monitoring and convert to CSV format
pidstat -u -d -r -w -h 2 | \
  # -u: Report CPU utilization statistics
  # -d: Report I/O statistics (disk reads/writes)
  # -r: Report page faults and memory utilization
  # -w: Report task switching activity (context switches)
  # -h: Print values in human-readable format (compatibility option, usually default)
  # 2:  Sample interval of 2 seconds

  # Remove the header lines
  tail -n +2 | \

  # Remove lines that are just whitespace or dashes (separator lines)
  grep -vE '^(#|$)' | \
  # -v: Invert match (exclude lines matching the pattern)
  # -E: Use extended regex
  # ^#: Match comment lines starting with #
  # ^-: Match separator lines starting with dashes
  
  # Replace multiple spaces/tabs with a single comma to create CSV format
   awk -v OFS='\t' '{$1=$1; print strftime("%Y-%m-%d"), $0}' \
  > "$output_file"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Stopped collecting"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Collected $(wc -l < "$output_file") lines of data"
