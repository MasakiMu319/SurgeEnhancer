# Surge Enhancer - Agent Guide

## Overview

Bridges Surge (macOS proxy) with Mihomo (Clash.Meta). Fetches subscriptions, parses proxy nodes, generates Mihomo YAML config, and serves a Surge-compatible HTTP API. Implemented in Rust under `src/`.

## Architecture

Subscriptions -> Fetcher -> Parser (Clash YAML / base64 URI) -> AppState (groups, nodes, port_map) -> Mihomo config generator -> HTTP API for Surge

## Key gotchas

- **Mihomo config path**: Put generated config under `~/.config/mihomo/` so Mihomo reload API can access it.
- **Mihomo lifecycle**: `mihomo_manager.rs` starts `mihomo -f <output>` and monitors `/version`.
- **Reload flow**: Refresh regenerates config, then calls Mihomo reload API through `mihomo_api.rs`.
- **Subscription parsing**: Clash YAML and URI list parsers normalize nodes into `ProxyNode`.
- **Port assignment**: `port_map` keeps stable SOCKS listener ports across refreshes.
- **Runtime state**: `AppState` uses Tokio `RwLock`; keep network and file I/O outside long-held write locks when extending refresh flows.
- **Surge output**: Surge endpoints expose each node as a local `socks5` proxy using the assigned listener port.

## Build

```bash
cargo build --release
cargo test
```

## Dependencies

- Rust stable
- Mihomo installed and available in `PATH`

## CI

- `.github/workflows/build.yml` runs Rust build and tests on push/PR.
- `.github/workflows/release.yml` builds the macOS release binary on `v*` tags.
