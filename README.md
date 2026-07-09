# dozenos-rebrand

The DozenOS rebrand **toolkit**: the transform scripts, overlays, dependency-graph
helpers, and release tooling that turn a fresh clone of an upstream VyOS repo
into its DozenOS mirror counterpart. This repo is itself checked out at the
workspace-relative path `/dozenos-rebrand` by CI jobs across the
`github.com/dozenos/*` org (mirror-push, incremental rebuild, nightly build) --
see `SYNC.md` and `REBUILD-DISPATCH.md` for the exact checkout steps.

DozenOS is a rebrand of [VyOS](https://vyos.io); this toolkit does not ship a
distribution itself, it only produces one from upstream VyOS sources.

## The rebrand: four-form transform, keep-vyatta

The core rule, applied case-sensitively and idempotently to every text file
and path (`rename-transform.sh` + `rebrand-map.conf`):

| from    | to        |
|---------|-----------|
| `vyos`  | `dozenos` |
| `VyOS`  | `DozenOS` |
| `VYOS`  | `DOZENOS` |
| `Vyos`  | `Dozenos` |

These four are the only spellings that occur in VyOS trees, the four output
tokens contain none of the four input tokens, so rule order doesn't matter
and running the transform twice is a no-op.

**`vyatta` is deliberately left untouched.** VyOS's own codebase still carries
`vyatta`-named paths, configs, and identifiers from its Vyatta Core lineage;
those are upstream's own naming, not a `vyos` token, and rewriting them would
diverge from upstream instead of just rebranding it. The transform's own
`--verify` mode asserts the tree is zero-`vyos` (excluding this toolkit's own
files, where `vyos` is data, not a shipped artifact) while leaving every
`vyatta` occurrence exactly as upstream wrote it.

## Key scripts and directories

- **`rename-transform.sh`** / **`rebrand-map.conf`** -- the deterministic
  four-form rename/rewrite. Pure text transform, no external state, safe to
  run unattended in CI. `--verify` asserts zero residual `vyos` tokens.
- **`wire-prebuild-hooks.sh`** -- ensures every recipe that clones its own
  upstream source at build time (`scripts/package-build/*/package.toml`) runs
  `rename-transform.sh` against that freshly cloned source via a
  `pre_build_hook`, so recipe-built package content is rebranded too, not
  just the tree the recipe itself lives in.
- **`mirror-push.sh`** -- the end-to-end mirror-push pipeline: clone upstream
  -> transform -> strip `.github/` -> optional build-repo/overlay steps ->
  generate `sync.yml` from `sync.yml.template` -> verify -> push to
  `github.com/dozenos/<target>` (seed or snapshot-sync mode, detected
  automatically). Supports `--dry-run` and `--work <dir>` (scratch dir,
  defaults to a fresh `mktemp -d`).
- **`overlay-dozenos-build/`** -- post-transform overlay for the `vyos-build` repo: new
  files, value fixes, and logic patches the pure text transform structurally
  cannot produce. See `overlay-dozenos-build/README.md` and `overlay-dozenos-build/MANIFEST.md`.
- **`overlay-dozenos-1x/`** -- the equivalent per-repo overlay for the
  `vyos-1x` -> `dozenos-1x` mirror.
- **`dep-graph/`** -- `dep-graph.json` plus `resolve-rebuild-set.sh`
  (transitive-closure incremental-rebuild resolver) and
  `validate-dep-graph.sh` (graph-integrity check).
- **`release/`** -- nightly-build release helpers: `gen-version-json.sh`,
  `sign-and-publish.sh` (minisign + GitHub Release), `inject-mok-cert.sh`
  (Secure Boot MOK signing material), `make-ephemeral-apt-repo.sh`
  (in-job, non-persistent apt repo).
- **`test/`** -- self-contained, network-free test scripts for the tooling
  above.

Longer-form design notes and audits (`DISTRIBUTION.md`, `SYNC.md`,
`REBUILD-DISPATCH.md`, `SB-SIGNING.md`, `TRANSFORM-COMPLETENESS-AUDIT.md`,
`WORKFLOW-POLICY.md`, and friends) live alongside the scripts they document.

## License

GPLv3 -- see [`LICENSE`](./LICENSE). This matches the license of upstream
VyOS, which this toolkit rebrands.

## Security: `keys/` is local-only, never published

`keys/` holds throwaway development key material (a dev GPG private key, a
minisign secret key, a local `gnupg/` homedir) used only for local/dev
signing experiments. It is:

- excluded by its own `keys/.gitignore` (a bare `*`, so git never tracks
  anything under `keys/`, including that `.gitignore` file itself), and
- excluded again at the top level by this repo's `.gitignore`,

so it is never staged, committed, or pushed to this (public) repo under any
normal git operation. Real CI signing secrets live only as named GitHub
Actions org/repo secrets referenced by name -- see `CI-SECRETS.md`, which
records secret *names* and consumers only, never values.

If you ever need real signing keys for your own DozenOS build, generate your
own and keep them out of version control; do not reuse or expect the
placeholder material referenced above.
