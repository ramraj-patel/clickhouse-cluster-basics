-- MV: auto-populate daily_stats on insert to trips
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_stats
TO daily_stats
AS SELECT
    toDate(pickup_datetime) AS date,
    pickup_ntaname,
    count()                 AS trip_count,
    sum(total_amount)       AS total_revenue,
    sum(trip_distance)      AS total_distance
FROM trips
GROUP BY date, pickup_ntaname;

-- MV: auto-populate daily_agg_stats with aggregate states
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_agg_stats
TO daily_agg_stats
AS SELECT
    toDate(pickup_datetime) AS date,
    pickup_ntaname,
    uniqState(passenger_count)  AS uniq_passengers,
    avgState(trip_distance)     AS avg_distance
FROM trips
GROUP BY date, pickup_ntaname;
