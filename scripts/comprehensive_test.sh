#!/bin/bash

# Comprehensive test script for all Lambda configurations
# Tests each config 20 times to get statistically valid data with P95/P99 metrics
# Tests both ARM64 and x86_64 architectures
# Includes burst test option for work-stealing demonstration

set -e

# Configuration
NUM_RUNS=${NUM_RUNS:-20}  # Number of warm invocations per config (default: 20)
ITEM_COUNT=${ITEM_COUNT:-20}  # Number of items to process per invocation
SLEEP_BETWEEN=${SLEEP_BETWEEN:-3}  # Sleep seconds between invocations
BURST_MODE=${BURST_MODE:-false}  # Set to 'true' for burst testing (100 items)

# Create results directory if it doesn't exist
mkdir -p test-results

RESULTS_FILE="test-results/comprehensive_$(date +%Y%m%d_%H%M%S).csv"
SUMMARY_FILE="test-results/summary_$(date +%Y%m%d_%H%M%S).txt"

# CSV header with new fields
echo "Architecture,Config,Memory_MB,Workers,Run,Duration_ms,Detected_CPUs,Memory_KB,Avg_ms_per_item" > "$RESULTS_FILE"

echo "============================================================"
echo "COMPREHENSIVE BENCHMARK TEST - ARM64 & x86_64"
echo "============================================================"
echo "Runs per config: $NUM_RUNS"
echo "Items per request: $ITEM_COUNT"
echo "Sleep between requests: ${SLEEP_BETWEEN}s"
echo "Burst mode: $BURST_MODE"
echo "Results file: $RESULTS_FILE"
echo "============================================================"
echo ""

# Test configurations: arch:config_name:function_name:memory:workers
CONFIGS=(
    "arm64:1vcpu-1536mb:rust-bench-arm64-1vcpu-1536mb:1536:1"
    "arm64:2vcpu-2048mb:rust-bench-arm64-2vcpu-2048mb:2048:2"
    "arm64:3vcpu-4096mb:rust-bench-arm64-3vcpu-4096mb:4096:3"
    "arm64:4vcpu-6144mb:rust-bench-arm64-4vcpu-6144mb:6144:4"
    "arm64:5vcpu-8192mb:rust-bench-arm64-5vcpu-8192mb:8192:5"
    "arm64:6vcpu-10240mb:rust-bench-arm64-6vcpu-10240mb:10240:6"
    "x86:1vcpu-1536mb:rust-bench-x86-1vcpu-1536mb:1536:1"
    "x86:2vcpu-2048mb:rust-bench-x86-2vcpu-2048mb:2048:2"
    "x86:3vcpu-4096mb:rust-bench-x86-3vcpu-4096mb:4096:3"
    "x86:4vcpu-6144mb:rust-bench-x86-4vcpu-6144mb:6144:4"
    "x86:5vcpu-8192mb:rust-bench-x86-5vcpu-8192mb:8192:5"
    "x86:6vcpu-10240mb:rust-bench-x86-6vcpu-10240mb:10240:6"
)

# Function to calculate percentile from sorted array
# Usage: percentile "sorted_values" percentile_value
percentile() {
    local sorted_values="$1"
    local p="$2"
    local count=$(echo "$sorted_values" | wc -w | tr -d ' ')

    # Calculate index (1-based)
    local index=$(echo "scale=0; ($count * $p / 100 + 0.5) / 1" | bc)
    [ "$index" -lt 1 ] && index=1
    [ "$index" -gt "$count" ] && index=$count

    echo "$sorted_values" | tr ' ' '\n' | sed -n "${index}p"
}

# Function to sort numbers
sort_numbers() {
    echo "$@" | tr ' ' '\n' | sort -n | tr '\n' ' '
}

