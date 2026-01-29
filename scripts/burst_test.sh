#!/bin/bash

# Burst Test Script - Demonstrates Rayon's Work-Stealing Capabilities
#
# This script tests how well the parallel processing scales with larger workloads.
# Rayon's work-stealing scheduler dynamically balances work across threads,
# which is especially visible with larger, variable-duration tasks.
#
# Usage:
#   ./burst_test.sh [function-name] [item-count]
#
# Examples:
#   ./burst_test.sh rust-bench-arm64-6vcpu-10240mb 100
#   ./burst_test.sh rust-bench-arm64-4vcpu-6144mb 200

set -e

FUNCTION_NAME=${1:-"rust-bench-arm64-6vcpu-10240mb"}
ITEM_COUNT=${2:-100}
NUM_RUNS=${NUM_RUNS:-10}

echo "============================================================"
echo "BURST TEST - Work-Stealing Demonstration"
echo "============================================================"
echo "Function: $FUNCTION_NAME"
echo "Items per request: $ITEM_COUNT"
echo "Number of runs: $NUM_RUNS"
echo "============================================================"
echo ""

# Get function config
FUNC_CONFIG=$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" 2>/dev/null || echo "{}")
MEMORY=$(echo "$FUNC_CONFIG" | jq -r '.MemorySize // "N/A"')
ARCH=$(echo "$FUNC_CONFIG" | jq -r '.Architectures[0] // "N/A"')

echo "Memory: ${MEMORY}MB | Architecture: $ARCH"
echo ""

# Warm up
echo "Warming up Lambda container..."
aws lambda invoke \
    --function-name "$FUNCTION_NAME" \
    --payload '{"count":10,"mode":"parallel"}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/warmup.json >/dev/null 2>&1

sleep 2

# Test parallel processing
echo ""
echo "Testing PARALLEL mode with $ITEM_COUNT items..."
echo "-------------------------------------------"

PARALLEL_DURATIONS=""
for i in $(seq 1 $NUM_RUNS); do
    RESULT=$(aws lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload "{\"count\":${ITEM_COUNT},\"mode\":\"parallel\"}" \
        --cli-binary-format raw-in-base64-out \
        /tmp/burst_parallel_${i}.json 2>&1)

    DURATION=$(cat /tmp/burst_parallel_${i}.json | jq -r '.duration_ms')
    WORKERS=$(cat /tmp/burst_parallel_${i}.json | jq -r '.workers')
    AVG_PER_ITEM=$(cat /tmp/burst_parallel_${i}.json | jq -r '.avg_ms_per_item')
    MEMORY_KB=$(cat /tmp/burst_parallel_${i}.json | jq -r '.memory_used_kb // 0')

    PARALLEL_DURATIONS="$PARALLEL_DURATIONS $DURATION"
    echo "  Run $i: ${DURATION}ms total, ${AVG_PER_ITEM}ms/item, ${WORKERS} workers, ${MEMORY_KB}KB memory"

    sleep 2
done

# Test sequential processing for comparison
echo ""
echo "Testing SEQUENTIAL mode with $ITEM_COUNT items..."
echo "---------------------------------------------"

SEQUENTIAL_DURATIONS=""
for i in $(seq 1 $NUM_RUNS); do
    RESULT=$(aws lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload "{\"count\":${ITEM_COUNT},\"mode\":\"sequential\"}" \
        --cli-binary-format raw-in-base64-out \
        /tmp/burst_sequential_${i}.json 2>&1)

    DURATION=$(cat /tmp/burst_sequential_${i}.json | jq -r '.duration_ms')
    AVG_PER_ITEM=$(cat /tmp/burst_sequential_${i}.json | jq -r '.avg_ms_per_item')

    SEQUENTIAL_DURATIONS="$SEQUENTIAL_DURATIONS $DURATION"
    echo "  Run $i: ${DURATION}ms total, ${AVG_PER_ITEM}ms/item"

    sleep 2
done

# Calculate statistics
echo ""
echo "============================================================"
echo "RESULTS SUMMARY"
echo "============================================================"
echo ""

# Parallel stats
PAR_SUM=0
PAR_MIN=""
PAR_MAX=""
PAR_COUNT=0

