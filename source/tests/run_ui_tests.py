"""Run isolated UIKit coverage on an installed iPhone and iPad Simulator."""
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path


def version_tuple(value):
    if isinstance(value, int):
        return value >> 16, (value >> 8) & 255, value & 255
    parts = [int(part) for part in str(value).split(".")[:3]]
    return tuple(parts + [0] * (3 - len(parts)))


def select_runtime(runtimes, sdk_version):
    # Images contain multiple Xcode generations. Do not pair the selected
    # toolchain with an unrelated newer runtime just because it sorts last.
    matches = [runtime for runtime in runtimes
               if runtime.get("isAvailable") and ".iOS-" in runtime["identifier"] and
               version_tuple(runtime["version"])[:2] == version_tuple(sdk_version)[:2]]
    if not matches:
        raise RuntimeError(f"No available iOS Simulator runtime matching SDK {sdk_version}")
    return max(matches, key=lambda runtime: version_tuple(runtime["version"]))


def run(*args, timeout=180):
    try:
        return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout).stdout.strip()
    except subprocess.CalledProcessError as error:
        print(error.stdout, flush=True)
        raise


def launch_and_collect(device, container, destination):
    destination.mkdir(parents=True, exist_ok=True)
    report_path = container / "Documents/ui-tests.json"
    with (destination / "launch.log").open("w") as log:
        process = subprocess.Popen(
            ["xcrun", "simctl", "launch", device, "local.wcrefine.swipetests"],
            stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            while not report_path.is_file():
                status = process.poll()
                if status is not None and status != 0:
                    raise RuntimeError(f"UIKit launcher failed ({status}); see {destination / 'launch.log'}")
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"No UIKit terminal report for {destination.name}")
                time.sleep(0.25)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            documents = container / "Documents"
            if documents.is_dir():
                shutil.copytree(documents, destination, dirs_exist_ok=True)
    return json.loads((destination / "ui-tests.json").read_text())


def main():
    out = Path(sys.argv[1]).resolve()
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    sdk_version = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
    runtime = select_runtime(runtimes, sdk_version)
    print(f"Simulator SDK {sdk_version}; runtime {runtime['identifier']}", flush=True)
    runtime_version = version_tuple(runtime["version"])
    types = json.loads(run("xcrun", "simctl", "list", "devicetypes", "-j"))["devicetypes"]
    reports = []
    for family, prefix in (("iphone", "iPhone"), ("ipad", "iPad")):
        device_type = next(t for t in reversed(types)
                           if t["name"].startswith(prefix) and
                           version_tuple(t.get("minRuntimeVersion", 0)) <= runtime_version <=
                           version_tuple(t.get("maxRuntimeVersion", 2**63)))
        device = run("xcrun", "simctl", "create", "WCR-Swipe-" + family,
                     device_type["identifier"], runtime["identifier"])
        try:
            print(f"Booting {family}: {device_type['name']} / {runtime['identifier']}", flush=True)
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
            run("xcrun", "simctl", "install", device, str(out / "SwipeTests.app"))
            container = Path(run("xcrun", "simctl", "get_app_container", device,
                                 "local.wcrefine.swipetests", "data"))
            destination = out / family
            # Gate on the app's atomic report, independently of simctl's lifetime.
            report = launch_and_collect(device, container, destination)
            print(json.dumps({"device": family, **report}), flush=True)
            if (report.get("passed") is not True or report.get("checks_run", 0) < 1400 or
                    report.get("activity_checks_run", 0) < 40):
                raise RuntimeError(report)
            reports.append({"device": family, "report": report})
        finally:
            run("xcrun", "simctl", "shutdown", device)
            run("xcrun", "simctl", "delete", device)
    (out / "ui-tests.json").write_text(json.dumps(
        {"passed": True, "devices": reports, "wechat_host_tested": False,
         "simulator_sdk": sdk_version, "simulator_runtime": runtime["identifier"]},
        indent=2) + "\n")


if __name__ == "__main__":
    main()
