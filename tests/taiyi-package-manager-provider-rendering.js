'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const patchPath = path.join(__dirname, '..', 'wrt_core', 'patches',
  '003-taiyi-package-manager-provider-rendering.patch');
const patch = fs.readFileSync(patchPath, 'utf8').split(/\r?\n/);
const helper = [];
let capture = false;

for (const line of patch) {
  if (line === '+// TAIYI_PROVIDER_SELECTION_BEGIN')
    capture = true;

  if (capture) {
    assert.ok(line.startsWith('+') || line.startsWith(' '),
      'provider helper contains an unexpected patch line');
    helper.push(line.slice(1));
  }

  if (line === '+// TAIYI_PROVIDER_SELECTION_END')
    break;
}

assert.ok(helper.length > 10, 'provider helper was not found in the production patch');

const context = {
  packages: {
    installed: { providers: {}, pkgs: {} },
    available: { providers: {}, pkgs: {} }
  },
  compareVersion(version, reference) {
    return String(version).localeCompare(String(reference), undefined, { numeric: true });
  }
};
vm.createContext(context);
vm.runInContext(helper.join('\n'), context, { filename: patchPath });

function add(sourceName, pkg) {
  const source = context.packages[sourceName];
  source.pkgs[pkg.name] = pkg;
  for (const provide of [pkg.name, ...(pkg.provides || [])]) {
    const name = provide.split('=')[0];
    source.providers[name] ||= [];
    source.providers[name].push(pkg);
  }
}

function reset() {
  for (const source of Object.values(context.packages)) {
    source.providers = {};
    source.pkgs = {};
  }
}

function select(name, operator = null, version = null) {
  return context.selectDependencyProvider(name, operator, version);
}

function assertAmbiguous(result, message) {
  assert.equal(result.pkg, null, message);
  assert.equal(result.ambiguous, true, message);
}

reset();
const nft = { name: 'iptables-nft', version: '1.8.10-r3', provides: ['iptables=1.8.10-r3'], depends: ['xtables-nft'] };
const legacy = { name: 'iptables-legacy', version: '1.8.10-r3', provides: ['iptables=1.8.10-r3'], depends: ['kmod-ipt-fullconenat', 'libip4tc2'] };
add('installed', nft);
add('available', legacy);
assert.strictEqual(select('iptables').pkg, nft, 'installed nft provider must win display expansion');

reset();
const installedV1 = { name: 'same-provider', version: '1', depends: ['installed-dependency'] };
const availableV2 = { name: 'same-provider', version: '2', depends: ['available-dependency'] };
add('installed', installedV1);
add('available', availableV2);
assert.strictEqual(select('same-provider', '>=', '1').pkg, installedV1,
  'a compatible installed provider must remain the advisory expansion source');
assert.strictEqual(select('same-provider', '>=', '2').pkg, availableV2,
  'an incompatible installed provider must not hide one compatible available provider');

reset();
const versionedVirtual = { name: 'virtual-new', version: '1', provides: ['virtual-api=5'], depends: [] };
add('available', versionedVirtual);
assert.strictEqual(select('virtual-api', '>=', '4').pkg, versionedVirtual,
  'versioned virtual provides must use the declared provide version');
assert.equal(select('virtual-api', '>', '5').pkg, null,
  'strict greater-than must reject an equal provided version');
assert.equal(select('virtual-api', '<', '5').pkg, null,
  'strict less-than must reject an equal provided version');
assert.strictEqual(select('virtual-api', '>=', '5').pkg, versionedVirtual,
  'inclusive greater-than must accept an equal provided version');
assert.strictEqual(select('virtual-api', '<=', '5').pkg, versionedVirtual,
  'inclusive less-than must accept an equal provided version');

reset();
add('available', { name: 'virtual-unversioned', version: '9', provides: ['virtual-api'], depends: [] });
assert.equal(select('virtual-api', '>=', '4').pkg, null,
  'an unversioned virtual provide must not satisfy a versioned dependency');
assert.equal(select('virtual-api', '>=', '4').ambiguous, false);

reset();
const installedA = { name: 'provider-a', version: '1', provides: ['choice'], depends: [] };
const installedB = { name: 'provider-b', version: '1', provides: ['choice'], depends: [] };
add('installed', installedA);
add('installed', installedB);
assertAmbiguous(select('choice'),
  'multiple compatible installed providers must remain ambiguous');
context.packages.installed.providers.choice.reverse();
assertAmbiguous(select('choice'),
  'installed provider order must not affect ambiguity');

reset();
const availableA = { name: 'provider-a', version: '1', provides: ['choice'], depends: [] };
const availableB = { name: 'provider-b', version: '1', provides: ['choice'], depends: [] };
add('available', availableA);
add('available', availableB);
assertAmbiguous(select('choice'),
  'multiple compatible available providers must remain a solver choice');
context.packages.available.providers.choice.reverse();
assertAmbiguous(select('choice'),
  'available provider order must not select an expansion source');

reset();
const duplicateA = { name: 'duplicate', version: '1', provides: ['choice=1'], depends: ['dep'] };
const duplicateB = { name: 'duplicate', version: '1', provides: ['choice=1'], depends: ['dep'] };
add('available', duplicateA);
add('available', duplicateB);
assert.strictEqual(select('choice', '=', '1').pkg, duplicateA,
  'equivalent provider records must be deduplicated before counting');

reset();
add('available', { name: 'different', version: '1', provides: ['choice=1'], depends: ['dep-a'] });
add('available', { name: 'different', version: '1', provides: ['choice=1'], depends: ['dep-b'] });
assertAmbiguous(select('choice', '=', '1'),
  'same-name records with different dependency metadata must remain ambiguous');

console.log('Taiyi package-manager provider selection tests passed.');
