# SYNC.md — DozenOS decentralized self-sync (item #14)

How every `dozenos/*` mirror keeps itself up to date with its VyOS upstream,
without any central coordinator. Cross-references: `mirror-push.sh` (the
engine this design calls), `WORKFLOW-POLICY.md` (the `.github/` strip +
sanctioned-workflow-source rules this design must obey), `CI-SECRETS.md`
(the `UPSTREAM_URL` variable and `BUILD_APP_ID`/`BUILD_APP_PRIVATE_KEY`
GitHub App contracts — the App replaced the retired `BUILD_PAT`, see its
§4), `overlay/MANIFEST.md`
(why this mechanism is a toolkit feature, not overlay content), and
`REBUILD-DISPATCH.md` (item #15, AUTHORED — the receiver this design hands
its dispatch off to, dep-graph bootstrap + resolver + incremental rebuild
workflow; item #16 completes that graph's coverage) and item #17
(dozenos-build's separate nightly full-image build).

## 1. Design: decentralized, no central loop (LOCKED)

Each of the 17 `dozenos/*` mirror repos carries its OWN
`.github/workflows/sync.yml`. That workflow runs on a **daily
`schedule: cron`** (plus `workflow_dispatch` for a manual kick) **inside that
repo's own GitHub Actions**, and does exactly one thing: re-run
`mirror-push.sh` against its own upstream, self-target, self-push. There is
**no** separate always-on process, no orchestrator repo, no fan-in loop that
walks all 17 repos — each mirror is independently responsible for noticing
its own upstream moved and re-syncing itself. This is intentional: it scales
to however many mirrors DozenOS ends up with, needs no additional
infrastructure beyond what every mirror already has (its own Actions), and
one mirror's sync failing cannot block or slow down any other mirror's sync.

## 2. Mechanism: template + generation, not hand-authored per repo

Hand-writing 17 near-identical `sync.yml` files (and keeping them in sync by
hand whenever the mechanism changes) is exactly the kind of one-off drift
this toolkit's `dozenos-rebrand/*` scripts exist to prevent. Instead:

- **`dozenos-rebrand/sync.yml.template`** is the single source of truth for
  the workflow's shape. It contains four placeholders:
  `@@BRANCH@@`, `@@MIRROR_PUSH_FLAGS@@`, `@@MIRROR_PUSH_FLAGS_COMMENT@@`
  (a human-readable echo of the same flags, used only in a header comment),
  and `@@REBRAND_REF@@`.
- **`mirror-push.sh`** renders that template into
  `<clone>/.github/workflows/sync.yml` as its own **step 5/7**
  (`generate_sync_workflow()`, plus its `portable_overlay_path()` helper) —
  see that script's updated pipeline comment and step numbering (previously
  6 steps, now 7: clone → rename-transform → strip `.github/` →
  build-repo/overlay hooks → **generate sync.yml** → verify → mode-detect
  + push). This runs for **every** target — plain mirrors, `--build-repo`,
  and `--overlay` alike — never gated on any of those flags, only shaped by
  them.
- The flags baked into a given mirror's `sync.yml` are **derived from how
  `mirror-push.sh` itself was invoked to produce that mirror** — the exact
  per-repo differences the locked design calls for:

  | Target class | Example | Baked `MIRROR_PUSH_FLAGS` |
  |---|---|---|
  | Plain mirror | `hvinfo` | *(empty)* |
  | Build repo | `dozenos-build` | `--build-repo` |
  | Overlay repo | `dozenos-1x` | `--overlay dozenos-rebrand/overlay-dozenos-1x --allow-residuals` |
  | Overlay repo | `vyconf` | `--overlay dozenos-rebrand/overlay-vyconf` |

  ⚠️ **This table is the authoritative flag list for ANY re-push/rollout of
  a mirror** — a re-push that drops a target's overlay flag ships an
  un-overlaid tree AND bakes overlay-less flags into that mirror's own
  sync.yml, so every subsequent self-sync keeps stomping the overlay's
  fixes. This actually happened (2026-07-09): `vyconf` was rolled out and
  later re-pushed as a plain mirror, so its daily self-sync reverted
  `overlay-vyconf`'s ocaml-protoc `>= 3.0` pin fix back to upstream's
  broken `< 3.0`, failing every dozenos-1x build until re-pushed WITH
  `--overlay dozenos-rebrand/overlay-vyconf`.

  `--build-repo` already implies `--allow-residuals` inside `mirror-push.sh`
  (see its existing comment on that), so a build-repo target's baked flags
  are just `--build-repo`, not `--build-repo --allow-residuals` — the
  redundant flag is deliberately not baked. A non-build-repo overlay target
  that was actually pushed with `--allow-residuals` bakes it explicitly,
  matching the exact invocation used.

- **`--overlay <dir>` path portability:** the `<dir>` a human passes to
  `mirror-push.sh` locally (e.g. `dozenos-rebrand/overlay-dozenos-1x`,
  relative to wherever the operator's shell happens to be) is not
  necessarily what a GitHub Actions job's `dozenos-rebrand` checkout will be
  called. `portable_overlay_path()` resolves the `--overlay` argument to an
  absolute path and, if (as for every real toolkit overlay) it lives under
  the `dozenos-rebrand` root, rewrites it to `dozenos-rebrand/<subpath>` —
  the exact relative path the generated `sync.yml`'s own "Checkout
  dozenos-rebrand" step (checked out to workspace-relative path
  `dozenos-rebrand/`) will resolve. If an overlay dir is NOT under the
  toolkit root (only possible for an ad-hoc/test fixture — every shipped
  overlay lives under `dozenos-rebrand/`), it logs a warning and omits
  `--overlay` from the baked flags rather than failing the whole push
  closed over an unreachable-in-CI path.

## 3. Byte-stability / idempotency / strip-survival

- **Idempotent, byte-stable per (flags) tuple:** the target repo's own name
  never appears as literal text in the generated file — it is only ever
  derived at CI runtime from the always-populated `GITHUB_REPOSITORY` runner
  env var (`${GITHUB_REPOSITORY##*/}`, computed once in a "Resolve mirror
  repo name" step and reused via `$GITHUB_ENV`), baked once into the template
  itself. So two different targets with the *same* flags (e.g. two plain
  mirrors) produce a byte-identical `sync.yml`, and the *same* target
  re-synced twice in a row with unchanged flags produces the byte-identical
  file both times — a re-sync never touches this file's content unless the
  flags or the template itself changed. This is stronger than "stable for a
  given (target, flags)" — it's stable across all targets sharing the same
  flags.
  **NOT** `${{ github.event.repository.name }}` — that field is part of the
  webhook event payload and is unset on this workflow's `schedule` trigger
  (the primary, unattended path this workflow exists for; only
  `workflow_dispatch` populates it, which previously masked the bug in manual
  testing). `GITHUB_REPOSITORY` (form `owner/repo`) is a top-level runner env
  var, always populated regardless of trigger.
- **Strip-survival is structural, not a preservation trick:** step 3 (`rm -rf
  <clone>/.github`) only ever runs against the freshly cloned **upstream**
  tree, at the very start of the pipeline. `generate_sync_workflow()` runs
  much later (step 5), well after that strip — so there is no code path
  where the strip could remove the file this toolkit itself is about to
  write. And because the file is **regenerated from scratch on every sync**
  (not read-back-and-preserved from the previous mirror state), there is
  nothing to "survive" a strip in the traditional sense: every sync
  re-derives it identically from this invocation's flags, so drift or
  accidental hand-edits on the mirror side are simply overwritten on the
  next sync, exactly as intended (see the generated file's own header
  comment).
- **Zero `vyos`, no `uses: vyos/*`:** verified for all three representative
  targets below via `grep -ci vyos` (0 hits each) and an explicit `uses:.*vyos`
  grep (0 hits each). The template's own upstream-URL-secret error message
  originally spelled out the literal path `github.com/vyos/<repo>` in its
  text — caught by this toolkit's own `--verify` step during development
  (see mirror-push.sh's step 6/7 catching it as a "1 residual vyos" failure)
  and reworded before landing; this is exactly the kind of self-check this
  toolkit's own residual-vyos verify step is for.
- The generated file also participates in the normal `--verify` /
  `--allow-residuals` gate (step 6/7 runs after step 5), so any future
  template change that accidentally reintroduces a `vyos` token fails the
  push closed for plain mirrors (and is visible, though not fatal, for
  `--allow-residuals` targets) rather than silently shipping.

## 4. What the generated `sync.yml` actually does

1. **Trigger:** `schedule: cron` (`17 3 * * *`, UTC, shared across every
   mirror for now — see the "known follow-up" note below) + manual
   `workflow_dispatch`.
2. **Concurrency guard:** `dozenos-self-sync-${{ github.repository }}`,
   `cancel-in-progress: false` (never cancel a sync mid-push).
3. **Checkout this mirror** (default checkout, repo root) — this is the repo
   `mirror-push.sh` will overwrite-and-push back into.
4. **Checkout `dozenos/dozenos-rebrand`** to workspace-relative path
   `dozenos-rebrand/`, pinned to `@@REBRAND_REF@@` (currently `main` — see
   §6's roll-out note on why this is not yet load-bearing).
5. **Fail loud if `UPSTREAM_URL` is unset** — a dedicated step that reads the
   variable into an env var and `exit 1`s with a `::error::` annotation before
   anything else runs, rather than letting `mirror-push.sh` fail confusingly
   on an empty first argument.
6. **Mint an App token (self-push) + `gh auth setup-git`** so
   `mirror-push.sh`'s own plain `git clone`/`git push` calls against
   `https://github.com/dozenos/<self>.git` authenticate automatically — no
   auth logic needed inside `mirror-push.sh` itself. **NOT `github.token`
   any more (changed 2026-07-09):** `GITHUB_TOKEN` categorically cannot
   create/update `.github/workflows/*` files, and every mirror's tree
   carries this very `sync.yml` (dozenos-build additionally the overlay
   build workflows) — the first real workflow-content change
   (rebuild-dispatch.yml's deb-cache wiring) had GitHub reject the push
   (`refusing to allow a GitHub App to create or update workflow ...
   without "workflows" permission`); every earlier sync passed only
   because the regenerated files were byte-identical. The App token is
   scoped to exactly this one repo and requires the App to hold
   **Workflows: Read/Write** (see `CI-SECRETS.md` §4's pending-user-action
   note); the job-level `permissions:` dropped to `contents: read`
   accordingly.
7. **Run `mirror-push.sh`** with this repo's baked flags, capturing combined
   output to `$RUNNER_TEMP/mirror-push.out` (via `tee`, under `pipefail` so a
   `mirror-push.sh` failure still fails the step) and setting a
   `changed` step output: `false` if the output contains mirror-push.sh's own
   `"no changes vs existing mirror; nothing to sync"` log line, `true`
   otherwise (covers both an actual `sync` push and, defensively, a `seed`
   push — a self-sync workflow should never actually hit `seed` mode, since
   its own presence implies the repo already exists and is non-empty, but the
   `changed` logic does not depend on that assumption holding).
8. **Dispatch a rebuild**, only `if: steps.mirror_push.outputs.changed ==
   'true'`: `gh api repos/dozenos/dozenos-build/dispatches` with
   `event_type=dozenos-package-rebuild` and
   `client_payload[package]=<this repo's name>`, authenticated with
   a runtime-minted org GitHub App token (`vars.BUILD_APP_ID` +
   `secrets.BUILD_APP_PRIVATE_KEY`, minted in the step just before the
   dispatch, scoped to `dozenos-build` only; the job's own `GITHUB_TOKEN`
   cannot dispatch cross-repo — see `CI-SECRETS.md` §4). **Fan-out routing
   (which dependents actually need rebuilding for a given package change) is
   item #15's receiver workflow** (`overlay/new-files/.github/workflows/rebuild-dispatch.yml`,
   AUTHORED — see `REBUILD-DISPATCH.md`) — this step only emits the event
   carrying the changed package's name; it does not itself decide what to
   rebuild. That receiver's own dependency-graph *coverage* (walking every
   `package.toml`'s actual build inputs, beyond the bootstrap edge set item
   #15 shipped) is item #16's follow-on, not item #14's.

## 5. `UPSTREAM_URL` variable contract

- **Per-repo, not org-level** — the one deliberate exception to
  `CI-SECRETS.md`'s otherwise-all-org-level config. Each of the 17 mirrors
  gets its OWN `UPSTREAM_URL` repository **variable**
  (`github.com/dozenos/<name>/settings/variables/actions`), holding that one
  repo's `https://github.com/vyos/<name>` mapping.
- **A variable, not a secret** — the value is a plain public
  `github.com/vyos/<name>` URL with nothing sensitive in it, so it is an
  Actions *variable*, not a *secret* (migrated 2026-07-08). It is the only
  `vyos` residual, and only at runtime: it never appears in the mirror's
  tree, in `mirror-push.sh`, in `sync.yml.template`, or in the generated
  `sync.yml` — only as `${{ vars.UPSTREAM_URL }}`, resolved by GitHub at
  job-run time. Being a variable, GitHub does not mask it in logs; that is
  intentional and harmless (the mapping is public knowledge).
- See `CI-SECRETS.md` §5 for the full per-repo variable table entry and
  verification checklist addition.

## 6. Roll-out plan (NOT done this cycle)

This cycle is **author + wire + verify only** — nothing was pushed, no repo
was created or touched, no key was handled. Getting `sync.yml` onto all 17
real mirrors is a **separate, later** cycle, blocked on:

1. **Item #20** (`dozenos-rebrand` itself pushed to `github.com/dozenos/dozenos-rebrand`)
   — the generated `sync.yml`'s "Checkout dozenos-rebrand" step has nothing
   to check out until this lands, and `@@REBRAND_REF@@`'s current default
   (`main`) needs to match whatever branch that push actually uses.
2. **Per-repo `UPSTREAM_URL` secrets** set on all 17 mirrors (§5) — every
   generated `sync.yml`'s first real step fails loud without it, by design.
3. Once both are true, the roll-out itself is: re-run `mirror-push.sh`
   (no new flags needed — it already generates `sync.yml` on every push) once
   per existing mirror, in `sync` mode, so each picks up its own
   `.github/workflows/sync.yml` on its very next regular resync. No separate
   "install sync.yml" tooling is needed — pushing IS installing, since
   generation is unconditional or every target as of this cycle.

**Known follow-up, not done here:** every mirror currently shares the exact
same cron expression (`17 3 * * *`), so 17 mirrors would first fire at the
same moment once all are rolled out — a mild thundering-herd concern (each
runs its own independent, cheap `git clone --depth 1` + compare, so this is
unlikely to be a real problem at this scale, but a future refinement could
stagger cron minutes by a hash of the repo name). Not implemented now,
specifically to keep `sync.yml.template`'s rendered output byte-stable
across every plain mirror (§3) — introducing target-specific scheduling
would mean re-baking the target name as literal text, which this design
deliberately avoids.

## 7. Value-not-string blind spots re-apply automatically

Confirmed for `dozenos-1x`: its overlay (`overlay-dozenos-1x/apply-overlay.sh`)
regenerates the default-login password hash (`regen-default-password-hash.sh`)
fresh on every run (a new `openssl passwd -6` salt each time, by design — see
that script's own header), not a static value baked in once. Because
`dozenos-1x`'s generated `sync.yml` bakes
`--overlay dozenos-rebrand/overlay-dozenos-1x --allow-residuals`, every daily
self-sync re-clones upstream, re-applies that overlay, and thus
re-regenerates that hash — so this "value, not string" fix is a per-sync
guarantee, not a one-time patch that could silently regress if a future
upstream vyos-1x sync happened to reintroduce the old hash. The same holds
for `pin-nonmirrored-org-refs.sh`'s 2 deliberate residual reverts in that
same overlay: they are re-applied, and re-verified against `--allow-residuals`,
on every sync.

## 8. Verification performed this cycle

Three representative dry-runs (`mirror-push.sh ... --dry-run --work <scratch>`,
scratch dirs under this session's scratchpad, nothing pushed, no repo
touched):

| Target | Upstream | Flags | Result |
|---|---|---|---|
| `hvinfo` (plain) | `https://github.com/vyos/hvinfo` | *(none)* | `sync.yml` generated, 0 residual vyos, valid YAML, `actionlint` clean |
| `dozenos-build` (`--build-repo`) | `https://github.com/vyos/vyos-build` | `--build-repo` | `sync.yml` generated AND coexists with the 3 item #8 build workflows (4 files total under `.github/workflows/`); baked-flags line reads `--build-repo` only; 9 known/expected residuals (matches `WORKFLOW-POLICY.md`) |
| `dozenos-1x` (`--overlay`) | `https://github.com/vyos/vyos-1x` | `--overlay dozenos-rebrand/overlay-dozenos-1x --allow-residuals` | `sync.yml` generated with that exact baked-flags line; 2 known/expected residuals (matches the cycle-19 memory note) |

Every generated file: `python3 -c "import yaml; yaml.safe_load(...)"` OK,
`grep -ci vyos` = 0, `grep -c 'uses:.*vyos'` = 0, `actionlint` clean (after
moving a `shellcheck disable=SC2086` comment to directly precede the
intentionally-unquoted `$MIRROR_PUSH_FLAGS` usage line — shellcheck disable
directives only apply to the line immediately below them, not persistently).

`dozenos-rebrand/test/test-mirror-push.sh` gained new network-free
assertions covering sync.yml generation for all three shapes (plain,
build-repo coexistence, overlay baked-flags) — see that file's Run 5/Run 6
additions. Full toolkit test suite: 171 assertions across 7 test files, 0
failures.
