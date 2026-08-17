# ClickHouse Cluster Basics

A hands-on learning project for building a ClickHouse cluster from a single node to a production-ready multi-node setup with Grafana monitoring. Everything runs locally via Docker Compose.

## Documentation

| Doc | Description |
|-----|-------------|
| [Prerequisites](docs/03-prerequisites.md) | Tools, Docker images, ports, and resource requirements |
| [Problem Statement](docs/01-problem-statement.md) | Goals, constraints, and non-goals |
| [Implementation Plan](docs/02-implementation-plan.md) | 6 phases with tasks, references, and validation steps |
| [Reference Guide](docs/04-reference-guide.md) | Every config block and query explained with intent |

## Phases

1. **Single Node Fundamentals** — MergeTree engines, SQL, materialized views
2. **Keeper + Replication** — 3 Keeper nodes, ReplicatedMergeTree, failover testing
3. **Sharding + Distributed Queries** — 2 shards x 2 replicas, Distributed table engine
4. **Monitoring** — Prometheus + Grafana dashboards and alerts
5. **Production Hardening** — TLS, RBAC, backups, benchmarking
6. **Production Gap Analysis** — Compare against real-world deployments, document rationale

## Quick Start

```bash
# Verify prerequisites
docker --version && docker compose version && echo "Ready"

# Start Phase 1
docker compose up -d

# Connect
docker compose exec clickhouse-server clickhouse-client
```

See [Prerequisites](docs/03-prerequisites.md) for the full environment checklist.

## License

Apache 2.0 — see [LICENSE](LICENSE).
