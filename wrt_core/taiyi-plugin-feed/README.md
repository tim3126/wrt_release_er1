# Taiyi Signed Add-on Feed Inputs

`channel.env` is non-secret, tracked release input. Both keys must be blank to
disable the channel, or both must be set to enable it:

```text
TAIYI_PLUGIN_FEED_INDEX_URL=https://packages.example.invalid/taiyi/25.12.2/aarch64_cortex-a53/packages.adb
TAIYI_PLUGIN_FEED_PUBLIC_KEY_SHA256=<sha256 of public-key.pem>
```

When enabled, `public-key.pem` is a regular, reviewed public EC key committed
beside this file. The build validates its SHA-256 before installing it at
`/etc/apk/keys/taiyi-plugin-feed.pem`, and the first-boot APK repository policy
adds the exact index URL to `customfeeds.list` without removing administrator
entries.

`allowlist` controls the artifacts staged for publication. It must contain only
one package name per line. Each package must already be classified as `safe` or
`network-critical` by `patches/taiyi-apk-plugin-catalog`; firmware-only,
kernel, kmod, NSS, ECM, and dependency packages are rejected. Leave it empty
until the exact package source and dependency closure are reviewed.

Never place a private signing key in this directory, the firmware build tree,
or Git. The protected publisher accepts an externally mounted key only long
enough to create the signed `packages.adb` index.
