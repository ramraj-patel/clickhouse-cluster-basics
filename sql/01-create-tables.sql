-- NYC Taxi trips — base MergeTree table
-- Source: https://clickhouse.com/docs/en/getting-started/example-datasets/nyc-taxi
CREATE TABLE IF NOT EXISTS trips (
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
ENGINE = MergeTree
PARTITION BY toYYYYMM(pickup_datetime)
ORDER BY (pickup_ntaname, pickup_datetime);

-- ReplacingMergeTree — track latest fare stats per pickup zone
CREATE TABLE IF NOT EXISTS zone_fare_latest (
    pickup_ntaname  LowCardinality(String),
    avg_fare        Float64,
    avg_tip         Float64,
    trip_count      UInt64,
    updated_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY pickup_ntaname;

-- SummingMergeTree — daily ride counts and revenue
CREATE TABLE IF NOT EXISTS daily_stats (
    date           Date,
    pickup_ntaname LowCardinality(String),
    trip_count     UInt64,
    total_revenue  Float64,
    total_distance Float64
)
ENGINE = SummingMergeTree((trip_count, total_revenue, total_distance))
ORDER BY (date, pickup_ntaname);

-- AggregatingMergeTree — daily unique passengers and avg distance per zone
CREATE TABLE IF NOT EXISTS daily_agg_stats (
    date             Date,
    pickup_ntaname   LowCardinality(String),
    uniq_passengers  AggregateFunction(uniq, UInt8),
    avg_distance     AggregateFunction(avg, Float64)
)
ENGINE = AggregatingMergeTree
ORDER BY (date, pickup_ntaname);
