# Rust Multi-threaded Lambda

High-performance AWS Lambda function demonstrating CPU-intensive parallel processing with Rust and Rayon.

## Why Multi-threading in Lambda?

By default, AWS Lambda functions run in a single-threaded environment. However, Lambda allocates CPU power proportional to the configured memory - from ~1 vCPU at 1,792 MB to 6 vCPUs at 10,240 MB. For CPU-intensive workloads like cryptographic operations, image processing, or data transformations, **leaving these extra vCPUs idle wastes both time and money**.

This project demonstrates how to unlock Lambda's full CPU potential using Rust and Rayon, achieving:
- **6.6x speedup** with 6 vCPUs vs single-threaded processing
- **Near-linear scaling** with proper workload distribution
- **Cost optimization** - ARM64 (Graviton2) offers best price/performance

![Architecture Diagram](images/Architectural%20Diagram.png)

## Overview

This project implements a multi-threaded Rust Lambda function that processes bcrypt password hashes in parallel across multiple vCPUs. It demonstrates practical techniques for CPU-bound parallel processing on AWS Lambda, with comprehensive benchmarks across both ARM64 (Graviton2) and x86_64 architectures.

**Key Features:**
- Multi-threaded processing using Rayon's work-stealing scheduler
- Configurable worker count via environment variables
- Support for ARM64 (Graviton2) and x86_64 architectures
- Proper thread pool initialization during cold start
- Input validation and error handling
- Comprehensive performance benchmarks with P95/P99 metrics

## Project Structure

```
rust-multithread-lambda/
├── src/
│   ├── main.rs              # Lambda entry point with thread pool initialization
│   └── handler.rs           # Request handler with Rayon implementation
├── scripts/
│   ├── comprehensive_test.sh   # Full benchmark suite (ARM64 & x86_64, 20 runs per config)
│   ├── validation_test.sh      # Quick validation test for deployments
│   ├── burst_test.sh           # Work-stealing scheduler demonstration
│   └── cloudwatch_metrics.sh   # CloudWatch metrics collection script
├── template.yaml            # SAM template for deploying all 12 configurations
├── Cargo.toml               # Dependencies and build configuration
└── README.md                # This file
```

## Prerequisites

Before starting, you should have:

