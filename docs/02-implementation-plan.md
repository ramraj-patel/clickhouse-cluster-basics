# Implementation Plan

Each phase has its own branch and Docker Compose file. Later phases extend earlier ones — nothing gets thrown away.

## References

Official documentation to consult before making configuration or architecture decisions.

| Topic | Link |
|-------|------|
| ClickHouse Server Config | https://clickhouse.com/docs/en/operations/server-configuration-parameters/settings |
| MergeTree Engine Family | https://clickhouse.com/docs/en/engines/table-engines/mergetree-family |
| ReplicatedMergeTree | https://clickhouse.com/docs/en/engines/table-engines/mergetree-family/replication |
| Distributed Table Engine | https://clickhouse.com/docs/en/engines/table-engines/special/distributed |
| ClickHouse Keeper | https://clickhouse.com/docs/en/guides/sre/keeper/clickhouse-keeper |
| Cluster Configuration | https://clickhouse.com/docs/en/architecture/cluster-deployment |
| Users and Roles | https://clickhouse.com/docs/en/operations/access-rights |
| Prometheus Metrics | https://clickhouse.com/docs/en/operations/monitoring |
| clickhouse-backup | https://github.com/Altinity/clickhouse-backup |
| Docker Image | https://hub.docker.com/r/clickhouse/clickhouse-server |
| Grafana ClickHouse Dashboards | https://grafana.com/grafana/dashboards/?search=clickhouse |
| Materialized Views | https://clickhouse.com/docs/en/guides/developer/cascading-materialized-views |
| System Tables | https://clickhouse.com/docs/en/operations/system-tables |
| Production Tips | https://clickhouse.com/docs/en/operations/tips |
| PostHog ClickHouse Config | https://github.com/PostHog/posthog/tree/master/docker/clickhouse |
| Altinity Operator Examples | https://github.com/Altinity/clickhouse-operator/tree/master/docs/chi-examples |
| GitLab ClickHouse Docs | https://docs.gitlab.com/ee/development/database/clickhouse/ |

---

## Phase 1: Single Node Fundamentals

**Branch:** `phase-1-single-node`

**Goal:** Get comfortable with ClickHouse SQL, table engines, and data ingestion on a single server.

### Deliverables
- `docker-compose.yml` — single ClickHouse server
- `configs/clickhouse/` — server config and users config
- `sql/` — sample DDL and queries

**Key References:** MergeTree Engine Family, Materialized Views, System Tables, Docker Image

### Tasks
1. Docker Compose with one ClickHouse container
2. Basic server configuration (logging, ports, memory limits)
3. Create sample tables using different MergeTree variants:
   - `MergeTree` — base engine
   - `ReplacingMergeTree` — deduplication by version
   - `SummingMergeTree` — pre-aggregation
   - `AggregatingMergeTree` — custom aggregation states
4. Load sample dataset (NYC taxi, UK price paid, or synthetic events)
5. Practice queries: filtering, aggregation, `FINAL` keyword, system tables
6. Create a materialized view that pre-aggregates incoming data
7. Document learnings in `docs/notes/phase-1.md`

### Validation Steps

```bash
# 1. Container health
docker compose ps  # all containers should show "running"

# 2. HTTP interface responds
curl -s http://localhost:8123/ping  # expect: "Ok.\n"

# 3. Native client connects
docker compose exec clickhouse-server clickhouse-client --query "SELECT version()"

# 4. Tables exist with expected engines
docker compose exec clickhouse-server clickhouse-client --query \
  "SELECT name, engine FROM system.tables WHERE database = 'default' FORMAT PrettyCompact"

# 5. Sample data row count > 0
docker compose exec clickhouse-server clickhouse-client --query \
  "SELECT count() FROM default.<sample_table>"

# 6. Parts are healthy (no detached or broken)
docker compose exec clickhouse-server clickhouse-client --query \
  "SELECT table, count() AS parts, sum(rows) AS total_rows
   FROM system.parts WHERE active AND database = 'default'
   GROUP BY table FORMAT PrettyCompact"

# 7. Materialized view populates on insert
docker compose exec clickhouse-server clickhouse-client --multiquery --query "
  INSERT INTO default.<source_table> VALUES (...);
  SELECT count() FROM default.<mv_target_table>;
"
# count should increase after insert

# 8. No persistent errors in server log
docker compose logs clickhouse-server 2>&1 | grep -ic "error\|exception"
# expect: 0 or only startup noise
```

