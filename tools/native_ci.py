#!/usr/bin/env python3
"""Unsigned, synthetic-only native release-source verification.

All owned build/fixture directories live below this checkout. No capture action,
TCC mutation, signing account, clipboard write, or legacy installation is used.
The resulting report is CI verification, not Apple release evidence.
"""
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
REVISION = "f0bc616c2aed34f2a88888806ed056ec7bafba61"
LOCKS = [
    NATIVE / "Package.resolved",
    NATIVE / "RAPPShot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
]


def isolated_environment(work):
    env = os.environ.copy()
    env.pop("GIT_CONFIG_PARAMETERS", None)
    env.update({
        "TMPDIR": str(work / "compiler-work"),
        "SHOT_HOME": str(work / "shot-home"),
        "PYTHONDONTWRITEBYTECODE": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        # SwiftPM's own, known bare caches need explicit process-local access.
        "GIT_CONFIG_COUNT": "4",
        "GIT_CONFIG_KEY_0": "safe.bareRepository", "GIT_CONFIG_VALUE_0": "all",
        "GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
        "GIT_CONFIG_KEY_2": "credential.interactive", "GIT_CONFIG_VALUE_2": "false",
        "GIT_CONFIG_KEY_3": "core.fsmonitor", "GIT_CONFIG_VALUE_3": "false",
    })
    return env


def verify_pins():
    for path in LOCKS:
        pins = json.loads(path.read_text())["pins"]
        if len(pins) != 1 or pins[0]["identity"] != "rapp-tools" or \
                pins[0]["location"] != "https://github.com/kody-w/rapp-tools.git" or \
                pins[0]["state"]["revision"] != REVISION:
            raise RuntimeError("Unexpected dependency pin: " + str(path))


def verify_startup(data):
    expected = {
        "uiStartup": "passed", "captureState": "idle", "hasImage": False,
        "captureAttempts": 0, "permissionRequests": 0,
        "sourceEnumerationAttempts": 0, "clipboardWritten": False,
    }
    if any(data.get(key) != value for key, value in expected.items()) or data.get("visibleMainWindows", 0) < 1:
        raise RuntimeError("Native startup did not satisfy no-capture invariants")


def main():
    if platform.system() != "Darwin":
        raise RuntimeError("Native CI requires macOS")
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        raise RuntimeError("Unsupported runner architecture: " + arch)
    for tool in ("git", "swift", "swiftc", "xcodegen", "xcodebuild", "xcrun"):
        if not shutil.which(tool):
            raise RuntimeError("Missing developer tool: " + tool)
    work = ROOT / ".test-artifacts" / ("native-ci-" + str(uuid.uuid4()))
    for directory in ("compiler-work", "shot-home"):
        (work / directory).mkdir(parents=True, exist_ok=False)
    env = isolated_environment(work)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, env=env, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, env=env, text=True).strip())
    if os.environ.get("GITHUB_ACTIONS") == "true" and (head != os.environ.get("GITHUB_SHA") or dirty):
        raise RuntimeError("Actions checkout must be clean and equal GITHUB_SHA")
    report = {
        "schema": "rapp-shot-ci/1.0", "product": "RAPPShot", "source_commit": head,
        "source_dirty": dirty, "architecture": arch, "runner": os.environ.get("RUNNER_OS", "local"),
        "support_revision": REVISION, "signing_attempted": False,
        "apple_release_evidence": False, "checks": [], "status": "running",
    }
    report_path = work / "report.json"

    def save():
        report_path.write_text(json.dumps(report, indent=2) + "\n")

    def run(name, command, cwd=ROOT, timeout=300):
        path = work / (name + ".log")
        start = time.monotonic()
        print("RUN " + name, flush=True)
        with path.open("w") as output:
            result = subprocess.run([str(arg) for arg in command], cwd=cwd, env=env,
                                    stdin=subprocess.DEVNULL, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        report["checks"].append({"name": name, "command": [str(arg) for arg in command],
                                  "exit_code": result.returncode,
                                  "seconds": round(time.monotonic() - start, 2)})
        save()
        text = path.read_text(errors="replace")
        if result.returncode:
            print(text[-12_000:], file=sys.stderr)
            raise RuntimeError(name + " exited " + str(result.returncode))
        print("PASS " + name, flush=True)
        return text

    try:
        verify_pins()
        swift_options = ["--scratch-path", work / "swift-build", "--cache-path", work / "swift-cache"]
        tests = run("swift-tests", ["swift", "test", "-j", "2", *swift_options], cwd=NATIVE, timeout=600)
        counts = re.findall(r"Executed (\d+) tests, with (\d+) failures", tests)
        if not counts or int(counts[-1][0]) < 38 or counts[-1][1] != "0":
            raise RuntimeError("Native XCTest results missing, incomplete, or failing")
        report["native_tests"] = int(counts[-1][0])
        run("swift-release", ["swift", "build", "-c", "release", "-j", "2", *swift_options], cwd=NATIVE, timeout=600)
        binary = work / "swift-build/release/RAPPShot"
        run("adapters", [sys.executable, "tools/test_native_adapters.py"])
        run("runner-contract", [sys.executable, "tools/test_native_ci.py"])
        run("detector-parity", [sys.executable, "tools/native_parity.py", binary])
        run("legacy-fixtures", ["bash", "tools/dryrun.sh"], timeout=600)
        run("xcodegen", ["xcodegen", "generate", "--spec", "project.yml", "--quiet"], cwd=NATIVE)
        run("native-app-build", [
            "xcodebuild", "-workspace", "RAPPShot.xcodeproj/project.xcworkspace",
            "-scheme", "RAPPShot", "-configuration", "Release", "-destination", "generic/platform=macOS",
            "-derivedDataPath", work / "xcode", "-clonedSourcePackagesDirPath", work / "xcode/SourcePackages",
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "ARCHS=" + arch,
            "ONLY_ACTIVE_ARCH=NO", "-jobs", "2", "build",
        ], cwd=NATIVE, timeout=600)
        app = work / "xcode/Build/Products/Release/RAPPShot.app/Contents/MacOS/RAPPShot"
        diagnostics = json.loads(run("native-diagnostics", [app, "--diagnose"], timeout=30))
        if diagnostics.get("version") != "1.3.1" or diagnostics.get("captureAttempted") is not False \
                or diagnostics.get("captureOnLaunch") is not False:
            raise RuntimeError("Unsafe native diagnostic state")
        startup = json.loads(run("native-startup", [app, "--ui-smoke-test"], timeout=45))
        verify_startup(startup)
        report["startup"] = startup
        architectures = run("native-architecture", ["xcrun", "lipo", "-archs", app]).split()
        if architectures != [arch]:
            raise RuntimeError("Built architecture differs from the runner")
        verify_pins()
        report["status"] = "passed"
        save()
        print("PASS all native CI checks; report: " + str(report_path), flush=True)
        return 0
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        save()
        print("FAIL " + str(error) + "; report: " + str(report_path), file=sys.stderr)
        return 1
    finally:
        # Retain only synthetic logs/report for Actions; remove owned build/cache/fixture trees.
        for name in ("swift-build", "swift-cache", "xcode", "compiler-work", "shot-home"):
            directory = work / name
            if directory.exists():
                shutil.rmtree(directory)


if __name__ == "__main__":
    sys.exit(main())