- An AWS account with Lambda permissions
- Rust 1.70 or later installed ([Installation guide](https://rustup.rs/))
- Cargo Lambda installed ([Installation guide](https://www.cargo-lambda.info/))
- AWS CLI configured with your credentials
- Basic understanding of Rust and concurrency concepts

## Quick Start

### Build

```bash
# Build for ARM64 (recommended)
cargo lambda build --release --arm64

# Or build for x86_64
cargo lambda build --release --x86-64
```

**Binary size**: ~1.7 MB (uncompressed), ~0.8 MB (zipped)

### Deploy

#### Option 1: Single Function with Cargo Lambda

```bash
# Deploy with 6144 MB memory (4 vCPUs) and 4 workers
cargo lambda deploy rust-multithread-lambda \
  --memory 6144 \
  --timeout 30 \
  --env-vars WORKER_COUNT=4
```

#### Option 2: All Configurations with SAM Template

Deploy all 12 benchmark configurations (6 ARM64 + 6 x86_64) using the SAM template:

```bash
# Build for both architectures
cargo lambda build --release --arm64 --output-format zip
mv target/lambda/rust-multithread-lambda target/lambda/rust-multithread-lambda-arm64

cargo lambda build --release --x86-64 --output-format zip
mv target/lambda/rust-multithread-lambda target/lambda/rust-multithread-lambda-x86

# Extract bootstrap binaries (required by SAM)
cd target/lambda/rust-multithread-lambda-arm64 && unzip -o bootstrap.zip && cd -
cd target/lambda/rust-multithread-lambda-x86 && unzip -o bootstrap.zip && cd -

# Deploy with SAM
sam deploy --guided --stack-name rust-multithread-benchmark
```

This deploys Lambda functions with the following naming convention:
- ARM64: `rust-bench-arm64-{vcpu}vcpu-{memory}mb`
- x86_64: `rust-bench-x86-{vcpu}vcpu-{memory}mb`

### Test

```bash
# Test the function
aws lambda invoke \
  --function-name rust-multithread-lambda \
  --payload '{"count":20,"mode":"parallel"}' \
  --cli-binary-format raw-in-base64-out \
  response.json

# View results
cat response.json | jq .
```

Example response:
```json
{
  "processed": 20,
  "duration_ms": 463,
  "mode": "parallel",
  "workers": 4,
  "detected_cpus": 4,
  "avg_ms_per_item": 23.15,
  "memory_used_kb": 3508,
  "threads_used": 4
}
```

## Request Format

```json
{
  "count": 20,           // Number of items to process (1-1000)
  "mode": "parallel"     // "parallel", "sequential", or "auto"
}
```

**Input Validation:**
- `count` must be between 1 and 1000
- Invalid inputs return error messages

## Performance Benchmarks

Tested on ARM64 (Graviton2) in us-east-1 with bcrypt hashing (cost factor 10). All results are averages from 20 warm invocations per configuration.

**Understanding the metrics:**
- **Speedup**: Performance improvement vs single-threaded baseline (1 worker)
- **Efficiency**: How well additional vCPUs are utilized (100% = perfect linear scaling)
- **Cold Init**: First invocation latency (includes thread pool initialization)
- **Warm Processing**: Average execution time after container warm-up

### ARM64 (Graviton2) Results (20 items)

| Memory | vCPUs | Workers | Warm Processing | Speedup |
|--------|-------|---------|-----------------|---------|
| 1536 MB | ~1 | 1 | 1,885 ms | 1.00x |
| 2048 MB | ~2 | 2 | 1,334 ms | 1.41x |
| 4096 MB | ~3 | 3 | 685 ms | 2.75x |
| **6144 MB** | **~4** | **4** | **463 ms** | **4.07x** |
| 8192 MB | ~5 | 5 | 338 ms | 5.57x |
| 10240 MB | ~6 | 6 | 280 ms | 6.73x |

*6144 MB (4 workers) offers the best balance of cost and performance - see Cost Analysis section below.*

### x86_64 Results (20 items)

| Memory | vCPUs | Workers | Warm Processing | Speedup |
|--------|-------|---------|-----------------|---------|
| 1536 MB | ~1 | 1 | 1,671 ms | 1.00x |
| 2048 MB | ~2 | 2 | 1,253 ms | 1.33x |
| 4096 MB | ~3 | 3 | 892 ms | 1.87x |
| 6144 MB | ~4 | 4 | 429 ms | 3.89x |
| 8192 MB | ~5 | 5 | 330 ms | 5.06x |
| 10240 MB | ~6 | 6 | 292 ms | 5.72x |

**Recommended Configuration**: 
- **Cost-Optimized**: ARM64 with 6144 MB (4 workers) - best price/performance
- **Performance**: ARM64 with 10240 MB (6 workers) - fastest at 280ms (6.73x speedup)

### Key Observations

- **Cold starts**: Similar to warm invocations (thread pool init is lightweight)
- **Near-linear scaling**: Up to 6.73x speedup with 6 workers on ARM64
- **Memory efficiency**: Uses only 1.5-3.5 MB regardless of allocation
- **Multi-threading validated**: `threads_used` field proves actual parallel execution
- **Architecture**: ARM64 recommended for better price/performance at higher vCPU counts

## Configuration

### Environment Variables

- `WORKER_COUNT`: Number of parallel workers (1-6, default: auto-detect from CPU count)

### Lambda Settings

- **Memory**: 1536-10240 MB
- **Timeout**: 30-120 seconds (depending on workload)
- **Architecture**: ARM64 or x86_64
- **Runtime**: provided.al2023

## Implementation Details

### Thread Pool Initialization

The function uses `std::sync::Once` to ensure the Rayon global thread pool is initialized exactly once during cold start:

```rust
static INIT: Once = Once::new();

pub fn init_thread_pool(workers: usize) {
    INIT.call_once(|| {
        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(workers)
            .build_global();
    });
}
```

### Parallel Processing with Thread Tracking

Uses Rayon's `par_iter()` for data parallelism, with thread ID tracking to prove multi-threading:

```rust
use rayon::prelude::*;
use std::collections::HashSet;
use std::sync::Mutex;

let thread_ids: Mutex<HashSet<std::thread::ThreadId>> = Mutex::new(HashSet::new());

let results = items
    .par_iter()
    .map(|item| {
        thread_ids.lock().unwrap().insert(std::thread::current().id());
        hash_password(item)
    })
    .collect();

let threads_used = thread_ids.lock().unwrap().len();
```

### Multi-threading vs Async: When to Use Each

**Use Multi-threading (Rayon) for:**
- **CPU-bound workloads** where the bottleneck is computation
- Tasks that can be parallelized independently (embarrassingly parallel problems)
- Operations like:
  - Cryptographic hashing/encryption
  - Image/video processing
  - Data transformations and calculations
  - Scientific computing

**Use Async (Tokio) for:**
- **I/O-bound workloads** where the bottleneck is waiting for external resources
- Operations like:
  - API calls to external services
  - Database queries
  - File I/O operations
  - Network requests

**Why Tokio is included:**
- AWS Lambda runtime requires an async runtime (Tokio)
- Tokio handles the Lambda event loop and invocation management
- Rayon handles the parallel CPU work within each invocation
- They complement each other: Tokio for concurrency, Rayon for parallelism

**Key Difference:**
- **Async (Tokio)**: Handles many tasks concurrently by switching between them while waiting for I/O
- **Multi-threading (Rayon)**: Executes multiple computations simultaneously on different CPU cores

This project uses **both**: Tokio for the Lambda runtime, and Rayon for parallel CPU processing.

## Testing

### Available Scripts

All scripts are located in the `scripts/` directory:

#### comprehensive_test.sh
Full benchmark suite that tests all 12 configurations (6 ARM64 + 6 x86_64):
```bash
./scripts/comprehensive_test.sh
```
- Runs 20 warm invocations per configuration
- Calculates P50, P90, P95, P99 percentiles
- Generates CSV results in `test-results/`
- Compares ARM64 vs x86_64 performance

#### validation_test.sh
Quick validation test for verifying deployments:
```bash
./scripts/validation_test.sh
```

#### burst_test.sh
Demonstrates Rayon's work-stealing scheduler behavior:
```bash
./scripts/burst_test.sh
```

#### cloudwatch_metrics.sh
Collects CloudWatch metrics for deployed functions:
```bash
./scripts/cloudwatch_metrics.sh
```

## Cost Analysis

For processing 20 bcrypt hashes (us-east-1 pricing):

> **Pricing**: ARM64 $0.0000133334/GB-second, x86_64 $0.0000166667/GB-second

### ARM64 (Recommended)

| Config | Memory | Duration | Cost per 1M Invocations |
|--------|--------|----------|-------------------------|
| 1 worker | 1536 MB | 1,885 ms | $38.60 |
| 2 workers | 2048 MB | 1,334 ms | $36.46 |
| 3 workers | 4096 MB | 685 ms | $37.47 |
| **4 workers** | **6144 MB** | **463 ms** | **$37.97** |
| 5 workers | 8192 MB | 338 ms | $36.94 |
| 6 workers | 10240 MB | 280 ms | $38.27 |

### x86_64

| Config | Memory | Duration | Cost per 1M Invocations |
|--------|--------|----------|-------------------------|
| 1 worker | 1536 MB | 1,671 ms | $42.78 |
| 2 workers | 2048 MB | 1,253 ms | $42.77 |
| 3 workers | 4096 MB | 892 ms | $60.80 |
| 4 workers | 6144 MB | 429 ms | $44.00 |
| 5 workers | 8192 MB | 330 ms | $45.10 |
| 6 workers | 10240 MB | 292 ms | $49.87 |

**Key Insights**:
- ARM64 consistently cheaper than x86_64 (15-30% savings)
- ARM64 5-6 workers offer best price/performance for high throughput
- ARM64 2 workers cheapest overall ($36.46 per 1M)
- x86_64 has anomalous performance at 3 vCPUs (possibly throttling)

## Use Cases

**Recommended for:**
- Batch data processing
- Cryptographic operations (hashing, encryption)
- Image/video processing
- Scientific computing
- High-volume workloads (>100K invocations/day)

**Not recommended for:**
- I/O-bound operations (use async instead)
- Simple transformations (<100ms)
- Low-volume workloads (<10K invocations/day)

## Dependencies

```toml
[dependencies]
lambda_runtime = "1.0.0"
tokio = { version = "1", features = ["macros", "rt-multi-thread"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
bcrypt = "0.15"
rayon = "1.7"
num_cpus = "1.16"
```

## IAM Permissions Required

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

## Cleanup

### Single Function
```bash
# Delete Lambda function
aws lambda delete-function --function-name rust-multithread-lambda

# Delete CloudWatch logs
aws logs delete-log-group --log-group-name /aws/lambda/rust-multithread-lambda
```

### SAM Stack (All Configurations)
```bash
# Delete all 12 Lambda functions deployed via SAM
aws cloudformation delete-stack --stack-name rust-multithread-benchmark
```

## Resources

- [AWS Lambda Rust Runtime](https://github.com/awslabs/aws-lambda-rust-runtime)
- [Cargo Lambda Documentation](https://www.cargo-lambda.info/)
- [Rayon Data Parallelism](https://docs.rs/rayon/latest/rayon/)
- [AWS Lambda Configuration](https://docs.aws.amazon.com/lambda/latest/dg/configuration-memory.html)

## Conclusion

This project demonstrates that multi-threaded processing in AWS Lambda is not only possible but highly effective for CPU-bound workloads. Key takeaways:

1. **Rayon makes parallelism simple**: Just replace `.iter()` with `.par_iter()` and Rayon handles thread management automatically.

2. **Thread pool initialization is critical**: Initialize the global thread pool during cold start, not during request processing, using `std::sync::Once`.

3. **ARM64 (Graviton2) delivers best value**: 15-30% cheaper than x86_64 with comparable or better performance at higher vCPU counts.

4. **Measure actual thread usage**: The `threads_used` field provides empirical proof that multi-threading is working correctly.

5. **Sweet spot varies by workload**: For bcrypt hashing, 4-6 workers provide the best throughput-to-cost ratio.

## License

MIT
