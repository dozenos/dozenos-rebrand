#!/usr/bin/env bash
#
# Integration test for overlay-dozenos-build/apply-overlay.sh, focused on the --ci/--local
# mode split (cicd.note item #18c).
#
# Self-contained and NETWORK-FREE: builds a synthetic "already-transformed,
# already-hooked" target tree (the state apply-overlay.sh assumes as input --
# see its own header / overlay-dozenos-build/README.md's pipeline position) covering every
# sub-step it drives, then asserts:
#
#   1. --ci (and no-flag, since --ci is the default) leaves all 14 mirrored
#      git scm_urls (pin-helper-scm-urls.sh's set: 8 rewritten-recipe blocks
#      plus the 6 new-files/ recipes, item #18d) at github.com/dozenos/*.
#   2. --local reverts those same scm_urls to github.com/vyos/*.
#   3. In BOTH modes: the toolchain apt-source host revert, the source-mirror
#      tarball URL revert, the vyos_mirror/dozenos_mirror empty-guard, the
#      dangling non-mirrored dozenos/* ref reverts (.coderabbit.yaml,
#      AGENTS.md, scripts/ansible-install -- REPOINT-AUDIT.md #6 finding),
#      the MOK cert removal, and new-files/ all still run identically.
#   4. Each mode is idempotent (2nd run byte-identical).
#   5. Bad usage (missing target, unknown flag) fails loudly.
#
# NOTE: no `set -e` -- this runner tallies pass/fail itself.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOLKIT=$(dirname "$HERE")
SCRIPT="$TOOLKIT/overlay-dozenos-build/apply-overlay.sh"
GUARD_SCRIPT="$TOOLKIT/overlay-dozenos-build/logic-patches/vyos-mirror-guard.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; fail=$((fail + 1)); }

snapshot() {
  local t=$1
  ( cd "$t"
    find . -not -path './.git/*' -not -name .git | LC_ALL=C sort | while IFS= read -r p; do
      if   [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -f "$p" ]; then printf 'F %s %s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"
      elif [ -d "$p" ]; then printf 'D %s\n' "$p"
      fi
    done )
}

# ---------------------------------------------------------------------------
# Extract vyos-mirror-guard.sh's exact `old_block` text (the pre-guard python
# block it looks for) straight from the real script, rather than
# hand-transcribing it -- avoids silent drift if the script's block text ever
# changes.
# ---------------------------------------------------------------------------
old_block=$(python3 - "$GUARD_SCRIPT" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"old_block = \((.*?)\n\)\n", src, re.S)
ns = {}
exec("old_block = (" + m.group(1) + "\n)", ns)
sys.stdout.write(ns["old_block"])
PY
)
if [ -z "$old_block" ]; then
  echo "FATAL: could not extract old_block from $GUARD_SCRIPT -- aborting" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Fixture: an "already-transformed, already-hooked" target tree -- i.e. the
