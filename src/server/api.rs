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

    let groups: Vec<serde_json::Value> = inner
        .groups
        .values()
        .map(|g| {
            serde_json::json!({
                "name": g.name,
                "status": format!("{:?}", g.status),
                "node_count": g.nodes.len(),
                "last_updated": g.last_updated,
                "last_error": g.last_error,
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
