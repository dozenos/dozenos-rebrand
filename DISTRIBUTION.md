# DISTRIBUTION.md — DozenOS artifact/release distribution model (item #9)

Authoritative spec for how DozenOS build artifacts move: from build job to
build job (ephemeral), and from a finished nightly build to a consumer
(durable). This document specifies the model and the reusable helper
building blocks under `release/`; it does **not** author the nightly
workflow itself — that is item #17, which *consumes* these helpers. See
`WORKFLOW-POLICY.md`'s "Release distribution (#9)" section for the
cross-reference, and `overlay-dozenos-build/MANIFEST.md` for where the item #8 build
workflows (which produce the ephemeral `.deb` artifacts this document
describes) already live.

## 1. No public apt mirror — image-based upgrade

DozenOS ships as a **whole-ISO, image-based upgrade**, the same model VyOS
itself uses: a consumer downloads a new ISO and swaps the whole image. There
is **no runtime `apt upgrade`** against a DozenOS package repo, and
therefore **no public/persistent apt mirror** to host, sign, or rate-limit.

This is a locked decision (superseding the original CI/CD plan's apt-mirror
row — see `CI-SECRETS.md`'s "GPG role reconciliation" section for the full
history). Concretely, this ruled out:

- A public/persistent apt repository serving DozenOS `.deb`s.
- `DOZENOS_MIRROR_URL`, and any Cloudflare/R2 object-storage secrets to back
  it — confirmed absent from `CI-SECRETS.md` ("Not present" note).
- Any rate-limiting concern for package downloads, since there is no
  standing package-download endpoint to rate-limit.

Packages still get **built** (that doesn't change — DozenOS rebuilds every
VyOS-derived `.deb` from source, per the C2 build system), but built
`.deb`s never need a durable, publicly-reachable home. They only need to
travel from the job that built them to the job that assembles the ISO. That
is what tier (a) below is for.

### §1a. Amendment (user-approved 2026-07-09): the deb-cache is not that mirror

`dozenos/dozenos-deb-cache` (see `DEB-CACHE.md`) durably stores built
`.deb`s as content-addressed GitHub Release entries so unchanged packages
skip their nightly rebuild. It does NOT reopen the decision above: there is
no `Packages`/`Release` index, no apt-reachable endpoint, no OS-runtime
consumer, no signing/rate-limit burden — its only readers are the CI jobs
that previously rebuilt the same bytes from source, and tier (a) below
remains exactly how `.deb`s travel into an ISO build. The decision this
section locks (image-based upgrade, no runtime package repo) is unchanged.

## 2. Two artifact tiers

### (a) Ephemeral: CI-internal `.deb` passing (job → job, within a run)

