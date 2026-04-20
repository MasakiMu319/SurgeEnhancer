# Surge Enhancer

Proxy subscription manager that bridges [Surge](https://nssurge.com/) with [Mihomo](https://github.com/MetaCubeX/mihomo) (Clash.Meta), enabling Surge to use proxy protocols it doesn't natively support (SS, VMess, VLESS, Trojan, Hysteria2, etc.) via a single Mihomo process.

## Problem

Surge's `external-proxy` feature spawns **one process per node** — unacceptable for 50–200 nodes. Surge Enhancer uses Mihomo as a single-process middleware with one SOCKS5 listener per node, so Surge connects to each as a regular `socks5` proxy.

```
Surge → (socks5) → Mihomo (127.0.0.1:PORT) → (ss/vmess/...) → Remote Server
```

## Features

- **Multi-subscription support** — fetch from multiple providers, each as a "group"
- **Format auto-detection** — Clash YAML, base64-encoded URI lists, plain URI lists
- **Mihomo config generation** — merges proxies + listeners into your mihomo template
- **Surge-compatible HTTP API** — `policy-path=http://127.0.0.1:9300/surge/group/ProviderA`
- **HTMX dashboard** — view node status, trigger refreshes, test delays
- **Scheduled refresh** — periodically re-fetches subscriptions and reloads mihomo
- **Regex filtering** — include/exclude nodes by name pattern per group

## Quick Start

1. Create `config.yaml` (see `config.example.yaml`)
2. Prepare a mihomo template YAML with your DNS/rules
3. Run: `cargo run -- -c config.yaml`
4. Point Surge to `http://127.0.0.1:9300/surge/group/YourGroup`

## HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | HTMX dashboard |
| GET | `/surge/proxies` | All nodes as Surge proxy list |
| GET | `/surge/group/:name` | Specific group's nodes |
| GET | `/surge/config` | Full Surge `[Proxy]` + `[Proxy Group]` snippet |
| POST | `/refresh` | Trigger refresh for all groups |
| POST | `/refresh/:name` | Trigger refresh for one group |
| GET | `/status` | JSON status (for dashboard) |
| GET | `/api/delay/:name` | Test node delay via mihomo |

## License

MIT