# exact input state apply-overlay.sh's own header documents (post
# rename-transform.sh + wire-prebuild-hooks.sh). Building it directly in
# post-transform form (rather than re-driving the real four-form transform)
# keeps this test focused on apply-overlay.sh's own contract.
# ---------------------------------------------------------------------------
make_fixture() {
  local t=$1
  mkdir -p "$t"/scripts/package-build/{libnss-mapuser,libpam-radius-auth,shim-signed,tacacs,vpp,dozenos-1x,linux-kernel}
  mkdir -p "$t"/scripts/image-build
  mkdir -p "$t"/docker
  mkdir -p "$t"/data/certificates

  # -- pin-helper-scm-urls.sh targets: 8 mirrored git scm_urls, dozenos-form --
  cat > "$t/scripts/package-build/libnss-mapuser/package.toml" <<'EOF'
[[packages]]
name = "libnss-mapuser"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/libnss-mapuser.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF
  cat > "$t/scripts/package-build/libpam-radius-auth/package.toml" <<'EOF'
[[packages]]
name = "libpam-radius-auth"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/libpam-radius-auth.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF
  cat > "$t/scripts/package-build/shim-signed/package.toml" <<'EOF'
[[packages]]
name = "shim-signed"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/shim-signed.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF
  cat > "$t/scripts/package-build/tacacs/package.toml" <<'EOF'
[[packages]]
name = "libtacplus-map"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/libtacplus-map.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"

[[packages]]
name = "libpam-tacplus"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/libpam-tacplus.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"

[[packages]]
name = "libnss-tacplus"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/libnss-tacplus.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF
  cat > "$t/scripts/package-build/vpp/package.toml" <<'EOF'
[[packages]]
name = "vpp"
commit_id = "rolling"
scm_url = "https://github.com/FDio/vpp"
build_cmd = "true"

[[packages]]
name = "dozenos-vpp-patches"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/dozenos-vpp-patches"
build_cmd = "true"
EOF
  cat > "$t/scripts/package-build/dozenos-1x/package.toml" <<'EOF'
[[packages]]
name = "dozenos-1x"
commit_id = "rolling"
scm_url = "https://github.com/dozenos/dozenos-1x.git"
build_cmd = "dpkg-buildpackage -us -uc -tc -b"
EOF

  # -- logic-patches/revert-source-mirror-urls.sh targets --
  for f in build-intel-qat.sh build-realtek-r8126.py build-realtek-r8152.py; do
    printf '#!/usr/bin/env bash\nURL="https://packages.dozenos.net/source-mirror/%s.tar.gz"\n' "$f" \
      > "$t/scripts/package-build/linux-kernel/$f"
  done

  # -- logic-patches/vyos-mirror-guard.sh target (exact old_block, extracted
  #    above from the real script) --
  {
    printf 'def something():\n'
    printf '%s\n' "$old_block"
  } > "$t/scripts/image-build/build-dozenos-image"

  # -- value-fixes/pin-toolchain-apt-source.sh targets --
  printf 'deb https://packages.dozenos.net/repositories/rolling main\n' > "$t/docker/dozenos-dev.list"
  printf 'FROM debian:bookworm\nRUN curl -fsSL https://cdn.dozenos.io/syft.tar.gz | tar xz\n' > "$t/docker/Dockerfile"

  # -- value-fixes/pin-nonmirrored-org-refs.sh targets (REPOINT-AUDIT.md #6
  #    finding: dangling github.com/dozenos/* refs with no mirror) --
  printf '# https://github.com/dozenos/coderabbit/blob/production/.coderabbit.yaml\ninheritance: true\n' > "$t/.coderabbit.yaml"
  printf -- '- Debian `live-build` (forked at https://github.com/dozenos/dozenos-live-build)\n- ISO assembly delegates to `dozenos/dozenos-live-build` (Debian live-build fork)\n' > "$t/AGENTS.md"
  mkdir -p "$t/scripts"
  printf '#!/usr/bin/env bash\nansible-galaxy collection install git+https://github.com/dozenos/dozenos.dozenos.git,main\n' > "$t/scripts/ansible-install"

  # -- value-fixes/remove-committed-mok-cert.sh target: a real cert with a
  #    VyOS-bearing subject (mirrors the real inherited upstream cert) --
  openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out \
    "$t/data/certificates/dozenos-prod-2025-linux.pem" -days 1 -nodes \
    -subj "/CN=VyOS Networks Secure Boot Signer 2025" >/dev/null 2>&1

  # -- value-fixes/replace-eula.sh target: transformed upstream EULA block --
  mkdir -p "$t/data/build-types"
  cat > "$t/data/build-types/development.toml" <<'EOF'
packages = [
  "gdb"
]

[[includes_chroot]]
  path = 'usr/share/dozenos/EULA'
  data = '''
DozenOS ROLLING RELEASE END USER LICENSE AGREEMENT

I. This End-User License Agreement is a legal document between you and DozenOS Inc.
(a company organized and existing under the laws of California,
having its registered office at 12585 Kirkham Ct, Suite 1, Poway, California 92604)
'''
EOF

  # -- value-fixes/pin-project-urls.sh target: transformed defaults URLs --
  cat > "$t/data/defaults.toml" <<'EOF'
kernel_version = "6.18.38"
website_url = "https://dozenos.io"
support_url = "https://support.dozenos.io"
bugtracker_url = "https://dozenos.dev"
documentation_url = "https://docs.dozenos.io/en/latest"
project_news_url = "https://blog.dozenos.io"
EOF
}

