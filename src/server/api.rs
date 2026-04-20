use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;

use crate::config::GroupConfig;
use crate::fetch::scheduler;
use crate::generate::surge;
use crate::model::{GroupState, GroupStatus};
use crate::state::AppState;

/// GET /surge/proxies — all nodes as Surge proxy list
pub async fn surge_proxies(State(state): State<AppState>) -> Response {
    let config = state.config.read().await.clone();
    let inner = state.inner.read().await;
    let all_nodes: Vec<_> = inner.groups.values().flat_map(|g| &g.nodes).collect();

    if all_nodes.is_empty() {
        return (StatusCode::OK, "# No nodes available yet\n").into_response();
    }

    let listen_addr = &config.port.listen_addr;
    let lines: Vec<String> = all_nodes
        .iter()
        .map(|n| format!("{} = socks5, {}, {}", n.name, listen_addr, n.assigned_port))
        .collect();

    (
        StatusCode::OK,
        [("content-type", "text/plain; charset=utf-8")],
        lines.join("\n"),
    )
        .into_response()
}

/// GET /surge/group/:name — specific group's nodes for Surge policy-path
pub async fn surge_group(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Response {
    let config = state.config.read().await.clone();
    let inner = state.inner.read().await;

    let group = match inner.groups.get(&name) {
        Some(g) => g,
        None => {
            return (StatusCode::NOT_FOUND, format!("# Group '{name}' not found\n"))
                .into_response()
        }
    };

    let listen_addr = &config.port.listen_addr;
    let lines = surge::generate_surge_proxy_list(&group.nodes, listen_addr);

    (
        StatusCode::OK,
        [("content-type", "text/plain; charset=utf-8")],
        lines,
    )
        .into_response()
}

/// GET /surge/config — full Surge [Proxy] + [Proxy Group] snippet
pub async fn surge_config(State(state): State<AppState>) -> Response {
    let config = state.config.read().await.clone();
    let inner = state.inner.read().await;

    let groups: indexmap::IndexMap<String, Vec<_>> = inner
        .groups
        .iter()
        .map(|(name, gs)| (name.clone(), gs.nodes.clone()))
        .collect();
    drop(inner);

    let config_text = surge::generate_surge_config(&config, &groups);

    (
        StatusCode::OK,
        [("content-type", "text/plain; charset=utf-8")],
        config_text,
    )
        .into_response()
}

/// POST /refresh — refresh all groups
pub async fn refresh_all(State(state): State<AppState>) -> Response {
    tokio::spawn(async move {
        let config = state.config.read().await.clone();
        let client = reqwest::Client::new();
        for group_cfg in &config.groups {
            scheduler::do_refresh(&state, &client, group_cfg).await;
        }
    });

    (StatusCode::ACCEPTED, "refresh triggered\n").into_response()
}

/// POST /refresh/:name — refresh a specific group
pub async fn refresh_group(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Response {
    let config = state.config.read().await.clone();
    let group_cfg = config.groups.iter().find(|g| g.name == name).cloned();

    match group_cfg {
        Some(group_cfg) => {
            let client = reqwest::Client::new();
            tokio::spawn(async move {
                scheduler::do_refresh(&state, &client, &group_cfg).await;
            });
            (StatusCode::ACCEPTED, format!("refresh triggered for '{name}'\n")).into_response()
        }
        None => (StatusCode::NOT_FOUND, format!("group '{name}' not found\n")).into_response(),
    }
}

/// GET /status — JSON status for dashboard
pub async fn status(State(state): State<AppState>) -> Response {
    let config = state.config.read().await.clone();
    let inner = state.inner.read().await;
    let server_listen = &config.server.listen;

    let groups: Vec<serde_json::Value> = inner
        .groups
        .values()
        .map(|g| {
            let group_cfg = config.groups.iter().find(|gc| gc.name == g.name);
            let subscription = group_cfg.and_then(|gc| {
                gc.subscription
                    .as_deref()
                    .map(|s| s.to_string())
                    .or_else(|| gc.file.as_ref().map(|f| f.display().to_string()))
            });

            let nodes: Vec<serde_json::Value> = g
                .nodes
                .iter()
                .map(|n| {
                    serde_json::json!({
                        "name": n.name,
                        "type": n.node_type.to_string(),
                        "server": n.server,
                        "port": n.port,
                        "assigned_port": n.assigned_port,
                    })
                })
                .collect();

            serde_json::json!({
                "name": g.name,
                "status": format!("{:?}", g.status),
                "node_count": g.nodes.len(),
                "last_updated": g.last_updated,
                "last_error": g.last_error,
                "subscription": subscription,
                "surge_policy_path": format!("http://{server_listen}/surge/group/{}", g.name),
                "nodes": nodes,
            })
        })
        .collect();

    let total_nodes: usize = inner.groups.values().map(|g| g.nodes.len()).sum();

    axum::Json(serde_json::json!({
        "total_nodes": total_nodes,
        "groups": groups,
    }))
    .into_response()
}

/// POST /api/batch-delay/:name — test delay for all nodes in a group
pub async fn batch_delay(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Response {
    let config = state.config.read().await.clone();
    let inner = state.inner.read().await;
    let node_names: Vec<String> = match inner.groups.get(&name) {
        Some(g) => g.nodes.iter().map(|n| n.name.clone()).collect(),
        None => {
            return (StatusCode::NOT_FOUND, format!("group '{name}' not found\n")).into_response()
        }
    };
    drop(inner);

    let mihomo = config.mihomo.clone();
    let mut set = tokio::task::JoinSet::new();
    for node_name in node_names {
        let mihomo = mihomo.clone();
        set.spawn(async move {
            let client = reqwest::Client::new();
            let result = crate::mihomo_api::test_delay(&client, &mihomo, &node_name).await;
            (node_name, result)
        });
    }

    let mut results = serde_json::Map::new();
    while let Some(res) = set.join_next().await {
        match res {
            Ok((node_name, Ok(val))) => {
                results.insert(node_name, val);
            }
            Ok((node_name, Err(e))) => {
                results.insert(
                    node_name,
                    serde_json::json!({ "message": e.to_string() }),
                );
            }
            Err(e) => {
                tracing::error!("batch delay task panicked: {e}");
            }
        }
    }

    axum::Json(serde_json::json!({ "results": results })).into_response()
}

/// GET /api/delay/:name — test delay for a node via mihomo
pub async fn test_delay(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Response {
    let config = state.config.read().await.clone();
    let client = reqwest::Client::new();
    match crate::mihomo_api::test_delay(&client, &config.mihomo, &name).await {
        Ok(val) => axum::Json(val).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            format!("mihomo delay test failed: {e}"),
        )
            .into_response(),
    }
}

// --- Group CRUD ---

#[derive(serde::Deserialize)]
pub struct AddGroupRequest {
    pub name: String,
    pub subscription: Option<String>,
    pub file: Option<String>,
    #[serde(default = "default_interval")]
    pub update_interval: u64,
    #[serde(default)]
    pub filter: Option<String>,
    #[serde(default)]
    pub exclude_filter: Option<String>,
}

fn default_interval() -> u64 {
    3600
}

#[derive(serde::Deserialize)]
pub struct UpdateGroupRequest {
    pub subscription: Option<String>,
    pub file: Option<String>,
    pub update_interval: Option<u64>,
    pub filter: Option<String>,
    pub exclude_filter: Option<String>,
}

/// POST /api/groups — add a new subscription group
pub async fn add_group(
    State(state): State<AppState>,
    Json(req): Json<AddGroupRequest>,
) -> Response {
    if req.name.is_empty() {
        return (StatusCode::BAD_REQUEST, "name is required").into_response();
    }
    if req.subscription.is_none() && req.file.is_none() {
        return (StatusCode::BAD_REQUEST, "subscription or file is required").into_response();
    }

    let group_cfg = GroupConfig {
        name: req.name.clone(),
        subscription: req.subscription,
        file: req.file.map(std::path::PathBuf::from),
        update_interval: req.update_interval,
        filter: req.filter,
        exclude_filter: req.exclude_filter,
    };

    // Update config
    {
        let mut config = state.config.write().await;
        if config.groups.iter().any(|g| g.name == group_cfg.name) {
            return (
                StatusCode::CONFLICT,
                format!("group '{}' already exists", group_cfg.name),
            )
                .into_response();
        }
        config.groups.push(group_cfg.clone());
        if let Err(e) = config.save(&state.config_path) {
            tracing::error!(error = %e, "failed to save config");
        }
    }

    // Add to runtime state
    {
        let mut inner = state.inner.write().await;
        inner
            .groups
            .insert(req.name.clone(), GroupState::new(req.name.clone()));
    }

    // Spawn refresh for the new group
    let state2 = state.clone();
    let gc = group_cfg.clone();
    tokio::spawn(async move {
        let client = reqwest::Client::new();
        scheduler::do_refresh(&state2, &client, &gc).await;
    });

    // Spawn periodic refresh loop
    scheduler::spawn_single_refresh_task(state.clone(), group_cfg);

    (StatusCode::CREATED, format!("group '{}' added\n", req.name)).into_response()
}

/// PUT /api/groups/:name — update a group's subscription/settings
pub async fn update_group(
    State(state): State<AppState>,
    Path(name): Path<String>,
    Json(req): Json<UpdateGroupRequest>,
) -> Response {
    let mut config = state.config.write().await;
    let group_cfg = match config.groups.iter_mut().find(|g| g.name == name) {
        Some(g) => g,
        None => {
            return (StatusCode::NOT_FOUND, format!("group '{name}' not found")).into_response()
        }
    };

    if let Some(sub) = req.subscription {
        group_cfg.subscription = if sub.is_empty() { None } else { Some(sub) };
    }
    if let Some(file) = req.file {
        group_cfg.file = if file.is_empty() {
            None
        } else {
            Some(std::path::PathBuf::from(file))
        };
    }
    if let Some(interval) = req.update_interval {
        group_cfg.update_interval = interval;
    }
    if let Some(filter) = req.filter {
        group_cfg.filter = if filter.is_empty() { None } else { Some(filter) };
    }
    if let Some(exclude) = req.exclude_filter {
        group_cfg.exclude_filter = if exclude.is_empty() {
            None
        } else {
            Some(exclude)
        };
    }

    let updated_cfg = group_cfg.clone();
    if let Err(e) = config.save(&state.config_path) {
        tracing::error!(error = %e, "failed to save config");
    }
    drop(config);

    // Trigger a refresh with the updated config
    let state2 = state.clone();
    tokio::spawn(async move {
        let client = reqwest::Client::new();
        scheduler::do_refresh(&state2, &client, &updated_cfg).await;
    });

    (StatusCode::OK, format!("group '{name}' updated\n")).into_response()
}

/// DELETE /api/groups/:name — remove a group
pub async fn delete_group(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Response {
    // Remove from config
    {
        let mut config = state.config.write().await;
        let before = config.groups.len();
        config.groups.retain(|g| g.name != name);
        if config.groups.len() == before {
            return (StatusCode::NOT_FOUND, format!("group '{name}' not found")).into_response();
        }
        if let Err(e) = config.save(&state.config_path) {
            tracing::error!(error = %e, "failed to save config");
        }
    }

    // Remove from runtime state and clean up ports
    {
        let mut inner = state.inner.write().await;
        if let Some(gs) = inner.groups.shift_remove(&name) {
            for node in &gs.nodes {
                inner.port_map.remove(&node.name);
            }
        }
    }

    // Regenerate configs without this group
    let config = state.config.read().await.clone();
    let inner = state.inner.read().await;
    let all_nodes: Vec<_> = inner
        .groups
        .values()
        .flat_map(|g| g.nodes.iter().cloned())
        .collect();
    drop(inner);

    if let Err(e) = crate::generate::regenerate(&config, &all_nodes).await {
        tracing::error!(error = %e, "failed to regenerate configs after delete");
    }
    if let Err(e) =
        crate::mihomo_api::reload_config(&reqwest::Client::new(), &config.mihomo).await
    {
        tracing::warn!(error = %e, "failed to reload mihomo");
    }

    (StatusCode::OK, format!("group '{name}' deleted\n")).into_response()
}
