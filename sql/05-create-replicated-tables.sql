-- ReplicatedMergeTree version of the trips table
-- ON CLUSTER creates it on all nodes in the cluster at once
-- {shard} and {replica} are substituted from each node's macros config
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
