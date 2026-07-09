# REPOINT-AUDIT.md — item #6: repoint external refs + rename recipe dirs

Because mode-B `--ci` already repoints external refs automatically (the
four-form transform rewrites `github.com/vyos/*` → `github.com/dozenos/*` in
every `scm_url`/opam pin, and the path-rename pass renames every recipe dir),
item #6 is now an **audit + reconciliation + consistency cross-check**: prove
the shipped mirrors are correctly repointed AND that every `dozenos/*`
reference they ship actually resolves against a real, pushed mirror. This
document is that audit, plus 2 codified fixes for gaps the audit found.

## 1. Reproduce commands + tree locations

Two mode-B `--ci` trees were reproduced fresh (both `--dry-run`, nothing
pushed, no repo created/touched):

```
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-build.git \
  --target dozenos-build --build-repo --dry-run --allow-residuals \
  --work <scratch>/repoint-build-final
```
- Upstream SHA: `fce9b6d` (branch `rolling`), mode detected: `sync`.
- Tree: `<scratch>/repoint-build-final/clone` (this is exactly what
  `mirror-push.sh --build-repo` pushes as `github.com/dozenos/dozenos-build`).

```
dozenos-rebrand/mirror-push.sh https://github.com/vyos/vyos-1x \
  --target dozenos-1x --overlay dozenos-rebrand/overlay-dozenos-1x \
  --dry-run --allow-residuals --work <scratch>/repoint-1x-final3
```
- Upstream SHA: `a56d9ff` (branch `rolling`), mode detected: `sync`.
- Tree: `<scratch>/repoint-1x-final3/clone` (what would push as
  `github.com/dozenos/dozenos-1x`).

`<scratch>` = `/tmp/claude-1000/-home-date-git-dozenos/c8f23573-7bb9-4dbd-83f8-7e520cf4044b/scratchpad`.
Both flag names confirmed against `mirror-push.sh`'s own arg parser
(`--target`, `--branch`, `--build-repo`, `--overlay`, `--allow-residuals`,
`--dry-run`, `--work`) before running.

## 2. scm_url table (dozenos-build tree, `scripts/package-build/*/package.toml`)

63 non-empty `scm_url` assignments across 39 recipes / 44 `[[packages]]`
blocks (`linux-kernel` has several empty `scm_url = ""` blocks — build-time
generated/not-fetched sub-targets — excluded from the table, they carry no
external ref at all).

