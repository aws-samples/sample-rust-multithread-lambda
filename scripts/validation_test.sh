#!/bin/bash

# =================================================================
# BLOG POST VALIDATION TEST
# Tests all configurations to validate the claims in the blog post
# =================================================================

set -e

echo "================================================================"
echo "BLOG POST VALIDATION TEST"
echo "Validating multi-threaded Rust Lambda performance claims"
echo "================================================================"
echo ""
echo "Test workload: 20 bcrypt hashes (cost factor 10)"
echo ""

RESULTS_DIR="../test-results"
mkdir -p $RESULTS_DIR
RESULTS_FILE="$RESULTS_DIR/validation_$(date +%Y%m%d_%H%M%S).csv"
echo "Config,Arch,Memory_MB,Workers,Cold_Init_ms,Cold_Proc_ms,Warm1_ms,Warm2_ms,Warm3_ms,Detected_CPUs,Avg_Warm_ms" > $RESULTS_FILE

# Function to test a single configuration
test_config() {
    local arch=$1
    local memory=$2
    local workers=$3
    local func_name="rust-validation-${arch}-${memory}"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Testing: ${arch} / ${memory}MB / ${workers} workers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Deploy with specific configuration
    echo "→ Deploying function..."
    cargo lambda deploy $func_name \
        --binary-name rust-multithread-lambda \
        --memory $memory \
        --timeout 120 \
        --env-vars WORKER_COUNT=${workers},RUST_LOG=info \
        2>&1 | grep -E "(deployed|error)" || true
    
    # Wait for deployment to stabilize
    echo "→ Waiting for deployment to stabilize..."
    sleep 8
    
    # COLD START TEST (first invocation after deploy)
    echo "→ Testing COLD start..."
    COLD_RESP=$(aws lambda invoke \
        --function-name $func_name \
        --payload '{"count":20,"mode":"parallel"}' \
        --cli-binary-format raw-in-base64-out \
        --log-type Tail \
        /tmp/cold_response.json 2>/dev/null)
    
    COLD_PROC=$(cat /tmp/cold_response.json | jq -r '.duration_ms' 2>/dev/null)
    DETECTED_CPUS=$(cat /tmp/cold_response.json | jq -r '.detected_cpus' 2>/dev/null)
    
    # Extract init duration from logs
    LOG_RESULT=$(echo "$COLD_RESP" | jq -r '.LogResult' 2>/dev/null)
    if [ ! -z "$LOG_RESULT" ] && [ "$LOG_RESULT" != "null" ]; then
        COLD_INIT=$(echo "$LOG_RESULT" | base64 -d 2>/dev/null | grep -oE "Init Duration: [0-9.]+" | grep -oE "[0-9.]+")
    else
        COLD_INIT="N/A"
    fi
    
    echo "  ❄️  Cold Init: ${COLD_INIT:-N/A}ms"
    echo "  ❄️  Cold Processing: ${COLD_PROC}ms"
    echo "  📊 Detected CPUs: ${DETECTED_CPUS}"
    
    # WARM TESTS (3 invocations)
    echo "→ Testing WARM executions..."
    WARM_RESULTS=()
    for i in 1 2 3; do
        sleep 2
        aws lambda invoke \
            --function-name $func_name \
            --payload '{"count":20,"mode":"parallel"}' \
            --cli-binary-format raw-in-base64-out \
            /tmp/warm_response_${i}.json >/dev/null 2>&1
        
        WARM_TIME=$(cat /tmp/warm_response_${i}.json | jq -r '.duration_ms' 2>/dev/null)
        WARM_RESULTS+=("$WARM_TIME")
        echo "  🔥 Warm #${i}: ${WARM_TIME}ms"
    done
    
    # Calculate average
    AVG_WARM=$(echo "scale=2; (${WARM_RESULTS[0]} + ${WARM_RESULTS[1]} + ${WARM_RESULTS[2]}) / 3" | bc)
    echo "  📈 Avg Warm: ${AVG_WARM}ms"
    
    # Save results
    echo "${func_name},${arch},${memory},${workers},${COLD_INIT:-N/A},${COLD_PROC},${WARM_RESULTS[0]},${WARM_RESULTS[1]},${WARM_RESULTS[2]},${DETECTED_CPUS},${AVG_WARM}" >> $RESULTS_FILE
}

# Build for ARM64
echo "Building for ARM64..."
cargo lambda build --release --arm64 2>&1 | tail -3

# ARM64 Test Matrix (matching blog post claims)
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    ARM64 (Graviton2) Tests                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Test all configurations from the blog
test_config "arm64" "1536" "1"   # 1 vCPU baseline
test_config "arm64" "2048" "2"   # 2 vCPU
test_config "arm64" "4096" "3"   # 3 vCPU
test_config "arm64" "6144" "4"   # 4 vCPU (claimed optimal)
test_config "arm64" "8192" "5"   # 5 vCPU
test_config "arm64" "10240" "6"  # 6 vCPU (max)

# Build for x86_64
echo ""
echo "Building for x86_64..."
cargo lambda build --release --x86-64 2>&1 | tail -3

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      x86_64 Tests                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Test x86_64 configurations for comparison
test_config "x86-64" "1536" "1"
test_config "x86-64" "4096" "3"
test_config "x86-64" "6144" "4"
test_config "x86-64" "10240" "6"

# Calculate and display results
echo ""
echo "================================================================"
echo "VALIDATION RESULTS SUMMARY"
echo "================================================================"
echo ""
cat $RESULTS_FILE | column -t -s,
echo ""
echo "Results saved to: $RESULTS_FILE"

# Calculate speedup metrics
echo ""
echo "================================================================"
echo "SPEEDUP ANALYSIS (vs 1 worker baseline)"
echo "================================================================"
BASELINE=$(grep "1536,1," $RESULTS_FILE | cut -d',' -f11)
echo "Baseline (1 worker): ${BASELINE}ms"
echo ""

grep "arm64" $RESULTS_FILE | while IFS=',' read -r config arch memory workers cold_init cold_proc w1 w2 w3 cpus avg; do
    if [ "$arch" = "arm64" ] && [ ! -z "$avg" ] && [ "$avg" != "Avg_Warm_ms" ]; then
        SPEEDUP=$(echo "scale=2; $BASELINE / $avg" | bc 2>/dev/null || echo "N/A")
        EFFICIENCY=$(echo "scale=1; ($SPEEDUP / $workers) * 100" | bc 2>/dev/null || echo "N/A")
        echo "${workers} workers: ${avg}ms → ${SPEEDUP}x speedup (${EFFICIENCY}% efficiency)"
    fi
done

echo ""
echo "✅ Validation complete!"
