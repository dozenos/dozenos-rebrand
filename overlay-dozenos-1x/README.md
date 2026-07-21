# Post-transform overlay for the dozenos-1x mirror (upstream vyos-1x)

Per-repo overlay for `github.com/dozenos/dozenos-1x`, applied by
`mirror-push.sh --overlay dozenos-rebrand/overlay-dozenos-1x` after
`rename-transform.sh` and the `.github/` strip, and before the final
`rename-transform.sh --verify` + push. See `apply-overlay.sh`'s own header
for the exact pipeline position and the `mirror-push.sh` command line.

This is a **separate** overlay from `../overlay-dozenos-build/` (the vyos-build overlay).
`../overlay-dozenos-build/`'s own MANIFEST.md flagged, but deliberately left out of scope,
three vyos-1x-internal items -- see "Per-repo overlay split" there. This
directory is where those items were resolved.

## What's here

```
overlay-dozenos-1x/
  README.md              this file
  apply-overlay.sh        entrypoint; mirror-push.sh calls
                           `<dir>/apply-overlay.sh <clone-dir>`
  value-fixes/
    regen-default-password-hash.sh   the overlay's primary job (see below)
    pin-nonmirrored-org-refs.sh      REPOINT-AUDIT.md #6 fix (see below)
    pin-opam-ocaml-branch.sh         opam pins: #<sha> -> #rolling (see apply-overlay.sh header)
    strip-motd-logo-frame.sh         remove the VyOS box-drawing MOTD logo frame
    fix-snmp-test-localized-keys.sh  SNMPv3 smoketest key constants (see below)
    fix-length-constrained-test-constants.sh
                                     smoketest constants the +3-char rename grew
                                     past an 8/15-char CLI ceiling (see below)
```

## The fix: default-login password hash (audit item #8/#23)

Upstream vyos-1x ships a default admin user whose SHA-512 crypt hash decodes
to the plaintext password `vyos`. `rename-transform.sh` correctly rewrites
the *username* (`user vyos` -> `user dozenos`), but the hash string itself
contains no literal `vyos` token -- it's high-entropy noise -- so it passes
through the four-form transform (and the zero-`vyos` `--verify` gate)
completely untouched. Left alone, the shipped default credential would
still functionally be `vyos`, even though every visible string says
`dozenos`. This is the general "value, not string" landmine class (see
`../LANDMINES.md` and `../overlay-dozenos-build/README.md`): no textual substitution can
turn one password's hash into a different password's hash.

`value-fixes/regen-default-password-hash.sh` regenerates the hash for the
new default password `dozenos` (`openssl passwd -6 dozenos`, fresh random
salt) and replaces the old VyOS hash by exact full-string match everywhere
it appears. See that script's header for the complete rationale (why the
match key is the full hash string, why Python's literal `str.replace()` is
used instead of `sed`, why a whole-tree grep is used instead of a hardcoded
5-file list).

Verified against a fresh `git clone --depth 1
https://github.com/vyos/vyos-1x`: the old hash

```
$6$QxPS.uk6mfo$9QBSo8u1FkH16gMyAVhus6fU3LOzvLR9Z9.82m3tiHFAxTtIkhaZSWssSgzt4v4dGAL8rhVQxTg0oAG9/q11h/
```

appears, byte-identical, in exactly these 5 files:

- `data/config.boot.default`
- `tests/data/config.boot.default`
- `src/tests/test_initial_setup.py`
- `smoketest/configs/firewall-groups-name`
- `smoketest/configs/assert/firewall-groups-name`

Re-verify this list on every upstream sync -- the script itself does not
trust it either; it greps the whole tree for the exact old-hash string
rather than hardcoding these 5 paths, so it self-heals if upstream ever
adds a 6th copy.

## The other fix: dangling non-mirrored `dozenos/*` refs (REPOINT-AUDIT.md #6)

`../REPOINT-AUDIT.md`'s step #6 cross-check (`gh repo view dozenos/<name>`
for every `github.com/dozenos/<name>` ref found anywhere in the tree, not
just `scm_url`/opam-pin fields) found 2 refs the four-form transform
correctly produced (zero residual `vyos`, pass `--verify` cleanly) but that
point at repos with no `dozenos` mirror and no mirror plan:

