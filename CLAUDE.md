# ClickHouse Cluster Basics

## What This Is

Hands-on ClickHouse cluster learning project. See [docs/01-problem-statement.md](docs/01-problem-statement.md) for goals and [docs/02-implementation-plan.md](docs/02-implementation-plan.md) for the phased plan.

## Current Phase

Phase 1 — Single Node Fundamentals (files created, ready to run)

## Commands

```bash
docker compose up -d
docker compose exec clickhouse-server clickhouse-client
docker compose down
docker compose down -v
```

## Conventions

- Config files: XML (ClickHouse native format)
- SQL files: numbered by purpose (`01-create-tables.sql`)
- Branches: `phase-N-description`
- Notes: `docs/notes/phase-N.md`
