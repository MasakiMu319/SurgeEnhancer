use std::sync::Arc;

use chrono::Utc;
use tokio::time::{self, Duration};

use crate::config::GroupConfig;
use crate::fetch::fetcher;
use crate::generate;
use crate::mihomo_api;
use crate::model::GroupStatus;
use crate::port;
use crate::state::AppState;

/// Spawn background tasks that periodically refresh each subscription group.
pub fn spawn_refresh_tasks(state: AppState, client: reqwest::Client) {
    let config = Arc::clone(&state.config);
    for group_cfg in &config.groups {
        let state = state.clone();
        let client = client.clone();
        let group_cfg = group_cfg.clone();
        tokio::spawn(async move {
            refresh_loop(state, client, group_cfg).await;
        });
    }
}

async fn refresh_loop(state: AppState, client: reqwest::Client, group_cfg: GroupConfig) {
    let interval = Duration::from_secs(group_cfg.update_interval);
    let group_name = group_cfg.name.clone();

    // Initial fetch immediately
    do_refresh(&state, &client, &group_cfg).await;

    let mut ticker = time::interval(interval);
    ticker.tick().await; // skip the first immediate tick
    loop {
        ticker.tick().await;
        tracing::info!(group = %group_name, "scheduled refresh");
        do_refresh(&state, &client, &group_cfg).await;
    }
}

/// Perform a single refresh for one group: fetch, parse, assign ports, regenerate configs.
#[tracing::instrument(skip_all, fields(group = %group_cfg.name))]
pub async fn do_refresh(state: &AppState, client: &reqwest::Client, group_cfg: &GroupConfig) {
    match fetcher::fetch_group(client, group_cfg).await {
        Ok(mut nodes) => {
            let mut inner = state.inner.write().await;

            // Remove old entries for this group's previous nodes first
            if let Some(gs) = inner.groups.get(&group_cfg.name) {
                let old_names: Vec<String> = gs.nodes.iter().map(|n| n.name.clone()).collect();
                for name in old_names {
                    inner.port_map.remove(&name);
                }
            }

            // Assign ports (merge into global port_map)
            let new_entries = port::assign_ports(
                &mut nodes,
                state.config.port.range_start,
                &inner.port_map,
            );

            // Merge new entries
            inner.port_map.extend(new_entries);

            // Update group state
            if let Some(gs) = inner.groups.get_mut(&group_cfg.name) {
                gs.nodes = nodes;
                gs.last_updated = Some(Utc::now());
                gs.last_error = None;
                gs.status = GroupStatus::Ok;
            }

            tracing::info!("group updated successfully");

            // Regenerate configs (while still holding lock for consistency)
            let all_nodes: Vec<_> = inner
                .groups
                .values()
                .flat_map(|g| g.nodes.iter().cloned())
                .collect();
            drop(inner);

            if let Err(e) = generate::regenerate(&state.config, &all_nodes).await {
                tracing::error!(error = %e, "failed to regenerate configs");
            }

            // Reload mihomo
            if let Err(e) = mihomo_api::reload_config(client, &state.config.mihomo).await {
                tracing::warn!(error = %e, "failed to reload mihomo (may not be running)");
            }
        }
        Err(e) => {
            tracing::warn!(error = %e, "fetch failed, keeping cached data");
            let mut inner = state.inner.write().await;
            if let Some(gs) = inner.groups.get_mut(&group_cfg.name) {
                gs.last_error = Some(e.to_string());
                gs.status = GroupStatus::Error;
            }
        }
    }
}