- `.coderabbit.yaml`'s org-baseline-config inherit link → real upstream is
  `vyos/coderabbit` (exists); `dozenos/coderabbit` does not.
- `python/dozenos/qos/base.py`'s `_build_base_qdisc()` docstring, a
  historical-context link to the old Perl QoS implementation → real upstream
  is `vyos/vyatta-cfg-qos` (exists, but **archived**); `dozenos/vyatta-cfg-qos`
  does not exist and is not on the mirror plan (it is not `vyatta-cfg`, the
  still-in-use C backend that IS mirrored).

Neither is on an executable code path (both are comment/config text read by
a bot or a human, not fetched by any build tooling), but both are genuine
dangling links. `value-fixes/pin-nonmirrored-org-refs.sh` reverts both,
unconditionally (no `--ci`/`--local` split in this overlay at all — these
are permanent non-mirrored targets, not a temporary pre-push-order gap).

## The SNMPv3 smoketest localized-key constants

Same "value, not string" class as the password hash above, found 2026-07-18
by the nightly `test-image` gate (test_snmpv3_md5 / test_snmpv3_sha):
`smoketest/scripts/cli/test_service_snmp.py` asserts the CLI's
`encrypted-password` values against four hardcoded RFC 3414 localized keys
derived from the ORIGINAL plaintext passwords (`vyos12345678` /
`vyos87654321`) plus the test's fixed engine-id. The four-form pass rewrites
the plaintexts to `dozenos...`, but a localized key contains no `vyos`
substring, so the constants pass the transform untouched and no longer match
what snmpd computes. `value-fixes/fix-snmp-test-localized-keys.sh` parses
the passwords/engine-id out of the file and recomputes all four constants
(algorithm validated 6/6 against the upstream constants and the failing
nightly's observed values -- see the script header).

## The length-constrained smoketest constants

Third instance of the same "value, not string" class, found 2026-07-21 by the
nightly `test-image` gate (`test-no-interfaces-no-vpp`, 5/94 failing, run
29835061325). `vyos` (4) -> `dozenos` (7) is a **+3-character** rewrite, and
upstream sets several test constants right at a CLI validator's ceiling, so
the transform pushes them over it and the `set` is rejected in `cli_set`
before the test asserts anything:

| file | constant | upstream | after transform | ceiling |
| --- | --- | --- | --- | --- |
| `test_protocols_nhrp.py` | `nhrp_secret` | `"vyos123"` (7) | 10 | 8 |
| `test_vpn_ipsec.py` | `nhrp_secret` | `"vyos123"` (7) | 10 | 8 |
| `test_protocols_ospf.py` | `password` | `'vyos1234'` (8) | 11 | 8 |
| `test_protocols_ospf.py` | `plaintext_key` | `'vyos123'` (7) | 10 | 8 |
| `test_service_dns_dynamic.py` | `vrf_name` | `f'vyos-test-{vrf_table}'` (15) | 18 | 15 |

Upstream's own values are all within their limits and upstream CI is green on
these tests -- this is purely the rebrand's +3 landmine.
`value-fixes/fix-length-constrained-test-constants.sh` substitutes the
**4-character** token `dzos` in these five constants only, restoring each to
its exact upstream byte length (including `vyos-test-58710`, which upstream
sets at exactly the 15-character VRF ceiling). None of these are values a
user ever sees or types -- they are test-local secrets and a test-local VRF
name -- and `dzos` carries no `vyos`, so the `--verify` gate stays clean.

The scope is five named constants matched by anchored per-constant regexes,
not a blanket `dozenos` -> `dzos` pass: a wildcard would silently shorten
brand strings that tests legitimately assert against. New violations are
meant to surface as a nightly failure and earn an explicit entry here.

## What's deliberately NOT here (and why)

Three vyos-1x-internal items were flagged by `../overlay-dozenos-build/MANIFEST.md`'s
"Per-repo overlay split" as belonging to *this* future overlay. Only one
(the password hash, above) turned out to actually need an overlay entry
under mode B. All three were re-verified from scratch against a fresh
upstream clone plus a fresh mirror-push-style transform, and the other two
were found to already be fully handled without any overlay code:

1. **opam pins in `libvyosconfig/Makefile`** (`vyos1x-config` ->
   `dozenos1x-config`, `github.com/vyos/*` -> `github.com/dozenos/*`) --
   these are ordinary strings, already caught by `rename-transform.sh`'s
   generic four-form pass. Confirmed post-transform:
   ```
   PACKAGES=dozenos1x-config,vyconf.vyconfd-config,vyconf.vycall-client,re,ctypes.stubs,ctypes.foreign
   opam pin add dozenos1x-config https://github.com/dozenos/dozenos1x-config.git#<sha> -y
   opam pin add vyconf https://github.com/dozenos/vyconf.git#<sha> -y
   ```
   (`vyconf`'s own package name is untouched -- correctly -- since
   "vyconf" doesn't contain "vyos"; only the URL host is rewritten. The
   dir itself is also renamed: `libvyosconfig/` -> `libdozenosconfig/`.)
   Since the `github.com/dozenos/dozenos1x-config` and
   `github.com/dozenos/vyconf` mirrors exist under the locked mode-B
   mirror plan, these pins resolve as-is. No overlay entry needed.

2. **`open Vyos1x` in the OCaml ctypes bindings**
   (`libdozenosconfig/lib/bindings.ml`) -- also an ordinary string, also
   already caught by the four-form pass. Confirmed post-transform:
   `open Dozenos1x` and `Dozenos1x.Parser.from_string`. No overlay entry
   needed.

3. **The `Makefile`'s `git ls-files` -> `find` patch** (audit item #17,
   applied by hand in the *local* vyos-build recipe copy at
   `scripts/package-build/vyos-1x/vyos-1x/Makefile`) -- **not** reproduced
   here, and not needed. That local patch was a workaround for a
   local-build-only problem: the local pipeline ran `rename-transform.sh`
   directly on an already-`git clone`d working tree without re-committing
   afterwards, so the tree's `.git` index stayed frozen at the
   pre-transform (still-`vyos`) paths while the files on disk were already
   renamed to `dozenos-*` -- `git ls-files 'src/services/dozenos*'`
   against that stale index returned 0 matches even though the files exist
   on disk (confirmed by inspecting that tree directly: `git status`
   there shows the entire rename as uncommitted `M`/`D` changes).

   Mode B does not share that problem. `mirror-push.sh`'s seed path runs
   `rename-transform.sh` on the clone FIRST, and only THEN does `rm -rf
   .git && git init && git add -A && commit` -- the fresh mirror's git
   index is built directly from the already-transformed tree, so it is
   never stale relative to it. Verified by simulation: transform a fresh
   vyos-1x clone, then `rm -rf .git && git init -b rolling && git add -A
   && commit` (mirroring `mirror-push.sh`'s seed path exactly) --
   `git ls-files 'src/services/dozenos*'` then returns all 8 renamed
   service files, matching disk exactly:
   ```
   src/services/dozenos-commitd
   src/services/dozenos-configd
   src/services/dozenos-conntrack-logger
   src/services/dozenos-domain-resolver
   src/services/dozenos-hostsd
   src/services/dozenos-http-api-server
   src/services/dozenos-netlinkd
   src/services/dozenos-network-event-logger
   ```
   The later re-clone of this mirror as a `dozenos-build` package
   dependency, followed by `dozenos-1x`'s `pre_build_hook` re-running
   `rename-transform.sh` (a no-op on an already-all-`dozenos` tree -- no
   renames means the index is never invalidated), preserves that same
   consistency. No overlay entry needed; not reproduced here.

## Idempotent

The one sub-step (`regen-default-password-hash.sh`) is idempotent: it
matches on the full old-hash string, so a second run against an
already-fixed tree finds nothing to do and exits as a clean no-op. See its
own header for the fresh-salt-on-every-fix caveat (re-running the script
when it DOES have work to do produces a different, equally valid, hash each
time -- there is no canonical "the" new hash).

## Tests

`../test/test-apply-overlay-dozenos-1x.sh` -- see that file for coverage
(patches all 5 known files, leaves unrelated `$6$` hashes untouched, new
hash validates `dozenos` and rejects `vyos`, idempotent on rerun, bad usage
fails loudly).
