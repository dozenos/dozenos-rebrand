# Rebrand Transform — Landmines & Deliberate Decisions

Careful cases from `REBRAND-PLAN.md` Appendix C, and exactly where
`rename-transform.sh` **does** and **does not** touch them. Read this before
adding rules to `rebrand-map.conf`.

## The core invariant (why this is safe at all)

Four case-sensitive, case-preserving rules (see `rebrand-map.conf`):

```
vyos -> dozenos      VyOS -> DozenOS
VYOS -> DOZENOS      Vyos -> Dozenos
```

- **`vyatta` is preserved automatically.** None of `vyos/VyOS/VYOS/Vyos` is a
  substring of `vyatta/Vyatta/VYATTA`, so substring replacement never touches
  it. The script also asserts this non-overlap at start-up and aborts if a
  future rule would violate it.
- **Idempotent by construction.** The four output tokens
  (`dozenos/DozenOS/DOZENOS/Dozenos`) contain none of the input tokens, so a
  second pass matches nothing → the tree is byte-identical. Verified by the
  unit test (run twice, snapshot compare).
- **No mixed forms exist.** Appendix C confirms only these four spellings
  occur in VyOS trees (no `vyOS`/`VyoS`/`vYos`), so the four rules are complete.
  The `--verify` self-check (`grep -rIi vyos == 0`) is the safety net that
  red-flags any future stray form the four rules miss.

## Handled by the generic rule (no special case needed)

The four-form rule is a **strict superset** of every item below — each contains
a `vyos` form, so all are covered by the content + path-rename passes:

| Case | Example | Result |
|---|---|---|
| C1 package names | `vyos-1x`, `libvyosconfig0`, `vyos-http-api-tools` | `dozenos-1x`, `libdozenosconfig0`, `dozenos-http-api-tools` |
| `debian/control` | `Source:`/`Package:`/`Depends:`/`Pre-Depends:`/`Provides:` | source + all binary + dep tokens renamed together |
| `debian/changelog` | source token `vyos-1x (...)` | `dozenos-1x (...)` (history preserved; see version-stamp hook below) |
| `debian/*.install/*.links` | `libvyosconfig0.install` | file **name** and contents renamed |
| Python namespace | `import vyos`, `from vyos.config import`, `vyos.` refs, `python/vyos/` dir | `dozenos` module + `python/dozenos/` dir |
| soname | `libvyosconfig0.so.0`, `shlibs`, `.symbols` | `libdozenosconfig0...` |
| systemd units | `vyos-router/configd/commitd/hostsd/netlinkd(.service)` | `dozenos-*` (name + `Description=`) |
| enable/disable hook | `18-enable-disable_services.chroot` | service tokens inside renamed |
| hardcoded paths | `/usr/libexec/vyos`, `/usr/share/vyos`, `/run/vyos`, `/etc/vyos`, `/var/log/vyos*`, dbus/apparmor names | `/…/dozenos` |
| maintainer emails | `maintainers@vyos.net`, `pkgs@vyos.net`, `*@lists.vyos.io` | `…@dozenos.local` (placeholder domain — see below) |

## Explicit landmines (Appendix C) — decisions

| Landmine | Decision | Mechanism |
|---|---|---|
| **ISO volid `VYOSNESTED`** (`scripts/check-qemu-install`) | **Replaced** consistently → `DOZENOSNESTED`. Test-only label; `VYOS→DOZENOS` rule applies everywhere it appears (mkisofs `-volid` and any matcher), so both ends stay consistent. | content pass |
| **Shell var names `VYOS_FIRMWARE_NAME` / `VYOS_FIRMWARE_DIR`** (`build-linux-firmware.sh`) | **Replaced** → `DOZENOS_FIRMWARE_*`. All uses live in one file and all use the `VYOS` form, so definition and every `${...}` expansion transform together → stays internally consistent. | content pass |
| **`kernel_flavor = "vyos"`** (`data/defaults.toml`) | **Replaced** → `"dozenos"`. This is the correct flag change. ⚠️ **Out of scope for the transform:** the kernel must be **rebuilt** so `CONFIG_LOCALVERSION`/vermagic become `-dozenos` (`uname -r`, `/lib/modules/…`, every `.ko`). That is a separate build item (REBRAND-PLAN §2c) — the flag flip belongs here, the rebuild does not. | content pass |
| **`vyos_mirror` URL** (`defaults.toml`) | Host token replaced by the generic rule. Pointing it at the real R2/mirror URL is a build-config step, not this transform's job. | content pass |
| **Maintainer / contact emails** (`maintainers@vyos.net`, `pkgs@vyos.net`, `*@lists.vyos.io`, GPG UIDs) | **Rewritten to `@dozenos.local`** — a NON-EXISTENT placeholder domain (`.local`, RFC 6762, never resolves). Runs BEFORE the four-form rules (`EMAIL_REWRITES` in `rebrand-map.conf`) so the address is zero-`vyos` yet does not imply ownership of a real `dozenos.net`/`.io`. Matches `@[host.]vyos.<tld>` (incl. subdomains); the generic rule cleans any stray form afterward. | email pass (pre-forms) |
| **strongswan patch filenames** (`0004-VyOS-…​.patch`, `0005-…`) | **Renamed** by the path pass (basename contains `VyOS`), and `debian/patches/series` is a text file whose entries are renamed by the content pass — so filename and `series` stay in sync. Purely cosmetic per Appendix C, but handling both is free and keeps the tree consistent (no orphaned series entry). | content + path pass |
| **`/opt/vyatta`** | **Preserved** (VYATTA class). Contains no `vyos` form → never matched. Verified: `/opt/vyatta`, `vyatta-op`, `VYATTA-TRAP-MIB.txt` survive intact. | not matched |
| **Symlink targets** (e.g. `99-vyos-pppoe-callback -> ../ip-up.d/99-vyos-pppoe-callback`) | **Rewritten** without dereferencing (`ln -sfn`). A dirty target is invisible to `grep -rIi vyos` (link string is not file content) but would break the package after the pointee is renamed — so it is handled explicitly, not left to the content pass. | symlink pass |