for config_line in "${CONFIGS[@]}"; do
    IFS=':' read -r arch config func_name memory workers <<< "$config_line"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Testing: $arch / $config ($memory MB, $workers workers)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Determine payload based on burst mode
    if [ "$BURST_MODE" == "true" ]; then
        PAYLOAD='{"count":100,"mode":"parallel"}'
        echo "  Mode: BURST (100 items - testing work-stealing)"
    else
        PAYLOAD="{\"count\":${ITEM_COUNT},\"mode\":\"parallel\"}"
    fi

    # Cold start (first invocation)
    echo "  Cold start..."
    COLD_RESPONSE=$(aws lambda invoke \
        --function-name "$func_name" \
        --payload "$PAYLOAD" \
        --cli-binary-format raw-in-base64-out \
        /tmp/cold_test.json 2>&1)

    # Check for errors
    if echo "$COLD_RESPONSE" | grep -q "FunctionError"; then
        echo "    ERROR: Function returned error. Check deployment."
        COLD_DURATION="ERROR"
        DETECTED_CPUS="N/A"
        continue
    fi

    COLD_DURATION=$(cat /tmp/cold_test.json | jq -r '.duration_ms // "null"')
    DETECTED_CPUS=$(cat /tmp/cold_test.json | jq -r '.detected_cpus // "null"')
    MEMORY_KB=$(cat /tmp/cold_test.json | jq -r '.memory_used_kb // 0')

    if [ "$COLD_DURATION" == "null" ]; then
        echo "    ERROR: Invalid response from function"
        cat /tmp/cold_test.json
        continue
    fi

    echo "    Cold: ${COLD_DURATION}ms (Memory: ${MEMORY_KB}KB)"

    sleep "$SLEEP_BETWEEN"

    # Warm invocations
    echo "  Running $NUM_RUNS warm invocations..."
    DURATIONS=""
    MEMORY_VALUES=""

    for i in $(seq 1 $NUM_RUNS); do
        aws lambda invoke \
            --function-name "$func_name" \
            --payload "$PAYLOAD" \
            --cli-binary-format raw-in-base64-out \
            /tmp/test_${i}.json >/dev/null 2>&1

        DURATION=$(cat /tmp/test_${i}.json | jq -r '.duration_ms // "null"')
        MEM=$(cat /tmp/test_${i}.json | jq -r '.memory_used_kb // 0')
        AVG_PER_ITEM=$(cat /tmp/test_${i}.json | jq -r '.avg_ms_per_item // 0')

        if [ "$DURATION" == "null" ]; then
            echo "    Run $i: ERROR"
            continue
        fi

        DURATIONS="$DURATIONS $DURATION"
        MEMORY_VALUES="$MEMORY_VALUES $MEM"

        echo "$arch,$config,$memory,$workers,$i,$DURATION,$DETECTED_CPUS,$MEM,$AVG_PER_ITEM" >> "$RESULTS_FILE"

        # Print progress every 5 runs
        if [ $((i % 5)) -eq 0 ]; then
            echo "    Completed $i/$NUM_RUNS runs..."
        fi

        sleep "$SLEEP_BETWEEN"
    done

    # Calculate statistics
    SORTED_DURATIONS=$(sort_numbers $DURATIONS)

    # Basic stats
    SUM=0
    COUNT=0
    MIN=""
    MAX=""

    for dur in $DURATIONS; do
        SUM=$((SUM + dur))
        COUNT=$((COUNT + 1))
        [ -z "$MIN" ] && MIN=$dur
        [ -z "$MAX" ] && MAX=$dur
        [ "$dur" -lt "$MIN" ] && MIN=$dur
        [ "$dur" -gt "$MAX" ] && MAX=$dur
    done

    if [ "$COUNT" -gt 0 ]; then
        AVG=$((SUM / COUNT))
        P50=$(percentile "$SORTED_DURATIONS" 50)
        P90=$(percentile "$SORTED_DURATIONS" 90)
        P95=$(percentile "$SORTED_DURATIONS" 95)
        P99=$(percentile "$SORTED_DURATIONS" 99)

        echo ""
        echo "  Statistics ($COUNT samples):"
        echo "    Avg: ${AVG}ms | Min: ${MIN}ms | Max: ${MAX}ms"
        echo "    P50: ${P50}ms | P90: ${P90}ms | P95: ${P95}ms | P99: ${P99}ms"
    else
        echo "  ERROR: No valid samples collected"
    fi

    echo ""
done

echo "============================================================"
echo "RESULTS SUMMARY"
echo "============================================================" | tee "$SUMMARY_FILE"
echo "" | tee -a "$SUMMARY_FILE"

# Display summary table for ARM64 with percentiles
echo "ARM64 (Graviton2) Results:" | tee -a "$SUMMARY_FILE"
echo "Config          | Workers | Avg (ms) | P50 (ms) | P95 (ms) | P99 (ms) | Min | Max | Speedup" | tee -a "$SUMMARY_FILE"
echo "----------------|---------|----------|----------|----------|----------|-----|-----|--------" | tee -a "$SUMMARY_FILE"

# Get ARM64 baseline (1 vCPU average)
BASELINE_ARM=$(awk -F',' '$1=="arm64" && $2=="1vcpu-1536mb" && $6 != "null" {sum+=$6; count++} END {if(count>0) print int(sum/count); else print 0}' "$RESULTS_FILE")