assert_ci_state() {
  local tree=$1 label=$2
  if grep -qF 'https://github.com/dozenos/dozenos-1x.git' "$tree/scripts/package-build/dozenos-1x/package.toml"; then
    ok "$label: dozenos-1x scm_url stays at github.com/dozenos/* (--ci)"
  else
    bad "$label: dozenos-1x scm_url unexpectedly changed"; cat "$tree/scripts/package-build/dozenos-1x/package.toml"
  fi
  if grep -qF 'https://github.com/dozenos/dozenos-vpp-patches' "$tree/scripts/package-build/vpp/package.toml"; then
    ok "$label: vpp's dozenos-vpp-patches scm_url stays at github.com/dozenos/* (--ci)"
  else
    bad "$label: vpp scm_url unexpectedly changed"; cat "$tree/scripts/package-build/vpp/package.toml"
  fi
  if grep -qF 'https://github.com/vyos/' "$tree/scripts/package-build/dozenos-1x/package.toml" \
     "$tree/scripts/package-build/vpp/package.toml" \
     "$tree/scripts/package-build/tacacs/package.toml" 2>/dev/null; then
    bad "$label: unexpected github.com/vyos/* scm_url found under --ci"
  else
    ok "$label: no reverted (github.com/vyos/*) scm_urls under --ci"
  fi

  # item #18d: the 6 new-files/ recipes ship pre-pointed at github.com/dozenos/*
  # and bypass rename-transform.sh entirely; they must stay that way under --ci.
  local newf_ok=1
  for pair in \
    "vyatta-bash:https://github.com/dozenos/vyatta-bash.git" \
    "vyatta-biosdevname:https://github.com/dozenos/vyatta-biosdevname.git" \
    "vyatta-cfg:https://github.com/dozenos/vyatta-cfg.git" \
    "ipaddrcheck:https://github.com/dozenos/ipaddrcheck.git" \
    "hvinfo:https://github.com/dozenos/hvinfo.git" \
    "dozenos-http-api-tools:https://github.com/dozenos/dozenos-http-api-tools.git"
  do
    local dir="${pair%%:*}" want="${pair#*:}"
    grep -qF "$want" "$tree/scripts/package-build/$dir/package.toml" || newf_ok=0
  done
  if [ "$newf_ok" -eq 1 ]; then
    ok "$label: all 6 new-files/ recipe scm_urls stay at github.com/dozenos/* (--ci, item #18d)"
  else
    bad "$label: a new-files/ recipe scm_url is not at github.com/dozenos/*"
    grep -H scm_url "$tree"/scripts/package-build/{vyatta-bash,vyatta-biosdevname,vyatta-cfg,ipaddrcheck,hvinfo,dozenos-http-api-tools}/package.toml
  fi
}

assert_local_state() {
  local tree=$1 label=$2
  if grep -qF 'https://github.com/vyos/vyos-1x.git' "$tree/scripts/package-build/dozenos-1x/package.toml"; then
    ok "$label: dozenos-1x scm_url reverted to github.com/vyos/* (--local)"
  else
    bad "$label: dozenos-1x scm_url not reverted"; cat "$tree/scripts/package-build/dozenos-1x/package.toml"
  fi
  if grep -qF 'https://github.com/vyos/vyos-vpp-patches' "$tree/scripts/package-build/vpp/package.toml"; then
    ok "$label: vpp's scm_url reverted to github.com/vyos/* (--local)"
  else
    bad "$label: vpp scm_url not reverted"; cat "$tree/scripts/package-build/vpp/package.toml"
  fi
  if grep -qF 'https://github.com/vyos/libtacplus-map.git' "$tree/scripts/package-build/tacacs/package.toml" \
     && grep -qF 'https://github.com/vyos/libpam-tacplus.git' "$tree/scripts/package-build/tacacs/package.toml" \
     && grep -qF 'https://github.com/vyos/libnss-tacplus.git' "$tree/scripts/package-build/tacacs/package.toml"; then
    ok "$label: all 3 tacacs blocks reverted to github.com/vyos/* (--local)"
  else
    bad "$label: tacacs blocks not fully reverted"; cat "$tree/scripts/package-build/tacacs/package.toml"
  fi

  # item #18d: the 6 new-files/ recipes must revert to the real upstream
  # github.com/vyos/* under --local (dozenos-http-api-tools also renames).
  local newf_ok=1
  for pair in \
    "vyatta-bash:https://github.com/vyos/vyatta-bash.git" \
    "vyatta-biosdevname:https://github.com/vyos/vyatta-biosdevname.git" \
    "vyatta-cfg:https://github.com/vyos/vyatta-cfg.git" \
    "ipaddrcheck:https://github.com/vyos/ipaddrcheck.git" \
    "hvinfo:https://github.com/vyos/hvinfo.git" \
    "dozenos-http-api-tools:https://github.com/vyos/vyos-http-api-tools.git"
  do
    local dir="${pair%%:*}" want="${pair#*:}"
    grep -qF "$want" "$tree/scripts/package-build/$dir/package.toml" || newf_ok=0
  done
  if [ "$newf_ok" -eq 1 ]; then
    ok "$label: all 6 new-files/ recipe scm_urls reverted to github.com/vyos/* (--local, item #18d)"
  else
    bad "$label: a new-files/ recipe scm_url is not reverted to github.com/vyos/*"
    grep -H scm_url "$tree"/scripts/package-build/{vyatta-bash,vyatta-biosdevname,vyatta-cfg,ipaddrcheck,hvinfo,dozenos-http-api-tools}/package.toml
  fi
}