---

## Phase 2: ClickHouse Keeper + Replication

**Branch:** `phase-2-replication`

**Goal:** Add coordination and data replication across multiple ClickHouse nodes.

### Deliverables
- Extended `docker-compose.yml` — 3 Keeper nodes + 2 ClickHouse replicas (1 shard, 2 replicas)
- `configs/keeper/` — Keeper configuration for each node
- Updated ClickHouse configs with `<remote_servers>` and `<zookeeper>` sections

**Key References:** ClickHouse Keeper, ReplicatedMergeTree, Cluster Configuration

### Tasks
1. Set up 3 ClickHouse Keeper nodes (odd number for quorum)
2. Configure 2 ClickHouse servers as replicas of a single shard
3. Define `ReplicatedMergeTree` tables
4. Insert data on replica 1, verify it appears on replica 2
5. Kill one replica, write to the surviving one, bring it back — verify catch-up
6. Explore `system.replicas` and `system.replication_queue` tables
7. Document learnings in `docs/notes/phase-2.md`

### Validation Steps

```bash
# 1. All containers running
docker compose ps  # 3 keepers + 2 clickhouse nodes all "running"

# 2. Keeper quorum is healthy (run on any keeper node)
docker compose exec keeper-1 bash -c \
  "echo ruok | nc localhost 9181"  # expect: "imok"
docker compose exec keeper-1 bash -c \
  "echo mntr | nc localhost 9181"  # look for zk_server_state=leader or follower

# 3. ClickHouse sees Keeper connection
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT * FROM system.zookeeper WHERE path = '/' FORMAT PrettyCompact"

# 4. Replicated table exists on both nodes
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT name, engine FROM system.tables WHERE engine LIKE '%Replicated%' FORMAT PrettyCompact"
docker compose exec clickhouse-2 clickhouse-client --query \
  "SELECT name, engine FROM system.tables WHERE engine LIKE '%Replicated%' FORMAT PrettyCompact"

# 5. Write on replica 1, read from replica 2
docker compose exec clickhouse-1 clickhouse-client --query \
  "INSERT INTO default.<table> VALUES (...)"
sleep 2
docker compose exec clickhouse-2 clickhouse-client --query \
  "SELECT count() FROM default.<table>"
# count should include the new row

# 6. Replication health — no queue backlog
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT database, table, is_leader, queue_size, log_pointer, absolute_delay
   FROM system.replicas FORMAT PrettyCompact"
# queue_size should be 0, absolute_delay near 0

# 7. Failure recovery — kill replica 2, write, bring it back
docker compose stop clickhouse-2
docker compose exec clickhouse-1 clickhouse-client --query \
  "INSERT INTO default.<table> VALUES (...)"
docker compose start clickhouse-2
sleep 5
docker compose exec clickhouse-2 clickhouse-client --query \
  "SELECT count() FROM default.<table>"
# should match replica 1's count

# 8. Verify catch-up completed
docker compose exec clickhouse-2 clickhouse-client --query \
  "SELECT queue_size, absolute_delay FROM system.replicas FORMAT PrettyCompact"
# queue_size = 0 after catch-up
```

---

## Phase 3: Sharding + Distributed Queries

**Branch:** `phase-3-sharding`

**Goal:** Split data across multiple shards and query them transparently.

