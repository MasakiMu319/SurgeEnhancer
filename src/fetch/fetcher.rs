use anyhow::{Context, Result};
use regex::Regex;

use crate::config::GroupConfig;
use crate::model::ProxyNode;
use crate::parse;

/// Fetch a subscription group and return parsed, filtered nodes.
#[tracing::instrument(skip_all, fields(group = %group_cfg.name))]
pub async fn fetch_group(client: &reqwest::Client, group_cfg: &GroupConfig) -> Result<Vec<ProxyNode>> {
    let body = if let Some(url) = &group_cfg.subscription {
        tracing::info!(url = %url, "fetching subscription");
        client
            .get(url)
            .header("User-Agent", "clash-verge/v2.2.3")
            .send()
            .await
            .context("HTTP request failed")?
            .error_for_status()
            .context("HTTP error status")?
            .text()
            .await
            .context("reading response body")?
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
