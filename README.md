# metering-poc

Experimental proof-of-concept for AI Gateway / MaaS **usage metering talk-back**:

**Praxis** (token capture) → **CloudEvents** (GenAI-aligned) → **OpenMeter** (pricing + entitlement) → **talk-back API** (go/no-go).

This is **not** product code and is **not** a CI gate for [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service).

## Start here

- **[ADR 0001 — PoC plan](docs/adr/0001-metering-poc-openmeter-talkback.md)** — detailed architecture, Praxis evaluation gates, OpenMeter pricing model, talk-back contract, and phased delivery.

Product intent lives in `models-as-a-service` under `METERING_PROPOSAL/` (`overview.md`, `talkback.md`).

## Status

Scaffolding: ADR only. Implementation phases are defined in ADR 0001.

## Container runtime

Prefer **Podman** for local compose. Docker-compatible commands are fine as an alternative (see ADR deploy notes).