| Recipe | `scm_url` | Classification |
|---|---|---|
| `amazon-cloudwatch-agent` | `https://github.com/aws/amazon-cloudwatch-agent` | (b) 3rd-party upstream |
| `amazon-ssm-agent` | `https://github.com/aws/amazon-ssm-agent` | (b) 3rd-party upstream |
| `aws-gwlbtun` | `https://github.com/aws-samples/aws-gateway-load-balancer-tunnel-handler` | (b) 3rd-party upstream |
| `bash-completion` | `https://salsa.debian.org/debian/bash-completion` | (b) 3rd-party upstream |
| `blackbox_exporter` | `https://github.com/prometheus/blackbox_exporter` | (b) 3rd-party upstream |
| `ddclient` | `https://salsa.debian.org/debian/ddclient` | (b) 3rd-party upstream |
| `dozenos-1x` | `https://github.com/dozenos/dozenos-1x.git` | (a) dozenos mirror |
| `dozenos-http-api-tools` | `https://github.com/dozenos/dozenos-http-api-tools.git` | (a) dozenos mirror |
| `dropbear` | `https://salsa.debian.org/debian/dropbear.git` | (b) 3rd-party upstream |
| `ethtool` | `https://salsa.debian.org/kernel-team/ethtool` | (b) 3rd-party upstream |
| `frr_exporter` | `https://github.com/tynany/frr_exporter` | (b) 3rd-party upstream |
| `frr` | `https://github.com/CESNET/libyang.git` | (b) 3rd-party upstream |
| `frr` | `https://github.com/FRRouting/frr.git` | (b) 3rd-party upstream |
| `hostap` | `https://git.w1.fi/hostap.git` | (b) 3rd-party upstream |
| `hostap` | `https://salsa.debian.org/debian/wpa` | (b) 3rd-party upstream |
| `hsflowd` | `https://github.com/sflow/host-sflow.git` | (b) 3rd-party upstream |
| `hvinfo` | `https://github.com/dozenos/hvinfo.git` | (a) dozenos mirror |
| `ipaddrcheck` | `https://github.com/dozenos/ipaddrcheck.git` | (a) dozenos mirror |
| `isc-dhcp` | `https://salsa.debian.org/debian/isc-dhcp` | (b) 3rd-party upstream |
| `isc-kea` | `https://gitlab.isc.org/isc-projects/kea.git` | (b) 3rd-party upstream |
| `keepalived` | `https://salsa.debian.org/debian/pkg-keepalived.git` | (b) 3rd-party upstream |
| `libhtp` | `https://salsa.debian.org/pkg-suricata-team/pkg-libhtp.git` | (b) 3rd-party upstream |
| `libnss-mapuser` | `https://github.com/dozenos/libnss-mapuser.git` | (a) dozenos mirror |
| `libpam-radius-auth` | `https://github.com/dozenos/libpam-radius-auth.git` | (a) dozenos mirror |
| `linux-kernel` | `http://github.com/intel/ethernet-linux-i40e` | (b) 3rd-party upstream |
| `linux-kernel` | `http://github.com/intel/ethernet-linux-iavf` | (b) 3rd-party upstream |
| `linux-kernel` | `http://github.com/intel/ethernet-linux-ice` | (b) 3rd-party upstream |
| `linux-kernel` | `http://github.com/intel/ethernet-linux-ixgbevf` | (b) 3rd-party upstream |
| `linux-kernel` | `https://github.com/accel-ppp/accel-ppp-ng.git` | (b) 3rd-party upstream |
| `linux-kernel` | `https://github.com/intel/ethernet-linux-igb` | (b) 3rd-party upstream |
| `linux-kernel` | `https://github.com/intel/ethernet-linux-ixgbe` | (b) 3rd-party upstream |
| `linux-kernel` | `https://github.com/maru-sama/rtsp-linux.git` | (b) 3rd-party upstream |
| `linux-kernel` | `https://github.com/nuclearcat/ipt-netflow` | (b) 3rd-party upstream |
| `linux-kernel` | `https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git` | (b) 3rd-party upstream |
| `ndppd` | `https://salsa.debian.org/debian/ndppd` | (b) 3rd-party upstream |
| `netfilter` | `https://salsa.debian.org/pkg-netfilter-team/pkg-libnftnl.git` | (b) 3rd-party upstream |
| `netfilter` | `https://salsa.debian.org/pkg-netfilter-team/pkg-nftables.git` | (b) 3rd-party upstream |
| `net-snmp` | `https://salsa.debian.org/debian/net-snmp` | (b) 3rd-party upstream |
| `node_exporter` | `https://github.com/prometheus/node_exporter` | (b) 3rd-party upstream |
| `openssl` | `https://salsa.debian.org/debian/openssl.git` | (b) 3rd-party upstream |
| `openvpn-otp` | `https://github.com/evgeny-gridasov/openvpn-otp` | (b) 3rd-party upstream |
| `owamp` | `https://github.com/perfsonar/owamp` | (b) 3rd-party upstream |
| `podman` | `https://github.com/containers/podman` | (b) 3rd-party upstream |
| `pyhumps` | `https://github.com/nficano/humps.git` | (b) 3rd-party upstream |
| `radvd` | `https://github.com/radvd-project/radvd` | (b) 3rd-party upstream |
| `shim-signed` | `https://github.com/dozenos/shim-signed.git` | (a) dozenos mirror |
| `squid` | `https://salsa.debian.org/squid-team/squid` | (b) 3rd-party upstream |
| `strongswan` | `https://salsa.debian.org/debian/strongswan.git` | (b) 3rd-party upstream |
| `tacacs` | `https://github.com/dozenos/libnss-tacplus.git` | (a) dozenos mirror |
| `tacacs` | `https://github.com/dozenos/libpam-tacplus.git` | (a) dozenos mirror |
| `tacacs` | `https://github.com/dozenos/libtacplus-map.git` | (a) dozenos mirror |
| `telegraf` | `https://github.com/influxdata/telegraf.git` | (b) 3rd-party upstream |
| `udp-broadcast-relay` | `https://github.com/nomeata/udp-broadcast-relay` | (b) 3rd-party upstream |
| `unionfs-fuse` | `https://github.com/rpodgorny/unionfs-fuse` | (b) 3rd-party upstream |
| `vpp` | `https://github.com/dozenos/dozenos-vpp-patches` | (a) dozenos mirror |
| `vpp` | `https://github.com/FDio/vpp` | (b) 3rd-party upstream |
| `vyatta-bash` | `https://github.com/dozenos/vyatta-bash.git` | (a) dozenos mirror |
| `vyatta-biosdevname` | `https://github.com/dozenos/vyatta-biosdevname.git` | (a) dozenos mirror |
| `vyatta-cfg` | `https://github.com/dozenos/vyatta-cfg.git` | (a) dozenos mirror |
| `waagent` | `https://salsa.debian.org/cloud-team/waagent.git` | (b) 3rd-party upstream |
| `wide-dhcpv6` | `https://salsa.debian.org/debian/wide-dhcpv6` | (b) 3rd-party upstream |
| `xen-guest-agent` | `https://gitlab.com/xen-project/xen-guest-agent` | (b) 3rd-party upstream |
| `zerotier-one` | `https://github.com/zerotier/ZeroTierOne.git` | (b) 3rd-party upstream |

