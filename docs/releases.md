# Active Releases & Branch Mapping

## Version Unification (2.17+)

Starting from **2.17**, MCE and ACM versions are unified. There is no separate `backplane-2.12` or MCE 2.12 — the unified versioning begins at 2.17. Both MCE and ACM repos use `release-2.17` branches going forward.

## MCE (Multicluster Engine) — `backplane-*` branches (legacy, ≤ 2.11)

MCE components use `backplane-X.Y` branches. These branches are legacy; no new `backplane-*` branches will be created after 2.11.

| Branch | Status |
|--------|--------|
| backplane-2.7 | Oldest active |
| backplane-2.8 | Active |
| backplane-2.9 | Active |
| backplane-2.10 | Active |
| backplane-2.11 | Active |

### Per-repo notes

- **cluster-proxy-addon** — deprecated starting from backplane-2.11, active branches: backplane-2.7 ~ 2.10 only

## ACM (Advanced Cluster Management) — `release-*` branches

ACM components use `release-X.Y` branches. MCE is a subset of ACM. Starting from 2.17, MCE repos also use `release-*` branches.

| Branch | Status |
|--------|--------|
| release-2.12 | Oldest active |
| release-2.13 | Active |
| release-2.14 | Active |
| release-2.15 | Active |
| release-2.16 | Active |
| release-2.17 | Latest (unified MCE + ACM) |
| main | Development (fast-forwards to next release) |

### Per-repo notes

- **multicluster-role-assignment** — newer component, active branches: release-2.15 ~ 2.16 only
