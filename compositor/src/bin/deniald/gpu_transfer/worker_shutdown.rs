//! Join transfer workers only after the compositor's resource graph has dropped.
//!
//! Returning from main runs Mesa/LLVM atexit destructors. A detached worker
//! still in eglTerminate can then touch that already-freed global state.
use std::{
    sync::Mutex,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

static WORKERS: Mutex<Vec<JoinHandle<()>>> = Mutex::new(Vec::new());
const EXIT_TIMEOUT: Duration = Duration::from_secs(10);

pub(super) fn register(worker: JoinHandle<()>) {
    let mut workers = WORKERS.lock().unwrap_or_else(|error| error.into_inner());
    let mut index = 0;
    while index < workers.len() {
        if workers[index].is_finished() {
            if workers.swap_remove(index).join().is_err() {
                tracing::error!("GPU transfer worker panicked during teardown");
            }
        } else {
            index += 1;
        }
    }
    workers.push(worker);
}

/// Call after denial_main returns, after all queue senders have been dropped.
/// Never called by the event/raster loop or during ordinary output retirement.
pub(crate) fn finish_process_workers() -> Result<(), String> {
    let workers = std::mem::take(&mut *WORKERS.lock().unwrap_or_else(|error| error.into_inner()));
    wait(workers, EXIT_TIMEOUT)
}

fn wait(workers: Vec<JoinHandle<()>>, timeout: Duration) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    while workers.iter().any(|worker| !worker.is_finished()) {
        if Instant::now() >= deadline {
            // main aborts on this error, preserving a core dump and avoiding
            // C atexit cleanup while a driver still has a live worker.
            return Err("GPU transfer teardown exceeded the process-exit deadline".into());
        }
        thread::sleep(Duration::from_millis(1));
    }
    for worker in workers {
        worker
            .join()
            .map_err(|_| "GPU transfer worker panicked during process teardown".to_owned())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    };

    #[test]
    fn waits_for_thread_destructors_before_allowing_process_exit() {
        struct DriverGuard(Arc<AtomicBool>);
        impl Drop for DriverGuard {
            fn drop(&mut self) {
                thread::sleep(Duration::from_millis(10));
                self.0.store(true, Ordering::Release);
            }
        }
        let destroyed = Arc::new(AtomicBool::new(false));
        let flag = destroyed.clone();
        let worker = thread::spawn(move || {
            let _driver = DriverGuard(flag);
        });
        wait(vec![worker], Duration::from_secs(2)).unwrap();
        assert!(destroyed.load(Ordering::Acquire));
    }

    #[test]
    fn stuck_worker_has_a_finite_process_exit_deadline() {
        let (release, blocked) = mpsc::channel();
        let (finished, completion) = mpsc::channel();
        let worker = thread::spawn(move || {
            blocked.recv().unwrap();
            finished.send(()).unwrap();
        });
        assert!(
            wait(vec![worker], Duration::ZERO)
                .unwrap_err()
                .contains("deadline")
        );
        release.send(()).unwrap();
        completion.recv_timeout(Duration::from_secs(2)).unwrap();
    }

    #[test]
    fn teardown_panics_remain_fatal() {
        let worker = thread::spawn(|| panic!("driver teardown"));
        assert!(
            wait(vec![worker], Duration::from_secs(2))
                .unwrap_err()
                .contains("panicked")
        );
    }
}
