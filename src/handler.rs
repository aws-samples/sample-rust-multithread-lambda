use serde::{Deserialize, Serialize};
use std::env;
use std::sync::Once;
use std::time::Instant;
use std::collections::HashSet;
use std::sync::Mutex;
use rayon::prelude::*;

static INIT: Once = Once::new();

#[derive(Deserialize)]
pub struct ProcessRequest {
    count: usize, mode: String,
}

#[derive(Serialize)]
pub struct ProcessResponse {
    processed: usize, duration_ms: u128, mode: String, workers: usize,
    detected_cpus: usize, avg_ms_per_item: f64, memory_used_kb: u64,
    threads_used: usize  // Actual threads that processed items (proves multi-threading)
}

// CPU-intensive bcrypt hashing with cost factor 10
fn hash_password(password: &str) -> Result<String, bcrypt::BcryptError> {
    bcrypt::hash(password, 10)
}

// Process items one at a time (baseline for comparison)
fn process_sequential(items: Vec<String>) -> Result<(Vec<String>, usize), Box<dyn std::error::Error + Send + Sync>> {
    let results: Result<Vec<String>, _> = items
        .iter().map(|item| hash_password(item)).collect();
    results
        .map(|r| (r, 1))
        .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send + Sync>)
}

// Process items in parallel using Rayon's work-stealing scheduler
// Thread pool size is configured once at cold start via init_thread_pool()
fn process_parallel(items: Vec<String>) -> Result<(Vec<String>, usize), Box<dyn std::error::Error + Send + Sync>> {
    let thread_ids: Mutex<HashSet<std::thread::ThreadId>> = Mutex::new(HashSet::new());
    
    let results: Result<Vec<String>, _> = items
        .par_iter()
        .map(|item| {
            thread_ids.lock().unwrap().insert(std::thread::current().id());
            hash_password(item)
        })
        .collect();
    
    let threads_used = thread_ids.lock().unwrap().len();
    results
        .map(|r| (r, threads_used))
        .map_err(|e| Box::new(e) as Box<dyn std::error::Error + Send + Sync>)
}

// Get worker count from env var or detect CPUs, clamped to 1-6
pub fn get_worker_count() -> usize {
    if let Ok(count_str) = env::var("WORKER_COUNT") {
        if let Ok(count) = count_str.parse::<usize>() {
            return count.clamp(1, 6);
        }
    }
    num_cpus::get().clamp(1, 6)
}

// Initialize Rayon global thread pool (only once per Lambda container)
pub fn init_thread_pool(workers: usize) {
    INIT.call_once(|| {
        let _ = rayon::ThreadPoolBuilder::new()
            .num_threads(workers)
            .build_global();
    });
}

// Read RSS memory from /proc/self/statm (Linux only)
fn get_memory_usage_kb() -> u64 {
    std::fs::read_to_string("/proc/self/statm")
        .ok().and_then(|s| s.split_whitespace().nth(1)?.parse::<u64>().ok())
        .map(|pages| pages * 4).unwrap_or(0)
}

// Main Lambda handler - processes items sequentially or in parallel
pub async fn function_handler(request: ProcessRequest) -> Result<ProcessResponse, Box<dyn std::error::Error + Send + Sync>> {
    if request.count == 0 { return Err("count must be greater than 0".into()); }
    if request.count > 1000 { return Err("count exceeds maximum of 1000 items".into()); }

    let items: Vec<String> = (0..request.count)
        .map(|i| format!("password_{:06}", i)).collect();

    let workers = get_worker_count();
    let mode = match request.mode.as_str() {
        "sequential" => "sequential",
        "parallel" => "parallel",
        _ => if workers > 1 { "parallel" } else { "sequential" }
    };

    let start = Instant::now();
    let (results, threads_used) = match mode {
        "sequential" => process_sequential(items)?,
        _ => process_parallel(items)?,
    };
    let duration_ms = start.elapsed().as_millis();

    Ok(ProcessResponse {
        processed: results.len(),
        duration_ms,
        mode: mode.to_string(),
        workers: if mode == "parallel" { workers } else { 1 },
        detected_cpus: num_cpus::get(),
        avg_ms_per_item: duration_ms as f64 / request.count as f64,
        memory_used_kb: get_memory_usage_kb(),
        threads_used,
    })
}
