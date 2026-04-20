use anyhow::{Context, Result};

use crate::config::MihomoConfig;

/// Tell mihomo to reload its config file.
#[tracing::instrument(skip_all)]
pub async fn reload_config(client: &reqwest::Client, mihomo: &MihomoConfig) -> Result<()> {
    let url = format!("{}/configs", mihomo.api.trim_end_matches('/'));

    let mut req = client
        .put(&url)
        .query(&[("force", "true")])
        .json(&serde_json::json!({ "path": mihomo.output.to_string_lossy() }));

    if let Some(secret) = &mihomo.api_secret {
        req = req.header("Authorization", format!("Bearer {secret}"));
    }

    req.send()
        .await
        .context("mihomo reload request failed")?
        .error_for_status()
        .context("mihomo reload returned error status")?;

    tracing::info!("mihomo config reloaded");
    Ok(())
}

/// Fetch proxy status from mihomo.
#[allow(dead_code)]
#[tracing::instrument(skip_all)]
pub async fn get_proxies(
    client: &reqwest::Client,
    mihomo: &MihomoConfig,
) -> Result<serde_json::Value> {
    let url = format!("{}/proxies", mihomo.api.trim_end_matches('/'));

    let mut req = client.get(&url);
    if let Some(secret) = &mihomo.api_secret {
        req = req.header("Authorization", format!("Bearer {secret}"));
    }

    let resp = req
        .send()
        .await
        .context("mihomo get proxies request failed")?
        .error_for_status()
        .context("mihomo get proxies returned error")?
        .json()
        .await
        .context("parsing mihomo proxies response")?;

    Ok(resp)
}

/// Test delay for a specific proxy node.
#[tracing::instrument(skip_all, fields(node = %node_name))]
pub async fn test_delay(
    client: &reqwest::Client,
    mihomo: &MihomoConfig,
    node_name: &str,
) -> Result<serde_json::Value> {
    let url = format!(
        "{}/proxies/{}/delay",
        mihomo.api.trim_end_matches('/'),
        percent_encoding::utf8_percent_encode(node_name, percent_encoding::NON_ALPHANUMERIC)
    );

    let mut req = client
        .get(&url)
        .query(&[("timeout", "5000"), ("url", "http://www.gstatic.com/generate_204")]);

    if let Some(secret) = &mihomo.api_secret {
        req = req.header("Authorization", format!("Bearer {secret}"));
    }

    let resp = req
        .send()
        .await
        .context("mihomo delay test request failed")?
        .error_for_status()
        .context("mihomo delay test returned error")?
        .json()
        .await
        .context("parsing mihomo delay response")?;

    Ok(resp)
}
