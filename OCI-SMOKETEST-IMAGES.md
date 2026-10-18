# OCI-SMOKETEST-IMAGES.md — smoketest container images on ghcr.io/dozenos

## Failure (nightly red since 2026-10-15)

Upstream vyos-1x `ab4babd53a` moved the two smoketest server images to
Docker Hub:

| File (upstream) | Variable | Value |
|---|---|---|
| `debian/vyos-1x-smoketest.postinst` | `TACPLUS_TAG` | `docker.io/vyos/tacacs_plus:alpine-slim` |
| `debian/vyos-1x-smoketest.postinst` | `RADIUS_TAG` | `docker.io/vyos/radius_server:latest` |
| `smoketest/scripts/cli/test_system_login.py` | `tac_image` | `docker.io/vyos/tacacs_plus:alpine-slim` |
| `smoketest/scripts/cli/test_system_login.py` | `radius_image` | `docker.io/vyos/radius_server:latest` |

The postinst runs `skopeo copy --additional-tag "$TAG" "docker://$TAG"
docker-archive:...`, and the test loads the archive and starts the image by
the same tag, so both files must name the same string. The four-form rule
turned both into `docker.io/dozenos/...`. That namespace does not exist, so
`skopeo copy` failed and every nightly ISO build failed with it.

## Upstream sources

| Upstream repo | Image | Build |
|---|---|---|
| `vyos/oci-tacacs-plus` | `tacacs_plus:alpine-slim` | `docker buildx build --platform linux/amd64,linux/arm64 --target slim` |
| `vyos/oci-radius-server` | `radius_server:latest` | `docker buildx build --platform linux/amd64,linux/arm64` |

Both repos track `rolling`. Neither has a `.github/workflows/`, so upstream
builds and pushes the images by hand. The Docker Hub names use an
underscore (`tacacs_plus`, `radius_server`) while the repo names use a dash.
vyos-1x names the Docker Hub images, so DozenOS keeps the underscore names.

## Design

- **Mirrors.** `dozenos/oci-tacacs-plus` and `dozenos/oci-radius-server`,
  normal mode-B mirrors on `rolling`. The mirror name is the four-form
  transform of the upstream name, as for every other mirror
  (`vyos-1x` → `dozenos-1x`, `live-boot` → `live-boot`). These names hold no
  `vyos` token, so they stay unchanged.
- **Build workflow.** `overlay-oci-<name>/new-files/.github/workflows/build-image.yml`,
  copied in by that overlay's `apply-overlay.sh`. It runs on every push to
  `rolling` (a self-sync push only happens when the upstream tree changed)
  and on `workflow_dispatch`. QEMU + buildx build `linux/amd64` and
  `linux/arm64`, and the job's own `GITHUB_TOKEN` (`packages: write`) pushes
  to `ghcr.io/dozenos/tacacs_plus:alpine-slim` (`--target slim`) and
  `ghcr.io/dozenos/radius_server:latest`. Same action pins and same GHCR login
  as `overlay-dozenos-build/`'s `build-docker-image.yml`. No extra OCI labels:
  the upstream Dockerfiles set their own, and the DozenOS workflows set none.
  This is the third sanctioned workflow source (`WORKFLOW-POLICY.md`).
- **Transform.** `REGISTRY_REWRITES` in `rebrand-map.conf` rewrites
  `docker.io/vyos/` → `ghcr.io/dozenos/` before the four-form rules. On
  vyos-1x `db29bdc` (rolling, 2026-10-17) the dozenos-1x dry-run gives:

  ```
  debian/dozenos-1x-smoketest.postinst:9:TACPLUS_TAG="ghcr.io/dozenos/tacacs_plus:alpine-slim"
  debian/dozenos-1x-smoketest.postinst:15:RADIUS_TAG="ghcr.io/dozenos/radius_server:latest"
  smoketest/scripts/cli/test_system_login.py:64:tac_image = 'ghcr.io/dozenos/tacacs_plus:alpine-slim'
  smoketest/scripts/cli/test_system_login.py:111:radius_image = 'ghcr.io/dozenos/radius_server:latest'
  ```

  These four lines are the only `docker.io/vyos/` hits in vyos-1x
  `db29bdc` and vyos-build `94192fd`, and the only hits GitHub code search
  finds in the whole `vyos` org.
- **Dependency graph.** Both repos are leaves in `dep-graph/dep-graph.json`
  and are listed in `build_units.unmappable`. They produce no `.deb`. Their
  self-sync dispatch therefore resolves to an empty build set, and
  `rebuild-dispatch.yml` neither rebuilds a package nor notifies the nightly.
  The images do end up in the ISO: nightly ISOs are the development build
  type, which installs `dozenos-1x-smoketest`, and its postinst saves both
  images as `docker-archive` tars during the chroot build. An image change
  still does not need its own ISO build. The nightly change-gate fingerprints
  every repo with a `rolling` branch, so the next nightly trigger (any other
  mirror change, or the weekly heartbeat) sees the new mirror SHA and builds
  with the new image. A direct trigger would also race `build-image.yml`,
  which starts on the same push and finishes later.

## Roll-out order

1. Seed both mirrors (`mirror-push.sh https://github.com/vyos/<name> --target <name> --overlay dozenos-rebrand/overlay-<name>`).
   The seed push starts `build-image.yml`, which pushes the first image.
2. Set the `UPSTREAM_URL` repository variable on each new mirror.
3. **One-time manual step (org admin):** set both GHCR packages
   (`tacacs_plus`, `radius_server`) to **Public** in the package settings
   (`github.com/orgs/dozenos/packages/container/<name>/settings`). A package
   that a workflow creates starts private, and the ISO build pulls it
   without credentials.
4. Push `dozenos-rebrand`. `rebake-mirrors.yml` re-syncs dozenos-1x with
   the new rule, and the normal rebuild → nightly chain follows.

If the `BUILD_APP_PRIVATE_KEY` secret is limited to selected repositories,
add both new mirrors, or their `sync.yml` cannot mint its self-push token.
