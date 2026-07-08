# SWEEP-dozenos-build.md — Whole-repo acceptance gate (item #5 / #22)

**Correction / reconciliation note (post-#22 cycle):** this sweep's
classification table below covers only the 5 non-git binary/apt-host
build-time pointers (the `revert-source-mirror-urls.sh` x3 +
`pin-toolchain-apt-source.sh` x2 reverts). It predates
`overlay/value-fixes/pin-nonmirrored-org-refs.sh` (REPOINT-AUDIT.md #6),
which reverts 4 more residual lines (`.coderabbit.yaml`, 2 lines in
`AGENTS.md`, `scripts/ansible-install`) that are equally deliberate but were
never added to this table. **The current, correct, re-verified `--ci`-mode
residual count for `dozenos-build` is 9, not 5** — see `overlay/MANIFEST.md`
(its "Repro test" section carries the same correction) and
`mirror-push.sh`'s own header comment. This sweep's "5 hits, 0 GENUINE"
verdict below is still accurate as far as it goes (those 5 are genuinely
build-time-pointer, not leaks) — it is simply incomplete, missing the 4
`nonmirrored-org-ref` items. The full 9-item set is now the checked-in
source of truth for `mirror-push.sh --allow-residuals`'s allowlist:
`overlay/expected-residuals.txt` (enforced by `residuals_allowlisted()` in
`mirror-push.sh`), which cross-references this file's classification.

Full case-insensitive `vyos` sweep over the mode-B transformed `dozenos-build`
tree (the exact tree `mirror-push.sh --build-repo` produces and pushes), plus
a cross-check against the live `github.com/dozenos/dozenos-build` mirror.

## Reproduce command + tree location

```
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-build.git \
  --target dozenos-build --build-repo --dry-run \
  --work /tmp/claude-1000/-home-date-git-dozenos/c8f23573-7bb9-4dbd-83f8-7e520cf4044b/scratchpad/sweep-build
```

`--dry-run` runs the WHOLE local pipeline for real (clone @ `rolling` →
`rename-transform.sh` → strip `.github/` → `wire-prebuild-hooks.sh` →
`overlay/apply-overlay.sh --ci` → `--verify`) and only skips the final
`gh`/`git push` step, so the tree left behind at `<work>/clone` is
byte-for-byte what would have been pushed. `--work <dir>` (vs. the default
`mktemp -d` + `trap rm -rf`) was passed specifically so the produced tree
survives the run for inspection.

- Upstream SHA cloned: `fce9b6d` (branch `rolling`)
- Tree swept: `/tmp/claude-1000/-home-date-git-dozenos/c8f23573-7bb9-4dbd-83f8-7e520cf4044b/scratchpad/sweep-build/clone`
- Mode detected: `sync` (repo already exists) — confirms this reproduces an
  incremental re-sync, not a first seed.
- `apply-overlay.sh` ran in `--ci` mode (the default, and what
  `mirror-push.sh --build-repo` always uses in production).

## Sweep methodology

Ran against the reproduced tree (`.git` excluded throughout — it holds only
the fresh upstream clone's history, never the mirror's history, and is
irrelevant to shipped-file-content zero-`vyos`):

1. `grep -rInI 'vyos' <tree> --exclude-dir=.git` — case-insensitive content sweep.
2. Each of the four case forms individually, case-sensitively (`vyos`,
   `VyOS`, `VYOS`, `Vyos`) — confirms no case form is silently missed by the
   combined case-insensitive count.
3. `find <tree> -iname '*vyos*'` — filenames and directory names.
4. Symlink targets read via `readlink` (not dereferenced) and grepped
   case-insensitively — a dirty target is invisible to a content grep.
5. The 4 binary files in the tree (2 `splash.png`, 2 `dejavu-bold-*.pf2`
   fonts — `grep -Iq .` identifies them as binary) force-scanned with
   `grep -a` in case a brand string was embedded as raw bytes/metadata.
6. Base64 heuristic: computed base64 of `vyos`/`VyOS`/`VYOS`/`Vyos` (bare,
   and with a leading/trailing byte to catch both 3-byte alignments) and
   searched for those substrings tree-wide.
7. URL-encoded (`%76%79%6f%73` and case variants) and hyphen/space/underscore
   split forms (`vy[-_. ]os`) searched for.
8. `vyatta` occurrences swept separately (41 hits) and cross-checked: since
   step 1 already lists literally every line matching `vyos` case-insensitively
   tree-wide, any line containing *both* `vyatta` and a genuine `vyos` leak
   would necessarily also appear in that list — none of the 5 hits below
   contain `vyatta`, so no leak is hiding behind a vyatta co-occurrence.

## Classification table

| file:line | matched text | classification | rationale |
|---|---|---|---|
| `scripts/package-build/linux-kernel/build-realtek-r8152.py:38` | `https://packages.vyos.net/source-mirror/...` | build-time-pointer | Realtek r8152 firmware tarball fetch from a real 3rd-party binary vendor mirror VyOS hosts; DozenOS does not self-host a source-mirror. Reverted from the transform's `packages.dozenos.net` (nonexistent) by `overlay/logic-patches/revert-source-mirror-urls.sh`. Matches TRANSFORM-COMPLETENESS-AUDIT.md item and `overlay/MANIFEST.md` "Repro test" §(a), 1st of 5. |
| `scripts/package-build/linux-kernel/build-realtek-r8126.py:37` | `https://packages.vyos.net/source-mirror/...` | build-time-pointer | Same as above, r8126 firmware. Same script, same rationale. |
| `scripts/package-build/linux-kernel/build-intel-qat.sh:17` | `https://packages.vyos.net/source-mirror/QAT.L.4.28.0-00004.tar.gz` | build-time-pointer | Intel QAT driver blob fetch, same real 3rd-party vendor mirror. Same revert script. |
| `docker/Dockerfile:336` | `https://cdn.vyos.io/tools/syft_1.44.0_linux_...` | build-time-pointer | syft SBOM-tool binary download host used only for the dev/CI container image build; real 3rd-party tool distribution CDN, not DozenOS-owned. Reverted by `overlay/value-fixes/pin-toolchain-apt-source.sh`. |
| `docker/dozenos-dev.list:1` | `https://packages.vyos.net/repositories/rolling` | build-time-pointer | Toolchain apt-source host for the dev-container build image (filename itself IS renamed to `dozenos-dev.list` — only the URL content is reverted). DozenOS ships as a whole-image upgrade model with no apt-tracked distro, so self-hosting this apt repo is out of scope. Reverted by `pin-toolchain-apt-source.sh`. |

**Totals: 5 hits, 0 GENUINE, 5 build-time-pointer, 0 upstream-3rd-party**
(scope of THIS table only — see the reconciliation note at the top of this
file: `pin-nonmirrored-org-refs.sh`'s 4 additional residual lines raise the
actual current `--ci`-mode total to 9, tracked in
`overlay/expected-residuals.txt`, not in this table)
(the 5 build-time-pointer hits are themselves references to genuine 3rd-party
upstream hosts — `packages.vyos.net`/`cdn.vyos.io` — but are bucketed as
"build-time-pointer" per the task's own framing, since they are the
specific, itemized, allowed residual set, not incidental 3rd-party mentions
elsewhere in the tree).

This is **exactly** the known deliberate 5-item residual set documented in
`dozenos-rebrand/overlay/MANIFEST.md` ("Repro test — PASSED" §(a)) and
enumerated in `mirror-push.sh`'s own header comment. No 6th or unexplained
residual bucketed as build-time-pointer — the bucket does not exceed the
known ~5, so no genuine leak is smuggled in under that label.

Note: the task context also mentions a 6th class of deliberate residual, the
"`UPSTREAM_URL` sync mapping." That one was confirmed **not** to appear
in-tree at all — per `mirror-push.sh`'s header, "the dozenos↔upstream URL
mapping is the only vyos residual, and it lives in the CALLER's argument /
UPSTREAM_URL mapping, never in this script or in anything it writes to the
mirror." It is an out-of-band CLI argument (`https://github.com/vyos/vyos-build.git`
passed to `mirror-push.sh` itself, e.g. from a future CI job config), never
committed into the shipped tree, so it correctly does not appear in this
in-tree sweep.

## Deliberate-residual whitelist (justification)

All 5 are non-git, real 3rd-party binary/apt hosts with no DozenOS-hosted
equivalent yet (a deliberate, revisitable decision — see
`overlay/logic-patches/revert-source-mirror-urls.sh` and
`overlay/value-fixes/pin-toolchain-apt-source.sh` headers): reverting them to
`dozenos.*` would produce a URL that never resolves and break the build
(firmware/driver tarball fetch, apt package install, SBOM tool download).
Unlike git `scm_url`s (which correctly point at `github.com/dozenos/*` once
that mirror exists — verified: all 14 `pin-helper-scm-urls.sh`-tracked git
scm_urls read `github.com/dozenos/*` in this `--ci`-mode tree, 0 residual),
these are not git repos DozenOS can mirror by cloning; they are binary
artifact hosts.

## Additional checks (filenames, symlinks, binaries, encoded forms)

- Filenames/dirnames matching `*vyos*` (case-insensitive): **0** hits.
- Symlink targets containing `vyos` (case-insensitive, read via `readlink`,
  not dereferenced): **0** hits.
- 4 binary files in the tree (2 boot-splash PNGs, 2 GRUB `.pf2` fonts)
  force-scanned with `grep -a`: **0** hits.
- Base64 heuristic (both byte-alignments of all 4 case forms): **0** hits.
- URL-encoded / hyphen-or-space-split forms: **0** hits.
- Each of the four case forms swept individually: `vyos` → 5 (the whitelist
  above), `VyOS` → 0, `VYOS` → 0, `Vyos` → 0. Sum matches the
  case-insensitive total exactly — no case form is under- or
  double-counted.
- `vyatta` (case-insensitive): **41** hits, all legitimate (recipe names
  `vyatta-bash`/`vyatta-biosdevname`/`vyatta-cfg`, `/opt/vyatta/...` paths in
  `AGENTS.md` and `scripts/iso-to-oci`) — none co-occur with a genuine `vyos`
  leak (cross-checked against the full case-insensitive `vyos` list above).
- `.github/` confirmed stripped (does not exist in the reproduced tree).

## Genuine leaks found

**None.** Zero genuine brand leaks in the reproduced mode-B tree. No fix was
needed; `rename-transform.sh`/`rebrand-map.conf`/the overlay were left
untouched.

## Live-repo cross-check

```
git clone --depth 1 https://github.com/dozenos/dozenos-build.git <scratch>/live-check/live
```

- Live repo's `HEAD` commit: `sync: rename-transform snapshot (upstream @fce9b6d)`
  — **same upstream SHA** (`fce9b6d`) as the freshly reproduced tree, i.e. the
  live mirror is already up to date with the current upstream `rolling` tip;
  no upstream drift to re-sync for.
- Live-repo sweep (same methodology: content, filenames, symlink targets):
  **identical 5 hits**, same files, same lines, same content, byte-for-byte.
- `vyatta` count: **41** in both trees — identical.
- `diff -rq <reproduced-tree> <live-repo> -x .git`: only difference is a
  `packages/` directory present in the raw pre-`git-add` reproduced clone but
  absent from the live repo. Root cause: `packages/.gitignore` in pristine
  upstream contains `/*`, which (per `git add -A`'s own-`.gitignore`-file
  semantics) causes the file to ignore itself when a real `git init`/`git
  add -A` runs during the seed/sync push step — `--dry-run` stops short of
  that step, so the raw clone still has the literal file on disk. This is
  expected git behavior, not a brand leak or a tree regression (confirmed
  `packages/.gitignore`'s only content is `/*`; no `vyos` string involved).
- **Result: MATCH, no drift.** The live pushed repo's brand-sweep result is
  identical to the freshly reproduced mode-B tree.

## Does `dozenos-build` need a re-sync?

**No.** The live repo is already at the same upstream SHA (`fce9b6d`) the
reproduction pulled, carries the identical 5-item deliberate-residual set and
zero genuine leaks, and no fix was made this cycle (there was nothing to
fix). No re-sync is required by this acceptance gate.

## Test suite results

Ran the full `dozenos-rebrand/test/*.sh` suite as a baseline/regression check
(no code was changed, so this simply confirms the toolkit is in the same
verified-passing state the sweep just exercised):

| Suite | Result |
|---|---|
| `test-apply-overlay-dozenos-1x.sh` | 11 passed, 0 failed |
| `test-apply-overlay.sh` | 35 passed, 0 failed |
| `test-mirror-push.sh` | 25 passed, 0 failed |
| `test-rebrand.sh` | 13 passed, 0 failed |
| `test-wire-prebuild-hooks.sh` | 18 passed, 0 failed |
| **Total** | **102 passed, 0 failed** |

## Final verdict

*(See the reconciliation note at the top of this file: the "5" below is this
sweep's own non-git binary/apt-host scope only. The current, correct,
`--ci`-mode total including `pin-nonmirrored-org-refs.sh`'s residuals is 9 —
still zero genuine leaks, tracked in `overlay/expected-residuals.txt`.)*

**PASS** — zero genuine `vyos` brand leaks in the mode-B `dozenos-build`
tree. The only residual `vyos` hits (5) are the known, documented, deliberate
build-time pointers to real 3rd-party non-git hosts, exactly matching the
whitelisted set. `vyatta` is fully preserved (41 legitimate occurrences,
none hiding a genuine leak). No filename, symlink-target, binary, base64, or
URL-encoded leak exists. The live `github.com/dozenos/dozenos-build` mirror
matches the reproduced tree exactly (same upstream SHA, same residuals, no
drift). No fix was required; the full test suite (102 assertions) passes
unchanged.
