mod config;
mod fetch;
mod generate;
mod mihomo_api;
mod mihomo_manager;
mod model;
mod parse;
mod port;
mod server;
mod state;

use std::path::PathBuf;

use anyhow::{Context, Result};
use axum::routing::{get, post, put};
use axum::Router;
use clap::Parser;
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(name = "surge-enhancer", about = "Proxy subscription manager for Surge + Mihomo")]
struct Cli {
    /// Path to config.yaml
    #[arg(short, long, default_value = "config.yaml")]
    config: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // Load config first so we can use log_level for tracing
    let app_config = config::AppConfig::load(&cli.config)?;

    // Initialize tracing
    let filter = EnvFilter::try_new(&app_config.server.log_level)
        .unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .with_thread_ids(false)
        .with_file(true)
        .with_line_number(true)
        .init();

    tracing::info!(
        config = %cli.config.display(),
        groups = app_config.groups.len(),
        listen = %app_config.server.listen,
        "surge-enhancer starting"
    );

    // Preflight: check dependencies
    check_dependencies(&app_config)?;

    let state = state::AppState::new(app_config, cli.config.clone());
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .context("building HTTP client")?;

    // Spawn mihomo process manager
    let mihomo = state.mihomo.clone();
    tokio::spawn(async move { mihomo.run().await });

    // Spawn background refresh tasks
    fetch::scheduler::spawn_refresh_tasks(state.clone(), client);

    // Build axum router
    let app = Router::new()
        .route("/", get(server::dashboard::dashboard))
        .route("/surge/proxies", get(server::api::surge_proxies))
        .route("/surge/group/{name}", get(server::api::surge_group))
        .route("/surge/config", get(server::api::surge_config))
        .route("/refresh", post(server::api::refresh_all))
        .route("/refresh/{name}", post(server::api::refresh_group))
        .route("/status", get(server::api::status))
        .route("/api/delay/{name}", get(server::api::test_delay))
        .route("/api/batch-delay/{name}", post(server::api::batch_delay))
        .route("/api/tcp-ping/{name}", post(server::api::tcp_ping_group))
        .route("/api/groups", post(server::api::add_group))
        .route(
            "/api/groups/{name}",
            put(server::api::update_group).delete(server::api::delete_group),
        )
        .with_state(state.clone());

    let listen_addr = state.config.read().await.server.listen.clone();
    let listener = tokio::net::TcpListener::bind(&listen_addr)
        .await
        .with_context(|| format!("binding to {listen_addr}"))?;

    tracing::info!(addr = %listen_addr, "HTTP server listening");
    axum::serve(listener, app).await.context("axum server error")?;

    Ok(())
}

/// Preflight checks — errors here abort startup.
fn check_dependencies(config: &config::AppConfig) -> Result<()> {
    // 1) mihomo binary must exist
    match mihomo_manager::MihomoManager::find_binary() {
        Some(path) => tracing::info!(path = %path, "mihomo binary found"),
        None => anyhow::bail!(
            "mihomo not found in PATH — install it first: https://github.com/MetaCubeX/mihomo"
        ),
    }

    // 2) mihomo template file must exist
    anyhow::ensure!(
        config.mihomo.template.exists(),
        "mihomo template not found: {}",
        config.mihomo.template.display()
    );

    Ok(())
}
