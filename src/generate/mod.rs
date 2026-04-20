pub mod mihomo;
pub mod surge;

use anyhow::Result;

use crate::config::AppConfig;
use crate::model::ProxyNode;

/// Regenerate both mihomo.yaml and Surge config after a refresh.
pub async fn regenerate(config: &AppConfig, all_nodes: &[ProxyNode]) -> Result<()> {
    mihomo::generate_mihomo_config(config, all_nodes).await?;
    tracing::info!(
        output = %config.mihomo.output.display(),
        nodes = all_nodes.len(),
        "mihomo config regenerated"
    );
    Ok(())
}
