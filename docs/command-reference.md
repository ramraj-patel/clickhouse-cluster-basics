# Command Reference

All Docker and SQL commands used throughout the project, organized by phase.

---

## Phase 1 — Single Node

### Docker

```bash
# Start (uses docker-compose.phase1.yml for single node)
docker compose -f docker-compose.phase1.yml up -d

# Check container status
docker compose -f docker-compose.phase1.yml ps

# HTTP health check
curl -s http://localhost:8123/ping

# Open interactive ClickHouse client
docker compose -f docker-compose.phase1.yml exec clickhouse-server clickhouse-client

# Run a one-off query
docker compose -f docker-compose.phase1.yml exec clickhouse-server clickhouse-client --query "SELECT version()"

# View logs
docker compose -f docker-compose.phase1.yml logs clickhouse-server

# Stop and remove containers (keep data)
docker compose -f docker-compose.phase1.yml down

# Stop and remove containers AND data
docker compose -f docker-compose.phase1.yml down -v
```

### SQL — Table Exploration

```sql
-- Version
SELECT version();

-- List tables and engines
SELECT name, engine FROM system.tables WHERE database = 'default';

-- Row counts across all tables
SELECT 'trips' AS tbl, count() FROM trips
UNION ALL SELECT 'daily_stats', count() FROM daily_stats
UNION ALL SELECT 'daily_agg_stats', count() FROM daily_agg_stats
UNION ALL SELECT 'zone_fare_latest', count() FROM zone_fare_latest;

-- Part health and disk usage
SELECT table, count() AS parts, sum(rows) AS total_rows,
       formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts WHERE active AND database = 'default'
GROUP BY table ORDER BY total_rows DESC;
```

### SQL — Query Examples

```sql
-- Top 10 pickup zones
SELECT pickup_ntaname, count() AS trips,
       round(avg(fare_amount), 2) AS avg_fare,
       round(avg(tip_amount), 2) AS avg_tip
FROM trips GROUP BY pickup_ntaname ORDER BY trips DESC LIMIT 10;

-- Hourly trip distribution
SELECT toHour(pickup_datetime) AS hour, count() AS trips
FROM trips GROUP BY hour ORDER BY hour;

-- Revenue by payment type
SELECT payment_type, count() AS trips, round(sum(total_amount), 2) AS revenue
FROM trips GROUP BY payment_type ORDER BY revenue DESC;

-- SummingMergeTree rollup
SELECT date, pickup_ntaname, trip_count, round(total_revenue, 2) AS revenue
FROM daily_stats ORDER BY trip_count DESC LIMIT 10;

-- AggregatingMergeTree rollup (must use -Merge combinators)
SELECT date, pickup_ntaname,
       uniqMerge(uniq_passengers) AS unique_passengers,
       round(avgMerge(avg_distance), 2) AS avg_dist
FROM daily_agg_stats GROUP BY date, pickup_ntaname
ORDER BY unique_passengers DESC LIMIT 10;
```

### SQL — ReplacingMergeTree & FINAL

```sql
-- Populate zone stats
INSERT INTO zone_fare_latest (pickup_ntaname, avg_fare, avg_tip, trip_count)
SELECT pickup_ntaname, round(avg(fare_amount), 2), round(avg(tip_amount), 2), count()
FROM trips GROUP BY pickup_ntaname;

-- Without FINAL — may show duplicates
SELECT pickup_ntaname, trip_count, updated_at
FROM zone_fare_latest ORDER BY trip_count DESC LIMIT 5;

-- With FINAL — deduplicated on read
SELECT pickup_ntaname, trip_count, updated_at
FROM zone_fare_latest FINAL ORDER BY trip_count DESC LIMIT 5;

-- Force physical merge (dedup on disk)
OPTIMIZE TABLE zone_fare_latest FINAL;
```

### SQL — System Introspection

```sql
-- Active merges
SELECT database, table, elapsed, progress, num_parts, result_part_name
FROM system.merges;

-- Server health metrics
SELECT metric, value FROM system.metrics
WHERE metric IN ('Query', 'Merge', 'MemoryTracking', 'TCPConnection');
```

