# Taiyi Controlled Plugin Channel

## Purpose

Taiyi keeps the firmware platform immutable between reviewed `sysupgrade`
releases. Kernel, kmods, NSS/ECM, libc, BusyBox, procd, netifd, firewall,
dnsmasq, Dropbear, APK, and LuCI framework packages are never updated through
LuCI's package manager.

R8 replaces the previous blanket LuCI APK upgrade rejection with narrow,
solver-validated component-group updates. It is a maintenance control, not a
security boundary against an administrator with a root shell.

## Runtime Policy

The rootfs contains these inputs:

- `/usr/share/taiyi/apk-plugin-catalog`: reviewed package classifications.
- `/usr/share/taiyi/apk-plugin-groups`: closed user-space component groups.
- `/etc/taiyi/apk-baseline-packages`: first-boot capture of all firmware
  packages other than catalogued update candidates.
- `/usr/libexec/taiyi-apk-plugin-policy`: the LuCI transaction guard.

The package-manager backend permits only explicit `upgrade <package...>`
requests whose packages all belong to one reviewed group. It rejects broad
upgrades and all install, remove, repair, downgrade, reinstall, local APK, URL,
repository, and force-option paths. The policy expands the request to the
currently installed members of that group, then runs
`apk --simulate upgrade <installed-group-members...>`. Every parsed transaction
entry must be an installation or upgrade and must belong to the same closed
group. Unknown, duplicate, cross-group, baseline, firmware-only, and partially
parsed solver operations are rejected. This permits a required daemon or
user-space dependency to be installed only when it was explicitly classified
as a member of the selected group.

The policy has three catalog classes:

| Class | R8 behavior |
| --- | --- |
| `safe` | Reviewed component-group update is eligible after solver validation. |
| `network-critical` | Reviewed component-group update is eligible after solver validation; it is never scheduled or automatically retried. |
| `firmware-only` | Rejected online; update only in a reviewed firmware image. |

OAF/AppFilter uses the authoritative
`https://github.com/destan19/OpenAppFilter` source locked by `OAF_COMMIT`.
`appfilter`, `luci-app-oaf`, and its translation are one online user-space
group; `kmod-oaf` remains firmware-only and rejects the entire transaction if a
solver ever attempts to change it. HomeProxy, DDNS-Go, AdGuardHome, CUPS,
Docker, eMMC Health, and the previously eligible VLMCSD, AutoReboot, DiskMan,
FRPC, Cloudflared, and SQM user-space components have explicit groups.

PBR remains firmware-only because a generic upstream update could remove
Taiyi's CMCC helpers. Nikki/Mihomo, EasyTier, Lucky, UPnP, and Samba remain
firmware-only until their complete runtime closures receive equivalent review.
Disabled services do not receive a policy exemption. Kernel, all `kmod-*`,
NSS/ECM, libc/musl, base-files, procd, netifd, firewall4, APK, and keyring
packages remain independently denied even if a catalog or group is malformed.

## Add-on Feed Requirement

The five NJU architecture repositories deliberately do not contain every
Taiyi custom package. A future custom plugin update feed must be a separate,
minimal repository. It must not publish core, target, kernel, kmod, NSS, or
ECM packages.

Before enabling such a feed on a device, all of the following are required:

1. A stable HTTPS directory URL, not a guessed release-asset URL.
2. A dedicated offline plugin-feed signing key. Its public key is baked into a
   reviewed firmware; its private key is available only to the controlled
   publisher.
3. A signed APK index and immutable APK artifacts containing only catalogued,
   audited user-space packages and their reviewed dependency closure.
4. A build identity binding each feed publication to the exact Taiyi firmware
   release, APK version, policy version, key fingerprint, package hashes, and
   source revisions.
5. Offline signature verification and `apk --simulate` tests against the
   matching firmware before the URL is placed in `customfeeds.list`.
6. A separate authorization for the route configuration write and device
   acceptance.

Until those preconditions are met, R8 leaves administrator-owned
`customfeeds.list` unchanged and does not claim that custom plugin updates are
available. The package policy remains fail-closed if a requested catalog package
cannot be resolved by a trusted configured feed.

## Prepared Publisher Path

The repository now carries the non-secret, reviewed inputs under
`wrt_core/taiyi-plugin-feed/`:

- `channel.env` binds one stable HTTPS `packages.adb` URL to the SHA-256 of a
  dedicated public key. Both values are blank by default, which disables the
  channel in the built rootfs.
- `public-key.pem` is added only when the channel is enabled and must be a
  committed public key matching `channel.env`. The build installs it as
  `/etc/apk/keys/taiyi-plugin-feed.pem` and appends the exact baked URL to
  `customfeeds.list` during first boot without replacing administrator entries.
- `allowlist` is deliberately empty. It is the release-reviewed list of direct
  custom user-space APK artifacts to stage; every entry must be `safe` or
  `network-critical` in the runtime catalog. Firmware-only packages and all
  kernel/platform artifacts are rejected.

`tools/taiyi-build/publish-plugin-feed.sh stage` runs only after a clean,
provenance-verified firmware build and copies exactly one built APK per approved
allowlist entry. The candidate contains package hashes and
catalog/group/allowlist hashes with the matching firmware provenance. `sign`
requires a separate private key, proves it matches the public key baked into
that firmware, and creates the signed `packages.adb` with `apk mkndx`.

`.github/workflows/taiyi_addon_feed.yml` is deliberately split by
`workflow_dispatch` operation:

- `candidate` has no protected Environment and no signing or upload secret. It
  consumes the explicitly supplied successful `Build WRT` run's staged artifact,
  checks its repository, workflow name, commit, strict plan and full hashes,
  then registers an `unsigned-not-installable` add-on candidate.
- `publish` requires a successful candidate run ID from the same repository,
  protected revision and workflow. In `taiyi-addon-production` it revalidates
  the plan schema, complete artifact SHA-256 manifest, source provenance and
  public-key binding before a digest-pinned signer creates `packages.adb`.

`tools/taiyi-build/addon-feed-plan.py` emits and strictly validates the
candidate plan against the reviewed [schema](../../tools/taiyi-build/schemas/addon-feed-plan.schema.json).
The plan schema rejects duplicate JSON keys, unknown fields, duplicate package
identities, unsafe package directories and files absent from the plan. The
published job uploads a signed immutable snapshot candidate only; it does not
deploy to a URL. Before dispatching it, configure the protected environment
with the URL, public-key fingerprint, signer image reference and image ID, plus
a base64-encoded private-key secret. The signer image must provide
`/usr/bin/apk`, `openssl`, `bash`, and `python3`. Publishing that artifact to
the configured static HTTPS directory remains a separate, explicit authorized
operation.


## Operator Checks

After a network-critical component-group update, verify the relevant service and
management path before performing another update. At minimum, check LuCI access,
WAN route, DNS resolution, and the selected service. Do not run a second APK
operation to attempt an improvised rollback; package and service scripts are not
an atomic transaction. Use the prior reviewed firmware for platform rollback.
