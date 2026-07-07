# Post-transform overlay (mode-B CI)

**Status: populated (item #18b).** This directory is the landing zone for
everything a fresh `vyos-build` clone needs *in addition to*
`rename-transform.sh` + `../wire-prebuild-hooks.sh` to reproduce our full
DozenOS delta, applied by `apply-overlay.sh`. See
`../TRANSFORM-COMPLETENESS-AUDIT.md` (item #18) for the full audit this
overlay is derived from, and `MANIFEST.md` for exactly what landed in each
bucket, the decisions made, and the repro-test results.

## Why an overlay exists at all

`rename-transform.sh` is a pure, deterministic, case-preserving four-form
text/rename transform. It is intentionally dumb: same input tree -> same
output tree, every time, no exceptions, no external state. That's exactly
why it's safe to run unattended in CI. But it structurally **cannot**:

- author brand-new files (new build recipes, new docs) — `new-files/`
- change a *value* rather than a *string* (password hashes, X.509 certs,
  cryptographic key material) — `value-fixes/`
- make a judgment call that depends on external state (does the
  `github.com/dozenos/*` mirror repo exist yet? is the ephemeral CI package
  mirror URL known at transform time?) or add non-renaming logic
  (an `if vyos_mirror:` guard, a build-env-leak strip step) — `logic-patches/`

Everything the transform *can* do deterministically (four-form renames,
including the `pre_build_hook` wiring described in the audit's item #4,
implemented as `../wire-prebuild-hooks.sh`) should stay in
`rename-transform.sh`/`rebrand-map.conf`/`wire-prebuild-hooks.sh`, not here.
If you're tempted to add a plain string substitution to this overlay, it
probably belongs in `rebrand-map.conf` instead.

This overlay is scoped to the **vyos-build repo only**. Per-package source
repos (e.g. `vyos-1x` -> `dozenos-1x`) get their own overlay as part of the
per-repo mirror step — see `MANIFEST.md`'s "Per-repo overlay split" section.

## Directory layout

```
overlay/
  README.md          this file
  MANIFEST.md         enumerated inventory: what will live here, sourced from
                       which current vyos-build working-tree path, and which
                       audit item it corresponds to
  new-files/           whole files/dirs to copy in verbatim, mirrored by
                       repo-relative path (e.g. new-files/scripts/package-build/hvinfo/)
  value-fixes/         scripts for value-not-string or external-state-dependent
                       changes (MOK cert removal, scm_url / apt-source
                       host reverts). Password-hash regen and throwaway
                       signing keys are deliberately NOT here — see MANIFEST.md.
  logic-patches/       small idempotent scripts (not unified diffs -- more
                       robust against upstream-sync line drift) for
                       non-renaming logic changes and external-host reverts
                       that the transform gets wrong (vyos_mirror guard,
                       linux-kernel source-mirror tarball URLs)
  apply-overlay.sh     the actual apply script -- runs all 3 buckets above,
                       in order, against an already-transformed,
                       already-hooked target tree
```

## Apply order (mode-B CI)

1. `git clone` a fresh upstream `vyos-build@rolling`.
2. Run `rename-transform.sh <tree>` (four-form + email rewrite).
3. Run `../wire-prebuild-hooks.sh <tree>/scripts/package-build` (injects
   `pre_build_hook` into every recipe block that needs it and doesn't
   already have one; excludes `linux-kernel` — see audit item #4 / MANIFEST.md).
4. Run `overlay/apply-overlay.sh [--ci|--local] <tree>` (new-files ->
   logic-patches -> value-fixes, in that order; see `apply-overlay.sh`'s own
   header for exactly what each step does, and "Modes" below).
5. Build.

Every step above must be idempotent and side-effect-free when re-run (same
contract `rename-transform.sh` already holds), since CI may retry.

## Modes: `--ci` (default) vs `--local` (item #18c)

`apply-overlay.sh` takes an optional mode flag. It changes exactly ONE thing:
whether `value-fixes/pin-helper-scm-urls.sh` runs (it reverts 8 mirrored git
`scm_url`s from `github.com/dozenos/*` back to `github.com/vyos/*`).

| Mode | When | 8 mirrored git `scm_url`s (pin-helper-scm-urls.sh) | Everything else (new-files/, logic-patches/, the other 2 value-fixes scripts) |
|---|---|---|---|
| `--ci` (**default**) | post-mirror: the `github.com/dozenos/*` mirrors for those 8 repos already exist and resolve — this is every `mirror-push.sh --build-repo` invocation, since `dozenos-build` is pushed leaf-first, after its dependency mirrors | **skipped** — stay at `github.com/dozenos/*` | runs, same in both modes |
| `--local` | pre-mirror/offline: a from-scratch local/offline build before any `dozenos/*` mirror has been pushed | **runs** — pinned back to `github.com/vyos/*` (always resolvable) | runs, same in both modes |

Default is `--ci` because that is the assumption that holds for this script's
primary, ongoing use (CI / post-mirror builds); `--local` is the narrower,
temporary, pre-mirror-existence case and must be requested explicitly rather
than assumed. `pin-toolchain-apt-source.sh` (non-git `packages.vyos.net` /
`cdn.vyos.io` hosts), the source-mirror tarball-fetch revert, the
`vyos_mirror`/`dozenos_mirror` guard, `remove-committed-mok-cert.sh`, and
`new-files/` all run in **both** modes — none of them depend on whether the
dozenos/* git mirrors exist.

Not a mode-switch/convert operation: running `--local` then `--ci` against
the same tree does not forward-migrate the 8 scm_urls back to
`github.com/dozenos/*` (`--ci` just skips the revert script, it does not run
it in reverse). Always apply the overlay once, in the desired mode, against a
freshly transformed tree — which is how every mode-B pipeline (including
`mirror-push.sh`) actually uses it.

## What is intentionally NOT here

- Anything `rename-transform.sh` already reproduces correctly (see audit
  categories AUTO/FOLD) — duplicating it here would create two sources of
  truth that can drift.
- `.powerloop/` — local batch-execution bookkeeping, never shipped.
- Anything that is a one-time local-build workaround with no CI relevance
  (e.g. the pre-image-#14 byte-substitution debrand of already-built
  `.deb`s) — see audit item #20.