for config_line in "${CONFIGS[@]}"; do
    IFS=':' read -r arch config func_name memory workers <<< "$config_line"

    if [ "$arch" == "arm64" ]; then
        # Extract all durations for this config
        VALUES=$(awk -F',' -v arch="$arch" -v cfg="$config" '$1==arch && $2==cfg && $6 != "null" {print $6}' "$RESULTS_FILE" | sort -n)
        COUNT=$(echo "$VALUES" | wc -l | tr -d ' ')

        if [ "$COUNT" -gt 0 ] && [ -n "$VALUES" ]; then
            AVG=$(awk -F',' -v arch="$arch" -v cfg="$config" '$1==arch && $2==cfg && $6 != "null" {sum+=$6; count++} END {if(count>0) print int(sum/count); else print "N/A"}' "$RESULTS_FILE")
            MIN=$(echo "$VALUES" | head -1)
            MAX=$(echo "$VALUES" | tail -1)

            # Calculate percentiles
            P50_IDX=$(echo "scale=0; ($COUNT * 50 / 100 + 0.5) / 1" | bc)
            P95_IDX=$(echo "scale=0; ($COUNT * 95 / 100 + 0.5) / 1" | bc)
            P99_IDX=$(echo "scale=0; ($COUNT * 99 / 100 + 0.5) / 1" | bc)
            [ "$P50_IDX" -lt 1 ] && P50_IDX=1
            [ "$P95_IDX" -lt 1 ] && P95_IDX=1
            [ "$P99_IDX" -lt 1 ] && P99_IDX=1
            [ "$P50_IDX" -gt "$COUNT" ] && P50_IDX=$COUNT
            [ "$P95_IDX" -gt "$COUNT" ] && P95_IDX=$COUNT
            [ "$P99_IDX" -gt "$COUNT" ] && P99_IDX=$COUNT

            P50=$(echo "$VALUES" | sed -n "${P50_IDX}p")
            P95=$(echo "$VALUES" | sed -n "${P95_IDX}p")
            P99=$(echo "$VALUES" | sed -n "${P99_IDX}p")

            if [ "$BASELINE_ARM" -gt 0 ] && [ "$AVG" != "N/A" ] && [ "$AVG" -gt 0 ]; then
                SPEEDUP=$(echo "scale=2; $BASELINE_ARM / $AVG" | bc)
            else
                SPEEDUP="N/A"
            fi

            printf "%-15s | %-7s | %-8s | %-8s | %-8s | %-8s | %-3s | %-3s | %sx\n" \
                "$config" "$workers" "$AVG" "$P50" "$P95" "$P99" "$MIN" "$MAX" "$SPEEDUP" | tee -a "$SUMMARY_FILE"
        else
            printf "%-15s | %-7s | %-8s | %-8s | %-8s | %-8s | %-3s | %-3s | %s\n" \
                "$config" "$workers" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" | tee -a "$SUMMARY_FILE"
        fi
    fi
done

echo "" | tee -a "$SUMMARY_FILE"
echo "x86_64 Results:" | tee -a "$SUMMARY_FILE"
echo "Config          | Workers | Avg (ms) | P50 (ms) | P95 (ms) | P99 (ms) | Min | Max | Speedup" | tee -a "$SUMMARY_FILE"
echo "----------------|---------|----------|----------|----------|----------|-----|-----|--------" | tee -a "$SUMMARY_FILE"

# Get x86 baseline (1 vCPU average)
BASELINE_X86=$(awk -F',' '$1=="x86" && $2=="1vcpu-1536mb" && $6 != "null" {sum+=$6; count++} END {if(count>0) print int(sum/count); else print 0}' "$RESULTS_FILE")

