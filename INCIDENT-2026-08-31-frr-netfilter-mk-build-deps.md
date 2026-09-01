# Incident: frr/netfilter mk-build-deps failures (2026-08-31 / 2026-09-01)

## Symptom

`dozenos-nightly-build` (amd64) runs `33384130392`, `33379809420`,
`33488603411` all failed the `build-packages (frr)` and
`build-packages (netfilter)` jobs at the `mk-build-deps --install` step:

```
mk-build-deps: Unable to install frr-build-deps at /usr/bin/mk-build-deps line 459.
E: Failed to create/install dependency package for frr: Command 'sudo mk-build-deps --install ...' returned non-zero exit status 1.
```

and the same for `nftables-build-deps` in the netfilter job.

## Root cause

`docker/dozenos-dev.list` (a build-container-only apt source, baked into
`ghcr.io/dozenos/dozenos-build:rolling`) was rebranded on 2026-08-19 (commit
`caf0c93`) from the real, resolvable `packages.vyos.net` host to
`packages.dozenos.net`, which does not exist and never has.

frr's `debian/control` declares:

```
libyang-dev (>= 3.0.3) | libyang2-dev (>= 2.1.128)
```

Debian bookworm's own `libyang2-dev` is `2.1.30-2` — well short of
`2.1.128` — and bookworm-backports/trixie don't help either (trixie renamed
the package to `libyang-dev 3.12.2-1`, not usable on a bookworm-slim
container). The only source that ever supplied a satisfying `libyang-dev`
was `packages.vyos.net`'s rolling apt repo — VyOS's own upstream rolling
repo happens to carry the exact same `libyang3 3.13.6-1` / `libyang-dev
3.13.6-1` that `dozenos-build`'s own `frr` recipe builds locally. Netfilter
hits the identical problem for `libnftnl-dev`.

`dozenos-build`'s `scripts/package-build/build.py` runs `mk-build-deps
--install` (pure apt, no local `.deb`s visible yet) before it ever installs
the locally-built `.deb`s via `build_cmd`'s `dpkg -i ../*.deb`, so the
locally-built libyang/libnftnl packages were never an alternative path —
`packages.vyos.net` was the only thing making `mk-build-deps` succeed at
all.

## Why it stayed dormant for 12 days

`ghcr.io/dozenos/dozenos-build:rolling` was rebuilt with the broken
`dozenos-dev.list` on 2026-08-19 (the image workflow triggers on push to
`docker/**`). But `dozenos-nightly-build`'s content-keyed deb-cache
(`dozenos/dozenos-deb-cache`) kept HIT-ing the frr/netfilter cache entries
built before the break (last real build: 2026-08-12, entry
`frr-81a898a58314`) — the recipe content and the frr/libyang pins never
changed, so the cache key never changed, so `mk-build-deps` never actually
ran again.

On 2026-08-31 `dozenos-build`'s daily self-sync bumped
`data/defaults.toml`'s `kernel_version` (`6.18.44` → `6.18.48`). That file
is a *global* input to every unit's deb-cache key (per
`dozenos-rebrand/release/deb-cache.sh`'s own key-material doc), so every
package's cache key changed at once — including frr's and netfilter's,
which had nothing to do with the kernel. That forced a real rebuild for the
first time since 2026-08-19, and `mk-build-deps` hit the missing apt source
immediately.

## Fix

`overlay-dozenos-build/new-files/docker/vyos-dev.list` — a brand-new file,
its content recovered verbatim from `dozenos-build` history at commit
`5b4005f` (the last commit before the 2026-08-19 rebrand) — restores the
real `packages.vyos.net` apt source as its own file, installed by
`overlay-dozenos-build/logic-patches/dockerfile-vyos-dev-list.sh` alongside
(not instead of) the still-rebranded `docker/dozenos-dev.list`.
`dozenos-dev.list` is deliberately left untouched: it stays pointed at
`packages.dozenos.net` and will take over cleanly if that host is ever
actually stood up, with `vyos-dev.list` simply becoming redundant at that
point (not a conflict — apt is happy to see the same package offered by two
sources).

## Note for future readers

Upstream `vyos-build` itself dropped this apt source from its own
`dozenos-dev.list`-equivalent file on 2026-08-16 (`35091fc`, T9216: "the dev
container no longer consumes the VyOS binary repository at all") — three
days before DozenOS's rebrand pass broke the URL. Upstream's own
`build.py` still has the same `mk-build-deps`-before-local-install
ordering, unchanged, so either VyOS's real infrastructure provides
prebuilt `libyang-dev`/`libnftnl-dev` through some other channel their CI
has that DozenOS does not, or their own nightly frr/netfilter builds are
equally exposed and untested. Restoring `packages.vyos.net` here is a
DozenOS-side pragmatic fix, not a reversion to upstream parity — see
`DISTRIBUTION.md` §1a for why this is deliberately not "the public apt
mirror" that document rules out.
