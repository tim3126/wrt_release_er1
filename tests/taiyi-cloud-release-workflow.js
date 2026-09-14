'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const workflowPath = path.join(__dirname, '..', '.github', 'workflows', 'build_taiyi_push.yml');
const workflow = fs.readFileSync(workflowPath, 'utf8').replace(/\r\n/g, '\n');

function includes(text, message) {
  assert.ok(workflow.includes(text), message);
}

function excludes(text, message) {
  assert.ok(!workflow.includes(text), message);
}

function before(first, second, message) {
  const firstIndex = workflow.indexOf(first);
  const secondIndex = workflow.indexOf(second);
  assert.ok(firstIndex >= 0, `missing first marker: ${first}`);
  assert.ok(secondIndex >= 0, `missing second marker: ${second}`);
  assert.ok(firstIndex < secondIndex, message);
}

includes('  workflow_dispatch:\n', 'manual candidate trigger must remain enabled');
includes('  push:\n    branches:\n      - taiyi/r8-plugin-channel', 'push trigger must remain branch-scoped');
excludes('pull_request:', 'pull requests must not receive the automatic release path');
includes('permissions:\n  contents: read', 'workflow build permissions must remain read-only');
includes('  release:\n    name: Publish cloud pre-release\n    needs: build', 'release must depend on a successful build');
includes("    if: ${{ github.ref == 'refs/heads/taiyi/r8-plugin-channel' }}", 'release must be guarded to the Taiyi branch');
includes('      actions: read\n      contents: write', 'release job must declare only required write permissions');
assert.equal((workflow.match(/^      contents: write$/gm) || []).length, 1, 'contents:write must occur exactly once');
excludes('actions/checkout@', 'release caller must not checkout or execute repository code with a write token');
excludes('action-gh-release', 'automatic cloud release must not use an unverified third-party release action');
includes('actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093', 'artifact download action must remain pinned');
includes('find firmware -mindepth 1 -print0', 'artifact validation must include nested entries');
includes('validate_manifest_members firmware/SHA256SUMS "${aggregate_members[@]}"', 'aggregate manifest membership must be exact');
includes('validate_manifest_members firmware/sha256sums "${image_manifest_members[@]}"', 'image manifest membership must be exact');
includes("grep -qFx 'WrtReleaseTreeState: clean'", 'clean-tree provenance must be required');
includes("grep -qFx 'BuildContainerImageId: native'", 'cloud release must require native-runner provenance');
includes('(.profiles | keys == ["jdcloud_re-cs-07"])', 'only the Taiyi profile may be released');
includes('Expected 11 release assets', 'release asset count must be fixed');
includes('Release SHA256SUMS must contain exactly 10 members.', 'release manifest member count must be fixed');
includes('if release_json=$(gh release view "$RELEASE_TAG"', 'existing releases must be detected for rerun recovery');
includes('          ensure_release_tag() {', 'release tag validation helper must exist');
includes('-f ref="refs/tags/$RELEASE_TAG"', 'missing release tags must be created explicitly');
assert.equal((workflow.match(/^          ensure_release_tag$/gm) || []).length, 2, 'release tag must be verified before creation and publication');
includes('--json databaseId,isDraft,isPrerelease,tagName,targetCommitish,assets,url', 'release identity must include its database ID');
includes('latestRelease{databaseId}', 'published cloud releases must be checked against Latest');
includes('validate_not_latest "$published_json"', 'published release must be verified as non-Latest');
includes('validate_remote_assets "$release_json" existing-release-download', 'existing assets must be downloaded and verified');
includes('missing_assets=()', 'matching Drafts must support missing-asset recovery');
includes('gh release upload "$RELEASE_TAG" "${missing_assets[@]}"', 'reruns must upload only missing Draft assets');
includes('if [[ $(jq -r \'.isDraft\' <<<"$release_json") == true ]]; then', 'published releases must not be edited again');
includes('            --draft \\', 'new cloud releases must start as Drafts');
includes('            --prerelease \\', 'new cloud releases must be Pre-releases');
includes('            --latest=false', 'cloud releases must never be Latest');
includes('(cd release-download && sha256sum -c SHA256SUMS)', 'downloaded release manifest must be verified');
includes('diff -u "$local_hashes" "$downloaded_hashes"', 'all downloaded assets must match local hashes');
includes("tag_type != commit", 'release tag must resolve directly to a commit');
includes('public-verify/SHA256SUMS', 'published checksum must be fetched anonymously');
includes('cloud-r${GITHUB_RUN_NUMBER}-${short_commit}', 'release tag must bind run number and commit');

before('needs: build', 'contents: write', 'write permission must be scoped after the build dependency');
before('          ensure_release_tag\n          release_json=', 'gh release create "$RELEASE_TAG"', 'tag binding must be authoritative before Draft creation');
before('gh release create "$RELEASE_TAG"', 'validate_remote_assets "$release_json" release-download', 'new Draft creation must precede final download verification');
before('diff -u "$local_hashes" "$downloaded_hashes"', 'gh release edit "$RELEASE_TAG"', 'all hashes must match before publication');
before('          ensure_release_tag\n          if [[ $(jq -r \'.isDraft\'', 'gh release edit "$RELEASE_TAG"', 'tag binding must be rechecked before publication');
before('gh release edit "$RELEASE_TAG"', 'public-verify/SHA256SUMS', 'public verification must follow publication');

console.log('Taiyi cloud release workflow invariants passed.');
