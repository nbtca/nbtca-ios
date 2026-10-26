#!/usr/bin/env python3
"""Run academic protocol tests on macOS with two build jobs and no simulator."""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="nbtca-academic-tests-") as folder:
    root = Path(folder)
    sources = root / "Sources" / "nbtca"
    tests = root / "Tests" / "nbtcaTests"
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    for name in ("AcademicModels.swift", "CampusClient.swift", "CampusLoginNavigation.swift", "CampusSessionStorage.swift", "DormitoryModels.swift", "CampusWebSession.swift", "AcademicStore.swift", "DormitoryStore.swift", "TimetableSchedule.swift", "TimetableCalendarExport.swift", "TimetableCalendarDiff.swift", "TimetableCache.swift"):
        shutil.copy2(repo / "nbtca" / "Features" / "Academic" / name, sources / name)
    for name in ("Models.swift", "FormDraftStore.swift", "AppStore.swift", "APIClient.swift"):
        shutil.copy2(repo / "nbtca" / "Core" / name, sources / name)
    for name in ("NewsroomStore.swift", "ArticlePage.swift", "ArticleCache.swift", "RepairStore.swift", "PhotoProcessor.swift"):
        shutil.copy2(repo / "nbtca" / "Features" / name, sources / name)
    for name in ("AcademicTests.swift", "AcademicStoreTests.swift", "OptimizationTests.swift", "nbtcaTests.swift", "NewsroomTests.swift", "TimetableTests.swift", "TimetableCacheTests.swift", "ArticlePageTests.swift", "DormitoryReportTests.swift"):
        shutil.copy2(repo / "nbtcaTests" / name, tests / name)
    (root / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AcademicProtocolTests", platforms: [.macOS(.v14)], targets: [.target(name: "nbtca"), .testTarget(name: "nbtcaTests", dependencies: ["nbtca"])], swiftLanguageModes: [.v5])
''')
    result = subprocess.run(["swift", "test", "--jobs", "2", "--package-path", str(root)], check=False)
    raise SystemExit(result.returncode)
