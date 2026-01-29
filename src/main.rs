use lambda_runtime::{run, service_fn, Error, LambdaEvent};
mod handler;
use handler::{function_handler, get_worker_count, init_thread_pool, ProcessRequest};

#[tokio::main]
async fn main() -> Result<(), Error> {
    // Initialize Rayon thread pool at cold start (once per container lifecycle)
    init_thread_pool(get_worker_count());

    run(service_fn(|event: LambdaEvent<ProcessRequest>| async move {
        function_handler(event.payload).await
    }))
    .await
}
