# Staging Continuous Deployment

> **Issue:** #1236 — Continuous deployment of main to a staging instance with
> post-deploy verification and automatic rollback.
> **Audience:** Maintainers, release managers, on-call operators.
> **Related:** `scripts/canary-deploy.sh`, `scripts/rollback.sh`,
> `scripts/health_check.sh`, `scripts/staging-upgrade.sh`,
> `.github/workflows/staging-deploy.yml`, `SECURITY.md` (upgrade governance),
> `docs/upgrade-guide.md`, `docs/incident-response-runbook.md`.

## 1. Goal

Every merge to `main` is continuously deployed to a **staging instance**
(testnet) so integration failures surface early and integrators have a stable
target. The deployment honours the **same time-locked proposal flow as
production** (`propose_upgrade` → delay → `execute_upgrade`), is verified by
the **health and canary checks**, and **rolls back automatically** on failure.

## 2. Architecture

```
merge to main
    │  (required branch protection: Contract CI must pass)
    ▼
Contract CI (ci.yml) succeeds on main
    │  workflow_run gate: conclusion==success && head_branch==main
    ▼
staging-deploy.yml ── concurrency: staging-deploy (cancel-in-progress: false)
    │
    ├─ build release WASM (Rust 1.81.0, --locked) → optimize → SHA-256 sign
    ├─ fetch previous verified WASM (rollback source) from last green run
    ├─ scripts/staging-upgrade.sh --non-interactive
    │     1. baseline health_check.sh (fail closed if already unhealthy)
    │     2. propose_upgrade(new_wasm_hash) — standard proposal flow
    │     3. poll get_pending_upgrade until executable_after (bounded wait;
    │        exit 2 = proposed-pending, completed by the hourly schedule)
    │     4. execute_upgrade
    │     5. health_check.sh + verify-deployment.sh canary checks
    │     6. on failure → rollback.sh --non-interactive (previous WASM)
    │        → re-run health checks → record status
    ├─ publish deploy/staging.json (machine-readable, schema-validated)
    ├─ commit status back to main ([skip ci]) + upload evidence artifact
    └─ on failure → notify maintainers (issue with run/evidence links)
```

### Triggers

| Trigger | Purpose |
|---|---|
| `workflow_run` ("Contract CI", completed, `main`) | Deploy only CI-verified merges. A push that skipped CI (or a failed CI run) closes the gate — no deployment. |
| `schedule` (hourly, `:17`) | Complete a `proposed-pending` execution once the on-chain delay elapses. The time-lock is never skipped (see §4). |
| `workflow_dispatch` | Manual rehearsal. Supports `dry_run=true` and an explicit `commit`. |

### Guards

| Requirement | Mechanism |
|---|---|
| No concurrent deployments | Top-level `concurrency: { group: staging-deploy, cancel-in-progress: false }` — a merge during a deployment queues behind it instead of interleaving proposals. |
| No unreviewed changes | The `gate` job deploys only when the triggering CI run concluded `success` on `main`. Branch protection on `main` (required CI + CODEOWNERS review) is the other half; see §7 setup. |
| Never mainnet | `staging-upgrade.sh` fails closed for any network alias outside `testnet\|futurenet`; the workflow pins `STAGING_NETWORK=testnet`. |

## 3. Machine-readable status

`deploy/staging.json` (schema: `deploy/staging.schema.json`) is rewritten on
every run and committed back to `main` with a `[skip ci]` trailer (which
suppresses CI, so the status commit cannot retrigger this pipeline).

| Field | Source |
|---|---|
| `network`, `contract_id` | Staging instance coordinates |
| `wasm_sha256`, `previous_wasm_sha256` | Signed build artifacts (rollback source) |
| `version`, `schema_version` | `get_version` post-deploy; contract schema (currently `4`) |
| `status` | `deployed` \| `proposed-pending` \| `rolled-back` \| `failed` \| `pending` |
| `health`, `canary` | `health_check.sh` / `verify-deployment.sh` outcomes |
| `commit_sha`, `workflow_run_url`, `last_deploy_utc` | Provenance for integrators |

Integrators poll this file (or the `staging-deployment-evidence` run
artifact) instead of asking operators for the current staging address.

## 4. The time-lock is honoured, not bypassed

Staging uses the **same** `propose_upgrade` / `execute_upgrade` entrypoints
and the **same** `MIN_UPGRADE_DELAY_SECS` (48 h) enforcement as production
(`SECURITY.md`). Consequences:

