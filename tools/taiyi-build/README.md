# Taiyi Build Helpers

This directory contains the first, fail-closed layer of long-running build
support. The current commands validate inputs or print plans only. They do not
start builds or Docker, copy caches, delete paths, or export candidates.

## Boundaries

Only `dl` and identity-compatible `.ccache` caches are eligible for future
reuse. Signing keys, signed packages, package indexes, `bin`, `rootfs`,
`build_dir`, `staging_dir`, generated firmware, and candidate artifacts must
never be migrated into a reusable cache.

Do not copy generation-specific scripts, state, paths, hashes, keys, tokens, or
one-off control files into this directory. In particular, historical temporary
build scripts are design evidence, not source files for this tool.

`wrt_core/modules/build_state.sh` remains the build pipeline authority for
prepared-source and container identity. These helpers do not replace, source,
or weaken it. A future worker must validate its run specification and cache
identity first, then use `build_state.sh` through the existing build pipeline.

Detached workers, terminal locks, reapers, replaceable monitors, clock gates,
and an authorized candidate exporter are not implemented yet.

A separate, deliberately non-deploying APK add-on-feed publisher is available
at `publish-plugin-feed.sh`. It stages only an explicitly reviewed allowlist
from an already completed firmware build, then signs `packages.adb` only when a
separate private key is mounted in a protected signer environment. It never
uses, migrates, or writes firmware build keys. `addon-feed-plan.py` creates and
strictly validates the companion `ADDON_PLAN.json` against
`schemas/addon-feed-plan.schema.json`; candidate plans are explicitly
`unsigned-not-installable`.


## Commands

Start from `schemas/run-spec.example.env`, using only absolute POSIX paths and
non-secret identity values:

```bash
bash tools/taiyi-build/validate-run-spec.sh \
  --spec /absolute/path/to/run-spec.env
```

Verify one cache manifest and its identity file without reading cache content:

```bash
bash tools/taiyi-build/cache.sh verify \
  --manifest /absolute/path/to/cache-manifest.env \
  --identity /absolute/path/to/cache-identity.env
```

A cache manifest has `CACHE_SCOPE`, `CACHE_PATH`, and `IDENTITY_SHA256` fields.
An identity file has matching `CACHE_SCOPE` and `CACHE_IDENTITY` fields. A
`.ccache` identity must also contain `TOOLCHAIN_IDENTITY`; `BUILD_IDENTITY` is
optional. Files use literal `KEY=VALUE` lines, not shell syntax.

Print a candidate export plan:

```bash
bash tools/taiyi-build/export-candidate.sh plan \
  --source /absolute/path/to/source \
  --evidence /absolute/path/to/evidence \
  --destination /absolute/path/to/new-candidate \
  --policy /absolute/path/to/export-policy
```

`lib/control.sh` is sourceable. Token generation and validation are read-only.
Every helper that writes control state requires the caller to set
`ALLOW_CONTROL_WRITE=1`; writes fail by default. The atomic write helper also
requires an existing absolute `TAIYI_CONTROL_DIR` and accepts only a single safe
state-file name.

## Syntax Check

Run the Bash parser over every added script:

```bash
bash -n tools/taiyi-build/validate-run-spec.sh \
  tools/taiyi-build/cache.sh \
  tools/taiyi-build/export-candidate.sh \
  tools/taiyi-build/publish-plugin-feed.sh \
  tools/taiyi-build/lib/control.sh
python3 -m py_compile tools/taiyi-build/addon-feed-plan.py
python3 -m json.tool tools/taiyi-build/schemas/addon-feed-plan.schema.json >/dev/null
```
