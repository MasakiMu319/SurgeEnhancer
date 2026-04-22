# Surge Enhancer

Proxy subscription manager that bridges [Surge](https://nssurge.com/) with [Mihomo](https://github.com/MetaCubeX/mihomo) (Clash.Meta), enabling Surge to use proxy protocols it doesn't natively support (SS, VMess, VLESS, Trojan, Hysteria2, etc.) via a single Mihomo process.

## Problem

Surge's `external-proxy` feature spawns **one process per node** — unacceptable for 50–200 nodes. Surge Enhancer uses Mihomo as a single-process middleware with one SOCKS5 listener per node, so Surge connects to each as a regular `socks5` proxy.

```
Surge → (socks5) → Mihomo (127.0.0.1:PORT) → (ss/vmess/...) → Remote Server
```

## Implementations

Two implementations, both fully functional and feature-equivalent:

| | **Zig** | **Rust** |
|---|---|---|
| Binary size | 1.8 MB | 11 MB |
| Memory (RSS) | ~19 MB | ~19 MB |
| API latency | ~0.5ms | ~0.8ms |
| Dependencies | None (static linked) | None (system libs only) |
| Build | `zig build -Doptimize=ReleaseFast` | `cargo build --release` |

## Features

- **Multi-subscription support** — fetch from multiple providers, each as a "group"
- **Format auto-detection** — Clash YAML (including flow mappings), base64-encoded URI lists, plain URI lists
- **Mihomo config generation** — merges proxies + listeners into your mihomo template
- **Surge-compatible HTTP API** — `policy-path=http://127.0.0.1:9300/surge/group/ProviderA`
- **HTMX dashboard** — view node status, trigger refreshes, test delays
- **Scheduled refresh** — periodically re-fetches subscriptions and reloads mihomo
- **Regex filtering** — include/exclude nodes by name pattern per group
- **Disk-level subscription cache** — falls back on fetch failure; only updated after successful parse
- **CRUD API** — add/update/delete groups at runtime

## Prerequisites

- [Mihomo](https://github.com/MetaCubeX/mihomo) installed and available in `PATH`
- For building Zig version: [Zig](https://ziglang.org/) 0.16+, libyaml, pcre2

## Install

### Download binary (recommended)

Download from [Releases](https://github.com/MasakiMu319/SurgeEnhancer/releases):
- `surge-enhancer-zig-macos-arm64` — smaller, faster
- `surge-enhancer-rust-macos-arm64` — alternative

### Build from source

```bash
# Zig (recommended)
cd zig && zig build -Doptimize=ReleaseFast

# Rust
cargo build --release
```

## Quick Start

1. Create `config.yaml` (see `config.example.yaml`)
2. Prepare a mihomo template YAML with your DNS/rules
3. Run:

```bash
surge-enhancer config.yaml
```

4. Point Surge to `http://127.0.0.1:9300/surge/group/YourGroup`
5. Open `http://127.0.0.1:9300` for the dashboard

## License

MIT
