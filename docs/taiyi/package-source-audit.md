# Taiyi Package Source Audit

## Purpose

This document records the provenance and update boundary for packages exposed by
Taiyi LuCI. It distinguishes build-time source inputs from device APK
repositories.

A Git repository, GitHub release, or OpenWrt feed is never a device repository.
A device may consume a custom package only after Taiyi builds it, verifies its
inputs, and publishes it through the separately signed Taiyi APK feed.

`safe`, `network-critical`, and `firmware-only` are policy classes, not an
allowlist. A package may enter the signed add-on feed only after a separate
package-payload, dependency-closure, solver, signature, and device acceptance
review.

## Source Rules

1. Prefer the maintainer's canonical project repository or release over a
   community collection that happens to contain an OpenWrt recipe.
2. Keep the OpenWrt package recipe in the Taiyi build or inherited official
   feed, and lock the application source by commit/tag and cryptographic hash.
3. A recipe that downloads a release binary must validate an exact SHA-256
   before it can be used in a release build.
4. Packages coupled to kmods, firewall, routing, filesystem drivers, service
   lifecycle, or a shared-library closure are firmware-only.
5. Default-disabled custom feed configuration and an empty allowlist are
   intentional. This audit does not enable online updates.

## Audited Components

| Component | Current recipe/build source | Canonical upstream or release source | Evidence and required boundary | Class |
| --- | --- | --- | --- | --- |
| eMMC Health | `adminchenyu/eMMC-Health` locked by `EMMC_HEALTH_COMMIT` | `https://github.com/adminchenyu/eMMC-Health` | LuCI/rpcd user-space package. Taiyi removes its legacy helper that invoked `opkg update/install`; the retained health reader must remain APK-only. | safe candidate, not allowlisted |
| DDNS-Go | Locked `kenzok8/small-package` recipe | `https://github.com/jeessy2/ddns-go` | Recipe downloads a versioned source archive with `PKG_HASH`; daemon/init/default configuration makes it network-critical. | network-critical |
| Nikki | `nikkinikki-org/OpenWrt-nikki` locked by `NIKKI_COMMIT` | `https://github.com/nikkinikki-org/OpenWrt-nikki` | Depends on firewall4, `kmod-*`, and installs firewall defaults/nftables integration. | firmware-only |
| Mihomo | Nikki's `mihomo-meta` recipe | `https://github.com/MetaCubeX/mihomo` | The recipe uses `v1.19.30` and `PKG_MIRROR_HASH`. It depends on network kernel contracts and provides the `mihomo` alternative. | firmware-only |
| HomeProxy | `immortalwrt/homeproxy` locked by `HOMEPROXY_COMMIT` | `https://github.com/immortalwrt/homeproxy` | Depends on sing-box, firewall4, and `kmod-nft-tproxy`; only the explicit `sing-box`/LuCI/translation user-space group may update online, while firewall and kmods remain firmware-bound. | network-critical user-space group |
| OAF/AppFilter | `destan19/OpenAppFilter` locked by `OAF_COMMIT` | `https://github.com/destan19/OpenAppFilter` | This is the authoritative OAF source. `appfilter`, `luci-app-oaf`, and its translation form the reviewed online user-space group; `kmod-oaf` remains firmware-only and any solver attempt to change it rejects the transaction. | network-critical user-space group; kmod firmware-only |
| PBR | Inherited official OpenWrt/ImmortalWrt feed package with Taiyi patches | `https://github.com/mossdef-org/pbr` and `https://github.com/mossdef-org/luci-app-pbr` | Requires nft kernel modules; package lifecycle installs/removes netifd integration and reloads firewall. Taiyi CMCC helpers add a further firmware contract. | firmware-only |
| AdGuard Home | `small-package` daemon recipe; LuCI frontend replaced by locked `ZqinKing/luci-app-adguardhome` | `https://github.com/AdguardTeam/AdGuardHome` | The daemon, UI, and translation are a closed online group. The solver may install the daemon only as that reviewed group dependency; historic runtime binary download paths remain prohibited. | network-critical user-space group |
| Lucky | `gdy666/luci-app-lucky` locked by `LUCKY_COMMIT`, with Taiyi local release input | `https://github.com/gdy666/lucky` and `https://github.com/gdy666/luci-app-lucky` | Architecture-specific upstream binary and service/UI must move together. | firmware-only |
| EasyTier | Locked `small-package` recipe with Taiyi ER1 archive lock | `https://github.com/EasyTier/EasyTier` | Requires `kmod-tun`; Taiyi verifies the exact `v2.6.4` aarch64 ZIP SHA-256 before extraction and fails for an unlocked architecture. | firmware-only |
| CUPS | Locked `small-package` recipe with Taiyi SHA-256 source fix | `https://github.com/OpenPrinting/cups` | The reviewed online group is limited to `cups`, `libcups`, LuCI, and translation packages; any other library or platform solver change is rejected. Taiyi replaces the legacy MD5 checksum with the verified CUPS 2.3.3 source SHA-256. | network-critical user-space group |
| FRP client | Inherited official feed recipe plus Taiyi `004-taiyi-frpc-default-disabled.patch` | `https://github.com/fatedier/frp` | The recipe uses a versioned tarball and `PKG_HASH`. Upstream starts an unconfigured client at boot with respawn; Taiyi adds an explicit default-off UCI/LuCI gate. Public package upgrades could overwrite the init and UI contract, so FRPC remains installed but updates only with reviewed firmware. | firmware-only |
| Cloudflared | Inherited official feed recipe | `https://github.com/cloudflare/cloudflared` | Current recipe uses a versioned tarball and `PKG_HASH`; the daemon connects Cloudflare Tunnel to local origins. | network-critical |
| miniupnpd / LuCI UPnP | Inherited official feed recipe | `https://github.com/miniupnp/miniupnp` | The nftables variant installs firewall integration and interface hotplug logic. | firmware-only |
| Samba4 / LuCI Samba4 | Inherited official feed recipes | `https://www.samba.org/` release tarballs | Recipe locks a source hash but the server depends on Samba libraries, VFS modules, TLS/auth libraries, and optional filesystem/kernel contracts. | firmware-only |
| Vlmcsd | Locked `small-package` recipe | `https://github.com/Wind4/vlmcsd` | Recipe uses a versioned source archive and `PKG_HASH`; service/init/defaults expose a network listener. | network-critical |
| msd_lite | Locked `small-package` recipe | `https://github.com/rozhuk-im/msd_lite` | Recipe pins an upstream Git commit and `PKG_MIRROR_HASH`; it is an IPTV/multicast network daemon and is not an initial add-on candidate. | network-critical |

