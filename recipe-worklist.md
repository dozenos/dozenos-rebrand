# DozenOS rebrand — per-recipe build worklist (item #15)

Scope: every recipe dir under `vyos-build/scripts/package-build/` (LOCAL build only).
Source of truth: `REBRAND-PLAN.md` §2a/§2b/§2c table, cross-checked against the actual
recipe dirs + `package.toml` + `patches/` + already-produced `.deb` on disk (2026-07-07).

Class legend:
- **C1** = produced binary/source name CONTAINS `vyos` -> four-form rename + rebuild.
- **C2** = VyOS-patched or VyOS-forked but upstream/Debian package name kept -> name stays,
  MUST rebuild locally (differs from stock Debian) + transform any shipped `vyos` string. Feeds item #16.
- **DEB** = pure Debian passthrough -> do NOT build locally, apt pulls from Debian.

Build status: `done` = dozenos `.deb` present on disk; `in_progress` = #8 kernel compile
running; `pending` = to be built in item #16.

**Count of recipe dirs on disk = 42** (plan §2a lists 40; disk adds `openssl` + `vyos-http-api-tools`,
which the plan had put in §2b as "gaps"). Note the "41" in the task brief is off by one — actual is 42.

| recipe | source name(s) | scm_url host | class | produced binary pkg(s) (best-effort) | needs local build? | build status | heavy? | notes |
|---|---|---|---|---|---|---|---|---|
| amazon-cloudwatch-agent | amazon-cloudwatch-agent | github.com/aws | C2 | amazon-cloudwatch-agent | yes | pending (#16) | | upstream tag v1.300057.0 |
| amazon-ssm-agent | amazon-ssm-agent | github.com/aws | C2 | amazon-ssm-agent | yes | pending (#16) | | upstream tag |
| aws-gwlbtun | aws-gwlbtun | github.com/aws-samples | C2 | aws-gwlbtun | yes | pending (#16) | | upstream sha |
| bash-completion | bash-completion | salsa.debian.org | C2 | bash-completion | yes | **done (#16)** | | VyOS-tracked debian pkg; `bash-completion_2.8-6+git20260707.3728429_all.deb`. NO VyOS patch (no recipe `patches/`), zero-vyos source — **DEB-passthrough candidate** BUT VyOS deliberately pins OLD `debian/2.8-6` ("older version required"); current Debian is newer, so passthrough changes version. |
| blackbox_exporter | blackbox_exporter | github.com/prometheus | C2 | prometheus-blackbox-exporter | yes | pending (#16) | | has build.sh |
| ddclient | ddclient | salsa.debian.org | C2 | ddclient | yes | **done (#16)** | | debian-tracked; `ddclient_3.11.2-1+git20260707.660bb2d_all.deb`. NO VyOS patch (no recipe `patches/`), zero-vyos source — **strong DEB-passthrough candidate** (plain Debian `debian/3.11.2-1`, drop from #16 worklist under Strategy B). |
| dropbear | dropbear | salsa.debian.org | C2 | dropbear-bin/-run/initramfs | yes | pending (#16) | | 1 local patch |
| ethtool | ethtool | salsa.debian.org | C2 | ethtool | yes | pending (#16) | | debian-tracked |
| frr | libyang + frr | github.com/CESNET + github.com/FRRouting | C2 | frr, frr-pythontools, libyang3 | yes | pending (#16) | HEAVY | 12 local patches |
| frr_exporter | frr_exporter | github.com/tynany | C2 | prometheus-frr-exporter | yes | pending (#16) | | upstream tag |
| hostap | wpa + hostap | salsa.debian.org + git.w1.fi | C2 | wpasupplicant/hostapd | yes | pending (#16) | | debian+sha, has build.sh |
| hsflowd | host-sflow | github.com/sflow | C2 | hsflowd | yes | pending (#16) | | upstream tag |
| isc-dhcp | isc-dhcp | salsa.debian.org | C2 | isc-dhcp-client/-common | yes | **DONE (#16, batch4)** | isc-dhcp-common_4.4.3-P1-4_amd64.deb, isc-dhcp-client_4.4.3-P1-4_amd64.deb | build.py; 4 local patches applied (0001-0004, incl fix-compilation-errors + ARPHRD_NONE) via series; +pre_build_hook added; patches zero-vyos; 0 residual vyos; excluded server/relay/keama/ddns/ldap/dev + all dbgsym |
| isc-kea | isc-kea | gitlab.isc.org | C2 | kea-* (dhcp4/6, ctrl-agent) | yes | pending (#16) | HEAVY | has prebuild.sh |
| keepalived | keepalived | salsa.debian.org | C2 | keepalived | yes | pending (#16) | | debian-tracked |
| libhtp | libhtp2 | salsa.debian.org | C2 | libhtp2 | yes | pending (#16) | | pkg-suricata-team sha |
| **libnss-mapuser** | **vyos-libnss-mapuser** | github.com/vyos | **C1** | dozenos-libnss-mapuser | yes | **done (#7)** | | dozenos .deb present |
| **libpam-radius-auth** | **vyos-libpam-radius-auth**, vyos-radius-shell | github.com/vyos | **C1** | dozenos-libpam-radius-auth, dozenos-radius-shell | yes | **done (#7)** | | dozenos .debs present |
| **linux-kernel** | linux-upstream + firmware + accel-ppp-ng + nat-rtsp + jool + mlnx + intel + realtek + ipt-netflow | kernel.org + intel + upstream | **C1(drivers)/C2** mixed | linux-image/headers/libc-dev/perf `*-dozenos` (C1 suffix); vyos-linux-firmware, vyos-intel-*, vyos-drivers-realtek-*, vyos-ipt-netflow (C1); accel-ppp-ng, nat-rtsp, jool, mlnx-tools (C2) | yes (must recompile, `-vyos`->`-dozenos` flavor) | **in_progress (#8)** | HEAVY | 21 kernel patches; sub-products see §2c below |
| ndppd | ndppd | salsa.debian.org | C2 | ndppd | yes | pending (#16) | | 2 local patches |
| netfilter | libnftnl + nftables | salsa.debian.org | C2 | libnftnl11, nftables | yes | **DONE (#16, batch4)** | libnftnl11_1.2.6-2_amd64.deb, libnftables1_1.0.9-1_amd64.deb, nftables_1.0.9-1_amd64.deb | build.py; 1 local patch (0001-meta-fix-hour-decoding) applied to pkg-nftables via series; +pre_build_hook on both blocks; patch zero-vyos; 0 residual vyos; libnftables1 added (hard dep of nftables); excluded -dev/-dev-doc/python3-nftables + all dbgsym |
| net-snmp | net-snmp | salsa.debian.org | C2 | snmp, snmpd, libsnmp* | yes | **DONE (#16, batch4)** | libsnmp-base_5.9.4+dfsg-1_all.deb, libsnmp40_5.9.4+dfsg-1_amd64.deb, snmp_5.9.4+dfsg-1_amd64.deb, snmpd_5.9.4+dfsg-1_amd64.deb | build.py; 2 VyOS patches (add-linux-6.7-compatibility-parsing, snmptrapd-fix-out-of-bounds-trapoid-acccess) applied via series; +pre_build_hook added; patches zero-vyos; 0 residual vyos; excluded snmptrapd/libnetsnmptrapd40/libsnmp-perl/libsnmp-dev/tkmib + all dbgsym |
| node_exporter | node_exporter | github.com/prometheus | C2 | prometheus-node-exporter | yes | pending (#16) | | upstream tag |
| **openssl** | openssl | salsa.debian.org | **C2** | openssl, libssl3 | **yes** | pending (#16) | | **DECISION: C2 not DEB — has VyOS `0001-Enable-FIPS-module.patch` (enable-fips + fipsmodule.cnf), binary differs from stock Debian. Contradicts plan §2b "no patch / DEB passthrough".** |
| openvpn-otp | openvpn-otp | github.com/evgeny-gridasov | C2 | openvpn-otp | yes | pending (#16) | | upstream sha |
| owamp | owamp + twamp | github.com/perfsonar | C2 | owamp-*, twamp-* | yes | pending (#16) | | upstream tag |
| podman | podman | github.com/containers | C2 | podman | yes | pending (#16) | HEAVY | golang build |
| pyhumps | humps | github.com/nficano | C2 | python3-pyhumps | yes | **done (#16)** | | upstream tag v3.8.0; `python3-pyhumps_3.8.0-1_all.deb` (built via stdeb bdist_deb). NO VyOS patch, zero-vyos source — but NOT a DEB-passthrough (not packaged in Debian; built from upstream PyPI/github via stdeb). Recipe toml `name="humps"` → inner clone dir is `humps/` (not `pyhumps/`). |
| radvd | radvd | github.com/radvd-project | C2 | radvd | yes | pending (#16) | | upstream tag |
| shim-signed | shim, shim-signed | github.com/vyos | C2 (name has no vyos) | shim-signed | yes | pending (#16) | | vyos-hosted scm (build-time pointer, tolerated) |
| strongswan | strongswan | salsa.debian.org | C2 | strongswan, libcharon*, charon-* | yes | pending (#16) | HEAVY | 5 local patches, has build-vici.sh |
| tacacs | libtacplus-map + libpam-tacplus + libnss-tacplus | github.com/vyos | C2 (names have no vyos) | libtacplus-map1, libpam-tacplus, libnss-tacplus | yes | pending (#16) | | vyos-hosted scm (build-time pointer, tolerated) |
| telegraf | telegraf | github.com/influxdata | C2 | telegraf | yes | pending (#16) | HEAVY | golang, has build.sh + plugins/ |
| udp-broadcast-relay | udp-broadcast-relay | github.com/nomeata | C2 | udp-broadcast-relay | yes | DONE (#16, batch2) | udp-broadcast-relay_0.3+dozenos_amd64.deb | 1 local patch APPLIED via build_cmd git am (apply_patches=false, no series file); patch pre-transformed; +pre_build_hook added; 0 residual vyos; no dbgsym |
| unionfs-fuse | unionfs-fuse | github.com/rpodgorny | C2 | unionfs-fuse | yes | pending (#16) | | AMBIGUOUS: plan flags "not seen in current rolling Packages" — confirm still shipped |
| vpp | vyos-vpp-patches + vpp | github.com/vyos + github.com/FDio | C2 | vpp, vpp-plugin-*, libvppinfra | yes | **IN_PROGRESS (#16, detached)** | pending (container dozenos-vpp-build) | HEAVY; stale inner clone rm'd for pristine re-clone; +transform of ../patches/vpp after rsync in pre_build_hook -> all 32 VyOS patches git-am'd cleanly (0020 now "DozenOS-specific versioning"); building dpdk/external at report time; unblocks accel-ppp #18 |
| **vyos-1x** | **vyos-1x** | github.com/vyos | **C1** | dozenos-1x, libdozenosconfig0, dozenos-user-utils, dozenos-1x-{smoketest,aws,vmware} | yes | **done (#6)** | | dozenos .debs present |
| **vyos-http-api-tools** | **vyos-http-api-tools** | github.com/vyos | **C1** | dozenos-http-api-tools | yes | **done** (dozenos .deb present) | | Plan §2b listed it as a "gap needing new recipe", but recipe dir EXISTS and is already built. Reconcile plan. |
| waagent | waagent | salsa.debian.org | C2 | waagent | yes | pending (#16) | | cloud-team debian |
| wide-dhcpv6 | wide-dhcpv6 | salsa.debian.org | C2 | wide-dhcpv6-client/-server | yes | pending (#16) | | 3 local patches |
| xen-guest-agent | xen-guest-agent | gitlab.com/xen-project | C2 | xen-guest-agent | yes | pending (#16) | | upstream tag |
| zerotier-one | zerotier-one | github.com/zerotier | C2 | zerotier-one | yes | pending (#16) | | upstream tag |

## linux-kernel sub-products (plan §2c) — handled inside the one `linux-kernel` recipe (#8, in_progress)

| sub-item | source | produced | class | notes |
|---|---|---|---|---|
| kernel | defaults.toml kernel_version (6.18.36) | linux-image/headers/libc-dev/perf `*-dozenos` | **C1** | `-vyos`->`-dozenos` via kernel_flavor; MUST recompile (LOCALVERSION baked into vermagic, not SED-able) |
| linux-firmware | git.kernel.org linux-firmware | vyos-linux-firmware | **C1** | blob repack, rename only (no recompile) |
| intel NIC | github.com/intel/ethernet-linux-{igb,ixgbe,ixgbevf,i40e,ice,iavf} | vyos-intel-* | **C1** | recompile against new flavor |
| realtek | build-realtek-r81xx.py | vyos-drivers-realtek-{r8126,r8152} | **C1** | recompile against new flavor |
| ipt-netflow | github.com/nuclearcat/ipt-netflow | vyos-ipt-netflow | **C1** | recompile |
| accel-ppp-ng | github.com/accel-ppp/accel-ppp-ng | accel-ppp-ng | C2 | recompile against new flavor |
| nat-rtsp | github.com/maru-sama/rtsp-linux | nat-rtsp | C2 | recompile |
| jool | github.com/NICMx/Jool | jool | C2 | recompile |
| mlnx (OFED) | mellanox.com MLNX_OFED_SRC | mlnx-tools etc | C2 | HEAVY (mellanox-ofed); skippable per §3g |

## Summary

### Counts per class (recipe dirs)
- **C1 = 5**: vyos-1x (done #6), libnss-mapuser (done #7), libpam-radius-auth (done #7),
  vyos-http-api-tools (done), linux-kernel (in_progress #8, mixed C1/C2).
  - C1 done = 4; C1 in_progress = 1 (linux-kernel drivers, #8).
- **C2 = 37**: all pending for #16 (openssl included). 0 built yet.
- **DEB passthrough = 0** among recipe dirs. (openssl was the only candidate but is C2 due to the FIPS patch;
  `salt` is not a recipe dir — it stays external/Broadcom per plan §2b; Debian-stock openssl passthrough is
  superseded by the local FIPS-patched build.)
- Total = 42 (4 C1 done + 1 kernel in_progress + 37 C2 pending).

### Explicit pending-C2 build list for item #16 (37 recipes)
amazon-cloudwatch-agent, amazon-ssm-agent, aws-gwlbtun, bash-completion, blackbox_exporter,
ddclient, dropbear, ethtool, **frr [HEAVY]**, frr_exporter, hostap, hsflowd, isc-dhcp,
**isc-kea [HEAVY]**, keepalived, libhtp, ndppd, netfilter, net-snmp, node_exporter, **openssl**,
openvpn-otp, owamp, **podman [HEAVY]**, pyhumps, radvd, shim-signed, **strongswan [HEAVY]**,
tacacs, **telegraf [HEAVY]**, udp-broadcast-relay, unionfs-fuse, **vpp [HEAVY]**, waagent,
wide-dhcpv6, xen-guest-agent, zerotier-one.

Heavy (in pending-C2): frr, isc-kea, podman, strongswan, telegraf, vpp.
Heavy (elsewhere): linux-kernel (#8, in_progress), mellanox-ofed (linux-kernel sub-product).

### Ambiguous / needs human
1. **openssl** — plan §2b says "DEB passthrough, no patch"; recipe on disk carries a VyOS
   FIPS-enable patch. Classified C2 (must rebuild). Reconcile plan text.
2. **vyos-http-api-tools** — plan §2b listed as a "gap needing a NEW recipe"; the recipe dir
   already exists and has already produced `dozenos-http-api-tools`. Reconcile plan (it is a C1, done).
3. **unionfs-fuse** — plan flags "not seen in current rolling Packages"; confirm whether still shipped
   before spending a build slot.
4. **Recipe count** — disk = 42, plan §2a = 40, task brief = 41. openssl + vyos-http-api-tools are the delta.
5. **linux-kernel** — mixed C1(drivers/kernel)/C2 within one recipe; tracked wholly under #8.

### vyos-hosted scm_url recipes (build-time pointers, tolerated — not shipped `vyos` strings)
libnss-mapuser (C1), libpam-radius-auth (C1), vyos-1x (C1), vyos-http-api-tools (C1),
shim-signed (C2), tacacs (C2), vpp (vyos-vpp-patches, C2).
All other recipes point at external upstream (github/salsa/gitlab/kernel.org).