### Deliverables
- Extended `docker-compose.yml` — 2 shards x 2 replicas (4 ClickHouse nodes) + 3 Keepers
- Cluster topology configuration in `<remote_servers>`
- `Distributed` table definitions

**Key References:** Distributed Table Engine, Cluster Configuration

### Tasks
1. Expand to 2 shards, each with 2 replicas
2. Define local `ReplicatedMergeTree` tables on each shard
3. Create a `Distributed` table that spans both shards
4. Configure sharding key and understand data routing
5. Insert via the Distributed table, verify data lands on correct shards
6. Run cross-shard aggregation queries
7. Compare query performance: local table vs Distributed table
8. Document learnings in `docs/notes/phase-3.md`

### Validation Steps

```bash
# 1. All 7 containers running (4 CH nodes + 3 keepers)
docker compose ps

# 2. Cluster topology is correct
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT cluster, shard_num, replica_num, host_name
   FROM system.clusters WHERE cluster = '<cluster_name>'
   FORMAT PrettyCompact"
# expect: 2 shards, 2 replicas each

# 3. Insert via Distributed table, verify shard placement
docker compose exec clickhouse-1 clickhouse-client --query \
  "INSERT INTO default.<distributed_table> VALUES (...), (...), (...)"
# check row counts per shard — should split based on sharding key
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT hostName(), count() FROM default.<local_table> FORMAT PrettyCompact"
docker compose exec clickhouse-3 clickhouse-client --query \
  "SELECT hostName(), count() FROM default.<local_table> FORMAT PrettyCompact"
# rows should be distributed, not all on one shard

# 4. Distributed query aggregates across shards
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM default.<distributed_table>"
# should equal sum of all shard-local counts

# 5. Cross-shard aggregation returns correct results
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT <sharding_key_col>, count() FROM default.<distributed_table>
   GROUP BY <sharding_key_col> FORMAT PrettyCompact"

# 6. Replication within each shard is healthy
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT database, table, is_leader, queue_size, absolute_delay
   FROM system.replicas FORMAT PrettyCompact"
docker compose exec clickhouse-3 clickhouse-client --query \
  "SELECT database, table, is_leader, queue_size, absolute_delay
   FROM system.replicas FORMAT PrettyCompact"
# queue_size = 0 on all nodes

# 7. Performance comparison: local vs distributed
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM default.<local_table>" --time
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM default.<distributed_table>" --time
# distributed will be slightly slower due to network; document the difference
```

---

## Phase 4: Monitoring (Prometheus + Grafana)

**Branch:** `phase-4-monitoring`

**Goal:** Observe cluster health, query performance, and resource usage in real time.

### Deliverables
- Prometheus + Grafana added to `docker-compose.yml`
- `configs/prometheus/prometheus.yml` — scrape targets for all ClickHouse nodes
- `configs/grafana/` — provisioned datasource + dashboards
- Pre-built dashboard JSON(s)

**Key References:** Prometheus Metrics, Grafana ClickHouse Dashboards

### Tasks
1. Enable the built-in Prometheus endpoint on each ClickHouse node (port 9363)
2. Add Prometheus container with scrape config for all nodes
3. Add Grafana container with provisioned Prometheus datasource
4. Import or build dashboards covering:
   - Queries per second and query latency
   - Active merges and parts count
   - Memory and CPU usage
   - Replication lag and queue size
   - Inserted rows/bytes per second
5. Add basic alert rules (replication lag > threshold, memory > 80%)
6. Document dashboard usage in `docs/notes/phase-4.md`

### Validation Steps

