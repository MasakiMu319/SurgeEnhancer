use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

use crate::fetch::scheduler;
use crate::generate::surge;
use crate::state::AppState;

/// GET /surge/proxies — all nodes as Surge proxy list
pub async fn surge_proxies(State(state): State<AppState>) -> Response {
    let inner = state.inner.read().await;
    let all_nodes: Vec<_> = inner.groups.values().flat_map(|g| &g.nodes).collect();

    if all_nodes.is_empty() {
        return (StatusCode::OK, "# No nodes available yet\n").into_response();
    }

    let listen_addr = &state.config.port.listen_addr;
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
    let inner = state.inner.read().await;

    let group = match inner.groups.get(&name) {
        Some(g) => g,
        None => {
            return (StatusCode::NOT_FOUND, format!("# Group '{name}' not found\n"))
                .into_response()
        }
    };

    let listen_addr = &state.config.port.listen_addr;
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
    let inner = state.inner.read().await;

    let groups: indexmap::IndexMap<String, Vec<_>> = inner
        .groups
        .iter()
        .map(|(name, gs)| (name.clone(), gs.nodes.clone()))
        .collect();
    drop(inner);

    let config_text = surge::generate_surge_config(&state.config, &groups);

    (
        StatusCode::OK,
        [("content-type", "text/plain; charset=utf-8")],
        config_text,
    )
        .into_response()
}

/// POST /refresh — refresh all groups
pub async fn refresh_all(State(state): State<AppState>) -> Response {
    let client = reqwest::Client::new();
    let config = state.config.clone();

    tokio::spawn(async move {
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
    let config = state.config.clone();
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
    let inner = state.inner.read().await;
    let server_listen = &state.config.server.listen;

    let groups: Vec<serde_json::Value> = inner
        .groups
        .values()
        .map(|g| {
            let group_cfg = state.config.groups.iter().find(|gc| gc.name == g.name);
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
    let inner = state.inner.read().await;
    let node_names: Vec<String> = match inner.groups.get(&name) {
        Some(g) => g.nodes.iter().map(|n| n.name.clone()).collect(),
        None => {
            return (StatusCode::NOT_FOUND, format!("group '{name}' not found\n")).into_response()
        }
    };
    drop(inner);

    let mihomo = state.config.mihomo.clone();
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
    let client = reqwest::Client::new();
    match crate::mihomo_api::test_delay(&client, &state.config.mihomo, &name).await {
        Ok(val) => axum::Json(val).into_response(),
        Err(e) => (
            StatusCode::BAD_GATEWAY,
            format!("mihomo delay test failed: {e}"),
        )
            .into_response(),
    }
}
