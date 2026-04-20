use std::path::PathBuf;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AppConfig {
    pub server: ServerConfig,
    pub mihomo: MihomoConfig,
    pub port: PortConfig,
    pub groups: Vec<GroupConfig>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ServerConfig {
    pub listen: String,
    #[serde(default = "default_log_level")]
    pub log_level: String,
}

fn default_log_level() -> String {
    "info".to_string()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct MihomoConfig {
    pub template: PathBuf,
    pub output: PathBuf,
    pub api: String,
    #[serde(default)]
    pub api_secret: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PortConfig {
    pub range_start: u16,
    #[serde(default = "default_listen_addr")]
    pub listen_addr: String,
}

fn default_listen_addr() -> String {
    "127.0.0.1".to_string()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct GroupConfig {
    pub name: String,
    #[serde(default)]
    pub subscription: Option<String>,
    #[serde(default)]
    pub file: Option<PathBuf>,
    #[serde(default = "default_update_interval")]
    pub update_interval: u64,
    #[serde(default)]
    pub filter: Option<String>,
    #[serde(default)]
    pub exclude_filter: Option<String>,
}

fn default_update_interval() -> u64 {
    3600
}

impl AppConfig {
    pub fn load(path: &PathBuf) -> Result<Self> {
        let content =
            std::fs::read_to_string(path).with_context(|| format!("reading config: {path:?}"))?;
        let config: AppConfig =
            serde_yml::from_str(&content).with_context(|| "parsing config.yaml")?;
        config.validate()?;
        Ok(config)
    }

    pub fn save(&self, path: &PathBuf) -> Result<()> {
        let content = serde_yml::to_string(self).context("serializing config")?;
        std::fs::write(path, content).with_context(|| format!("writing config: {path:?}"))?;
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        if self.groups.is_empty() {
            tracing::warn!("no groups defined in config");
        }
        for g in &self.groups {
            anyhow::ensure!(
                g.subscription.is_some() || g.file.is_some(),
                "group '{}' must have either 'subscription' or 'file'",
                g.name
            );
        }
        Ok(())
    }
}
