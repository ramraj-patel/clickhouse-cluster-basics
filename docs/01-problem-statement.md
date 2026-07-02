# Problem Statement

## Objective

Build a local ClickHouse cluster from scratch, progressing from a single-node setup to a production-ready multi-node cluster with monitoring. The goal is hands-on learning of ClickHouse internals, cluster topology, replication, sharding, and operational practices.

## Why ClickHouse?

ClickHouse is a column-oriented OLAP database designed for real-time analytical queries over large datasets. It is widely used for:

- Log and event analytics
- Time-series data
- Real-time dashboards and reporting
- Metrics aggregation at scale

Understanding its architecture — MergeTree engine family, replication via Keeper, distributed query execution — is essential for anyone working with high-volume analytical workloads.

## Learning Goals

See [Implementation Plan](02-implementation-plan.md) for the detailed phase-by-phase breakdown and [Reference Guide](04-reference-guide.md) for explained configs and queries. In summary: MergeTree engine family → Keeper + replication → sharding + distributed queries → Prometheus/Grafana monitoring → TLS, backups, and production hardening → gap analysis against real deployments.

## Constraints

- Everything runs locally via Docker Compose
- No cloud-specific tooling — portable setup
- Incremental complexity: each phase builds on the previous one
- Documentation and configuration are version-controlled in this repo

## Non-Goals

- Running in Kubernetes (out of scope for this learning project)
- ClickHouse Cloud managed service
- Multi-datacenter or geo-distributed setups