### Prometheus Metrics

```bash
# Raw metrics endpoint
curl -s http://localhost:9363/metrics | head -20
```

---

## Phase 2 — Keeper + Replication

### Docker

```bash
# Start the full cluster (3 keepers + 2 CH nodes)
docker compose up -d

# Check all 5 containers
docker compose ps

# Connect to clickhouse-1
docker compose exec clickhouse-1 clickhouse-client

# Connect to clickhouse-2
docker compose exec clickhouse-2 clickhouse-client

# Run query on a specific node
docker compose exec clickhouse-1 clickhouse-client --query "SELECT version()"
docker compose exec clickhouse-2 clickhouse-client --query "SELECT version()"

# Stop one replica (for failure testing)
docker compose stop clickhouse-2

# Bring it back
docker compose start clickhouse-2

# View logs for a specific service
docker compose logs clickhouse-1
docker compose logs keeper-1

# Tear down everything
docker compose down -v
```

### Keeper Health

```bash
# Is Keeper alive? (four-letter command)
echo ruok | nc localhost 9181

# Keeper stats (shows leader/follower, connections, latency)
echo mntr | nc localhost 9181

# Keeper config
echo conf | nc localhost 9181
```

### SQL — Cluster Verification

```sql
-- Verify Keeper connectivity
SELECT * FROM system.zookeeper WHERE path = '/';

-- Cluster topology
SELECT cluster, shard_num, replica_num, host_name
FROM system.clusters WHERE cluster = 'cluster_1s2r';

-- Check macros (should differ per node)
SELECT * FROM system.macros;
```

### SQL — Create Replicated Table

```sql
-- Creates on both nodes via Keeper coordination
CREATE TABLE IF NOT EXISTS trips_replicated ON CLUSTER cluster_1s2r (
    trip_id              UInt32,
    pickup_datetime      DateTime,
    dropoff_datetime     DateTime,
    pickup_longitude     Float64,
    pickup_latitude      Float64,
    dropoff_longitude    Float64,
    dropoff_latitude     Float64,
    passenger_count      UInt8,
    trip_distance        Float64,
    fare_amount          Float64,
    extra                Float64,
    tip_amount           Float64,
    tolls_amount         Float64,
    total_amount         Float64,
    payment_type         Enum8('CSH' = 1, 'CRE' = 2, 'NOC' = 3, 'DIS' = 4, 'UNK' = 5),
    pickup_ntaname       LowCardinality(String),
    dropoff_ntaname      LowCardinality(String)
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/trips_replicated',
    '{replica}'
)
PARTITION BY toYYYYMM(pickup_datetime)
ORDER BY (pickup_ntaname, pickup_datetime);

-- Verify table exists on both nodes
SELECT name, engine FROM system.tables
WHERE database = 'default' AND name = 'trips_replicated';
```

### SQL — Replication Testing

```sql
-- Insert on replica 1
INSERT INTO trips_replicated VALUES
(1, '2024-01-15 10:00:00', '2024-01-15 10:30:00', -73.98, 40.75, -73.97, 40.76,
 2, 3.5, 15.0, 0.5, 3.0, 0.0, 18.5, 'CRE', 'Midtown-Midtown South', 'Murray Hill-Kips Bay');

-- Check count on both nodes (should match after a few seconds)
SELECT hostName(), count() FROM trips_replicated;

-- Replication health
SELECT database, table, is_leader, queue_size, log_pointer, absolute_delay
FROM system.replicas;

-- Replication queue (pending operations)
SELECT * FROM system.replication_queue;
```

### SQL — Failure Recovery Testing

```sql
-- After stopping clickhouse-2 and inserting on clickhouse-1:
-- Check count on clickhouse-1 (has the new data)
SELECT count() FROM trips_replicated;

-- After restarting clickhouse-2:
-- Check count on clickhouse-2 (should catch up)
SELECT count() FROM trips_replicated;

-- Verify catch-up completed
SELECT queue_size, absolute_delay FROM system.replicas;
-- queue_size = 0 means fully caught up
```