```bash
# 1. Prometheus is scraping all targets
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {instance: .labels.instance, health: .health}'
# all targets should show "health": "up"

# 2. ClickHouse Prometheus endpoint responds on each node
curl -s http://localhost:9363/metrics | head -5
# should return Prometheus-format metrics lines

# 3. Key metrics exist in Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=ClickHouseProfileEvents_Query' | jq '.data.result | length'
# should be > 0 (one result per node)

# 4. Grafana is up and datasource is provisioned
curl -s http://localhost:3000/api/health  # expect: {"status":"ok",...}
curl -s -u admin:admin http://localhost:3000/api/datasources | jq '.[].name'
# should list the Prometheus datasource

# 5. Dashboards loaded without errors
curl -s -u admin:admin http://localhost:3000/api/search | jq '.[].title'
# should list imported ClickHouse dashboards

# 6. Generate load and verify metrics move
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM system.numbers LIMIT 10000000"
# then check Prometheus: query count metric should increment
curl -s 'http://localhost:9090/api/v1/query?query=ClickHouseProfileEvents_Query' | jq '.data.result[0].value[1]'

# 7. Simulate alert condition (if memory alert is configured)
# Run a memory-heavy query and check Prometheus alerts endpoint
curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {name: .labels.alertname, state: .state}'
```

---

## Phase 5: Operations and Production Hardening

**Branch:** `phase-5-production`

**Goal:** Apply production-grade practices to the cluster.

### Deliverables
- TLS certificates (self-signed for local use)
- Updated configs with TLS, users, quotas
- Backup/restore scripts
- Benchmark scripts

**Key References:** ClickHouse Server Config, Users and Roles, clickhouse-backup

### Tasks
1. Generate self-signed TLS certs; enable encrypted inter-node and client connections
2. Configure named users with role-based access (admin, reader, writer)
3. Set quotas and resource limits per user profile
4. Set up `clickhouse-backup` for automated snapshots
5. Test backup and restore workflow
6. Add Docker resource limits (CPU, memory) to all containers
7. Add health checks and restart policies
8. Run `clickhouse-benchmark` against the cluster under load
9. Document operational runbook in `docs/notes/phase-5.md`

### Validation Steps

```bash
# 1. TLS enforced — plain connection should fail
docker compose exec clickhouse-1 clickhouse-client --query "SELECT 1" --secure 2>&1
# should succeed with --secure
docker compose exec clickhouse-1 clickhouse-client --query "SELECT 1" --port 9000 2>&1
# should fail or be refused if requireTLSForNativeProtocol is set

# 2. Verify TLS certificate is served
echo | openssl s_client -connect localhost:9440 2>/dev/null | openssl x509 -noout -subject -dates

# 3. User access control — reader cannot write
docker compose exec clickhouse-1 clickhouse-client --user reader --password <pw> --query \
  "INSERT INTO default.<table> VALUES (...)" 2>&1
# expect: ACCESS_DENIED error
docker compose exec clickhouse-1 clickhouse-client --user reader --password <pw> --query \
  "SELECT count() FROM default.<table>"
# expect: success

# 4. Quotas enforced
docker compose exec clickhouse-1 clickhouse-client --user reader --password <pw> --query \
  "SELECT * FROM system.quota_usage FORMAT PrettyCompact"

# 5. Backup workflow
docker compose exec clickhouse-1 clickhouse-backup create test-backup
docker compose exec clickhouse-1 clickhouse-backup list  # should show test-backup
# restore to a fresh node or after dropping a table
docker compose exec clickhouse-1 clickhouse-client --query "DROP TABLE default.<table>"
docker compose exec clickhouse-1 clickhouse-backup restore test-backup
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM default.<table>"
# count should match pre-backup value

# 6. Container restart recovery
docker compose restart clickhouse-1
sleep 10
docker compose exec clickhouse-1 clickhouse-client --query "SELECT 1"  # should connect
docker compose exec clickhouse-1 clickhouse-client --query \
  "SELECT queue_size FROM system.replicas FORMAT PrettyCompact"
# queue_size should return to 0

# 7. Docker resource limits applied
docker inspect $(docker compose ps -q clickhouse-1) --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}'
# should show non-zero values matching compose config

# 8. Benchmark completes without errors
docker compose exec clickhouse-1 clickhouse-benchmark \
  --query "SELECT count() FROM default.<table>" \
  --iterations 100 --concurrency 4 2>&1 | tail -20
# look for: no OOM, no timeout, QPS and latency summary
```

