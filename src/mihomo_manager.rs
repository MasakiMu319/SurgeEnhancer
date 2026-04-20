use std::sync::Arc;

use tokio::process::Command;
use tokio::sync::RwLock;
use tokio::time::{self, Duration};

use crate::config::MihomoConfig;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MihomoStatus {
    Running,
    Stopped,
    Starting,
    Crashed,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct MihomoState {
    pub status: MihomoStatus,
    pub pid: Option<u32>,
    pub restarts: u32,
    pub last_error: Option<String>,
}

impl Default for MihomoState {
    fn default() -> Self {
        Self {
            status: MihomoStatus::Stopped,
            pid: None,
            restarts: 0,
            last_error: None,
        }
    }
}

#[derive(Clone)]
pub struct MihomoManager {
    pub state: Arc<RwLock<MihomoState>>,
    mihomo_config: MihomoConfig,
}

impl MihomoManager {
    pub fn new(mihomo_config: MihomoConfig) -> Self {
        Self {
            state: Arc::new(RwLock::new(MihomoState::default())),
            mihomo_config,
        }
    }

    /// Check if the mihomo binary exists in PATH.
    pub fn find_binary() -> Option<String> {
        let output = std::process::Command::new("which")
            .arg("mihomo")
            .output()
            .ok()?;
        if output.status.success() {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if path.is_empty() {
                None
            } else {
                Some(path)
            }
        } else {
            None
        }
    }

    /// Check if mihomo API is reachable.
    async fn is_api_alive(&self) -> bool {
        let url = format!("{}/version", self.mihomo_config.api.trim_end_matches('/'));
        let mut req = reqwest::Client::new()
            .get(&url)
            .timeout(Duration::from_secs(2));
        if let Some(secret) = &self.mihomo_config.api_secret {
            req = req.header("Authorization", format!("Bearer {secret}"));
        }
        matches!(req.send().await, Ok(resp) if resp.status().is_success())
    }

    /// Start mihomo process and return the Child.
    async fn start_process(&self) -> Result<tokio::process::Child, String> {
        let output_path = self.mihomo_config.output.display().to_string();

        let child = Command::new("mihomo")
            .arg("-f")
            .arg(&output_path)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| format!("failed to spawn mihomo: {e}"))?;

        Ok(child)
    }

    /// Main lifecycle loop: start mihomo, monitor, restart on crash.
    pub async fn run(self) {
        const HEALTH_INTERVAL: Duration = Duration::from_secs(10);
        const STARTUP_GRACE: Duration = Duration::from_secs(3);
        const RESTART_BACKOFF: Duration = Duration::from_secs(5);

        loop {
            // Check if already running externally
            if self.is_api_alive().await {
                tracing::info!("mihomo API already reachable, attaching to existing process");
                {
                    let mut s = self.state.write().await;
                    s.status = MihomoStatus::Running;
                    s.last_error = None;
                }
                self.health_loop(HEALTH_INTERVAL).await;
                // health_loop returns when API becomes unreachable
                tracing::warn!("mihomo API lost, will attempt restart");
            }

            // Start mihomo
            {
                let mut s = self.state.write().await;
                s.status = MihomoStatus::Starting;
            }

            let child = match self.start_process().await {
                Ok(child) => child,
                Err(e) => {
                    tracing::error!(error = %e, "failed to start mihomo");
                    let mut s = self.state.write().await;
                    s.status = MihomoStatus::Crashed;
                    s.last_error = Some(e);
                    time::sleep(RESTART_BACKOFF).await;
                    continue;
                }
            };

            let pid = child.id();
            tracing::info!(pid = pid, "mihomo process started");

            {
                let mut s = self.state.write().await;
                s.pid = pid;
                s.status = MihomoStatus::Starting;
            }

            // Wait for API to come up
            time::sleep(STARTUP_GRACE).await;

            let api_up = {
                let mut up = false;
                for _ in 0..5 {
                    if self.is_api_alive().await {
                        up = true;
                        break;
                    }
                    time::sleep(Duration::from_secs(1)).await;
                }
                up
            };

            if api_up {
                tracing::info!("mihomo API is up");
                {
                    let mut s = self.state.write().await;
                    s.status = MihomoStatus::Running;
                    s.last_error = None;
                }
            } else {
                tracing::warn!("mihomo started but API not responding");
                {
                    let mut s = self.state.write().await;
                    s.status = MihomoStatus::Running;
                    s.last_error = Some("API not responding after start".into());
                }
            }

            // Monitor: wait for process exit OR API health failure
            self.monitor_loop(child, HEALTH_INTERVAL).await;

            // Process died or API unreachable
            {
                let mut s = self.state.write().await;
                s.status = MihomoStatus::Crashed;
                s.pid = None;
                s.restarts += 1;
                tracing::warn!(restarts = s.restarts, "mihomo exited, restarting...");
            }

            time::sleep(RESTART_BACKOFF).await;
        }
    }

    /// Poll API until it becomes unreachable. Returns when health check fails.
    async fn health_loop(&self, interval: Duration) {
        let mut ticker = time::interval(interval);
        let mut consecutive_failures = 0u32;
        loop {
            ticker.tick().await;
            if self.is_api_alive().await {
                consecutive_failures = 0;
            } else {
                consecutive_failures += 1;
                tracing::warn!(failures = consecutive_failures, "mihomo health check failed");
                if consecutive_failures >= 3 {
                    let mut s = self.state.write().await;
                    s.status = MihomoStatus::Crashed;
                    s.last_error = Some("API unreachable (3 consecutive failures)".into());
                    return;
                }
            }
        }
    }

    /// Monitor a child process we spawned. Returns when the process exits
    /// or API health checks fail 3 times consecutively.
    async fn monitor_loop(&self, mut child: tokio::process::Child, interval: Duration) {
        let mut ticker = time::interval(interval);
        let mut consecutive_failures = 0u32;
        loop {
            tokio::select! {
                status = child.wait() => {
                    match status {
                        Ok(exit) => {
                            let mut s = self.state.write().await;
                            s.last_error = Some(format!("process exited: {exit}"));
                        }
                        Err(e) => {
                            let mut s = self.state.write().await;
                            s.last_error = Some(format!("wait error: {e}"));
                        }
                    }
                    return;
                }
                _ = ticker.tick() => {
                    if self.is_api_alive().await {
                        consecutive_failures = 0;
                    } else {
                        consecutive_failures += 1;
                        tracing::warn!(failures = consecutive_failures, "mihomo health check failed");
                        if consecutive_failures >= 3 {
                            tracing::error!("mihomo unresponsive, killing process");
                            let _ = child.kill().await;
                            let mut s = self.state.write().await;
                            s.last_error = Some("killed: API unreachable".into());
                            return;
                        }
                    }
                }
            }
        }
    }
}