- A merge produces a **proposal immediately** and **execution later**: if the
  delay has not elapsed within `STAGING_UPGRADE_MAX_WAIT_SECS` (default 3 h),
  the script exits `2`, records `proposed-pending`, and the hourly schedule
  completes execution. Staging therefore tracks `main` with a delay of at
  most one upgrade window — the price of a real time-lock.
- `scripts/staging-upgrade.sh --skip-delay-wait` exists **only** for hermetic
  rehearsal/tests (`STAGING_ALLOW_SKIP_DELAY_WAIT=1` or `--dry-run`). It is
  never used by the workflow. Bypassing the delay on a real network would
  defeat the veto window the whole governance model depends on.

## 5. Rollback

Rollback triggers on **any** post-execute failure: `execute_upgrade` error,
health-check failure, or canary failure (plus the `STAGING_SMOKE_FAIL=1`
rehearsal hook used by `scripts/test-staging-deploy.sh` to prove the path).

1. `scripts/rollback.sh --non-interactive` re-proposes the **previous verified
   WASM** (fetched from the last green run's evidence artifact) and executes
   it through the same proposal flow.
2. `health_check.sh` re-runs against the restored instance. Only if it passes
   is the status recorded as `rolled-back` — i.e. **rollback restores a state
   verified by the health checks** (acceptance criterion 3). If post-rollback
   health fails, status is `failed` and the failure notice escalates to
   manual intervention (incident runbook, §8).
3. The previous WASM for run N+1 is always the artifact of the last green
   run, so repeated failures converge rather than compounding.

### Terminal status guarantee

A failed staging run **always** records a terminal status — either
`rolled-back` (previous WASM restored and re-verified) or `failed` (manual
intervention required) — and **never leaves `pending`** in
`deploy/staging.json`. `pending` is only the initial placeholder written
before a run starts; the workflow's final status-publish step overwrites it
on every outcome, including failures and rollbacks. If a failure issue shows
`pending`, the run did not reach its status-publish step (e.g. cancelled or
infrastructure failure) — treat it as `failed` and investigate per §8.
=======

`rollback.sh --non-interactive` (new in this change) only skips the *execute*
prompt on non-mainnet networks; a mainnet rollback still refuses to run
non-interactively and requires the typed confirmation. Interactive behaviour
is unchanged.

## 6. Failure notification

The workflow's `Notify maintainers on failure` step (`if: failure()`) files an
issue labelled `staging,deployment-failure` referencing #1236, containing:

- the failed commit, the recorded `deploy/staging.json` status/note,
- the Actions run URL (logs) and the `staging-deployment-evidence` artifact
  (`staging-upgrade.log`, `staging.json`, WASM SHA-256, deployed WASM),
- the recovery pointer (§8) and a `/cc @LedgerLens/arch-reviewers`.

A deliberately broken change is therefore visible as: red run → rollback
executed → `rolled-back` status → filed issue. The rehearsal that proves this
end-to-end without a live network is `scripts/test-staging-deploy.sh`
(scenario: stubbed CLI + `STAGING_SMOKE_FAIL=1` asserts the rollback branch
runs and the workflow contains the notify step).

## 7. Secrets scope and rotation (reviewed)

All staging secrets live in the **`staging` GitHub Environment** (not
repository secrets), which carries: required reviewers, `main`-only branch
policy, and separate audit logging.

| Secret | Scope | Use |
|---|---|---|
| `STAGING_SOROBAN_SECRET_KEY` | **Staging-only deploy key.** Funds capped to testnet fees; it is *not* an admin of any mainnet contract and *not* a service signer. Sole writer of the staging instance. | Imported as the ephemeral `staging-deployer` CLI identity each run; never printed. |
| `STAGING_CONTRACT_ID` | Testnet staging instance address (public, non-secret but environment-pinned so forks cannot redirect deployments). | Upgrade target + health/canary subject. |

Rules:

- **Strict scope:** the key is authorized *only* on the staging instance
  (testnet). Authorizing it anywhere else (mainnet, service set) is a
  policy violation — reviewable via `get_admin`/`get_service_signers` and
  the environment audit log.
- **Rotation:** every **90 days** or on any suspected exposure, whichever is
  first. Procedure: generate a new key off-chain → `add_admin_signer` (or
  admin transfer, per `docs/key-rotation-runbook.md`) on the staging
  instance → update the environment secret → delete the old secret →
  trigger a `workflow_dispatch` dry run to confirm → record the rotation in
  the staging issue thread. The rehearsal script
  (`scripts/rotate-keys-rehearsal.sh`) validates the mechanics beforehand.
- **Review:** this section plus the environment configuration require
  `@LedgerLens/arch-reviewers` approval (CODEOWNERS covers `/docs`,
  `/scripts`, `/deploy`, `/.github`). Secret *values* are never committed;
  only names and policies are documented here.

## 8. Operator runbook

### First-time setup

1. Deploy a fresh staging instance on testnet (`./deploy.sh testnet
   <admin> <service>`), or designate the existing canary contract.
2. Create the `staging` environment (Settings → Environments): add the two
   secrets above, enable required reviewers (`@LedgerLens/arch-reviewers`),
   restrict to `main`.
3. Require `Contract CI` as a branch-protection check on `main`.
4. Run a manual rehearsal: Actions → Staging Continuous Deployment →
   `workflow_dispatch` with `dry_run=true`; confirm green.
5. Replace the placeholder `contract_id`/`wasm_sha256` in
   `deploy/staging.json` on the first green run (automatic).

### Responding to a staging failure issue

Every staging failure issue (e.g. #1493, #1494, #1495, #1496) is investigated
with the same steps:

1. Open the run link in the issue, download the
   `staging-deployment-evidence` artifact, and read `staging-upgrade.log`
   top-down (baseline → propose → execute → verify → rollback).
2. Check `deploy/staging.json` for the recorded status. A failed run is
   always terminal — `rolled-back` or `failed`, never `pending` (see §5).
   - `rolled-back`: the previous WASM was restored and re-verified by the
     health checks. Confirm post-rollback health passed in the log, verify
     `deploy/staging.json` matches on-chain (`health_check.sh` manually),
     then fix forward on a branch — the next merge redeploys.
   - `failed`: manual intervention is required. Follow
     `docs/incident-response-runbook.md` (freeze if needed, snapshots,
     reconcile) before re-running.
   - `pending`: the run did not reach its status-publish step; treat as
     `failed` and investigate the run itself.
3. If status is `proposed-pending` for >1 delay window, follow
   `docs/incident-response-runbook.md` before re-running.
4. **Do not promote the failing commit further until staging is green
   again.** No additional merges, releases, or promotions from that commit
   until a subsequent run records `deployed` with passing health and canary.
5. Close the loop on the issue with the root cause and the green run link.

### Local rehearsal (no network)

```bash
./scripts/test-staging-deploy.sh   # hermetic: workflow checks, schema, dry-runs,
                                   # broken-change rollback simulation
./scripts/staging-upgrade.sh --help
./scripts/staging-upgrade.sh --dry-run --non-interactive \
  testnet staging-deployer CSTAGINGXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
  target/wasm32-unknown-unknown/release/ledgerlens_score.optimized.wasm
```

## 9. Compatibility impact

**None.** This change touches only CI configuration (`/.github`), operator
scripts (`/scripts`), deployment data (`/deploy`), docs (`/docs`), and tests
(`/scripts/test-staging-deploy.sh`):

- No public ABI change (no function added, removed, or re-signed).
- No storage layout change (no `DataKey` touched).
- No event or error-enum change (no discriminant touched; the
  append-only error policy and event-stability rules are unaffected).

Per `CONTRIBUTING.md` and `docs/interface-versioning-policy.md`, no
migration guide, deprecation entry, or version bump is required.

## 10. Test plan

- `scripts/test-staging-deploy.sh` (hermetic, no network/toolchain):
  workflow gate/concurrency/secret scoping assertions, `staging.json`
  schema validation, `--dry-run` of `staging-upgrade.sh` and
  `rollback.sh --non-interactive`, and the broken-change simulation
  (`STAGING_SMOKE_FAIL=1` → rollback branch executes → non-zero exit →
  `rolled-back` recorded).
- Existing suites untouched and still green: `tests/deploy/test_deploy.sh`,
  `scripts/health_check.test.sh`, `scripts/test-deploy-manifest-validation.sh`.
- Live proof (post-merge, maintainer-run): push a test branch with a failing
  canary assertion, observe rollback + failure issue on the staging run.
