"""Run isolated UIKit coverage on an installed iPhone and iPad Simulator."""
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path


def run(*args, timeout=180):
    try:
        return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout).stdout.strip()
    except subprocess.CalledProcessError as error:
        print(error.stdout, flush=True)
        raise


def main():
    out = Path(sys.argv[1]).resolve()
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    runtime = next(r for r in reversed(runtimes)
                   if r.get("isAvailable") and ".iOS-" in r["identifier"])
    def version_tuple(value):
        if isinstance(value, int):
            return value >> 16, (value >> 8) & 255, value & 255
        parts = [int(part) for part in str(value).split(".")[:3]]
        return tuple(parts + [0] * (3 - len(parts)))
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
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
            run("xcrun", "simctl", "install", device, str(out / "SwipeTests.app"))
            container = Path(run("xcrun", "simctl", "get_app_container", device,
                                 "local.wcrefine.swipetests", "data"))
            report_path = container / "Documents/ui-tests.json"
            # simctl's console attachment can outlive an exited simulator app.
            # The app writes its terminal report atomically before exiting.
            print(run("xcrun", "simctl", "launch", device,
                      "local.wcrefine.swipetests"), flush=True)
            deadline = time.monotonic() + 90
            while not report_path.is_file():
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"No UIKit terminal report for {family}")
                time.sleep(0.25)
            destination = out / family
            shutil.copytree(container / "Documents", destination)
            report = json.loads((destination / "ui-tests.json").read_text())
            print(json.dumps({"device": family, **report}), flush=True)
            if report.get("passed") is not True or report.get("checks_run", 0) < 900:
                raise RuntimeError(report)
            reports.append({"device": family, "report": report})
        finally:
            run("xcrun", "simctl", "shutdown", device)
            run("xcrun", "simctl", "delete", device)
    (out / "ui-tests.json").write_text(json.dumps(
        {"passed": True, "devices": reports, "wechat_host_tested": False},
        indent=2) + "\n")


if __name__ == "__main__":
    main()
