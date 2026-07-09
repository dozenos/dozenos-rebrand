# Secure Boot MOK certificates

This directory is copied wholesale into the image at build time:

    scripts/image-build/build-dozenos-image:369-371
        sb_certs = 'data/certificates'
        if os.path.isdir(sb_certs):
            shutil.copytree(sb_certs, f'{lb_config_dir}/includes.chroot/var/lib/shim-signed/mok')

Everything present here at build time ends up in the image at
`/var/lib/shim-signed/mok/`. Only PUBLIC material belongs here.

## What ships here (and where it comes from)

- The DozenOS Secure Boot kernel-signing certificate (PUBLIC,
  `dozenos-dev-2025-linux.pem` — see "Naming reconciliation" below) is
  **not committed** to this repo. It is injected into this directory by
  `../../release/inject-mok-cert.sh` (Phase 4 / progress item #10), called
  from the CI ISO-build workflow, sourced from the org secret
  `MOK_SIGNING_CERT`.
- The matching private signing key (`dozenos-dev-2025-linux.key`) comes
  from the org secret `MOK_SIGNING_KEY`, via the same script. It is
  gitignored (see `.gitignore` = `*.key`) and is **never** committed to
  this repo, regardless of source (CI or local).
- The DozenOS Secure Boot **MOK enrollment** certificate (PUBLIC,
  `dozenos-dev-2025-shim.der` — see "shim-signed / MOK enrollment" below,
  progress item #11) is a DER re-encoding of the exact same cert as the
  `.pem` above (`openssl x509 -outform DER`, no signing involved), derived
  by the same `inject-mok-cert.sh` call. This is the file
  `install_mok.sh`'s `mokutil --import` reads on a running DozenOS system.
- Local/dev builds with no secrets available will simply have an empty
  `data/certificates/` (aside from this README and `.gitignore`), so the
  `copytree` above ships an empty MOK enrollment set. That is fine for
  local builds with Secure Boot off — `93-sb-sign-kernel.chroot` detects
  the missing key/cert pair and skips kernel signing rather than failing,
  and `install_mok.sh` prints "Secure Boot Machine Owner Key not found"
  rather than failing.

## Naming reconciliation (resolved, progress item #10)

`data/live-build-config/hooks/live/93-sb-sign-kernel.chroot` signs the
kernel using:

    /var/lib/shim-signed/mok/dozenos-dev-2025-linux.key
    /var/lib/shim-signed/mok/dozenos-dev-2025-linux.pem

i.e. a `*-dev-*` named keypair. This directory's earlier draft assumed the
CI-injected enrollment cert would instead be named `*-prod-*` (e.g.
`dozenos-prod-2025-linux.pem`, mirroring the upstream project's pre-rebrand
naming convention) — that would have meant shim enrolls a cert that does not
correspond to the key that signed the kernel, and Secure Boot verification
would fail.

**Resolved:** there is only one injected keypair, written under the
**`*-dev-*`** name for both halves, by `../../release/inject-mok-cert.sh`
(reads org secrets `MOK_SIGNING_KEY` / `MOK_SIGNING_CERT`, see
`../../CI-SECRETS.md`):

    data/certificates/dozenos-dev-2025-linux.key   (private, mode 0600, gitignored)
    data/certificates/dozenos-dev-2025-linux.pem   (public,  mode 0644)

Because this whole directory is copied verbatim (filenames preserved) to
`/var/lib/shim-signed/mok/`, this `.pem` is the cert `sbsign` signs
`vmlinuz` against. No `*-prod-*`-named copy is produced or needed. See
`../../SB-SIGNING.md` for the full end-to-end flow, the module- vs
kernel-signing distinction, and the post-build verification checklist.

## shim-signed / MOK enrollment (resolved, progress item #11)

`shim-signed` (`scripts/package-build/shim-signed/`) repackages Debian's
already Microsoft-signed shim binary as-is — DozenOS cannot and does not
re-sign shim itself (that requires Microsoft's UEFI CA). DozenOS's own cert
enters the boot chain a different way: as a **MOK** the shim-provided
`MokManager`/`mokutil` enrolls, which shim then trusts to verify the
signature on the next-stage bootloader/kernel it chain-loads. The dozenos-1x
package ships `install_mok.sh` (the `install mok` op-mode command), which
runs:

    mokutil --ignore-keyring --import /var/lib/shim-signed/mok/dozenos-dev-2025-shim.der

i.e. it expects a **DER**-encoded cert at that exact path/name — `mokutil
--import` requires DER, not PEM. `inject-mok-cert.sh` derives
`dozenos-dev-2025-shim.der` from the same `MOK_SIGNING_CERT`-sourced `.pem`
above (`openssl x509 -in <.pem> -outform DER -out <.der>`), so the cert
`mokutil` enrolls and the cert `sbsign` signs the kernel with are
**guaranteed to be the same MOK** — just two encodings of one certificate,
not two different certs. See `../../SB-SIGNING.md` "shim-signed / MOK
enrollment (#11)" for the full trust-flow explanation.

This directory intentionally does NOT contain a placeholder/fabricated
certificate — no cert or key material should be generated for DozenOS
without the real MOK keypair (owned by the user, injected via CI secrets
in Phase 4).
