use std::collections::HashMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NodeType {
    Ss,
    Ssr,
    Vmess,
    Vless,
    Trojan,
    Hysteria2,
    Tuic,
    Anytls,
    Unknown(String),
}

impl std::fmt::Display for NodeType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NodeType::Ss => write!(f, "ss"),
            NodeType::Ssr => write!(f, "ssr"),
            NodeType::Vmess => write!(f, "vmess"),
            NodeType::Vless => write!(f, "vless"),
            NodeType::Trojan => write!(f, "trojan"),
            NodeType::Hysteria2 => write!(f, "hysteria2"),
            NodeType::Tuic => write!(f, "tuic"),
            NodeType::Anytls => write!(f, "anytls"),
            NodeType::Unknown(s) => write!(f, "{s}"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyNode {
    pub name: String,
    pub group: String,
    pub node_type: NodeType,
    pub server: String,
    pub port: u16,
    pub params: HashMap<String, serde_json::Value>,
    pub assigned_port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum GroupStatus {
    Ok,
    Error,
    Pending,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupState {
    pub name: String,
    pub nodes: Vec<ProxyNode>,
    pub last_updated: Option<chrono::DateTime<chrono::Utc>>,
    pub last_error: Option<String>,
    pub status: GroupStatus,
}

impl GroupState {
    pub fn new(name: String) -> Self {
        Self {
            name,
            nodes: Vec::new(),
            last_updated: None,
            last_error: None,
            status: GroupStatus::Pending,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct NodeHealth {
    pub alive: bool,
    pub delay: Option<u64>,
}
