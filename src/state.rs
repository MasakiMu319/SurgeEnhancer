use std::collections::HashMap;
use std::sync::Arc;

use indexmap::IndexMap;
use tokio::sync::RwLock;

use crate::config::AppConfig;
use crate::model::{GroupState, NodeHealth};

#[derive(Clone)]
pub struct AppState {
    pub inner: Arc<RwLock<AppStateInner>>,
    pub config: Arc<AppConfig>,
}

pub struct AppStateInner {
    pub groups: IndexMap<String, GroupState>,
    pub port_map: HashMap<String, u16>,
    pub mihomo_health: HashMap<String, NodeHealth>,
}

impl AppState {
    pub fn new(config: AppConfig) -> Self {
        let mut groups = IndexMap::new();
        for g in &config.groups {
            groups.insert(g.name.clone(), GroupState::new(g.name.clone()));
        }
        Self {
            inner: Arc::new(RwLock::new(AppStateInner {
                groups,
                port_map: HashMap::new(),
                mihomo_health: HashMap::new(),
            })),
            config: Arc::new(config),
        }
    }
}