assert_both_modes_state() {
  local tree=$1 label=$2

  if grep -qF 'packages.vyos.net' "$tree/docker/dozenos-dev.list" \
     && grep -qF 'cdn.vyos.io' "$tree/docker/Dockerfile"; then
    ok "$label: toolchain apt-source hosts reverted (both modes)"
  else
    bad "$label: toolchain apt-source hosts not reverted"
  fi

  local n
  n=0
  for f in build-intel-qat.sh build-realtek-r8126.py build-realtek-r8152.py; do
    grep -qF 'https://packages.vyos.net/source-mirror/' "$tree/scripts/package-build/linux-kernel/$f" && n=$((n + 1))
  done
  if [ "$n" -eq 3 ]; then
    ok "$label: all 3 source-mirror tarball URLs reverted (both modes)"
  else
    bad "$label: only $n/3 source-mirror URLs reverted"
  fi

  if grep -q "if build_config.get('dozenos_mirror')" "$tree/scripts/image-build/build-dozenos-image"; then
    ok "$label: vyos_mirror/dozenos_mirror empty-guard applied (both modes)"
  else
    bad "$label: empty-guard not applied"
  fi

  if [ -e "$tree/data/certificates/dozenos-prod-2025-linux.pem" ]; then
    bad "$label: inherited MOK cert NOT removed"
  else
    ok "$label: inherited MOK cert removed (both modes)"
  fi

  if grep -qF 'github.com/vyos/coderabbit' "$tree/.coderabbit.yaml" \
     && ! grep -qF 'github.com/dozenos/coderabbit' "$tree/.coderabbit.yaml"; then
    ok "$label: .coderabbit.yaml dangling dozenos/coderabbit ref reverted (both modes)"
  else
    bad "$label: .coderabbit.yaml ref not reverted"; cat "$tree/.coderabbit.yaml"
  fi
  if grep -qF 'vyos/vyos-live-build' "$tree/AGENTS.md" \
     && ! grep -qF 'dozenos/dozenos-live-build' "$tree/AGENTS.md"; then
    ok "$label: AGENTS.md dangling dozenos-live-build refs reverted (both modes)"
  else
    bad "$label: AGENTS.md refs not reverted"; cat "$tree/AGENTS.md"
  fi
  if grep -qF 'DozenOS END USER NOTICE' "$tree/data/build-types/development.toml" \
     && ! grep -qE 'Kirkham|DozenOS Inc' "$tree/data/build-types/development.toml"; then
    ok "$label: upstream EULA payload replaced by authored notice (both modes)"
  else
    bad "$label: EULA payload not replaced"; grep -n 'Inc\|NOTICE' "$tree/data/build-types/development.toml"
  fi

  if grep -qF 'website_url = "https://dozenos.github.io/dozenos-nightly-build"' "$tree/data/defaults.toml" \
     && ! grep -qE 'dozenos\.io|dozenos\.dev' "$tree/data/defaults.toml"; then
    ok "$label: project URLs pinned to org-controlled hosts (both modes)"
  else
    bad "$label: project URLs not pinned"; grep '_url' "$tree/data/defaults.toml"
  fi

  if grep -qF 'github.com/vyos/vyos.vyos.git' "$tree/scripts/ansible-install" \
     && ! grep -qF 'github.com/dozenos/dozenos.dozenos.git' "$tree/scripts/ansible-install"; then
    ok "$label: ansible-install dangling dozenos.dozenos collection ref reverted (both modes)"
  else
    bad "$label: ansible-install ref not reverted"; cat "$tree/scripts/ansible-install"
  fi

  if [ -f "$tree/scripts/package-build/hvinfo/package.toml" ]; then
    ok "$label: new-files/ recipe (hvinfo) copied in (both modes)"
  else
    bad "$label: new-files/ recipe (hvinfo) missing"
  fi
}