**Summary: 14 (a) dozenos-mirror refs, 49 (b) 3rd-party-upstream refs, 0 (c)
stray `github.com/vyos/*` git refs.**

3rd-party host breakdown (49 refs): `github.com` ×28 (aws, aws-samples,
CESNET, FRRouting, accel-ppp, intel ×6, maru-sama, nuclearcat, tynany, sflow,
prometheus ×2, evgeny-gridasov, perfsonar, containers, nficano, radvd-project,
nomeata, rpodgorny, influxdata, FDio, zerotier, xen-project via gitlab.com is
separate — see below), `salsa.debian.org` ×17, `git.kernel.org` ×1,
`gitlab.com` ×1, `gitlab.isc.org` ×1, `git.w1.fi` ×1.

`grep -rIn 'scm_url' scripts/package-build | grep -i vyos` → **0 matches**
(confirmed directly against the reproduced tree — zero stray `vyos/*` scm_urls
of any kind).

## 3. opam-pin / OCaml source refs (dozenos-1x tree, `libdozenosconfig/Makefile`)

```
opam pin add dozenos1x-config https://github.com/dozenos/dozenos1x-config.git#<sha> -y
opam pin add vyconf            https://github.com/dozenos/vyconf.git#<sha> -y
```

Both correctly repointed: `vyos1x-config` → `dozenos1x-config` (package name,
four-form) with its URL host rewritten to `github.com/dozenos/*`; `vyconf`
correctly keeps its own name (no `vyos` substring) with only its URL host
rewritten. `grep -rIn "scm_url" <dozenos-1x tree>` → **0 matches** (no other
scm_url-style field exists in a source repo, as expected — only vyos-build's
recipes have `scm_url`). Whole-tree `github.com/vyos/` grep on the dozenos-1x
tree → **0 matches** post-fix (see §7).

## 4. Recipe-dir rename evidence

`find <dozenos-build tree> -iname '*vyos*'` → **0 hits** (no directory or file
anywhere in the tree carries a `vyos` token, case-insensitive).

Confirmed renamed recipe dirs under `scripts/package-build/`:
- `dozenos-1x/` (was `vyos-1x/`)
- `dozenos-http-api-tools/` (was `vyos-http-api-tools/`, via `new-files/`
  shipped pre-renamed — see `overlay-dozenos-build/MANIFEST.md`)

(The other 15 mirrored-dependency recipes — `libnss-mapuser`,
`libpam-radius-auth`, `shim-signed`, `tacacs`, `vpp`, `vyatta-bash`,
`vyatta-biosdevname`, `vyatta-cfg`, `ipaddrcheck`, `hvinfo` — never had a
`vyos` token in their directory names upstream, so there is nothing to
rename; their *content* repointing is covered in §2.)

## 5. --ci / --local correctness

