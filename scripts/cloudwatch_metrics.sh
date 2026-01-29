#!/bin/bash

# CloudWatch Metrics Integration Example
# Queries Lambda performance metrics from CloudWatch for analysis
#
# Usage:
#   ./cloudwatch_metrics.sh [function-name] [hours-back]
#
# Examples:
#   ./cloudwatch_metrics.sh rust-bench-arm64-4vcpu-6144mb 1
#   ./cloudwatch_metrics.sh rust-bench-arm64-4vcpu-6144mb 24

set -e

FUNCTION_NAME=${1:-"rust-bench-arm64-4vcpu-6144mb"}
HOURS_BACK=${2:-1}
REGION=${AWS_REGION:-"us-east-1"}

# Calculate time range
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    START_TIME=$(date -u -v-${HOURS_BACK}H +%Y-%m-%dT%H:%M:%SZ)
    END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
else
    # Linux
    START_TIME=$(date -u -d "${HOURS_BACK} hours ago" +%Y-%m-%dT%H:%M:%SZ)
    END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

echo "============================================================"
echo "CloudWatch Metrics for: $FUNCTION_NAME"
echo "============================================================"
echo "Region: $REGION"
echo "Time Range: $START_TIME to $END_TIME"
echo "============================================================"
echo ""

# Function to get metric statistics
get_metric() {
    local metric_name=$1
    local stat=$2
    local unit=$3

    aws cloudwatch get-metric-statistics \
        --namespace AWS/Lambda \
        --metric-name "$metric_name" \
        --dimensions Name=FunctionName,Value="$FUNCTION_NAME" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 300 \
        --statistics "$stat" \
        --region "$REGION" \
        --output json 2>/dev/null
}

echo "Duration Metrics (milliseconds):"
echo "--------------------------------"

# Get Duration statistics
DURATION_AVG=$(get_metric "Duration" "Average")
DURATION_MAX=$(get_metric "Duration" "Maximum")
DURATION_P90=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name "Duration" \
    --dimensions Name=FunctionName,Value="$FUNCTION_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --extended-statistics p90 \
    --region "$REGION" \
    --output json 2>/dev/null)

