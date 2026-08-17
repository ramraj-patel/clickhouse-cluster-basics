-- === Sample queries to explore after data load ===

-- 1. Basic counts
SELECT count() AS total_trips FROM trips;
SELECT uniq(pickup_ntaname) AS unique_zones FROM trips;

-- 2. Top 10 pickup zones by trip count
SELECT
    pickup_ntaname,
    count() AS trips,
    round(avg(fare_amount), 2) AS avg_fare,
    round(avg(tip_amount), 2) AS avg_tip
FROM trips
GROUP BY pickup_ntaname
ORDER BY trips DESC
LIMIT 10;

-- 3. Hourly trip distribution
SELECT
    toHour(pickup_datetime) AS hour,
    count() AS trips
FROM trips
GROUP BY hour
ORDER BY hour;

-- 4. Revenue by payment type
SELECT
    payment_type,
    count() AS trips,
    round(sum(total_amount), 2) AS revenue
FROM trips
GROUP BY payment_type
ORDER BY revenue DESC;

-- 5. Query the SummingMergeTree rollup
SELECT
    date,
    pickup_ntaname,
    trip_count,
    round(total_revenue, 2) AS revenue
FROM daily_stats
ORDER BY trip_count DESC
LIMIT 10;

-- 6. Query the AggregatingMergeTree rollup (use -Merge combinators)
SELECT
    date,
    pickup_ntaname,
    uniqMerge(uniq_passengers) AS unique_passengers,
    round(avgMerge(avg_distance), 2) AS avg_dist
FROM daily_agg_stats
GROUP BY date, pickup_ntaname
ORDER BY unique_passengers DESC
LIMIT 10;

-- 7. FINAL keyword on ReplacingMergeTree
-- First populate zone_fare_latest
INSERT INTO zone_fare_latest (pickup_ntaname, avg_fare, avg_tip, trip_count)
SELECT
    pickup_ntaname,
    round(avg(fare_amount), 2),
    round(avg(tip_amount), 2),
    count()
FROM trips
GROUP BY pickup_ntaname;

SELECT * FROM zone_fare_latest FINAL
ORDER BY trip_count DESC
LIMIT 10;

-- 8. System tables — part health
SELECT
    table,
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size
FROM system.parts
WHERE active AND database = 'default'
GROUP BY table
ORDER BY active_parts DESC;

-- 9. Active merges (run during/after insert)
SELECT * FROM system.merges FORMAT PrettyCompact;

-- 10. Server health snapshot
SELECT metric, value
FROM system.metrics
WHERE metric IN ('Query', 'Merge', 'MemoryTracking', 'TCPConnection')
FORMAT PrettyCompact;