`overlay-dozenos-build/apply-overlay.sh`'s exact mode gating (step 3/3):

```bash
if [ "$MODE" = "local" ]; then
  "$VALUE_FIXES/pin-helper-scm-urls.sh" "$TARGET"
else
  echo "pin-helper-scm-urls: skipped (--ci mode -- 14 mirrored git scm_urls stay at github.com/dozenos/*)"
fi
```

`pin-helper-scm-urls.sh` runs **only** when `MODE=local`; the default
(`MODE=ci`, set at the top of the script and never overridden by
`mirror-push.sh --build-repo`, which always calls `apply-overlay.sh --ci`
explicitly) takes the `else` branch and never touches the 14 tracked
scm_urls. Confirmed empirically in both reproductions above ("pin-helper-
scm-urls: skipped" appears in the `--ci` run's log; all 14 blocks read
`github.com/dozenos/*` in the resulting tree — see §2's 14 (a)-classified
rows). This is exactly item #6's crux ("drop the git-scm_url pin-back once
mirrors exist") — confirmed live: the mirrors exist (§6), and `--ci` leaves
all 14 pointed at them.

## 6. gh-existence cross-check (the important one)

Every distinct `github.com/dozenos/<name>` ref found in §2/§3 (16 names),
checked against the live org with `gh repo view dozenos/<name> --json name -q .name`:

| `dozenos/<name>` | Exists? |
|---|---|
| `dozenos-1x` | yes |
| `dozenos-http-api-tools` | yes |
| `dozenos-vpp-patches` | yes |
| `hvinfo` | yes |
| `ipaddrcheck` | yes |
| `libnss-mapuser` | yes |
| `libnss-tacplus` | yes |
| `libpam-radius-auth` | yes |
| `libpam-tacplus` | yes |
| `libtacplus-map` | yes |
| `shim-signed` | yes |
| `vyatta-bash` | yes |
| `vyatta-biosdevname` | yes |
| `vyatta-cfg` | yes |
| `dozenos1x-config` | yes |
| `vyconf` | yes |

**16/16 exist. Zero 404s.** `gh repo list dozenos --limit 50` confirms exactly
these 16 plus `dozenos-build` itself = **17 mirrors**, matching the locked
mirror plan 1:1.

**Orphan mirrors** (pushed, but no `scm_url`/opam-pin references them from
either reproduced tree): `dozenos-build` only — expected, it's the top-level
product repo, never a dependency of itself. (It IS referenced informationally
via doc links in `AGENTS.md`/`README.md`, just not as a build dependency.)

### Extended finding (beyond scm_url/opam-pin scope, surfaced by the same
### "does every dozenos/* ref resolve" methodology)

A repo-wide `grep -rIhoE 'github\.com/dozenos/[A-Za-z0-9._-]+'` over both
reproduced trees (not limited to `package.toml`/opam pins — every file) found
**4 more** `github.com/dozenos/*` refs that the four-form transform correctly
produced (zero residual `vyos`, pass `--verify` cleanly) but that pointed at
repos with **no mirror and no mirror plan** — invisible to `--verify` because
they contain no literal `vyos` after transform, and invisible to §2/§3
because they are not `scm_url`/opam-pin fields:

| Ref found | File | Real upstream (confirmed via `gh repo view`) | Executable? |
|---|---|---|---|
| `dozenos/coderabbit` | `.coderabbit.yaml` (both trees — org-wide template) | `vyos/coderabbit` (exists) | No — CodeRabbit bot config comment only |
| `dozenos/vyatta-cfg-qos` | `python/dozenos/qos/base.py` (dozenos-1x) | `vyos/vyatta-cfg-qos` (exists, **archived**) | No — docstring comment only |
| `dozenos/dozenos-live-build` | `AGENTS.md` ×2 lines (dozenos-build) | `vyos/vyos-live-build` (exists, active) | No — prose only; the *actual* Dockerfile clones live-build from `salsa.debian.org/live-team/live-build.git` directly |
| `dozenos/dozenos.dozenos` | `scripts/ansible-install` (dozenos-build) | `vyos/vyos.vyos` (exists, active, real published Ansible collection) | **Yes** — `make ansible-install` runs `ansible-galaxy collection install git+https://github.com/dozenos/dozenos.dozenos.git,main` for real |