---

## Phase 6: Production Gap Analysis

**Branch:** `phase-6-gap-analysis`

**Goal:** Compare our cluster setup against a real production-grade ClickHouse deployment to understand what's missing, what's over-simplified, and why production clusters make the choices they do.

### Deliverables
- `docs/notes/phase-6.md` — gap analysis report with rationale for each difference
- Updated configs or TODOs where gaps can be addressed locally

### Approach
1. Pick a well-documented production reference to compare against (candidates below)
2. Diff our setup against the reference across every category in the checklist
3. For each gap: document what production does, why, and whether it applies to us

### Reference Candidates (pick one or combine)
- [Altinity Kubernetes Operator examples](https://github.com/Altinity/clickhouse-operator/tree/master/docs/chi-examples) — production patterns even if we skip K8s
- [PostHog ClickHouse config](https://github.com/PostHog/posthog/tree/master/docker/clickhouse) — real SaaS-scale deployment
- [ClickHouse official production recommendations](https://clickhouse.com/docs/en/operations/tips)
- [GitLab ClickHouse usage docs](https://docs.gitlab.com/ee/development/database/clickhouse/) — enterprise patterns

### Comparison Checklist

**Cluster Topology**
- [ ] Shard count and replication factor rationale
- [ ] Keeper placement (co-located vs dedicated nodes)
- [ ] Network topology and failure domains

**Storage**
- [ ] Disk layout (separate disks for data, logs, tmp)
- [ ] Storage policies and tiered storage (hot/cold)
- [ ] Compression codec choices (`LZ4` vs `ZSTD` vs per-column)

**Configuration**
- [ ] `max_memory_usage` and memory overcommit protection
- [ ] `max_threads`, `max_concurrent_queries`
- [ ] Merge settings (`max_bytes_to_merge_at_max_space_in_pool`, etc.)
- [ ] `distributed_ddl` timeout and retry settings
- [ ] Mark cache and uncompressed cache sizing

**Schema Design**
- [ ] Partition key granularity (too fine = too many parts, too coarse = slow drops)
- [ ] Primary key / ORDER BY choices for query patterns
- [ ] TTL policies for data lifecycle
- [ ] Codec selection per column type

**Replication and Consistency**
- [ ] `insert_quorum` and `insert_quorum_parallel`
- [ ] `select_sequential_consistency`
- [ ] Replication queue monitoring and alerting thresholds

**Security**
- [ ] Network-level isolation beyond TLS
- [ ] Row-level and column-level access policies
- [ ] Audit logging

**Operational**
- [ ] Mutation management and kill strategies
- [ ] Part management (`OPTIMIZE`, `DETACH`, `DROP PARTITION`)
- [ ] Automated replica recovery
- [ ] Capacity planning signals (parts count growth, merge pressure)
- [ ] Upgrade and rollback strategy

**Monitoring Gaps**
- [ ] Metrics our Grafana dashboards miss vs production dashboards
- [ ] Log-based alerting (query log, error log patterns)
- [ ] Distributed query tracing

### Verification
- [ ] Every checklist item has a documented status: matches / gap / not applicable
- [ ] Each gap has a rationale explaining the production choice
- [ ] Actionable gaps are filed as TODOs or follow-up tasks

---

## How to Use This Plan

1. Start with [Prerequisites](03-prerequisites.md) to validate your environment
2. Read the [Reference Guide](04-reference-guide.md) alongside each phase — it explains the intent behind every config and query
3. Work through phases sequentially — each builds on the previous
4. Each phase has a branch so you can compare diffs between stages
5. The `docs/notes/` files are your learning journal — write what surprised you
6. The validation steps are your "definition of done" per phase