Mechanism: `actions/upload-artifact` / `actions/download-artifact`
(GitHub Actions' own artifact store), as already wired up in
`overlay-dozenos-build/new-files/.github/workflows/rebuild-packages.yml`'s `build` job
(`Upload built package(s)`, `retention-days: 7`).

- **Scope:** build-internal only. A `.deb` uploaded here exists to let a
  later job (or a later step of the same workflow run) in the *same*
  workflow — or item #13's ephemeral in-job apt repo, which consumes these
  `.deb`s to source packages for an ISO build — pick it up. It is never
  advertised to, or fetched by, anything outside the CI run(s) that produced
  and consume it.
- **Retention:** GitHub Actions artifacts **expire** — a hard **90-day**
  platform ceiling, and `rebuild-packages.yml` currently sets an even
  shorter `retention-days: 7`. This is fine and intentional: nothing outside
  the build pipeline is supposed to depend on an artifact still existing 8
  days later. If a consumer needs a `.deb` that's already expired, the
  correct action is to re-run the build, not to extend retention.
  Expiring artifacts is a **feature** here, not a limitation to work around
  — it keeps the ephemeral tier honest about not being a mirror.
- **Trust model:** these `.deb`s are unsigned (`dpkg-buildpackage -us -uc`,
  matching upstream — see `rebuild-packages.yml`'s own header comment) and
  consumed inside a controlled, single-tenant build environment (the
  ephemeral in-job apt repo is `[trusted=yes]`, per `CI-SECRETS.md`'s GPG
  role reconciliation). That's acceptable *only* because tier (a) never
  leaves the build's trust boundary — nothing here is ever offered to an
  external consumer to install.
- **Owner:** item #13 (ephemeral in-job apt repo) decides exactly how these
  `.deb`s get consumed when assembling an ISO (`dpkg-scanpackages`/`reprepro`
  over the artifact-store contents, pointed to by `--dozenos-mirror
  file://...` or similar). That mechanism is item #13's concern; this
  document only draws the boundary: tier (a) is where those `.deb`s come
  from, tier (b) below is what tier (a) eventually feeds into producing.

### (b) Durable: the GitHub Release in `dozenos/dozenos-nightly-build`

Mechanism: `gh release create` (a real GitHub Release, not a workflow
artifact), publishing into the repo `dozenos/dozenos-nightly-build` — the
repo that *runs* the nightly build **and** *stores* its releases (item #17;
distinct from VyOS's own nightly repo, which is store-only and does not
itself run builds).

- **Scope:** the **finished ISO** for that nightly build, plus everything a
  consumer needs to verify it: the detached minisign signature, a
  `version.json` pointer, a `sha256`, and the public verify key
  (`minisign.pub`). This is the artifact DozenOS actually distributes to
  end users/downstream consumers — analogous to VyOS's own nightly ISO
  release.
- **Retention:** GitHub Releases **do not expire**. This is precisely why
  the durable artifact — the thing a real consumer downloads and installs —
  lives here and not in the ephemeral artifact store: a consumer following
  a `version.json` pointer from last month (or last year) must still find a
  working download.
- **Not durable here:** individual `.deb`s. Rebuilding a specific historical
  `.deb` from a past nightly is out of scope for this tier — the durable,
  consumer-facing unit of distribution is the whole ISO, matching the
  image-based-upgrade model in §1. (A future "release the .deb set too"
  decision, if ever made, is a separate, additional tier — not implied by
  anything in this document.)

### Why this split, restated plainly

| | Tier (a): ephemeral artifacts | Tier (b): GitHub Release |
|---|---|---|
| Holds | intra-run `.deb`s | ISO + `.minisig` + `version.json` + `minisign.pub` |
| Retention | ≤90d platform cap (7d as configured) | permanent |
| Audience | later jobs in the same build pipeline | end users / downstream consumers |
| Signed? | no (`-us -uc`, trusted only inside the build) | yes (minisign detached sig) |
| Repo | `dozenos-build` (produces them) | `dozenos-nightly-build` (publishes them) |

The retention contrast is the whole reason for the two-tier design: use the
cheap, auto-expiring mechanism for anything that only needs to survive one
pipeline run, and reserve the permanent mechanism for the one artifact set
an external consumer actually needs to keep finding later.

## 3. Release tag / version scheme

Follows VyOS's own nightly-release convention directly (reference format
observed on VyOS's real nightly releases, e.g. tag `2026.06.30-0048-rolling`
shipping asset `vyos-2026.06.30-0048-rolling-generic-amd64.iso`):

- **Version string / release tag:** `YYYY.MM.DD-HHMM-rolling`, generated at
  build time as:
  ```sh
  version="$(date -u +%Y.%m.%d-%H%M)-rolling"
  ```
  This string is used **both** as the `gh release create <tag>` tag **and**
  as the `--version` value passed to the DozenOS image builder
  (`build-dozenos-image`'s own `--version` flag).
- **ISO asset name:** `dozenos-<version>-generic-amd64.iso`, e.g.
  `dozenos-2026.07.08-0130-rolling-generic-amd64.iso` — same
  `<project>-<version>-<edition>-<arch>.iso` shape as VyOS's own asset
  naming, `vyos-` swapped for `dozenos-`.
- **Full asset set per release** (all four, every nightly):

  | Asset | Produced by | Purpose |
  |---|---|---|
  | `dozenos-<version>-generic-amd64.iso` | image build (item #17's job) | the installable image |
  | `dozenos-<version>-generic-amd64.iso.minisig` | `release/sign-and-publish.sh` | detached minisign signature over the ISO |
  | `version.json` | `release/gen-version-json.sh` | machine-readable pointer: latest version, ISO name/URL, sha256, minisig name/URL |
  | (sha256) | embedded *inside* `version.json`'s `iso.sha256` field, not shipped as a separate `.sha256` file | integrity check, paired with the minisign signature (belt-and-suspenders: minisign already covers integrity+authenticity; the sha256 field lets a consumer check the download without invoking minisign first) |

  `minisign.pub` (the public verify key) is **not** a per-release asset — it
  is a **single, stable file committed in `dozenos-nightly-build`**, reused
  across every nightly release (see §5). It is listed here because a
  consumer needs it alongside the four per-release assets to complete
  verification, not because it changes every release.

## 4. `version.json` schema

Generated by `release/gen-version-json.sh` (see that script's `--help` for
the exact CLI). Fields:

| Field | Type | Meaning |
|---|---|---|
| `version` | string | The release version/tag, `YYYY.MM.DD-HHMM-rolling`. |
| `artifacts[]` | array | One entry per released image file (multi-flavor/multi-format). |
| `artifacts[].flavor` | string | Flavor name (toml basename), e.g. `generic`, `kvm`. |
| `artifacts[].install_type` | string \| null | The `flavors/<subdir>` the flavor toml came from — `fresh-install` or `upgrade` — distinguishing installer images from upgrade images that share a flavor name. `null` when the generator was given the legacy two-field `--artifact` form. |
| `artifacts[].format` | string | File extension: `iso`, `qcow2`, `vmdk`, ... |
| `artifacts[].name` | string | Asset filename. |
| `artifacts[].sha256` | string | Lowercase hex sha256 of the file, computed by `sha256sum`. |
| `artifacts[].url` | string \| null | Full download URL, or `null` if `--release-url` was not supplied to the generator. |
| `artifacts[].minisig` | object | `name`/`url` of the detached signature asset, same null rule. |
| `iso.*`, `minisig.*` (top-level) | object \| null | **Legacy** single-ISO pointers kept for backward compatibility: the `generic` flavor's `.iso` when present, else the first `.iso`; `null` when no `.iso` was released. New consumers should read `artifacts[]`. |
| `minisign_pubkey_file` | string | Filename of the public verify key **as committed in this repo** (`minisign.pub`) — a fixed pointer, not a per-release value; a consumer resolves it relative to the `dozenos-nightly-build` repo root, not relative to the release's own asset list. |
| `published_at` | string | UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) of when `version.json` was generated. |

### Worked example

```json
{
  "version": "2026.07.08-0130-rolling",
  "iso": {
    "name": "dozenos-2026.07.08-0130-rolling-generic-amd64.iso",
    "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a1",
    "url": "https://github.com/dozenos/dozenos-nightly-build/releases/download/2026.07.08-0130-rolling/dozenos-2026.07.08-0130-rolling-generic-amd64.iso"
  },
  "minisig": {
    "name": "dozenos-2026.07.08-0130-rolling-generic-amd64.iso.minisig",
    "url": "https://github.com/dozenos/dozenos-nightly-build/releases/download/2026.07.08-0130-rolling/dozenos-2026.07.08-0130-rolling-generic-amd64.iso.minisig"
  },
  "artifacts": [
    {
      "flavor": "generic",
      "install_type": "fresh-install",
      "format": "iso",
      "name": "dozenos-2026.07.08-0130-rolling-generic-amd64.iso",
      "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a1",
      "url": "https://github.com/dozenos/dozenos-nightly-build/releases/download/2026.07.08-0130-rolling/dozenos-2026.07.08-0130-rolling-generic-amd64.iso",
      "minisig": {
        "name": "dozenos-2026.07.08-0130-rolling-generic-amd64.iso.minisig",
        "url": "https://github.com/dozenos/dozenos-nightly-build/releases/download/2026.07.08-0130-rolling/dozenos-2026.07.08-0130-rolling-generic-amd64.iso.minisig"
      }
    }
  ],
  "minisign_pubkey_file": "minisign.pub",
  "published_at": "2026-07-08T01:35:00Z"
}
```

`version.json` itself is published as **both** a release asset (a snapshot
frozen alongside that specific release) **and**, by convention, updated at
the `dozenos-nightly-build` repo's well-known "latest" location (e.g. the
repo's default-branch `version.json`, or a `latest` release alias) so a
consumer always has one stable URL for "what's current" without having to
query the Releases API. Which exact "latest" publication mechanism item #17
uses (default-branch commit vs. a `latest`-tagged release vs. both) is
item #17's own implementation choice — this document only fixes the schema
and the per-release asset set, not that plumbing detail.

## 5. Consumer verify flow

A consumer who has downloaded the ISO plus `version.json` runs, in order:

1. **Fetch the public verify key**, `minisign.pub`, from the
   `dozenos-nightly-build` repo (a small, stable, committed file — see §6).
2. **Check the sha256** against `version.json`'s `iso.sha256`:
   ```sh
   sha256sum dozenos-2026.07.08-0130-rolling-generic-amd64.iso
   # compare to version.json's iso.sha256 field
   ```
3. **Verify the minisign signature**, using either the pubkey file or its
   inline contents:
   ```sh
   minisign -Vm dozenos-2026.07.08-0130-rolling-generic-amd64.iso -p minisign.pub
   # or, inline (no separate pubkey file on disk):
   minisign -Vm dozenos-2026.07.08-0130-rolling-generic-amd64.iso -P "$(cat minisign.pub)"
   ```
   `minisign -V` fails loudly (non-zero exit) on a mismatched signature,
   tampered ISO, or wrong key — a consumer's tooling should treat any
   non-zero exit here as "do not install this image."

The sha256 check and the minisign check are intentionally both present:
minisign already covers both integrity and authenticity, so step 2 is
strictly redundant with step 3 for a consumer who trusts `minisign.pub` —
but it lets tooling do a cheap sanity check (or resume a partial download)
without invoking minisign, and it gives a human a second, simpler thing to
eyeball.

## 6. `minisign.pub` is PUBLIC — hard rule

- `minisign.pub` is the **public** half of the minisign keypair whose
  private half is stored, base64-encoded, in the org secret
  `MINISIGN_SECRET_KEY` (see `CI-SECRETS.md`).
- It is committed as a plain file in `dozenos-nightly-build` (maintainer-
  provided/committed once, updated only if the keypair itself is rotated) —
  **or**, equivalently, re-derived at CI time from the secret via
  `minisign -R -s <decoded seckey> -p minisign.pub` (the public key is a
  deterministic function of the secret key + its password, so either
  approach yields the identical file). Either way the file that ends up
  published is public material with no confidentiality requirement.
- **This is a distinct key from the `dozenos-{backup,release,rolling-release}.minisign.pub`
  files already shipped inside the built image** (see
  `TRANSFORM-COMPLETENESS-AUDIT.md` item #10) — those back a different,
  in-image mechanism and are out of scope for this document. The
  `minisign.pub` this document describes is specifically the release-verify
  key paired with `MINISIGN_SECRET_KEY`, hosted in `dozenos-nightly-build`
  for verifying the *release asset itself*, not anything baked into the ISO.
- **Hard rule, no exceptions:** this task, `release/*`, and any CI workflow
  that consumes these helpers must **never** embed, print, log, or generate
  the **private** minisign key. Every reference in this repo's tooling to
  minisign key material is a reference to the secret **names**
  (`MINISIGN_SECRET_KEY`, `MINISIGN_PASSWORD`) — never to key bytes. See
  `release/sign-and-publish.sh`'s own header for the same rule restated at
  the point where the private key is actually (transiently) decoded to disk.

## 7. `GITHUB_TOKEN` suffices — no cross-repo credential needed

Publishing the Release happens **inside** `dozenos-nightly-build` itself
(item #17's workflow runs there, and publishes there) — this is a
same-repo operation. The workflow's own ambient `GITHUB_TOKEN` (with
`contents: write` permission granted in that job) is sufficient for
`gh release create`; **no cross-repo credential is needed for this step.**
A cross-repo credential — the runtime-minted org GitHub App token
(`vars.BUILD_APP_ID` + `secrets.BUILD_APP_PRIVATE_KEY`, which replaced the
retired `BUILD_PAT`; see `CI-SECRETS.md` §4) — remains necessary elsewhere
in item #17's workflow for genuinely cross-repo operations (checking out
`dozenos-build` and `dozenos-rebrand` into the `dozenos-nightly-build`
job), but the Release-publish step itself is same-repo and should use
`GITHUB_TOKEN`, not an App token, to keep the cross-repo credential out of
a step that doesn't need it.

## 8. Cross-references

- **Implements this spec:** item #17 (`dozenos-nightly-build`'s nightly
  workflow) — not authored here; it calls `release/gen-version-json.sh` and
  `release/sign-and-publish.sh` as building blocks.
- **Upstream of this spec:** item #13 (ephemeral in-job apt repo) decides
  how tier (a)'s `.deb` artifacts get consumed to source the ISO's package
  set. That mechanism is item #13's concern; this document only names the
  boundary (tier (a) is where those `.deb`s live before item #13 consumes
  them; tier (b) is what the resulting ISO becomes afterward).
- **Secret names:** `CI-SECRETS.md` is authoritative for
  `MINISIGN_SECRET_KEY`, `MINISIGN_PASSWORD`, `GITHUB_TOKEN`, and the
  `BUILD_APP_ID`/`BUILD_APP_PRIVATE_KEY` App pair (replaced the retired
  `BUILD_PAT`). This document does not redefine any of them, only states
  which step of the release flow consumes which one.
- **Workflow policy / discoverability:** `WORKFLOW-POLICY.md`'s "Release
  distribution (#9)" section; `overlay-dozenos-build/MANIFEST.md`'s note on `release/`
  (toolkit, not overlay content — see that note for the placement
  reasoning).
