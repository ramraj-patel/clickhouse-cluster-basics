# Agent Guidelines

## Before Any Work

1. Read [HANDOFF.md](HANDOFF.md) — current phase, what's done, decisions, open questions, next steps
2. Read the matching phase in [docs/02-implementation-plan.md](docs/02-implementation-plan.md)
3. Consult the references listed in that phase before writing configs or SQL

## Validation Rules

- **XML configs**: validate element names against official docs before writing; only override what differs from defaults
- **SQL**: test against a running ClickHouse instance via `docker compose exec`; do not use external clients
- **Docker Compose**: run `docker compose config` after edits
- **Prometheus/Grafana**: verify scrape targets are reachable and dashboards load without errors

## Session Handoff Protocol

At the end of every session:

1. Copy current `HANDOFF.md` to `docs/sessions/YYYY-MM-DD-<short-summary>.md`
2. Overwrite `HANDOFF.md` with updated state:
   - Current phase and status
   - What was completed this session
   - Decisions made and rationale
   - Open questions
   - Concrete next steps
3. Update `Current Phase` in `CLAUDE.md` if it changed
4. Commit the handoff files

## Hard Constraints

- ClickHouse Keeper only — no ZooKeeper
- Docker Compose only — no Kubernetes, no Helm, no cloud services
- See [docs/01-problem-statement.md#non-goals](docs/01-problem-statement.md#non-goals) for full list