## Feed Metadata Warnings

The `3a9603d` source-preparation run reports three dependency warnings from
installed feed metadata:

- `jool` references `kmod-nf-conntrack6`.
- `openvswitch` references `kmod-nf-conntrack6`.
- `trojan-plus` references `boost-system`.

None of these packages is selected by the ER1 profile, and the final profile
gate passes. These warnings are not the Dockerman dependency-detail bug and are
not permission to add legacy packages or public target/kmod feeds. If any of
these packages becomes selected later, source preparation must fail until its
actual dependency closure is reviewed and available.

## Implementation References

- Build-time custom-source synchronization: `wrt_core/modules/custom_feed.sh`
- Locked custom-source commits: `wrt_core/source-locks.env`
- Runtime package classes: `wrt_core/patches/taiyi-apk-plugin-catalog`
- Runtime component groups: `wrt_core/patches/taiyi-apk-plugin-groups`
- Runtime transaction guard: `wrt_core/patches/taiyi-apk-plugin-policy`
- Candidate stage and signer boundary: `tools/taiyi-build/publish-plugin-feed.sh`

## Current Decision

The Taiyi custom feed remains disabled. No package in this document has been
added to `wrt_core/taiyi-plugin-feed/allowlist`.

The only plausible initial add-on-feed candidate remains
`luci-app-emmc-health`. Runtime architecture feeds may update the reviewed
component groups independently of that disabled custom feed, but each real
solver closure still must pass the closed-group policy and matching-firmware
acceptance checks before production use.
