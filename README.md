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
git clone https://github.com/ramraj-patel/clickhouse-cluster-basics.git
cd clickhouse-cluster-basics
git fetch --tags
```

Each completed phase is tagged so you can check out that snapshot (Compose, server, and Keeper configs) and validate it:

| Tag | What you get | Start |
|-----|--------------|-------|
| `phase1` | Single ClickHouse node | `docker compose -f docker-compose.phase1.yml up -d` |
| `phase2` | 3 Keepers + 2 replicas (1 shard) | `docker compose up -d` |

```bash
# Phase 1 — single node
git checkout phase1
docker compose -f docker-compose.phase1.yml up -d
docker compose -f docker-compose.phase1.yml exec clickhouse-server clickhouse-client

# Phase 2 — Keeper + replication
git checkout phase2
docker compose up -d
docker compose exec clickhouse-1 clickhouse-client
```

Validation steps for each phase are in the [implementation plan](docs/02-implementation-plan.md). Commands for Phase 2+ are in the [command reference](docs/command-reference.md) (that file was added in Phase 2).

See [Prerequisites](docs/03-prerequisites.md) for the full environment checklist.

## License

Apache 2.0 — see [LICENSE](LICENSE).