Of these, only `dozenos.dozenos` sits on an actual executable code path; the
other three are documentation/comment dead links. All 4 are genuine "CI 404
waiting to happen" per the task's own framing, so all 4 were codified (§7),
not just noted.

## 7. Codified fix

**Two new overlay scripts**, following the existing `pin-toolchain-apt-
source.sh` pattern exactly (revert to real upstream, **both modes**
unconditionally — these are permanent non-mirrored targets, not a
temporary pre-push-order gap like `pin-helper-scm-urls.sh`'s 14 entries):

- `overlay-dozenos-build/value-fixes/pin-nonmirrored-org-refs.sh` (vyos-build overlay) —
  reverts `.coderabbit.yaml`, `AGENTS.md` (both lines), and
  `scripts/ansible-install`. Wired into `overlay-dozenos-build/apply-overlay.sh` step 3/3,
  both `--ci` and `--local`.
- `overlay-dozenos-1x/value-fixes/pin-nonmirrored-org-refs.sh` (dozenos-1x
  overlay) — reverts `.coderabbit.yaml` and `python/dozenos/qos/base.py`.
  Wired into `overlay-dozenos-1x/apply-overlay.sh` step 2/2 (this overlay has
  no mode split at all).

Both are idempotent, fail loudly on drift (neither expected form found),
match every existing script's `ENTRIES=("file|dozenos-form|vyos-form")`
convention.

**Verified** by re-running both reproductions end-to-end after the fix:

- dozenos-build: `--verify` now reports **9** residual `vyos` hits (the
  original 5 non-git build-time pointers + these 4 new reverts), all
  individually confirmed to be exactly the deliberate whitelisted set, 0
  unexplained. `mirror-push.sh --build-repo` still exits 0 (`--allow-
  residuals` implied).
- dozenos-1x: `--verify` now reports **2** residual `vyos` hits (both
  reverts), same pattern, `mirror-push.sh --overlay overlay-dozenos-1x
  --allow-residuals` exits 0.
- Full-tree `github.com/dozenos/*` re-scan (both fixed trees): exactly the
  **17** names from §6's table — 1:1 match with the 17 pushed mirrors, **zero
  orphan dangling refs remaining**.

**Regression: none.** Existing conventions that reference an exact residual
count needed updating (not a regression, an expected consequence of adding
4 more deliberate residuals):
- `test/test-mirror-push.sh`: `--build-repo` residual-count assertion updated
  5 → 9 (this test drives the real local `vyos-build` checkout via `file://`,
  so it exercises the actual fix).
- `mirror-push.sh`'s own header comment/log line updated to mention the new
  script and the 9-count.
- `test/test-apply-overlay.sh` / `test/test-apply-overlay-dozenos-1x.sh`:
  fixtures gained the 4 new target files + assertions that they revert in
  both modes.

Full test suite after the fix: **113 passed, 0 failed** (up from the 102
baseline in `SWEEP-dozenos-build.md`: `test-apply-overlay-dozenos-1x.sh`
13/13, `test-apply-overlay.sh` 44/44, `test-mirror-push.sh` 25/25,
`test-rebrand.sh` 13/13, `test-wire-prebuild-hooks.sh` 18/18).

## Verdict

**PASS**, with 2 gaps found and codified during this audit (§7). Summary:

- §2/§3 core scope (recipe `scm_url` + opam pins): **0 stray `vyos/*` git
  refs**, 14+2=16 `dozenos/*` refs, all 16 verified live (§6) — item #6's
  actual deliverable is clean.
- §4: 0 leftover `vyos`-named paths; both real rename cases confirmed.
- §5: `pin-helper-scm-urls.sh` proven `--local`-only by direct code quote +
  empirical confirmation.
- §6 extended finding: 4 non-recipe dangling refs found and fixed (only 1 of
  the 4 was on an executable code path — `scripts/ansible-install`, the
  other 3 were docs/comments — but all 4 are now correct either way).
- Nothing was pushed. `vyatta` preserved throughout (unaffected by any change
  in this audit — all edits target `vyos`↔`dozenos` forms only).

## Report path

This file: `dozenos-rebrand/REPOINT-AUDIT.md`.