# ---------------------------------------------------------------------------
# Run 1: --ci mode.
# ---------------------------------------------------------------------------
echo "== apply-overlay.sh --ci =="
TREE_CI="$WORK/tree-ci"
make_fixture "$TREE_CI"
if OUT_CI=$("$SCRIPT" --ci "$TREE_CI" 2>&1); then
  ok "--ci exits 0"
else
  bad "--ci exited non-zero"; printf '%s\n' "$OUT_CI"
fi
assert_ci_state "$TREE_CI" "--ci"
assert_both_modes_state "$TREE_CI" "--ci"

snap_ci_1=$(snapshot "$TREE_CI")
OUT_CI2=$("$SCRIPT" --ci "$TREE_CI" 2>&1)
snap_ci_2=$(snapshot "$TREE_CI")
if [ "$snap_ci_1" = "$snap_ci_2" ]; then
  ok "--ci: idempotent (2nd run byte-identical)"
else
  bad "--ci: NOT idempotent"
  diff <(printf '%s\n' "$snap_ci_1") <(printf '%s\n' "$snap_ci_2") | head
fi

# ---------------------------------------------------------------------------
# Run 2: --local mode.
# ---------------------------------------------------------------------------
echo "== apply-overlay.sh --local =="
TREE_LOCAL="$WORK/tree-local"
make_fixture "$TREE_LOCAL"
if OUT_LOCAL=$("$SCRIPT" --local "$TREE_LOCAL" 2>&1); then
  ok "--local exits 0"
else
  bad "--local exited non-zero"; printf '%s\n' "$OUT_LOCAL"
fi
assert_local_state "$TREE_LOCAL" "--local"
assert_both_modes_state "$TREE_LOCAL" "--local"

snap_local_1=$(snapshot "$TREE_LOCAL")
OUT_LOCAL2=$("$SCRIPT" --local "$TREE_LOCAL" 2>&1)
snap_local_2=$(snapshot "$TREE_LOCAL")
if [ "$snap_local_1" = "$snap_local_2" ]; then
  ok "--local: idempotent (2nd run byte-identical)"
else
  bad "--local: NOT idempotent"
  diff <(printf '%s\n' "$snap_local_1") <(printf '%s\n' "$snap_local_2") | head
fi

# ---------------------------------------------------------------------------
# Run 3: no flag -- must default to --ci.
# ---------------------------------------------------------------------------
echo "== apply-overlay.sh (no flag => default) =="
TREE_DEFAULT="$WORK/tree-default"
make_fixture "$TREE_DEFAULT"
if OUT_DEFAULT=$("$SCRIPT" "$TREE_DEFAULT" 2>&1); then
  ok "no-flag exits 0"
else
  bad "no-flag exited non-zero"; printf '%s\n' "$OUT_DEFAULT"
fi
assert_ci_state "$TREE_DEFAULT" "no-flag (default)"
assert_both_modes_state "$TREE_DEFAULT" "no-flag (default)"

TREE_CI_FOR_COMPARE="$WORK/tree-ci-compare"
make_fixture "$TREE_CI_FOR_COMPARE"
"$SCRIPT" --ci "$TREE_CI_FOR_COMPARE" >/dev/null
if [ "$(snapshot "$TREE_DEFAULT")" = "$(snapshot "$TREE_CI_FOR_COMPARE")" ]; then
  ok "no-flag output is byte-identical to --ci (default confirmed)"
else
  bad "no-flag output differs from --ci"
fi

# ---------------------------------------------------------------------------
# Run 4: bad usage.
# ---------------------------------------------------------------------------
echo "== bad usage =="
if "$SCRIPT" >/dev/null 2>&1; then
  bad "missing target: expected non-zero exit"
else
  ok "missing target: exits non-zero"
fi
if "$SCRIPT" --bogus-flag "$WORK/tree-ci" >/dev/null 2>&1; then
  bad "unknown flag: expected non-zero exit"
else
  ok "unknown flag: exits non-zero"
fi

echo
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
