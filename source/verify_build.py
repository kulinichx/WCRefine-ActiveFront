"""Inspect a native build and bind its report to the exact source snapshot.

This parser validates Mach-O structure, not Apple's code signature or runtime.
The build script must separately run codesign --verify and the native tests.
"""

import argparse
import hashlib
import json
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INPUTS = (
    "ActiveFront.m", "WCRAFStateStore.h", "WCRAFStateStore.m",
    "tests/StateStoreTests.m", "test_core.sh", "build_ios.sh", "verify_build.py",
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_snapshot():
    return {name: sha256(ROOT / name) for name in INPUTS}


def inspect_macho(data):
    if len(data) < 32:
        raise ValueError("Truncated Mach-O header")
    magic, cpu, subtype, filetype, count, size, flags, reserved = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype & 0xFFFFFF, filetype) != (0xFEEDFACF, 0x100000C, 0, 6):
        raise ValueError("Expected a thin ARM64 iOS dynamic library")
    end = 32 + size
    if count == 0 or end > len(data) or count > size // 8:
        raise ValueError("Invalid load command bounds")
    offset = 32
    names = []
    dependencies = []
    versions = []
    signatures = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        command, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or length % 8 or offset + length > end:
            raise ValueError("Invalid load command length")
        if command in (0xD, 0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20):
            if length < 24:
                raise ValueError("Truncated dylib command")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if not 24 <= name_offset < length:
                raise ValueError("Invalid dylib name offset")
            raw = data[offset + name_offset:offset + length]
            terminator = raw.find(b"\0")
            if terminator < 0:
                raise ValueError("Unterminated dylib name")
            name = raw[:terminator].decode("utf-8", errors="strict")
            (names if command == 0xD else dependencies).append(name)
        elif command == 0x32:
            if length < 24:
                raise ValueError("Truncated build version")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", data, offset + 8)
            if length != 24 + 8 * tools:
                raise ValueError("Invalid build tools table")
            versions.append((platform, minimum))
        elif command == 0x1D:
            if length != 16:
                raise ValueError("Invalid code signature command")
            start, signature_size = struct.unpack_from("<2I", data, offset + 8)
            if start < end or signature_size < 12 or start + signature_size > len(data):
                raise ValueError("Invalid signature bounds")
            blob_magic, blob_length, blobs = struct.unpack_from(">3I", data, start)
            if blob_magic != 0xFADE0CC0 or blob_length > signature_size or blob_length < 12:
                raise ValueError("Invalid signature superblob")
            if blobs == 0 or 12 + 8 * blobs > blob_length:
                raise ValueError("Invalid signature index")
            signatures.append((start, signature_size))
        offset += length
    if offset != end:
        raise ValueError("Load command count/size mismatch")
    if names != ["@rpath/WCRefineGroup.dylib"]:
        raise ValueError("Unexpected or duplicate install name")
    if versions != [(2, 14 << 16)]:
        raise ValueError("Expected exactly one iOS 14.0 build version; not Simulator/macOS")
    if len(signatures) != 1:
        raise ValueError("Expected one signature blob")
    if not dependencies or any(
        not name.startswith(("/System/Library/Frameworks/", "/usr/lib/")) or
        ".." in name.split("/")
        for name in dependencies
    ):
        raise ValueError("Unexpected non-system dependency")
    return {
        "architecture": "arm64", "platform": "iOS", "minimum_os": "14.0",
        "install_name": names[0], "dependencies": dependencies,
        "signature_blob_present": True,
        "signature_cryptographically_verified_by_this_parser": False,
    }


def validate_inputs(tests, snapshot, current):
    if not isinstance(tests, dict) or not isinstance(snapshot, dict):
        raise ValueError("Invalid native report or input snapshot")
    if tests.get("passed") is not True or type(tests.get("failures")) is not int or tests["failures"] != 0:
        raise ValueError("Native tests did not pass")
    count = tests.get("tests_run")
    if type(count) is not int or count < 26:
        raise ValueError("Missing current native test coverage")
    if tests.get("ios_runtime_tested") is not False:
        raise ValueError("Native core report must not claim device testing")
    if snapshot != current:
        raise ValueError("Source changed since the native test build; rebuild required")


def write_json(path, value):
    encoded = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(encoded, encoding="utf-8")
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("snapshot")
    snapshot.add_argument("output", type=Path)
    validate = commands.add_parser("validate")
    validate.add_argument("--binary", required=True, type=Path)
    validate.add_argument("--tests", required=True, type=Path)
    validate.add_argument("--inputs", required=True, type=Path)
    validate.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "snapshot":
        write_json(args.output, source_snapshot())
        return
    if args.binary.name != "WCRefineGroup.dylib":
        raise ValueError("Final product must be named WCRefineGroup.dylib")
    tests = json.loads(args.tests.read_text(encoding="utf-8"))
    inputs = json.loads(args.inputs.read_text(encoding="utf-8"))
    current = source_snapshot()
    validate_inputs(tests, inputs, current)
    binary = inspect_macho(args.binary.read_bytes())
    report = {
        "product": "WCRefineGroup.dylib", "source_version": "1.9.9-source",
        "binary_sha256": sha256(args.binary), "binary_size": args.binary.stat().st_size,
        "native_tests": tests, "native_test_report_sha256": sha256(args.tests),
        "source_files_sha256": current, "macho": binary,
        "ios_runtime_tested": False, "root_hotfix_replaced": False,
        "scope": "Native core results and structured Mach-O checks; device acceptance still required",
    }
    write_json(args.output, report)
    print(f"Validated {args.binary.name}: {report['binary_sha256']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, struct.error) as error:
        raise SystemExit(f"Build validation failed: {error}")