AVG_VALUE=$(echo "$DURATION_AVG" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Average // "N/A"')
MAX_VALUE=$(echo "$DURATION_MAX" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Maximum // "N/A"')
P90_VALUE=$(echo "$DURATION_P90" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .ExtendedStatistics.p90 // "N/A"')

echo "  Average: ${AVG_VALUE}ms"
echo "  Maximum: ${MAX_VALUE}ms"
echo "  P90: ${P90_VALUE}ms"
echo ""

echo "Invocation Metrics:"
echo "-------------------"

# Get Invocations
INVOCATIONS=$(get_metric "Invocations" "Sum")
ERRORS=$(get_metric "Errors" "Sum")
THROTTLES=$(get_metric "Throttles" "Sum")

INV_VALUE=$(echo "$INVOCATIONS" | jq -r '[.Datapoints[].Sum] | add // 0')
ERR_VALUE=$(echo "$ERRORS" | jq -r '[.Datapoints[].Sum] | add // 0')
THR_VALUE=$(echo "$THROTTLES" | jq -r '[.Datapoints[].Sum] | add // 0')

echo "  Total Invocations: $INV_VALUE"
echo "  Errors: $ERR_VALUE"
echo "  Throttles: $THR_VALUE"
echo ""

echo "Cold Start Metrics:"
echo "-------------------"

# Get Init Duration (cold starts)
INIT_DURATION=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name "InitDuration" \
    --dimensions Name=FunctionName,Value="$FUNCTION_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics Average Maximum SampleCount \
    --region "$REGION" \
    --output json 2>/dev/null)

INIT_AVG=$(echo "$INIT_DURATION" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Average // "N/A"')
INIT_MAX=$(echo "$INIT_DURATION" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Maximum // "N/A"')
INIT_COUNT=$(echo "$INIT_DURATION" | jq -r '[.Datapoints[].SampleCount] | add // 0')

echo "  Cold Starts: $INIT_COUNT"
echo "  Avg Init Duration: ${INIT_AVG}ms"
echo "  Max Init Duration: ${INIT_MAX}ms"
echo ""

echo "Memory Metrics:"
echo "---------------"

# Get Memory utilization
MEMORY=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name "MaxMemoryUsed" \
    --dimensions Name=FunctionName,Value="$FUNCTION_NAME" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --period 300 \
    --statistics Average Maximum \
    --region "$REGION" \
    --output json 2>/dev/null)

MEM_AVG=$(echo "$MEMORY" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Average // "N/A"')
MEM_MAX=$(echo "$MEMORY" | jq -r '.Datapoints | sort_by(.Timestamp) | last | .Maximum // "N/A"')

echo "  Avg Memory Used: ${MEM_AVG}MB"
echo "  Max Memory Used: ${MEM_MAX}MB"
echo ""

echo "============================================================"
echo "Cost Estimation (based on invocations in time range)"
echo "============================================================"

# Get function configuration
FUNC_CONFIG=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --output json 2>/dev/null)

MEMORY_MB=$(echo "$FUNC_CONFIG" | jq -r '.MemorySize')
ARCH=$(echo "$FUNC_CONFIG" | jq -r '.Architectures[0]')

# Calculate cost (simplified)
# ARM64: $0.0000133334 per GB-second
# x86_64: $0.0000166667 per GB-second
# Request cost: $0.20 per 1M requests

if [ "$ARCH" == "arm64" ]; then
    PRICE_PER_GB_SEC="0.0000133334"
    ARCH_LABEL="ARM64 (Graviton2)"
else
    PRICE_PER_GB_SEC="0.0000166667"
    ARCH_LABEL="x86_64"
fi

if [ "$AVG_VALUE" != "N/A" ] && [ "$INV_VALUE" != "0" ]; then
    GB_SECONDS=$(echo "scale=6; $MEMORY_MB / 1024 * $AVG_VALUE / 1000 * $INV_VALUE" | bc)
    COMPUTE_COST=$(echo "scale=6; $GB_SECONDS * $PRICE_PER_GB_SEC" | bc)
    REQUEST_COST=$(echo "scale=6; $INV_VALUE * 0.0000002" | bc)
    TOTAL_COST=$(echo "scale=4; $COMPUTE_COST + $REQUEST_COST" | bc)

    echo "Architecture: $ARCH_LABEL"
    echo "Memory: ${MEMORY_MB}MB"
    echo "Avg Duration: ${AVG_VALUE}ms"
    echo "Invocations: $INV_VALUE"
    echo ""
    echo "GB-Seconds: $GB_SECONDS"
    echo "Compute Cost: \$${COMPUTE_COST}"
    echo "Request Cost: \$${REQUEST_COST}"
    echo "Total Cost: \$${TOTAL_COST}"
else
    echo "Insufficient data for cost estimation"
fi

echo ""
echo "============================================================"
echo "CloudWatch Insights Query (copy to CloudWatch Logs Insights)"
echo "============================================================"
echo ""
cat << 'EOF'
# Query to analyze Lambda performance over time
# Use this in CloudWatch Logs Insights

fields @timestamp, @message, @duration, @billedDuration, @memorySize, @maxMemoryUsed
| filter @type = "REPORT"
| stats
    avg(@duration) as avg_duration,
    max(@duration) as max_duration,
    pct(@duration, 50) as p50,
    pct(@duration, 90) as p90,
    pct(@duration, 95) as p95,
    pct(@duration, 99) as p99,
    avg(@maxMemoryUsed) as avg_memory,
    count(*) as invocations
    by bin(5m)
| sort @timestamp desc
| limit 100
EOF

echo ""
echo "============================================================"
echo "To create a CloudWatch Dashboard, use:"
echo "============================================================"
echo ""
echo "aws cloudwatch put-dashboard \\"
echo "  --dashboard-name 'RustLambdaBenchmark' \\"
echo "  --dashboard-body file://cloudwatch_dashboard.json"
echo ""
