#!/usr/bin/env bash
#
# deb-cache.sh -- content-addressed .deb reuse for DozenOS CI (see
# ../DEB-CACHE.md for the full design; DISTRIBUTION.md §1a for why this is
# NOT the "public apt mirror" that document rules out).
#
# A package build's output is a pure function of its inputs. This helper
# derives a KEY from exactly those inputs and uses it to probe/store the
# built .deb set as a GitHub Release on a dedicated cache repo
# (dozenos/dozenos-deb-cache by default, tag "<unit>-<key12>"). An
# unchanged package therefore hits the entry stored by ANY earlier run --
# the cache is keyed by content, never by run/date -- and a changed
# package (or changed recipe/toolchain input) misses and rebuilds. A cache
# wipe degrades to a full rebuild, never to a wrong ISO.
#
# KEY MATERIAL for a build unit (a scripts/package-build/<dir> recipe;
# unit "linux-kernel" also covers vpp -- the kernel leg builds vpp inside
# itself, see dozenos-nightly-build's discover-job comment):
#   - the recipe dir's git TREE hash (covers every recipe file change)
#   - each package.toml [[packages]] entry whose commit_id is a BRANCH
#     (rolling, stable/*, empty, ...): the branch's live remote SHA via
#     `git ls-remote` (pinned tags/hashes need no lookup -- the recipe
#     tree hash already covers a pin bump)
#   - the forward transitive dep closure from dep-graph.json (the same
#     graph rebuild-dispatch fans out over, inverted): every dep node's
#     recipe dir joins the material, and every dep node that is itself a
#     dozenos/* mirror contributes its rolling HEAD SHA (e.g. dozenos-1x
#     builds against the vyconf + dozenos1x-config mirrors, which appear
#     in NO package.toml)
#   - global inputs shared by every recipe: scripts/package-build/build.py,
#     data/defaults.toml (kernel version lives here), and the rebrand
#     toolkit's rename-transform.sh (every recipe's pre_build_hook)
#   NOT in the key (accepted, documented): the ghcr build-container digest
#   -- toolchain drift alone never invalidates; in practice a toolchain
#   change that matters comes with a recipe/defaults change.
#
# Subcommands (all exit 2 on usage/internal error):
#   key   --unit <recipe> --build <dozenos-build-dir> --rebrand <dir>
#         [--graph <dep-graph.json>] [--manifest <out.json>]
#       Print the full 64-hex key on stdout. Any resolution failure exits
#       non-zero -- callers must then build WITHOUT cache (fail-safe).
#   probe --unit <recipe> --key <hex> --dest <dir> [--repo <owner/name>]
#       Download the cached .debs for <unit>-<key12> into <dest>.
#       Exit 0 = hit (>=1 .deb landed, manifest key verified),
#       exit 3 = miss. Needs GH_TOKEN (any token; cache repo is public).
#   store --unit <recipe> --key <hex> --debs <dir> [--manifest <file>]
#         [--repo <owner/name>]
#       Create release <unit>-<key12> with <dir>/*.deb (+ manifest).
#       No .debs found or tag already exists => warn + exit 0 (idempotent,
#       race-safe). Needs GH_TOKEN with contents:write on the cache repo.
#   prune [--keep <N>] [--repo <owner/name>]
#       Keep the newest N (default 3) entries per unit, delete the rest
#       (tags included). Needs GH_TOKEN with contents:write.
#
# Env overrides (testing only): DEB_CACHE_MIRROR_URL_BASE replaces
# "https://github.com/dozenos" as the base URL for mirror-node HEAD
# lookups (lets the network-free test suite point at file:// bare repos).
set -euo pipefail

DEFAULT_REPO="dozenos/dozenos-deb-cache"
MANIFEST_NAME="deb-cache-manifest.json"

die() { printf 'deb-cache: %s\n' "$*" >&2; exit 2; }
log() { printf 'deb-cache: %s\n' "$*" >&2; }

usage() {
  sed -n '/^# Subcommands/,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//;$d' >&2
}

[ $# -ge 1 ] || { usage; die "missing subcommand"; }
SUB="$1"; shift

UNIT="" KEY="" BUILD="" REBRAND="" GRAPH="" MANIFEST="" DEST="" DEBS=""
REPO="$DEFAULT_REPO" KEEP=3
while [ $# -gt 0 ]; do
  case "$1" in
    --unit)     UNIT="${2:-}"; shift 2 ;;
    --key)      KEY="${2:-}"; shift 2 ;;
    --build)    BUILD="${2:-}"; shift 2 ;;
    --rebrand)  REBRAND="${2:-}"; shift 2 ;;
    --graph)    GRAPH="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --dest)     DEST="${2:-}"; shift 2 ;;
    --debs)     DEBS="${2:-}"; shift 2 ;;
    --repo)     REPO="${2:-}"; shift 2 ;;
    --keep)     KEEP="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage; die "unknown argument: $1" ;;
  esac