for d in $PARALLEL_DURATIONS; do
    PAR_SUM=$((PAR_SUM + d))
    PAR_COUNT=$((PAR_COUNT + 1))
    [ -z "$PAR_MIN" ] && PAR_MIN=$d
    [ -z "$PAR_MAX" ] && PAR_MAX=$d
    [ "$d" -lt "$PAR_MIN" ] && PAR_MIN=$d
    [ "$d" -gt "$PAR_MAX" ] && PAR_MAX=$d
done
PAR_AVG=$((PAR_SUM / PAR_COUNT))

# Sequential stats
SEQ_SUM=0
SEQ_MIN=""
SEQ_MAX=""
SEQ_COUNT=0

for d in $SEQUENTIAL_DURATIONS; do
    SEQ_SUM=$((SEQ_SUM + d))
    SEQ_COUNT=$((SEQ_COUNT + 1))
    [ -z "$SEQ_MIN" ] && SEQ_MIN=$d
    [ -z "$SEQ_MAX" ] && SEQ_MAX=$d
    [ "$d" -lt "$SEQ_MIN" ] && SEQ_MIN=$d
    [ "$d" -gt "$SEQ_MAX" ] && SEQ_MAX=$d
done
SEQ_AVG=$((SEQ_SUM / SEQ_COUNT))

echo "PARALLEL Processing ($ITEM_COUNT items):"
echo "  Average: ${PAR_AVG}ms"
echo "  Min: ${PAR_MIN}ms"
echo "  Max: ${PAR_MAX}ms"
echo "  Avg per item: $(echo "scale=2; $PAR_AVG / $ITEM_COUNT" | bc)ms"
echo ""

echo "SEQUENTIAL Processing ($ITEM_COUNT items):"
echo "  Average: ${SEQ_AVG}ms"
echo "  Min: ${SEQ_MIN}ms"
echo "  Max: ${SEQ_MAX}ms"
echo "  Avg per item: $(echo "scale=2; $SEQ_AVG / $ITEM_COUNT" | bc)ms"
echo ""

# Calculate speedup
SPEEDUP=$(echo "scale=2; $SEQ_AVG / $PAR_AVG" | bc)
EFFICIENCY=$(echo "scale=1; $SPEEDUP * 100 / $WORKERS" | bc)

echo "============================================================"
echo "PARALLEL PROCESSING EFFICIENCY"
echo "============================================================"
echo ""
echo "Speedup: ${SPEEDUP}x faster than sequential"
echo "Workers: $WORKERS"
echo "Efficiency: ${EFFICIENCY}% (speedup / workers * 100)"
echo ""

if (( $(echo "$SPEEDUP > $WORKERS * 0.8" | bc -l) )); then
    echo "Assessment: EXCELLENT - Near-linear scaling achieved!"
    echo "Rayon's work-stealing is effectively distributing work."
elif (( $(echo "$SPEEDUP > $WORKERS * 0.6" | bc -l) )); then
    echo "Assessment: GOOD - Reasonable parallel efficiency."
    echo "Some overhead from thread coordination."
else
    echo "Assessment: MODERATE - Below expected efficiency."
    echo "Consider checking workload characteristics."
fi

echo ""
echo "============================================================"
echo "THEORETICAL vs ACTUAL"
echo "============================================================"
echo ""
echo "If perfect linear scaling:"
echo "  Expected parallel time: $(echo "scale=0; $SEQ_AVG / $WORKERS" | bc)ms"
echo "  Actual parallel time: ${PAR_AVG}ms"
echo "  Overhead: $(echo "scale=0; $PAR_AVG - ($SEQ_AVG / $WORKERS)" | bc)ms"
echo ""

# Cost comparison
echo "============================================================"
echo "COST COMPARISON (per 1M invocations)"
echo "============================================================"
echo ""

if [ "$ARCH" == "arm64" ]; then
    PRICE="0.0000133334"
else
    PRICE="0.0000166667"
fi

# Sequential cost (would need lower memory config realistically, but for comparison)
SEQ_COST=$(echo "scale=2; ($MEMORY / 1024) * ($SEQ_AVG / 1000) * $PRICE * 1000000" | bc)
PAR_COST=$(echo "scale=2; ($MEMORY / 1024) * ($PAR_AVG / 1000) * $PRICE * 1000000" | bc)

echo "Sequential at ${MEMORY}MB: \$${SEQ_COST}"
echo "Parallel at ${MEMORY}MB: \$${PAR_COST}"
echo ""
echo "Note: Sequential would typically use lower memory allocation,"
echo "so actual cost comparison depends on your specific requirements."
echo ""