for config_line in "${CONFIGS[@]}"; do
    IFS=':' read -r arch config func_name memory workers <<< "$config_line"

    if [ "$arch" == "x86" ]; then
        VALUES=$(awk -F',' -v arch="$arch" -v cfg="$config" '$1==arch && $2==cfg && $6 != "null" {print $6}' "$RESULTS_FILE" | sort -n)
        COUNT=$(echo "$VALUES" | wc -l | tr -d ' ')

        if [ "$COUNT" -gt 0 ] && [ -n "$VALUES" ]; then
            AVG=$(awk -F',' -v arch="$arch" -v cfg="$config" '$1==arch && $2==cfg && $6 != "null" {sum+=$6; count++} END {if(count>0) print int(sum/count); else print "N/A"}' "$RESULTS_FILE")
            MIN=$(echo "$VALUES" | head -1)
            MAX=$(echo "$VALUES" | tail -1)

            P50_IDX=$(echo "scale=0; ($COUNT * 50 / 100 + 0.5) / 1" | bc)
            P95_IDX=$(echo "scale=0; ($COUNT * 95 / 100 + 0.5) / 1" | bc)
            P99_IDX=$(echo "scale=0; ($COUNT * 99 / 100 + 0.5) / 1" | bc)
            [ "$P50_IDX" -lt 1 ] && P50_IDX=1
            [ "$P95_IDX" -lt 1 ] && P95_IDX=1
            [ "$P99_IDX" -lt 1 ] && P99_IDX=1
            [ "$P50_IDX" -gt "$COUNT" ] && P50_IDX=$COUNT
            [ "$P95_IDX" -gt "$COUNT" ] && P95_IDX=$COUNT
            [ "$P99_IDX" -gt "$COUNT" ] && P99_IDX=$COUNT

            P50=$(echo "$VALUES" | sed -n "${P50_IDX}p")
            P95=$(echo "$VALUES" | sed -n "${P95_IDX}p")
            P99=$(echo "$VALUES" | sed -n "${P99_IDX}p")

            if [ "$BASELINE_X86" -gt 0 ] && [ "$AVG" != "N/A" ] && [ "$AVG" -gt 0 ]; then
                SPEEDUP=$(echo "scale=2; $BASELINE_X86 / $AVG" | bc)
            else
                SPEEDUP="N/A"
            fi

            printf "%-15s | %-7s | %-8s | %-8s | %-8s | %-8s | %-3s | %-3s | %sx\n" \
                "$config" "$workers" "$AVG" "$P50" "$P95" "$P99" "$MIN" "$MAX" "$SPEEDUP" | tee -a "$SUMMARY_FILE"
        else
            printf "%-15s | %-7s | %-8s | %-8s | %-8s | %-8s | %-3s | %-3s | %s\n" \
                "$config" "$workers" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" | tee -a "$SUMMARY_FILE"
        fi
    fi
done

echo "" | tee -a "$SUMMARY_FILE"
echo "Architecture Comparison (ARM64 vs x86_64):" | tee -a "$SUMMARY_FILE"
echo "Config          | ARM64 Avg | x86 Avg | Diff % | Faster Arch" | tee -a "$SUMMARY_FILE"
echo "----------------|-----------|---------|--------|------------" | tee -a "$SUMMARY_FILE"

for config_line in "${CONFIGS[@]}"; do
    IFS=':' read -r arch config func_name memory workers <<< "$config_line"

    if [ "$arch" == "arm64" ]; then
        AVG_ARM=$(awk -F',' -v cfg="$config" '$1=="arm64" && $2==cfg && $6 != "null" {sum+=$6; count++} END {if(count>0) print int(sum/count); else print 0}' "$RESULTS_FILE")
        AVG_X86=$(awk -F',' -v cfg="$config" '$1=="x86" && $2==cfg && $6 != "null" {sum+=$6; count++} END {if(count>0) print int(sum/count); else print 0}' "$RESULTS_FILE")

        if [ "$AVG_ARM" -gt 0 ] && [ "$AVG_X86" -gt 0 ]; then
            DIFF=$(echo "scale=1; (($AVG_X86 - $AVG_ARM) * 100 / $AVG_X86)" | bc)
            if [ "$AVG_ARM" -lt "$AVG_X86" ]; then
                FASTER="ARM64"
            elif [ "$AVG_ARM" -gt "$AVG_X86" ]; then
                FASTER="x86_64"
            else
                FASTER="Same"
            fi
            printf "%-15s | %-9s | %-7s | %-6s%% | %s\n" \
                "$config" "${AVG_ARM}ms" "${AVG_X86}ms" "$DIFF" "$FASTER" | tee -a "$SUMMARY_FILE"
        else
            printf "%-15s | %-9s | %-7s | %-6s | %s\n" \
                "$config" "N/A" "N/A" "N/A" "N/A" | tee -a "$SUMMARY_FILE"
        fi
    fi
done

echo "" | tee -a "$SUMMARY_FILE"
echo "Memory Usage Summary:" | tee -a "$SUMMARY_FILE"
echo "Config          | Arch   | Avg Memory (KB)" | tee -a "$SUMMARY_FILE"
echo "----------------|--------|----------------" | tee -a "$SUMMARY_FILE"

for config_line in "${CONFIGS[@]}"; do
    IFS=':' read -r arch config func_name memory workers <<< "$config_line"
    AVG_MEM=$(awk -F',' -v arch="$arch" -v cfg="$config" '$1==arch && $2==cfg && $8 > 0 {sum+=$8; count++} END {if(count>0) print int(sum/count); else print "N/A"}' "$RESULTS_FILE")
    printf "%-15s | %-6s | %s\n" "$config" "$arch" "$AVG_MEM" | tee -a "$SUMMARY_FILE"
done

echo ""
echo "============================================================"
echo "Detailed results saved to: $RESULTS_FILE"
echo "Summary saved to: $SUMMARY_FILE"
echo "============================================================"
echo ""
echo "Benchmark complete!"