## External-upstream references inside package source (item #6 bug #5 — READ BEFORE building any package)

Some package trees reference **other upstream repos/libraries as build sources** — the same tolerated "build-time pointer" class as `scm_url`, but living *inside* the source. Blindly four-form-rebranding them breaks the build (they point at real `github.com/vyos/*` that must be fetched), yet leaving them means the linked binary keeps `vyos*` symbols. Known cases in `vyos-1x`:
- `libvyosconfig/Makefile` **opam pins** for `vyos1x-config` / `vyconf` and their `github.com/vyos/*` URLs → rebranding makes `github.com/dozenos/*` (404 on `git fetch`). **Preserve for local build** (revert to vyos upstream) OR rebrand+rebuild those libs too (see below).
- `lib/bindings.ml` `open Vyos1x` — the OCaml module name of the *external* `vyos1x-config` lib; rebranding to `Dozenos1x` breaks linkage unless that lib is also rebranded/rebuilt.

**Consequence for zero-`vyos` (#12):** if these external refs are preserved, the shipped `libdozenosconfig.so.0` carries ~1154 internal `vyos1x` OCaml symbol strings (build-time upstream). Package name / soname / paths are clean, but a `grep -ri vyos` over the shipped `.so` is NOT zero. **True zero-`vyos` requires also rebranding+rebuilding `vyos1x-config` and `vyconf`** and repointing the opam pins at them — tracked as a progress-table item. The transform tool cannot auto-distinguish "our source being rebuilt" from "external dep to fetch", so this stays a manual landmine.

## Hashed credentials — the transform CANNOT catch these (item #23, found cycle 48)

`vyos-1x/data/config.boot.default` ships the installed system's **default login**. The
four-form transform correctly renames the username (`user vyos` → `user dozenos`) and
`host-name`, BUT the default **password** is stored as a SHA-512 crypt hash
(`encrypted-password "$6$QxPS.uk6mfo$…"`) that is the hash of the plaintext `vyos`. A crypt
hash contains **no literal `vyos` substring**, so:

- `grep -ri vyos` over the shipped deb returns **0** (passes the #12 acceptance gate), YET
- the default password is still functionally **`vyos`** (the hash validates that word).

This is a **blind spot**: zero-`vyos`-by-grep does NOT imply the credential was debranded.
**Fix (manual, cannot be automated by text substitution):** regenerate the hash for a new
default password and replace it. DozenOS uses `dozenos` / `dozenos` (matching VyOS's
user==password convention). The old VyOS hash `$6$QxPS.uk6mfo$…` appears in 5 places in
`vyos-1x`: `data/config.boot.default` (the SHIPPED default — critical),
`tests/data/config.boot.default`, `src/tests/test_initial_setup.py`, and
`smoketest/configs/{firewall-groups-name,assert/firewall-groups-name}`. Generate with
`openssl passwd -6 dozenos` (salt differs each run — that's fine).

**General rule for CI:** anything that debrands by *value* rather than *string* — password
hashes, checksums of renamed files, signed digests, pre-generated keys — is invisible to the
transform and must be handled explicitly. Audit `config.boot.default` / cloud-init seeds /
any `encrypted-password` on every upstream sync.

## Git-index vs on-disk transform (item #6 bug #3)

The transform renames files **on disk only** (it never runs `git`). Build steps that read the **git index** instead of the filesystem — e.g. a `Makefile` using `$(shell git ls-files ...)` — will miss the renames and operate on stale paths. Mitigation for the per-package build flow: after running `rename-transform.sh` on a throwaway clone, run `git -C <clone> add -A` so the index matches disk (the clone is disposable — no commit, no push). If `git add` is unavailable, patch the offending `git ls-files` → `find` (preserving its glob semantics).

## Scope boundaries (intentionally NOT done by this script)

- **Target root directory** is never renamed even if its name contains `vyos`
  (`-mindepth 1`): the script transforms *contents in place* and must not pull
  the tree out from under its caller. In the sync workflow the tree lives in a
  neutral dir (`up/`), so this never matters in production; it only makes the
  script safe to run on an arbitrarily-named checkout.
- **`git` is never invoked.** Cloning, committing, and pushing the mirror are
  the sync job's responsibility (REBRAND-PLAN §3e). This toolkit is pure,
  local, deterministic tree transform.
- **Kernel / driver rebuild**, signing keys (GPG/minisign/Secure Boot), and
  `scm_url`/`UPSTREAM_URL` handling are build-pipeline concerns, not text
  transform — see REBRAND-PLAN §1 (金鑰段), §2c, §3.
- **Version-stamp hook** (`--stamp <DATE.SHA>`): optional; appends
  `+git<DATE.SHA>` to the **newest** `debian/changelog` entry so apt sees a
  monotonically-increasing version for branch-tracked packages (REBRAND-PLAN
  §3d gotcha 1). Idempotent (guarded by a `+git` check). Off by default; the
  source-package rename happens regardless.
