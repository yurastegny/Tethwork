#!/usr/bin/env python3
"""Compile and run isolated Swift regression tests without changing app settings.

Examples:
    python3 Tests/run_tests.py
    python3 Tests/run_tests.py --sanitize-thread --repeat 3
    python3 Tests/run_tests.py --suite engine

Engine tests disable filesystem callbacks to check reconciliation deterministically.
Watcher tests exercise the real watcher concurrently; --sanitize-thread adds TSan
to every executable so a race is reported at its source instead of a random crash.
"""

import argparse
import os
import platform
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", "engine", "merge", "trash", "unpin", "favorites", "watcher", "coordinator", "startup"], default="all")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--sanitize-thread", action="store_true")
    parser.add_argument("--compile-timeout", type=float, default=120)
    parser.add_argument("--run-timeout", type=float, default=90)
    parser.add_argument("--temp-dir", type=Path, default=Path(tempfile.gettempdir()))
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if args.compile_timeout <= 0 or args.run_timeout <= 0:
        parser.error("timeouts must be positive")

    repo = Path(__file__).resolve().parent.parent
    common = [
        "Tethwork/Models/Models.swift",
        "Tethwork/Sync/DirectoryWatcher.swift",
        "Tethwork/Sync/TrashStore.swift",
        "Tethwork/Sync/SyncEngine.swift",
    ]
    suites = {
        "engine": common + ["Tests/SyncEngineTests.swift"],
        "merge": common + ["Tests/InitialMergeTests.swift"],
        "trash": common + ["Tests/TrashStoreTests.swift"],
        "unpin": common + ["Tests/SyncEngineUnpinTests.swift"],
        "favorites": common + ["Tethwork/Services/ConfigStore.swift", "Tests/FavoritesTests.swift"],
        "watcher": ["Tethwork/Sync/DirectoryWatcher.swift", "Tests/DirectoryWatcherTests.swift"],
        "coordinator": common + ["Tethwork/Services/ConnectionSyncCoordinator.swift", "Tests/ConnectionSyncCoordinatorTests.swift"],
        "startup": sorted(str(path.relative_to(repo)) for path in (repo / "Tethwork").rglob("*.swift")
                          if path.name != "TethworkApp.swift") + ["Tests/AppStartupTests.swift"],
    }
    if args.suite != "all":
        suites = {args.suite: suites[args.suite]}

    failures = []
    with tempfile.TemporaryDirectory(prefix="tethwork-tests-", dir=args.temp_dir) as temporary:
        work = Path(temporary)
        for name, sources in suites.items():
            executable = work / name
            command = ["swiftc", "-g", "-parse-as-library", "-swift-version", "5",
                       "-target", f"{platform.machine()}-apple-macosx14.0"]
            if args.sanitize_thread:
                command.append("-sanitize=thread")
            command += sources + ["-o", str(executable)]
            print(f"Building {name}", flush=True)
            try:
                result = subprocess.run(command, cwd=repo, timeout=args.compile_timeout)
            except subprocess.TimeoutExpired:
                failures.append(f"{name}: compilation timed out")
                continue
            if result.returncode:
                failures.append(f"{name}: compile failed")
                continue
            for iteration in range(1, args.repeat + 1):
                print(f"Running {name} ({iteration}/{args.repeat})", flush=True)
                env = os.environ.copy()
                if args.sanitize_thread:
                    env["TSAN_OPTIONS"] = "halt_on_error=1"
                try:
                    result = subprocess.run([str(executable), str(work)], env=env, timeout=args.run_timeout)
                    if result.returncode:
                        failures.append(f"{name} run {iteration}: exit {result.returncode}")
                except subprocess.TimeoutExpired:
                    failures.append(f"{name} run {iteration}: timed out")

    if failures:
        print("FAILED: " + "; ".join(failures), flush=True)
        return 1
    print("All selected suites passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
