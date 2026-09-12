#!/usr/bin/env python3
"""Create and verify the strict unsigned Taiyi add-on feed candidate plan."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.-]*$")
APK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.-]*\.apk$")


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def is_platform_package(name: str) -> bool:
    protected = (
        "apk", "base-files", "busybox", "kernel", "kmod-", "nss-", "libc", "musl", "libgcc", "libstdcpp",
        "libubox", "libubus", "libuci", "procd", "ubox", "ubus", "uci", "rpcd", "dropbear", "uhttpd",
        "luci-base", "luci-lib-", "luci-mod-", "firewall4", "fw4", "nftables", "netifd", "dnsmasq",
        "ppp", "odhcp", "ip-full", "ip-tiny", "iproute2", "tc",
    )
    return "nss" in name or "ecm" in name or any(name == prefix or name.startswith(prefix) for prefix in protected)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path):
    try:
        with path.open("r", encoding="ascii") as source:
            return json.load(source, object_pairs_hook=strict_object)
    except UnicodeDecodeError:
        fail(f"JSON is not ASCII: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON {path}: {error}")


def require_keys(value, expected, name: str) -> None:
    if not isinstance(value, dict) or set(value) != set(expected):
        fail(f"{name} keys do not match the schema")


def read_hash_file(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        parts = line.split()
        if len(parts) != 2 or not SHA256_RE.fullmatch(parts[0]) or not APK_RE.fullmatch(parts[1]):
            fail("PACKAGE_SHA256SUMS is malformed")
        if parts[1] in result:
            fail("PACKAGE_SHA256SUMS contains a duplicate APK")
        result[parts[1]] = parts[0]
    if not result:
        fail("PACKAGE_SHA256SUMS is empty")
    return result


def read_catalog(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2 or parts[0] not in {"safe", "network-critical", "firmware-only"} or not PACKAGE_RE.fullmatch(parts[1]):
            fail("catalog is malformed")
        if parts[1] in result:
            fail("catalog contains a duplicate package")
        result[parts[1]] = parts[0]
    return result


def provenance_values(path: Path) -> dict[str, str]:
    allowed = {
        "WrtReleaseCommit",
        "WrtReleaseTreeState",
        "WrtReleaseInputSha256",
        "SourceCommit",
        "SourceLocksSha256",
        "ConfigSha256",
        "PreparedSourceSha256",
        "TaiyiPluginFeedMode",
        "TaiyiPluginFeedCatalogSha256",
        "TaiyiPluginFeedAllowlistSha256",
        "TaiyiPluginPolicyVersionSha256",
    }
    values: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if ": " not in line:
            continue
        key, value = line.split(": ", 1)
        if key in allowed:
            if key in values:
                fail(f"firmware provenance duplicates {key}")
            values[key] = value
    missing = allowed - set(values)
    if missing:
        fail("firmware provenance is missing required fields")
    if values["WrtReleaseTreeState"] != "clean" or values["TaiyiPluginFeedMode"] != "enabled":
        fail("firmware provenance is not a clean enabled plugin-feed build")
    return values


def candidate_paths(candidate: Path) -> tuple[Path, Path, Path]:
    if not candidate.is_dir() or candidate.is_symlink():
        fail("candidate must be a regular directory")
    packages = candidate / "packages"
    plan = candidate / "ADDON_PLAN.json"
    validation = candidate / "VALIDATION.json"
    if not packages.is_dir() or packages.is_symlink():
        fail("candidate packages directory is missing or unsafe")
    return packages, plan, validation


def create(args) -> None:
    candidate = Path(args.candidate)
    packages_dir, plan_path, validation_path = candidate_paths(candidate)
    if plan_path.exists() or validation_path.exists():
        fail("candidate plan or validation already exists")
    package_names = (candidate / "PACKAGES").read_text(encoding="ascii").splitlines()
    if not package_names or len(set(package_names)) != len(package_names):
        fail("PACKAGES is empty or contains duplicates")
    package_hashes = read_hash_file(candidate / "PACKAGE_SHA256SUMS")
    catalog = read_catalog(Path(args.catalog))
    provenance = provenance_values(Path(args.firmware_provenance))
    actual_files = {entry.name for entry in packages_dir.iterdir() if entry.is_file() and not entry.is_symlink()}
    if actual_files != set(package_hashes):
        fail("candidate APK set differs from PACKAGE_SHA256SUMS")
    plan_packages = []
    for package_name in package_names:
        if not PACKAGE_RE.fullmatch(package_name):
            fail("PACKAGES contains an invalid package name")
        package_class = catalog.get(package_name)
        if package_class not in {"safe", "network-critical"}:
            fail("candidate plan includes a non-updatable package")
        if is_platform_package(package_name):
            fail("candidate plan includes a protected platform package")
        matches = [name for name in package_hashes if name.startswith(package_name + "-")]
        if len(matches) != 1:
            fail("each package name must map to exactly one APK")
        filename = matches[0]
        artifact = packages_dir / filename
        if sha256(artifact) != package_hashes[filename]:
            fail("candidate APK hash does not match PACKAGE_SHA256SUMS")
        plan_packages.append({
            "class": package_class,
            "filename": filename,
            "name": package_name,
            "sha256": package_hashes[filename],
            "size": artifact.stat().st_size,
        })
    if len(plan_packages) != len(package_hashes):
        fail("candidate package names do not cover every APK")
    plan = {
        "firmware": {
            "build_provenance_sha256": sha256(Path(args.firmware_provenance)),
            "config_sha256": provenance["ConfigSha256"],
            "prepared_source_sha256": provenance["PreparedSourceSha256"],
            "source_commit": provenance["SourceCommit"],
            "source_locks_sha256": provenance["SourceLocksSha256"],
            "wrt_release_commit": provenance["WrtReleaseCommit"],
            "wrt_release_input_sha256": provenance["WrtReleaseInputSha256"],
        },
        "packages": plan_packages,
        "policy": {
            "allowlist_sha256": sha256(Path(args.allowlist)),
            "catalog_sha256": sha256(Path(args.catalog)),
            "policy_version_sha256": sha256(Path(args.policy_version)),
        },
        "schema_version": 1,
        "status": "unsigned-not-installable",
        "target": {
            "architecture": args.architecture,
            "device": args.device,
            "package_format": "apk",
        },
    }
    plan_path.write_text(json.dumps(plan, sort_keys=True, separators=(",", ":")) + "\n", encoding="ascii")
    validation = {
        "plan_sha256": sha256(plan_path),
        "schema_version": 1,
        "status": "candidate-verified",
    }
    validation_path.write_text(json.dumps(validation, sort_keys=True, separators=(",", ":")) + "\n", encoding="ascii")


def verify(args) -> None:
    candidate = Path(args.candidate)
    packages_dir, plan_path, validation_path = candidate_paths(candidate)
    plan = load_json(plan_path)
    require_keys(plan, {"firmware", "packages", "policy", "schema_version", "status", "target"}, "plan")
    if plan["schema_version"] != 1 or plan["status"] != "unsigned-not-installable":
        fail("plan schema version or unsigned status is invalid")
    require_keys(plan["target"], {"architecture", "device", "package_format"}, "target")
    if plan["target"]["device"] != "jdcloud_er1_libwrt" or plan["target"]["architecture"] != "aarch64_cortex-a53" or plan["target"]["package_format"] != "apk":
        fail("plan target identity is not the Taiyi APK profile")
    require_keys(plan["firmware"], {"build_provenance_sha256", "config_sha256", "prepared_source_sha256", "source_commit", "source_locks_sha256", "wrt_release_commit", "wrt_release_input_sha256"}, "firmware")
    require_keys(plan["policy"], {"allowlist_sha256", "catalog_sha256", "policy_version_sha256"}, "policy")
    if not isinstance(plan["packages"], list) or not plan["packages"]:
        fail("plan packages must be a non-empty array")
    files: dict[str, str] = {}
    names: set[str] = set()
    for entry in plan["packages"]:
        require_keys(entry, {"class", "filename", "name", "sha256", "size"}, "package")
        if entry["class"] not in {"safe", "network-critical"} or not PACKAGE_RE.fullmatch(entry["name"]) or not APK_RE.fullmatch(entry["filename"]) or not SHA256_RE.fullmatch(entry["sha256"]) or not isinstance(entry["size"], int) or entry["size"] <= 0:
            fail("plan contains an invalid package entry")
        if is_platform_package(entry["name"]):
            fail("plan contains a protected platform package")
        if entry["filename"] in files or entry["name"] in names:
            fail("plan contains duplicate package identity")
        files[entry["filename"]] = entry["sha256"]
        names.add(entry["name"])
    actual = {entry.name for entry in packages_dir.iterdir() if entry.is_file() and not entry.is_symlink()}
    if actual != set(files) or len(list(packages_dir.iterdir())) != len(actual):
        fail("candidate package directory does not exactly match the plan")
    for filename, expected_hash in files.items():
        artifact = packages_dir / filename
        if sha256(artifact) != expected_hash:
            fail("candidate APK hash differs from plan")
    validation = load_json(validation_path)
    require_keys(validation, {"plan_sha256", "schema_version", "status"}, "validation")
    if validation["schema_version"] != 1 or validation["status"] != "candidate-verified" or validation["plan_sha256"] != sha256(plan_path):
        fail("candidate validation does not bind the plan")


parser = argparse.ArgumentParser()
subparsers = parser.add_subparsers(dest="command", required=True)
create_parser = subparsers.add_parser("create")
create_parser.add_argument("--candidate", required=True)
create_parser.add_argument("--catalog", required=True)
create_parser.add_argument("--allowlist", required=True)
create_parser.add_argument("--policy-version", required=True)
create_parser.add_argument("--firmware-provenance", required=True)
create_parser.add_argument("--device", required=True)
create_parser.add_argument("--architecture", required=True)
create_parser.set_defaults(func=create)
verify_parser = subparsers.add_parser("verify")
verify_parser.add_argument("--candidate", required=True)
verify_parser.set_defaults(func=verify)
args = parser.parse_args()
args.func(args)
