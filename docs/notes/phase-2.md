# Phase 2 — Keeper + Replication

> Learning journal. Record what surprised you, what broke, and what clicked.

## Architecture

```
┌─────────┐  ┌─────────┐  ┌─────────┐
│keeper-1 │  │keeper-2 │  │keeper-3 │    ← 3-node Keeper quorum (Raft consensus)
└────┬────┘  └────┬────┘  └────┬────┘
     │            │            │
     └────────────┼────────────┘
                  │
     ┌────────────┴────────────┐
     │                         │
┌────┴──────┐          ┌──────┴────┐
│clickhouse-1│  ←sync→ │clickhouse-2│   ← 1 shard, 2 replicas
└───────────┘          └───────────┘
```

## Setup Notes

- ClickHouse image: `clickhouse/clickhouse-server:latest`
- Keeper image: `clickhouse/clickhouse-keeper:latest`
- Cluster name: `cluster_1s2r` (1 shard, 2 replicas)

## Rationale Q&A

### Why 3 Keeper nodes? Why not 2 or 4?

Keeper uses the Raft consensus protocol, which requires a **majority (quorum)** to agree on any write. Odd numbers are the sweet spot:

| Nodes | Quorum needed | Failures tolerated |
|-------|--------------|-------------------|
| 2 | 2 | 0 (any failure kills quorum) |
| 3 | 2 | 1 |
| 4 | 3 | 1 (same as 3, but costs an extra node) |
| 5 | 3 | 2 |

3 nodes is the minimum for fault tolerance. 5 is common in large production clusters.

### What are the two ports in Keeper configs (9181 vs 9234)?

Each keeper node has two communication channels:

| Port | Purpose | Who connects |
|------|---------|-------------|
| 9181 (tcp_port) | Client-facing API | ClickHouse servers connect here for coordination (table metadata, replication log, leader election) |
| 9234 (raft port) | Internal consensus | Keeper nodes talk to each other for Raft protocol (leader election among keepers, log replication between keepers) |

The `<raft_configuration>` block lists all keeper peers on port 9234. It's not additional services — it's the same 3 keepers telling each other "here are your peers."

### Why so many XML files? (8 total)

**Keeper configs (3 files — unavoidable):**
Each keeper needs a unique `server_id`. Keeper has no variable substitution in XML, so each node gets its own file. They are 99% identical.

**ClickHouse configs (5 files — split by concern):**

| File | Content | Why separate |
|------|---------|-------------|
| `config.xml` | Logging, ports, Prometheus | Server-level settings (from Phase 1) |
| `users.xml` | Users, memory limits, quotas | Access control — different team might own this |
| `cluster.xml` | Keeper addresses + cluster topology | Cluster-level settings (added in Phase 2) |
| `macros-node1.xml` | `replica = clickhouse-1` | Per-node identity — unavoidable |
| `macros-node2.xml` | `replica = clickhouse-2` | Per-node identity — unavoidable |

The 3 shared files (`config.xml`, `users.xml`, `cluster.xml`) could be merged into one. They're split for readability and because in production, different settings have different owners and change frequencies. The 2 macros files can't be merged — each replica must know its own name.

**Minimum possible: 5 files** (3 keeper + 1 shared CH config + 1 per-node macros using docker-compose env var tricks). We keep it at 8 for clarity.

### What does `is_leader = 1` mean in `system.replicas`?

Not what you'd think. It does **not** mean "this is the primary that accepts writes." ClickHouse uses **multi-master replication** — both replicas accept writes.

`is_leader = 1` means this replica is responsible for initiating background merges for that table. In a single-shard setup with `internal_replication = true`, both replicas typically show `is_leader = 1` because each independently merges its own parts.

The real coordination happens through Keeper: inserts create log entries that the other replica picks up and applies.

Key difference from PostgreSQL/MySQL: ClickHouse replicas are peers, not primary/standby.

## Gotchas Encountered

- **Keeper `listen_host` defaults to `127.0.0.1`** — other Docker containers can't reach it. Must add `<listen_host>0.0.0.0</listen_host>` outside the `<keeper_server>` block.
- **macOS `nc` hangs** on four-letter commands — use `docker compose exec keeper-1 bash -c "echo mntr | nc localhost 9181"` instead.
- **`docker compose exec` + input redirection** requires `-T` flag (`docker compose exec -T clickhouse-1 clickhouse-client --multiquery < file.sql`).

## Observations

- Cluster start: ~30 seconds for all 5 containers (keeper image pull on first run adds more)
- keeper-2 won the initial leader election
- `ON CLUSTER` DDL created the replicated table on both nodes in one command
- Replication of a single insert was near-instant (sub-second)
- Failure recovery: stopped clickhouse-2, inserted on clickhouse-1, restarted clickhouse-2 — caught up within seconds, `queue_size` returned to 0

## Validation Checklist

- [x] All 5 containers running (`docker compose ps`)
- [x] Keeper quorum healthy (`ruok` → `imok` from inside container)
- [x] Keeper leader elected (keeper-2 was leader)
- [x] ClickHouse sees Keeper (`system.zookeeper` returns paths)
- [x] Cluster topology correct (`system.clusters` shows 1 shard, 2 replicas)
- [x] Macros differ per node (`system.macros`)
- [x] ReplicatedMergeTree table created on both nodes via `ON CLUSTER`
- [x] Insert on node 1 appears on node 2
- [x] Replication health clean (`system.replicas` — queue_size = 0)
- [x] Failure recovery works (stop node 2, insert on node 1, restart node 2, data catches up)
