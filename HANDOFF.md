# Session Handoff

> Last updated: 2026-08-17

## Current Phase

Phase 2 — Keeper + Replication (**complete**)

## What's Done

### Session 1 — Project Scaffolding
- Project documentation structure created and committed
  - `docs/01-problem-statement.md` — goals, constraints, non-goals
  - `docs/02-implementation-plan.md` — 6 phases with tasks, references, validation steps
  - `docs/03-prerequisites.md` — host tools, Docker images, ports, resource estimates, env validation script
  - `docs/04-reference-guide.md` — every config and query explained with intent
- `README.md` — repo entry point linking all docs
- `CLAUDE.md` — harness config (current phase, commands, conventions)
- `AGENTS.md` — agent rules, validation requirements, constraints
- Repo initialized and pointed to `https://github.com/ramraj-patel/clickhouse-cluster-basics.git`
- Initial commit: `e8ce6d2`

### Session 2 — Phase 1 Implementation Files
- `docker-compose.yml` — single ClickHouse node (`latest`/v26.6), health check, named volumes, ulimits
- `configs/clickhouse/config.xml` — logging, listen_host, HTTP/TCP ports, Prometheus metrics endpoint (9363)
- `configs/clickhouse/users.xml` — default user (no password), 4GB memory cap, 60s query timeout, hourly quotas
- `sql/01-create-tables.sql` — 4 tables: `trips` (MergeTree), `zone_fare_latest` (ReplacingMergeTree), `daily_stats` (SummingMergeTree), `daily_agg_stats` (AggregatingMergeTree)
- `sql/02-materialized-views.sql` — 2 MVs: `mv_daily_stats` (SummingMergeTree target), `mv_daily_agg_stats` (AggregatingMergeTree target with -State combinators)
- `sql/03-load-nyc-taxi.sql` — loads ~2M rows from ClickHouse public S3 bucket via `s3()` table function
- `sql/04-sample-queries.sql` — 10 sample queries covering all engine types, FINAL keyword, system tables
- `docs/notes/phase-1.md` — learning journal template with validation checklist
- SQL files mount to `/docker-entrypoint-initdb.d` for auto-execution on first startup

### Session 3 — Phase 1 Validation & Run
- Fixed `s3()` call to include `NOSIGN` for public bucket access (v26.7+ requirement)
- Fixed health check from `curl` to `wget` (newer ClickHouse image doesn't bundle curl)
- Started container, data loaded successfully (2M rows, ~2 min)
- All 8 validation steps passed (container health, HTTP ping, client connect, tables, row counts, parts, MVs, logs)
- All 10 sample queries executed and documented results
- Filled in `docs/notes/phase-1.md` with observations and checked off all validation items

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Docker Compose only, no K8s | Learning project — keep orchestration simple |
| ClickHouse Keeper, not ZooKeeper | Keeper is the modern replacement, fewer moving parts |
| Standalone Keeper image, not embedded | Clearer architecture separation for learning |
| 6 phases (added gap analysis as Phase 6) | Compare our setup against production deployments to understand real-world rationale |
| Hybrid handoff system | Single HANDOFF.md for current state + session archive for history |
| All tooling dockerized | Only Docker + CLI utils needed on host; reduces environment issues |
| `NOSIGN` for public S3 | v26.7+ blocks server credential passthrough; public buckets need explicit NOSIGN |
| `wget` for health check | Newer ClickHouse images dropped curl from the base image |
| Keeper `listen_host` = `0.0.0.0` | Default is localhost-only; Docker containers need cross-container access |
| Split CH configs by concern | `config.xml` (server), `users.xml` (access), `cluster.xml` (topology), `macros-*.xml` (per-node identity) |

### Session 4 — Phase 2: Keeper + Replication
- 3 ClickHouse Keeper nodes with Raft consensus
- 2 ClickHouse servers as replicas (1 shard, 2 replicas)
- `configs/keeper/keeper-{1,2,3}.xml` — per-node keeper configs with `listen_host` fix
- `configs/clickhouse/cluster.xml` — shared Keeper + cluster topology
- `configs/clickhouse/macros-node{1,2}.xml` — per-node replica identity
- `sql/05-create-replicated-tables.sql` — ReplicatedMergeTree with `ON CLUSTER`
- `docker-compose.yml` — 5-service cluster (3 keepers + 2 CH nodes)
- `docker-compose.phase1.yml` — preserved Phase 1 single-node config
- `docs/command-reference.md` — all Docker and SQL commands across phases
- `docs/notes/phase-2.md` — rationale Q&A, gotchas, observations, completed validation
- All validation steps passed: quorum, replication, failure recovery

## Open Questions

(none)

## Resolved Questions

| Question | Decision |
|----------|----------|
| Sample dataset | NYC Taxi (~2M rows via S3) |
| ClickHouse image version | `latest` (v26.7.3 at time of run) |

## Next Steps

1. Expand to 2 shards x 2 replicas (4 CH nodes + 3 keepers)
2. Create `Distributed` table spanning both shards
3. Configure sharding key and test data routing
4. Run cross-shard aggregation queries
5. Compare local vs Distributed query performance
6. Document learnings in `docs/notes/phase-3.md`
