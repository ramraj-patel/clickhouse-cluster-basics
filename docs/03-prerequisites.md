# Prerequisites

Everything runs in Docker — no local installation of ClickHouse, Prometheus, or Grafana needed. This checklist covers what your host machine must have.

## Required on Host

| Tool | Minimum Version | Check Command | Purpose |
|------|----------------|---------------|---------|
| Docker Engine | 24.0+ | `docker --version` | Container runtime |
| Docker Compose | 2.20+ (V2 plugin) | `docker compose version` | Multi-container orchestration |
| curl | any | `curl --version` | HTTP validation steps |
| openssl | any | `openssl version` | TLS cert generation (Phase 5) |
| jq | 1.6+ | `jq --version` | Parsing JSON in validation steps |

## Optional on Host

| Tool | When Needed | Check Command | Purpose |
|------|------------|---------------|---------|
| clickhouse-client | Never required | `clickhouse-client --version` | Connect from host instead of `docker exec`; all validation steps use the containerized client so this is purely convenience |
| netcat (nc) | Phase 2 validation | `nc -h` | Keeper health checks; falls back to `docker exec` if missing |
| git | All phases | `git --version` | Branch-per-phase workflow |

## Docker Images Used

All pulled automatically on first `docker compose up`. Listed here so you know what's coming.

| Image | First Used | Ports Exposed |
|-------|-----------|---------------|
| `clickhouse/clickhouse-server:latest` | Phase 1 | 8123 (HTTP), 9000 (native), 9363 (Prometheus metrics), 9440 (TLS native) |
| `clickhouse/clickhouse-keeper:latest` | Phase 2 | 9181 (Keeper client), 9234 (Keeper Raft) |
| `prom/prometheus:latest` | Phase 4 | 9090 (Prometheus UI + API) |
| `grafana/grafana:latest` | Phase 4 | 3000 (Grafana UI) |

Note: We use `clickhouse/clickhouse-keeper` as a standalone image. ClickHouse Keeper can also run embedded inside `clickhouse-server`, but separate containers make the architecture clearer for learning.

## Resource Requirements

| Phase | Containers | Estimated RAM | Estimated Disk |
|-------|-----------|--------------|----------------|
| 1 | 1 | ~1 GB | ~500 MB |
| 2 | 5 (3 keepers + 2 CH) | ~3 GB | ~1 GB |
| 3 | 7 (3 keepers + 4 CH) | ~4 GB | ~2 GB |
| 4 | 9 (+ Prometheus + Grafana) | ~5 GB | ~3 GB |
| 5 | 9 (same + TLS overhead) | ~5 GB | ~3 GB |

Recommended host: 8 GB+ RAM, 10 GB+ free disk.

## Network Ports

Ensure these host ports are free before starting. If any conflict, update the port mappings in `docker-compose.yml`.

| Port | Service | Protocol |
|------|---------|----------|
| 8123 | ClickHouse HTTP | HTTP |
| 9000 | ClickHouse native | TCP |
| 9363 | ClickHouse metrics | HTTP (Prometheus) |
| 9440 | ClickHouse native TLS | TCP (Phase 5) |
| 9090 | Prometheus | HTTP (Phase 4) |
| 3000 | Grafana | HTTP (Phase 4) |

## Quick Validation

Run this before starting Phase 1 to confirm your environment is ready:

```bash
# Check all required tools
docker --version && \
docker compose version && \
curl --version | head -1 && \
jq --version && \
openssl version && \
echo "--- All prerequisites met ---"

# Verify Docker daemon is running
docker info > /dev/null 2>&1 && echo "Docker daemon: OK" || echo "Docker daemon: NOT RUNNING"

# Check available disk space (need ~10 GB free)
df -h . | tail -1

# Check available RAM
# macOS:
sysctl -n hw.memsize | awk '{printf "%.1f GB\n", $1/1073741824}'
# Linux:
# free -h | awk '/Mem:/{print $2}'

# Test port availability (Phase 1 ports)
for port in 8123 9000 9363; do
  (echo > /dev/tcp/localhost/$port) 2>/dev/null && echo "Port $port: IN USE (conflict)" || echo "Port $port: free"
done
```