done

tag_for() { printf '%s-%s' "$1" "${2:0:12}"; }

# --------------------------------------------------------------------------
# key
# --------------------------------------------------------------------------
cmd_key() {
  [ -n "$UNIT" ]    || die "key: --unit is required"
  [ -d "$BUILD" ]   || die "key: --build dir not found: $BUILD"
  [ -d "$REBRAND" ] || die "key: --rebrand dir not found: $REBRAND"
  [ -n "$GRAPH" ] || GRAPH="$REBRAND/dep-graph/dep-graph.json"
  [ -f "$GRAPH" ] || die "key: dep-graph not found: $GRAPH"

  python3 - "$UNIT" "$BUILD" "$REBRAND" "$GRAPH" "${MANIFEST:-}" <<'PYEOF'
import hashlib, json, os, re, subprocess, sys
try:
    import tomllib
except ImportError:
    print('deb-cache: key: python3 >= 3.11 (tomllib) required', file=sys.stderr)
    sys.exit(1)

unit, build, rebrand, graph_path, manifest_out = sys.argv[1:6]
MIRROR_BASE = os.environ.get(
    'DEB_CACHE_MIRROR_URL_BASE', 'https://github.com/dozenos')
# Never let git fall into an interactive credential prompt (a nonexistent
# github.com repo answers 401/404, which triggers one).
GIT_ENV = {**os.environ, 'GIT_TERMINAL_PROMPT': '0',
           'GIT_ASKPASS': '/bin/true'}

def fail(msg):
    print(f'deb-cache: key: {msg}', file=sys.stderr)
    sys.exit(1)

def git(*args):
    r = subprocess.run(['git', *args], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout.strip()

def rev(build, path):
    out = git('-C', build, 'rev-parse', f'HEAD:{path}')
    if not out:
        fail(f'cannot resolve HEAD:{path} in {build}')
    return out

def ls_remote(url, ref):
    # ls-remote against a moving ref; one retry for transient flakes.
    for _ in range(2):
        r = subprocess.run(['git', 'ls-remote', url, ref], env=GIT_ENV,
                           capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            out = r.stdout.strip()
            return out.split()[0] if out else ''
        last_err = r.stderr
    return None  # transport error (distinct from "ref not found" == '')

NOT_A_REPO = re.compile(
    r'not found|does not appear to be a git repository|could not read'
    r'|Authentication failed|access denied', re.IGNORECASE)

def mirror_head(node):
    # Rolling HEAD of a dozenos/* mirror candidate; '' when the node is not
    # a mirror at all (repo does not exist -- e.g. binary .deb node names
    # like libyang3). Only a genuine transport failure returns None.
    r = subprocess.run(
        ['git', 'ls-remote', f'{MIRROR_BASE}/{node}', 'refs/heads/rolling'],
        env=GIT_ENV, capture_output=True, text=True, timeout=60)
    if r.returncode == 0:
        out = r.stdout.strip()
        return out.split()[0] if out else ''
    if NOT_A_REPO.search(r.stderr or ''):
        return ''
    # one retry for a transient flake, then give up
    r = subprocess.run(
        ['git', 'ls-remote', f'{MIRROR_BASE}/{node}', 'refs/heads/rolling'],
        env=GIT_ENV, capture_output=True, text=True, timeout=60)
    if r.returncode == 0:
        out = r.stdout.strip()
        return out.split()[0] if out else ''
    if NOT_A_REPO.search(r.stderr or ''):
        return ''
    return None

# commit_id values that pin an immutable (or effectively immutable) ref --
# the recipe TREE hash already covers a pin bump, so no live lookup needed.
PINNED = [
    re.compile(r'^[0-9a-f]{7,40}$'),           # commit hash
    re.compile(r'^v?[0-9]'),                   # 1.16.0 / v5.20.28 / 20260410
    re.compile(r'^debian/'),                   # debian/2.8-6
    re.compile(r'%'),                          # epoch-encoded tag
    re.compile(r'^[A-Za-z][\w.]*-[0-9]'),      # Kea-3.0.3 / frr-10.6.1
]
def is_pinned(cid):
    return any(p.search(cid) for p in PINNED)

def unit_dirs(u):
    # The linux-kernel leg also builds vpp inside itself (accel-ppp-ng
    # links HAVE_VPP=1) -- see dozenos-nightly-build's discover comment.
    return [u, 'vpp'] if u == 'linux-kernel' else [u]

g = json.load(open(graph_path))
reverse = {k: v for k, v in g.get('reverse_dependencies', {}).items()}
n2u = g.get('build_units', {}).get('node_to_unit', {})
# forward[node] = the nodes it depends on (invert the reverse map)
forward = {}
for dep, dependents in reverse.items():
    for d in dependents:
        forward.setdefault(d, []).append(dep)

material = set()

# ---- global inputs shared by every recipe --------------------------------
material.add(f'global build.py {rev(build, "scripts/package-build/build.py")}')
material.add(f'global defaults.toml {rev(build, "data/defaults.toml")}')
rt = f'{rebrand}/rename-transform.sh'
try:
    h = hashlib.sha256(open(rt, 'rb').read()).hexdigest()
except OSError:
    fail(f'cannot read {rt}')
material.add(f'global rename-transform.sh {h}')

# ---- recipe-dir set: the unit + its forward transitive dep closure -------
# Every node in the closure is processed exactly once AT POP TIME (mirror
# lookup included) -- checking only at dep-discovery time was order-dependent
# (a node already popped from the initial frontier would be `seen`-skipped
# when later reached as somebody's dep, silently dropping its mirror SHA
# from the key).
dirs = set(unit_dirs(unit))
seen_nodes = set()
frontier = [unit] + [n for n, u in n2u.items()
                     if isinstance(u, dict) and u.get('recipe') in dirs]
while frontier:
    node = frontier.pop()
    if node in seen_nodes:
        continue
    seen_nodes.add(node)

    u = n2u.get(node)
    r = u.get('recipe') if isinstance(u, dict) else None
    if r and r not in dirs \
            and os.path.isdir(os.path.join(build, 'scripts/package-build', r)):
        for d in unit_dirs(r):
            dirs.add(d)
            frontier.extend(n for n, uu in n2u.items()
                            if isinstance(uu, dict) and uu.get('recipe') == d)

    # A closure node that is itself a dozenos/* mirror contributes its
    # rolling HEAD (e.g. vyconf / dozenos1x-config / dozenos-vpp-patches --
    # consumed by builds but present in NO package.toml). Nodes that are not
    # mirrors (binary .deb names like libyang3) resolve to '' and are
    # skipped; a transport error fails the whole key (fail-safe: the caller
    # then builds without cache rather than risk a stale hit). kernel_block
    # nodes are skipped outright: OOT module blocks pin external upstreams
    # in linux-kernel's own package.toml and are never dozenos/* mirrors --
    # skipping them saves ~15 pointless 404 lookups per kernel-leg key.
    is_kernel_block = isinstance(u, dict) and u.get('kernel_block')
    if not is_kernel_block and re.fullmatch(r'[A-Za-z0-9._-]+', node):
        sha = mirror_head(node)
        if sha is None:
            fail(f'ls-remote transport error for mirror candidate {node}')
        if sha:
            material.add(f'mirror {node} {sha}')

    frontier.extend(dep for dep in forward.get(node, [])
                    if dep not in seen_nodes)

# ---- per recipe dir: tree hash + branch-tracking scm entries -------------
for d in sorted(dirs):
    rel = f'scripts/package-build/{d}'
    if not os.path.isdir(os.path.join(build, rel)):
        fail(f'recipe dir not found: {rel}')
    material.add(f'recipe {d} {rev(build, rel)}')
    for root, _, files in os.walk(os.path.join(build, rel)):
        for fn in files:
            if fn != 'package.toml':
                continue
            with open(os.path.join(root, fn), 'rb') as f:
                toml = tomllib.load(f)
            for p in toml.get('packages', []):
                url = (p.get('scm_url') or '').strip()
                cid = (p.get('commit_id') or '').strip()
                name = p.get('name', '?')
                if not url or is_pinned(cid):
                    continue
                sha = ls_remote(url, f'refs/heads/{cid}' if cid else 'HEAD')
                if sha is None:
                    fail(f'ls-remote transport error for {name} ({url})')
                if not sha and cid:
                    sha = ls_remote(url, f'refs/tags/{cid}')
                if not sha:
                    fail(f'cannot resolve ref "{cid or "HEAD"}" for {name} ({url})')
                material.add(f'scm {d} {name} {url} {sha}')

lines = sorted(material)
key = hashlib.sha256(('\n'.join(lines) + '\n').encode()).hexdigest()
if manifest_out:
    with open(manifest_out, 'w') as f:
        json.dump({'unit': unit, 'key': key, 'material': lines}, f, indent=1)
print(key)
PYEOF
}

# --------------------------------------------------------------------------
# probe
# --------------------------------------------------------------------------
cmd_probe() {
  [ -n "$UNIT" ] || die "probe: --unit is required"
  [ -n "$KEY" ]  || die "probe: --key is required"
  [ -n "$DEST" ] || die "probe: --dest is required"
  mkdir -p "$DEST"
  local tag; tag=$(tag_for "$UNIT" "$KEY")

  # Any `gh release view` failure (404 or transport) is a MISS, never an
  # error: fail-open here only ever costs a rebuild, exactly today's cost.
  if ! gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    log "probe: MISS $REPO@$tag"
    return 3
  fi
  if ! gh release download "$tag" --repo "$REPO" --dir "$DEST" --clobber; then
    log "probe: $tag exists but download failed -- treating as MISS"
    return 3
  fi
  # 12-hex tag prefix could theoretically collide across full keys --
  # verify the stored manifest records exactly this key.
  local stored
  stored=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("key",""))' \
    "$DEST/$MANIFEST_NAME" 2>/dev/null) || stored=""
  if [ "$stored" != "$KEY" ]; then
    log "probe: $tag manifest key mismatch (stored=${stored:-none}) -- treating as MISS"
    rm -f "$DEST"/*.deb "$DEST/$MANIFEST_NAME"
    return 3
  fi
  if ! ls "$DEST"/*.deb >/dev/null 2>&1; then
    log "probe: $tag contains no .deb assets -- treating as MISS"
    return 3
  fi
  log "probe: HIT $REPO@$tag ($(ls "$DEST"/*.deb | wc -l) debs)"
  return 0
}

# --------------------------------------------------------------------------
# store
# --------------------------------------------------------------------------
cmd_store() {
  [ -n "$UNIT" ] || die "store: --unit is required"
  [ -n "$KEY" ]  || die "store: --key is required"
  [ -d "$DEBS" ] || die "store: --debs dir not found: $DEBS"
  local tag; tag=$(tag_for "$UNIT" "$KEY")

  local debs=("$DEBS"/*.deb)
  if [ ! -e "${debs[0]}" ]; then
    log "store: no .deb files under $DEBS -- nothing to cache (skipping, not an error)"
    return 0
  fi
  if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    log "store: $REPO@$tag already exists -- skipping (idempotent)"
    return 0
  fi

  local assets=("${debs[@]}")
  if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    local mcopy
    mcopy=$(mktemp -d)/"$MANIFEST_NAME"
    cp "$MANIFEST" "$mcopy"
    assets+=("$mcopy")
  else
    log "store: WARNING no --manifest given -- probe's full-key verification will always miss this entry"
  fi

  if ! gh release create "$tag" --repo "$REPO" \
      --title "$tag" \
      --notes "deb-cache entry: unit=$UNIT key=$KEY (content-addressed CI cache -- see dozenos-rebrand/DEB-CACHE.md; not an apt repo)" \
      "${assets[@]}"; then
    # Lost a create race with a concurrent leg storing the same key --
    # the winner's entry is equivalent by construction.
    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
      log "store: lost create race for $tag -- entry exists, done"
      return 0
    fi
    die "store: gh release create failed for $REPO@$tag"
  fi
  log "store: cached ${#debs[@]} debs as $REPO@$tag"
}

# --------------------------------------------------------------------------
# prune
# --------------------------------------------------------------------------
cmd_prune() {
  case "$KEEP" in (*[!0-9]*|'') die "prune: --keep must be a non-negative integer" ;; esac
  # API order is useless here: list-releases sorts by created_at, which
  # GitHub sets to the tagged COMMIT's date -- identical for every entry
  # because all tags point at the seed commit (the tie-break is tag-name
  # order, i.e. random w.r.t. age). Sort by release id, the only monotonic
  # store-time signal, so "newest" means most recently stored. Keep the
  # first $KEEP per unit (tag minus the trailing -<12hex> key suffix).
  gh api --paginate "repos/$REPO/releases" \
    --jq '.[] | "\(.id)\t\(.tag_name)"' \
    | sort -k1,1 -rn | while IFS=$'\t' read -r _ tag; do
      printf '%s\t%s\n' "$(printf '%s' "$tag" | sed -E 's/-[0-9a-f]{12}$//')" "$tag"
    done | awk -F'\t' -v keep="$KEEP" '{ if (++n[$1] > keep) print $2 }' \
    | while IFS= read -r tag; do
        log "prune: deleting $REPO@$tag"
        gh release delete "$tag" --repo "$REPO" --yes --cleanup-tag \
          || log "prune: WARNING failed to delete $tag (continuing)"
      done
}

case "$SUB" in
  key)   cmd_key ;;
  probe) cmd_probe ;;
  store) cmd_store ;;
  prune) cmd_prune ;;
  -h|--help) usage ;;
  *) usage; die "unknown subcommand: $SUB" ;;
esac
