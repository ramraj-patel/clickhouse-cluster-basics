# Reference Guide — Configs, Queries, and Intent

This document explains the **why** behind every configuration block and query used across phases. Read this alongside the implementation plan to understand the rationale, not just the syntax.

---

## Table of Contents

- [ClickHouse Server Configuration](#clickhouse-server-configuration)
- [MergeTree Engine Family](#mergetree-engine-family)
- [Materialized Views](#materialized-views)
- [ClickHouse Keeper Configuration](#clickhouse-keeper-configuration)
- [Replication Configuration](#replication-configuration)
- [Sharding and Distributed Tables](#sharding-and-distributed-tables)
- [Prometheus Metrics Configuration](#prometheus-metrics-configuration)
- [Key System Tables](#key-system-tables)
- [Common Diagnostic Queries](#common-diagnostic-queries)

---

## ClickHouse Server Configuration

### Minimal server config (Phase 1)

```xml
<clickhouse>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse-server/clickhouse-server.log</log>
        <errorlog>/var/log/clickhouse-server/clickhouse-server.err.log</errorlog>
        <size>100M</size>
        <count>3</count>
    </logger>

    <listen_host>0.0.0.0</listen_host>

    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
</clickhouse>
```

| Element | Intent |
|---------|--------|
| `<level>information</level>` | Default log level. Use `trace` only when debugging specific issues — it generates enormous output. |
| `<listen_host>0.0.0.0</listen_host>` | Accept connections from any interface. Required inside Docker because the client connects from outside the container's network namespace. In production, bind to specific interfaces. |
| `<size>100M</size>` / `<count>3</count>` | Rotate logs at 100 MB, keep 3 rotations. Prevents unbounded log growth inside the container volume. |
| `<http_port>` / `<tcp_port>` | HTTP is for REST API, dashboards, and health checks. TCP (native protocol) is for `clickhouse-client` and inter-node communication — it's faster and supports streaming. |

### Users config (Phase 1)

```xml
<clickhouse>
    <users>
        <default>
            <password></password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>
    </users>

    <profiles>
        <default>
            <max_memory_usage>4000000000</max_memory_usage>
            <max_execution_time>60</max_execution_time>
        </default>
    </profiles>

    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>1000</queries>
                <read_rows>1000000000</read_rows>
            </interval>
        </default>
    </quotas>
</clickhouse>
```

| Element | Intent |
|---------|--------|
| `<password></password>` | Empty password for local learning. Phase 5 replaces this with named users and real passwords. |
| `<ip>::/0</ip>` | Allow connections from any IP. Safe inside Docker networking; in production, restrict to known CIDRs. |
| `<max_memory_usage>` | Per-query memory cap (4 GB here). Without this, a single bad query can OOM the server. This is the single most important safety setting. |
| `<max_execution_time>` | Kill queries running longer than 60 seconds. Prevents runaway analytical queries from blocking the server. |
| `<quotas>` | Rate limiting per time interval. `queries: 1000` per hour prevents accidental query storms during learning. |

---

## MergeTree Engine Family

### MergeTree — the base engine

```sql
CREATE TABLE events (
    event_date Date,
    event_time DateTime,
    user_id    UInt64,
    event_type String,
    payload    String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_time);
```

| Clause | Intent |
|--------|--------|
| `PARTITION BY toYYYYMM(event_date)` | Groups data into monthly partitions. Each partition is a separate directory on disk. This enables efficient `DROP PARTITION` for data lifecycle (delete an entire month instantly) and limits the scope of merges. **Too fine** (daily on low-volume data) = thousands of tiny parts. **Too coarse** (yearly) = slow drops and large merges. Monthly is a safe default. |
| `ORDER BY (user_id, event_time)` | **This is not a primary key in the RDBMS sense.** It determines the physical sort order on disk. ClickHouse reads data in sorted order and skips granules (blocks of 8192 rows by default) that don't match the query's WHERE clause. Put the most frequently filtered column first. Here, queries like `WHERE user_id = X` will skip most granules. |

**Key concept — ORDER BY vs PRIMARY KEY:**
In ClickHouse, `ORDER BY` defines both the sort order AND the primary key index by default. You can decouple them with an explicit `PRIMARY KEY` clause (a prefix of `ORDER BY`), but for most cases they're the same. The "primary key" is a sparse index — it stores one value per granule, not per row.

### ReplacingMergeTree — last-write-wins deduplication

```sql
CREATE TABLE user_profiles (
    user_id    UInt64,
    name       String,
    email      String,
    updated_at DateTime
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY user_id;
```

| Clause | Intent |
|--------|--------|
| `ReplacingMergeTree(updated_at)` | During background merges, if multiple rows share the same `ORDER BY` key (`user_id`), keep only the row with the highest `updated_at`. This is eventual deduplication — duplicates exist between merges. Use `FINAL` in queries to force dedup at read time: `SELECT * FROM user_profiles FINAL`. |

**When to use:** Mutable entity tables (user profiles, device state) where you INSERT updates as new rows and want the latest version.

**Gotcha:** `FINAL` forces a merge at query time, which is slower. For hot paths, consider a materialized view on top.

### SummingMergeTree — automatic pre-aggregation

```sql
CREATE TABLE daily_counts (
    date       Date,
    source     String,
    hits       UInt64,
    bytes      UInt64
)
ENGINE = SummingMergeTree((hits, bytes))
ORDER BY (date, source);
```

| Clause | Intent |
|--------|--------|
| `SummingMergeTree((hits, bytes))` | During merges, rows with the same `ORDER BY` key are collapsed into one, summing the specified numeric columns. Reduces storage and speeds up `GROUP BY` queries on pre-aggregated data. |

**When to use:** Counters, metrics, rollups — anywhere you're doing `SUM(x) GROUP BY dimensions`.

**Gotcha:** Non-summed columns (not in the tuple) get an arbitrary value from one of the merged rows. Don't rely on them for anything meaningful.

### AggregatingMergeTree — custom aggregation states

```sql
CREATE TABLE session_stats (
    date       Date,
    source     String,
    uniq_users AggregateFunction(uniq, UInt64),
    avg_duration AggregateFunction(avg, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY (date, source);
```

```sql
-- Insert using -State combinators
INSERT INTO session_stats
SELECT
    toDate(event_time) AS date,
    source,
    uniqState(user_id),
    avgState(duration)
FROM raw_events
GROUP BY date, source;

-- Query using -Merge combinators
SELECT
    date,
    source,
    uniqMerge(uniq_users) AS unique_users,
    avgMerge(avg_duration) AS avg_dur
FROM session_stats
GROUP BY date, source;
```

| Concept | Intent |
|---------|--------|
| `AggregateFunction(uniq, UInt64)` | Stores the intermediate state of a `uniq` aggregation, not a final number. This lets merges combine states correctly — you can't just sum unique counts. |
| `-State` / `-Merge` combinators | `-State` produces the intermediate state during INSERT. `-Merge` finalizes it during SELECT. This two-phase pattern is what makes it possible to pre-aggregate complex functions like `uniq`, `quantile`, `avg`. |

**When to use:** When you need pre-aggregated rollups for functions that aren't simple sums (uniques, percentiles, averages).

---

## Materialized Views

```sql
-- Source table: raw incoming events
CREATE TABLE raw_events (
    event_time DateTime,
    user_id    UInt64,
    action     String,
    duration   Float64
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (user_id, event_time);

-- Target table: hourly rollup
CREATE TABLE hourly_rollup (
    hour       DateTime,
    action     String,
    total      UInt64,
    avg_dur    Float64
)
ENGINE = SummingMergeTree((total))
ORDER BY (hour, action);

-- Materialized view: automatically populates hourly_rollup on insert to raw_events
CREATE MATERIALIZED VIEW raw_to_hourly
TO hourly_rollup
AS SELECT
    toStartOfHour(event_time) AS hour,
    action,
    count() AS total,
    avg(duration) AS avg_dur
FROM raw_events
GROUP BY hour, action;
```

| Concept | Intent |
|---------|--------|
| `TO hourly_rollup` | Routes the MV output to an explicit target table. Without `TO`, ClickHouse creates a hidden `.inner` table — using an explicit target is clearer and lets you query the rollup directly. |
| Triggered on INSERT | MVs in ClickHouse are insert triggers, not periodically refreshed views. Every batch inserted into `raw_events` fires the MV's SELECT against that batch only, and inserts the result into `hourly_rollup`. The MV never scans the full source table — it processes incrementally. |
| SummingMergeTree as target | Because each INSERT batch produces a partial aggregation, the target needs an engine that merges partial results. SummingMergeTree sums `total` across batches with the same `(hour, action)` key. |

**Gotcha:** The MV SELECT runs against each inserted block independently. If two separate INSERTs each contain rows for the same hour, you get two partial rows that merge later. This is fine for SummingMergeTree but subtle for AggregatingMergeTree — always use `-State`/`-Merge` combinators there.

---

## ClickHouse Keeper Configuration

### Single Keeper node config (Phase 2)

```xml
<clickhouse>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>1</server_id>

        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
        </coordination_settings>

        <raft_configuration>
            <server>
                <id>1</id>
                <hostname>keeper-1</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>2</id>
                <hostname>keeper-2</hostname>
                <port>9234</port>
            </server>
            <server>
                <id>3</id>
                <hostname>keeper-3</hostname>
                <port>9234</port>
            </server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
```

| Element | Intent |
|---------|--------|
| `<server_id>1</server_id>` | Unique ID for this Keeper node within the Raft cluster. Each of the 3 nodes gets a different ID (1, 2, 3). The Raft protocol uses these IDs for leader election and log replication. |
| `<tcp_port>9181</tcp_port>` | Port for ClickHouse servers to connect to Keeper (analogous to ZooKeeper's 2181). ClickHouse nodes point their `<zookeeper>` config at this port. |
| `<port>9234</port>` | Inter-Keeper Raft communication port. Keeper nodes use this to replicate the consensus log and elect leaders. Not exposed to ClickHouse servers. |
| `<operation_timeout_ms>` | How long a single Keeper operation (create znode, set data) can take before timing out. 10s is generous for local Docker; production may tighten this. |
| `<session_timeout_ms>` | If a ClickHouse server doesn't heartbeat within this window, Keeper considers it dead and releases its ephemeral nodes. 30s is standard; too low = false positives on slow networks, too high = slow failure detection. |

**Why 3 nodes:** Raft requires a majority quorum. With 3 nodes, the cluster tolerates 1 failure. With 5, it tolerates 2. For learning, 3 is the minimum meaningful cluster. Even numbers (2, 4) give no benefit — losing half the nodes loses quorum either way.

---

## Replication Configuration

### ClickHouse server pointing to Keeper (Phase 2)

```xml
<clickhouse>
    <zookeeper>
        <node>
            <host>keeper-1</host>
            <port>9181</port>
        </node>
        <node>
            <host>keeper-2</host>
            <port>9181</port>
        </node>
        <node>
            <host>keeper-3</host>
            <port>9181</port>
        </node>
    </zookeeper>

    <macros>
        <shard>01</shard>
        <replica>clickhouse-1</replica>
        <cluster>learning_cluster</cluster>
    </macros>
</clickhouse>
```

| Element | Intent |
|---------|--------|
| `<zookeeper>` | Despite the name, this section works with ClickHouse Keeper too. Lists all Keeper nodes so the ClickHouse server can find the consensus cluster. Multiple nodes provide failover — if keeper-1 is down, it tries keeper-2. |
| `<macros>` | Template variables used in `ReplicatedMergeTree` table definitions. Instead of hardcoding shard/replica names in every CREATE TABLE, you use `{shard}` and `{replica}` placeholders. Each ClickHouse node sets different macro values, so the same DDL creates correctly-named replicas everywhere. |

### ReplicatedMergeTree table using macros

```sql
CREATE TABLE events ON CLUSTER '{cluster}'
(
    event_date Date,
    event_time DateTime,
    user_id    UInt64,
    event_type String
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/events',
    '{replica}'
)
PARTITION BY toYYYYMM(event_date)
ORDER BY (user_id, event_time);
```

| Argument | Intent |
|----------|--------|
| First arg: ZooKeeper path | `/clickhouse/tables/{shard}/events` — the path in Keeper where this table's replication metadata lives. The `{shard}` macro ensures each shard has its own path. All replicas of the same shard share the same path — that's how they know to replicate to each other. |
| Second arg: replica name | `{replica}` — unique identifier for this replica within the shard. Comes from the `<macros>` config. Two replicas in the same shard must have different replica names but the same ZooKeeper path. |
| `ON CLUSTER '{cluster}'` | Executes this DDL on all nodes in the cluster via distributed DDL. Without it, you'd have to run the CREATE TABLE on each node manually. |

**How replication works:** When you INSERT into replica A, it writes the data locally and logs the operation in Keeper. Replica B watches that log and pulls the data. There's no "master" — any replica can accept writes. Keeper coordinates who has what, not where writes go.

---

## Sharding and Distributed Tables

### Cluster topology config (Phase 3)

```xml
<clickhouse>
    <remote_servers>
        <learning_cluster>
            <shard>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>clickhouse-1</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-2</host>
                    <port>9000</port>
                </replica>
            </shard>
            <shard>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>clickhouse-3</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>clickhouse-4</host>
                    <port>9000</port>
                </replica>
            </shard>
        </learning_cluster>
    </remote_servers>
</clickhouse>
```

| Element | Intent |
|---------|--------|
| `<learning_cluster>` | Cluster name — referenced in `ON CLUSTER` DDL and `Distributed` table definitions. |
| `<shard>` (two blocks) | Each shard holds a different subset of the data. Shard 1 has clickhouse-1 and clickhouse-2 as replicas; shard 2 has clickhouse-3 and clickhouse-4. |
| `<internal_replication>true</internal_replication>` | **Critical setting.** When true, the Distributed table sends each INSERT to only one replica per shard, and ReplicatedMergeTree handles replication to the other. When false, the Distributed table sends to ALL replicas, causing duplicates if ReplicatedMergeTree is also active. Always `true` with ReplicatedMergeTree. |

### Distributed table definition

```sql
CREATE TABLE events_distributed ON CLUSTER '{cluster}'
(
    event_date Date,
    event_time DateTime,
    user_id    UInt64,
    event_type String
)
ENGINE = Distributed(
    '{cluster}',
    'default',
    'events',
    sipHash64(user_id)
);
```

| Argument | Intent |
|----------|--------|
| `'{cluster}'` | Which cluster topology to use (from `<remote_servers>`). |
| `'default'` | Database name on each shard where the local table lives. |
| `'events'` | Local table name on each shard (the ReplicatedMergeTree table). |
| `sipHash64(user_id)` | **Sharding key expression.** Determines which shard receives each row. `sipHash64` produces a uniform hash; the Distributed engine takes `hash % num_shards` to pick the shard. All events for the same `user_id` land on the same shard — this enables efficient per-user queries without cross-shard joins. |

**How queries work:**
- **INSERT into Distributed:** The node hashes each row's sharding key and forwards it to the correct shard. With `internal_replication=true`, only one replica per shard receives the write.
- **SELECT from Distributed:** The query is sent to all shards in parallel. Each shard runs it against its local data and returns partial results. The initiating node merges them (re-applies GROUP BY, ORDER BY, LIMIT).

---

## Prometheus Metrics Configuration

### Enabling the metrics endpoint (Phase 4)

```xml
<clickhouse>
    <prometheus>
        <endpoint>/metrics</endpoint>
        <port>9363</port>
        <metrics>true</metrics>
        <events>true</events>
        <asynchronous_metrics>true</asynchronous_metrics>
    </prometheus>
</clickhouse>
```

| Element | Intent |
|---------|--------|
| `<metrics>true</metrics>` | Exposes `system.metrics` — current gauge values (active queries, active merges, memory used, open connections). These are point-in-time snapshots. |
| `<events>true</events>` | Exposes `system.events` — cumulative counters (total queries, total inserted rows, total failed queries). Prometheus computes rates from these. |
| `<asynchronous_metrics>true</asynchronous_metrics>` | Exposes background metrics updated every ~60 seconds (uptime, max part count, replica queue size). Lower overhead but less granular. |

### Prometheus scrape config

```yaml
scrape_configs:
  - job_name: 'clickhouse'
    scrape_interval: 15s
    static_configs:
      - targets:
          - 'clickhouse-1:9363'
          - 'clickhouse-2:9363'
          - 'clickhouse-3:9363'
          - 'clickhouse-4:9363'
        labels:
          cluster: 'learning_cluster'
```

| Setting | Intent |
|---------|--------|
| `scrape_interval: 15s` | How often Prometheus pulls metrics. 15s is standard; shorter intervals increase storage and load with minimal insight gain for learning. |
| `labels: cluster` | Custom label added to all metrics from these targets. Enables filtering in Grafana: `{cluster="learning_cluster"}`. |

---

## Key System Tables

These are your diagnostic toolbox. ClickHouse exposes its internals through system tables — no external tooling needed.

| Table | What It Tells You | When to Use |
|-------|-------------------|-------------|
| `system.parts` | Every data part on disk — name, rows, bytes, partition, active/inactive | Check part count, detect too many small parts, verify merges are happening |
| `system.merges` | Currently running merge operations | Diagnose slow inserts (merge backlog), check merge progress |
| `system.replicas` | Replication state per table — leader status, queue size, delay | First place to look when replication seems broken |
| `system.replication_queue` | Pending replication tasks | Identify stuck or failed replication entries |
| `system.query_log` | Historical query execution — duration, memory, rows read, exceptions | Performance analysis, finding slow queries |
| `system.clusters` | Configured cluster topology — shards, replicas, hosts | Verify cluster config is loaded correctly |
| `system.metrics` | Live gauges — active queries, connections, memory | Real-time health check |
| `system.events` | Cumulative counters — total queries, inserts, errors | Rate-of-change analysis |
| `system.disks` | Disk usage and free space | Capacity monitoring |
| `system.mutations` | Running and completed ALTER TABLE mutations | Check if mutations are stuck |

---

## Common Diagnostic Queries

### Health check — is the server overloaded?

```sql
SELECT
    metric, value
FROM system.metrics
WHERE metric IN (
    'Query', 'Merge', 'MemoryTracking',
    'TCPConnection', 'HTTPConnection'
)
FORMAT PrettyCompact;
```

Intent: Quick snapshot of active load. `Query` > 50 or `MemoryTracking` near `max_memory_usage` means the server is stressed.

### Part count per table — are merges keeping up?

```sql
SELECT
    database, table,
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY active_parts DESC
FORMAT PrettyCompact;
```

Intent: If `active_parts` grows past ~300 for a single table, merges aren't keeping up. This causes slower queries (more parts to scan) and eventually write rejections (`too many parts`).

### Replication lag — is replica B behind?

```sql
SELECT
    database, table,
    is_leader,
    queue_size,
    absolute_delay,
    last_queue_update
FROM system.replicas
FORMAT PrettyCompact;
```

Intent: `queue_size > 0` means there are pending replication tasks. `absolute_delay` shows seconds behind. Both should be near zero in steady state.

### Slow queries — what's taking long?

```sql
SELECT
    query_id,
    user,
    query_duration_ms,
    read_rows,
    formatReadableSize(memory_usage) AS peak_mem,
    substring(query, 1, 100) AS query_preview
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 20
FORMAT PrettyCompact;
```

Intent: Find queries exceeding 1 second. Check `read_rows` — if a query reads millions of rows for a simple filter, the ORDER BY key probably doesn't match the WHERE clause.

### Cluster topology — is the config loaded correctly?

```sql
SELECT
    cluster, shard_num, replica_num,
    host_name, port, is_local
FROM system.clusters
WHERE cluster = 'learning_cluster'
FORMAT PrettyCompact;
```

Intent: Verify that `<remote_servers>` config was parsed correctly. If a shard or replica is missing here, the config file has a typo.

### Disk usage — how much space is left?

```sql
SELECT
    name,
    formatReadableSize(total_space) AS total,
    formatReadableSize(free_space) AS free,
    round(free_space * 100.0 / total_space, 1) AS free_pct
FROM system.disks
FORMAT PrettyCompact;
```

Intent: ClickHouse stops accepting writes if disk fills up. Monitor `free_pct` — alert below 20%.
