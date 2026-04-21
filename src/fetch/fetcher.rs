use anyhow::{Context, Result};
use regex::Regex;
use std::path::PathBuf;

use crate::config::GroupConfig;
use crate::model::ProxyNode;
use crate::parse;

fn cache_dir() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(|| PathBuf::from(".cache"))
        .join("surge-enhancer")
}

fn cache_path(group_name: &str) -> PathBuf {
    cache_dir().join(format!("{}.sub", group_name))
}

async fn save_cache(group_name: &str, data: &str) {
    let dir = cache_dir();
    if let Err(e) = tokio::fs::create_dir_all(&dir).await {
        tracing::warn!(error = %e, "failed to create cache dir");
        return;
    }
    let path = cache_path(group_name);
    if let Err(e) = tokio::fs::write(&path, data).await {
        tracing::warn!(error = %e, group = %group_name, "failed to write cache");
    } else {
        tracing::info!(group = %group_name, "cached subscription");
    }
}

async fn load_cache(group_name: &str) -> Option<String> {
    let path = cache_path(group_name);
    match tokio::fs::read_to_string(&path).await {
        Ok(data) => {
            tracing::info!(group = %group_name, "loaded subscription from cache");
            Some(data)
        }
        Err(_) => None,
    }
}

/// Fetch a subscription group and return parsed, filtered nodes.
#[tracing::instrument(skip_all, fields(group = %group_cfg.name))]
pub async fn fetch_group(client: &reqwest::Client, group_cfg: &GroupConfig) -> Result<Vec<ProxyNode>> {
    let body = if let Some(url) = &group_cfg.subscription {
        tracing::info!(url = %url, "fetching subscription");
        match client
            .get(url)
            .header("User-Agent", "clash-verge/v2.2.3")
            .send()
            .await
            .and_then(|r| r.error_for_status())
        {
            Ok(resp) => {
                let text = resp.text().await.context("reading response body")?;
                save_cache(&group_cfg.name, &text).await;
                text
            }
            Err(e) => {
                tracing::warn!(error = %e, "fetch failed, trying cache");
                load_cache(&group_cfg.name).await
                    .with_context(|| format!("fetch failed and no cache for '{}'", group_cfg.name))?
            }
        }
    } else if let Some(path) = &group_cfg.file {
        tracing::info!(path = %path.display(), "reading local file");
        tokio::fs::read_to_string(path)
            .await
            .with_context(|| format!("reading file: {path:?}"))?
    } else {
        anyhow::bail!("group '{}' has no subscription or file", group_cfg.name);
    };

    let mut nodes = parse::parse_subscription(&body, &group_cfg.name)?;
    tracing::info!(count = nodes.len(), "parsed nodes before filtering");

    // Apply include filter
    if let Some(ref pattern) = group_cfg.filter {
        let re = Regex::new(pattern).context("invalid filter regex")?;
        nodes.retain(|n| re.is_match(&n.name));
    }

    // Apply exclude filter
    if let Some(ref pattern) = group_cfg.exclude_filter {
        let re = Regex::new(pattern).context("invalid exclude_filter regex")?;
        nodes.retain(|n| !re.is_match(&n.name));
    }

    tracing::info!(count = nodes.len(), "nodes after filtering");
    Ok(nodes)
}
