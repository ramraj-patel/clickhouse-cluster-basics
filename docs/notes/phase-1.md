# Phase 1 — Single Node Fundamentals

> Learning journal. Record what surprised you, what broke, and what clicked.

## Setup Notes

- ClickHouse image: `clickhouse/clickhouse-server:latest` (v26.7.3 at time of run)
- Dataset: NYC Taxi (~2M rows via S3)
- Data load required `NOSIGN` in the `s3()` function — v26.7+ blocks server credential passthrough by default
- Health check required `wget` instead of `curl` — the newer ClickHouse image no longer bundles curl

## Table Engines Used

| Engine | Table | Purpose |
|--------|-------|---------|
| MergeTree | `trips` | Base table for raw taxi data |
| ReplacingMergeTree | `zone_fare_latest` | Latest fare stats per zone (dedup by `updated_at`) |
| SummingMergeTree | `daily_stats` | Auto-summed daily counts and revenue |
| AggregatingMergeTree | `daily_agg_stats` | Pre-aggregated uniques and averages |

## Materialized Views

| MV | Source → Target | What it does |
|----|----------------|--------------|
| `mv_daily_stats` | `trips` → `daily_stats` | Sums trip count, revenue, distance per day+zone |
| `mv_daily_agg_stats` | `trips` → `daily_agg_stats` | Stores uniq/avg states per day+zone |

## Observations

- **Data load**: 2M rows from S3 loaded during container init (entrypoint scripts). Took ~2 minutes including download and insert.
- **Parts after initial insert**: `trips` had 3 parts (79.9 MiB on disk) after the bulk insert. Small tables (`daily_stats`, `daily_agg_stats`, `zone_fare_latest`) compacted to 1 part each.
- **FINAL keyword**: On `zone_fare_latest` (376 rows across 2 parts), `FINAL` had no noticeable overhead. On larger tables this would matter — it forces a merge-on-read.
- **Materialized views**: Both MVs populated correctly during the bulk `INSERT INTO trips`. A subsequent single-row insert incremented both MV target tables from 6,543 → 6,544, confirming they fire on every insert.
- **AggregatingMergeTree**: Requires `-State` combinators in the MV (`uniqState`, `avgState`) and `-Merge` combinators at query time (`uniqMerge`, `avgMerge`). Forgetting either produces confusing errors.
- **Enum8 payment_type**: Worked seamlessly with the S3 dataset. The mapping (`CSH=1, CRE=2, NOC=3, DIS=4, UNK=5`) matched the source data. Cash trips outnumber credit ~1.6:1.
- **Parts after merges settled**: All tables show healthy part counts (trips: 4 parts, others: 1-2 parts). No detached or broken parts.
- **SummingMergeTree**: Rows with the same `(date, pickup_ntaname)` key are auto-summed for the numeric columns. 2M trips collapsed into 6,543 daily/zone rollup rows.
- **Memory**: Server uses ~267 MB at idle with 2M rows loaded. Well within the 4GB cap set in `users.xml`.

## Validation Checklist

- [x] Container healthy (`docker compose ps`) — running (healthy)
- [x] HTTP ping OK (`wget localhost:8123/ping`) — "Ok."
- [x] Client connects (`SELECT version()`) — 26.7.3.19
- [x] All 4 tables created with correct engines
- [x] Row count > 0 in `trips` — 2,000,001
- [x] Parts are healthy (no detached/broken)
- [x] MVs populate on insert — both targets incremented on single-row insert
- [x] No persistent errors in logs — only startup noise ("Logging errors to...")
