"""Sequentially revert individual fixes, require targeted XCTest assertion failures, restore bytes.

No hardware/permission actions: these filters use real coordinator/service control
flow with injected resource boundaries. Run only with exclusive source ownership.
Logs stay in ignored .planning. A compilation failure is never a killed mutation.
"""
import argparse
import hashlib
import json
import os
import uuid
import tempfile
import shutil
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
APP = "Sources/ClavuneApp/AppCoordinator.swift"
SERVICE = "Sources/ClavuneCore/CaptureService.swift"
PREFIX = "AppCoordinatorIntegrationTests/"
BUILD_ROOT = Path(tempfile.mkdtemp(prefix="Clavune-regression-", dir="/tmp"))
EVIDENCE_ROOT = ROOT / ".build/regression-evidence" / BUILD_ROOT.name
CASES = [
    ("C01-coordinator-resamples-stop", APP,
     "let audio = try await capture.stop(request)",
     "let audio = try await capture.stop(CaptureStopRequest(session: id, cutoffHostTime: environment.nowHostTime()))",
     "testStopTimestampTraversesActualCoordinatorAndServiceBeforeDelayedDelivery"),
    ("C02-service-resamples-stop", SERVICE,
     "active.stop(cutoff: request.cutoffHostTime, completion: continuation)",
     "active.stop(cutoff: mach_absolute_time(), completion: continuation)",
     "testStopTimestampTraversesActualCoordinatorAndServiceBeforeDelayedDelivery"),
    ("C03-coordinator-ignores-raw-review", APP,
     "guard busy || session.phase == .review || !session.rawTranscript.isEmpty || !editedText.isEmpty else { return }",
     "guard busy || !editedText.isEmpty else { return }",
     "testCancelWithEmptyEditedTextClearsActualCoordinatorRawReview"),
    ("C04-service-constructs-before-gate", SERVICE,
     "do {\n                    try authorization.check(privacyAllowsCapture: self.privacyAllowsCapture)\n                    let run = try self.makeRun",
     "do {\n                    let run = try self.makeRun",
     "testCancelAfterServiceEnqueueInvalidatesActualStartupBeforeFactory"),
    ("C05-service-opens-without-revalidation", SERVICE,
     "try authorization.start(privacyAllowsCapture: self.privacyAllowsCapture,\n                                            open: { try run.start() }, close: { run.shutdown() })",
     "try run.start()",
     "testPrivacyChangeDuringActualServiceOpenClosesWithoutPumping"),
    ("C06-coordinator-acks-close-early", APP,
     "Task {\n            await capture.cancel(session: id)\n            microphone.acknowledgeClosed(id)",
     "Task {\n            microphone.acknowledgeClosed(id)\n            await capture.cancel(session: id)",
     "testActualCoordinatorRemainsMicClosingUntilServiceAcknowledges"),
    ("C07-quit-waits-on-permission", APP,
     "let pendingOperation = operationNeedsDrain ? task : nil",
     "let pendingOperation = task",
     "testQuitCompletesWithUnansweredPermissionAndRejectsLateGrantedReply"),
    ("C08-quit-reopens-admission", APP,
     "var busy: Bool { quitRequested || operationPending",
     "var busy: Bool { operationPending",
     "testQuitPermanentlyClosesStartAndImportAdmissionDuringDelayedUnload"),
    ("C09-token-after-session-admission", APP,
     "let admitted = try session.begin(preparing: environment.makeCancellation)\n            id = admitted.id; cancellation = admitted.resource",
     "id = try session.begin()\n            cancellation = try environment.makeCancellation()",
     "testCancellationAllocationFailureDoesNotAdmitActualCoordinator"),
    ("C10-cancelled-task-requests-permission", APP,
     "guard session.id == id, session.phase == .preparing, !quitRequested, !Task.isCancelled else {\n                    throw DictationError.cancelled\n                }\n                let granted: Bool",
     "let granted: Bool",
     "testCancelBeforeStartupTaskEntryNeverRequestsPermission"),
]


EXPECTED_FAILURES = {
    "C01-coordinator-resamples-stop": r'XCTAssertEqual failed:.*\[.*\].*\[1000\]',
    "C02-service-resamples-stop": r'XCTAssertEqual failed:.*\[.*\].*\[1000\]',
    "C03-coordinator-ignores-raw-review": r'XCTAssertEqual failed:.*review.*cancelled',
    "C04-service-constructs-before-gate": r'XCTAssertEqual failed:.*1.*0',
    "C05-service-opens-without-revalidation": r'XCTAssertEqual failed:.*1.*0',
    "C06-coordinator-acks-close-early": r'XCTAssertEqual failed:.*closed.*closing',
    "C07-quit-waits-on-permission": r'Asynchronous wait failed:.*permission answer',
    "C08-quit-reopens-admission": r'XCTAssert(?:True|False) failed',
    "C09-token-after-session-admission": r'XCTAssertEqual failed:.*preparing.*idle',
    "C10-cancelled-task-requests-permission": r'XCTAssertEqual failed:.*1.*0',
}


def run_filter(test_filter, log):
    build = BUILD_ROOT
    for name in ["ModuleCache", "cache", "config", "security", "scratch"]:
        (build / name).mkdir(parents=True, exist_ok=True)
    with log.open("wb") as output:
        # Isolate the regression experiment from a previously observed XCBuild database
        # I/O failure. Keep normal SwiftPM sandboxing; preserve every existing cache.
        environment = dict(os.environ)
        environment["CLANG_MODULE_CACHE_PATH"] = str(build / "ModuleCache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(build / "ModuleCache")
        environment["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
        command = ["swift", "test", "--build-system", "swiftbuild", "--jobs", "2",
                   *(["--filter", test_filter] if test_filter else []),
                   "--cache-path", str(build / "cache"), "--config-path", str(build / "config"),
                   "--security-path", str(build / "security"), "--scratch-path", str(build / "scratch")]
        inputs = {}
        for directory in ["Sources", "Tests/ClavuneCoreTests"]:
            for source in sorted((ROOT / directory).rglob("*")):
                if source.is_file() and source.suffix in {".swift", ".cpp", ".h"}:
                    inputs[str(source.relative_to(ROOT))] = hashlib.sha256(source.read_bytes()).hexdigest()
        details = {"command": command, "workingDirectory": str(ROOT),
                   "environment": {key: environment[key] for key in ["CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "MACOSX_DEPLOYMENT_TARGET"]},
                   "sourceSHA256": inputs}
        result = subprocess.run(command, cwd=ROOT, env=environment,
                                stdout=output, stderr=subprocess.STDOUT, timeout=180)
        details["exitCode"] = result.returncode
        products = []
        for product in (build / "scratch").rglob("*.xctest/Contents/MacOS/*"):
            if product.is_file():
                destination = EVIDENCE_ROOT / log.stem / product.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(product, destination)
                products.append({"builtPath": str(product), "evidencePath": str(destination.relative_to(ROOT)),
                                 "sha256": hashlib.sha256(product.read_bytes()).hexdigest()})
        details["products"] = products
        (log.with_suffix(".command.json")).write_text(json.dumps(details, indent=2) + "\n")
    return result.returncode, log.read_text(errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", help="Run selected case IDs; defaults to all.")
    args = parser.parse_args()
    cases = [case for case in CASES if not args.case or case[0] in args.case]
    if not cases or (args.case and set(args.case) - {case[0] for case in cases}):
        raise SystemExit("Unknown mutation case; no source changed.")
    output = ROOT / ".planning/regression-sensitivity"
    output.mkdir(parents=True, exist_ok=True)
    for name in ["ModuleCache", "cache", "config", "security", "scratch"]:
        (BUILD_ROOT / name).mkdir(parents=True, exist_ok=True)
    report = {"baseline": None, "cases": [], "productionRestored": False,
              "buildRoot": str(BUILD_ROOT), "swiftPMSandboxEnabled": True, "isolation": "owned temporary namespace outside project checkpoint hardlinks; sequential builds", "buildSystem": "swiftbuild"}
    code, text = run_filter("AppCoordinatorIntegrationTests", output / "baseline.log")
    report["baseline"] = {"exitCode": code}
    if code or re.search(r"^error:", text, re.MULTILINE) or not re.search(r"Executed \d+ tests?, with 0 failures", text):
        raise SystemExit("Production baseline did not pass; no mutation attempted.")
    for case_id, relative, before, after, test in cases:
        file = ROOT / relative
        original = file.read_bytes()
        source = original.decode()
        if source.count(before) != 1:
            raise SystemExit(case_id + ": expected one exact production site; no mutation applied.")
        record = {"id": case_id, "source": relative, "test": PREFIX + test,
                  "productionSourceSHA256": hashlib.sha256(original).hexdigest()}
        try:
            file.write_text(source.replace(before, after, 1))
            code, text = run_filter(record["test"], output / (case_id + ".log"))
            failures = re.search(r"Executed (\d+) tests?, with ([1-9]\d*) failures?", text)
            record.update({"exitCode": code, "assertionFailures": int(failures[2]) if failures else 0,
                           "expectedAssertionPattern": EXPECTED_FAILURES[case_id],
                           "expectedAssertionObserved": bool(re.search(EXPECTED_FAILURES[case_id], text)),
                           "killed": code != 0 and failures is not None and bool(re.search(EXPECTED_FAILURES[case_id], text)) and not re.search(r"^error:", text, re.MULTILINE)})
        finally:
            file.write_bytes(original)
            record["sourceRestored"] = file.read_bytes() == original
            report["cases"].append(record)
            (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(case_id + (": targeted assertion failure confirmed" if record["killed"] else ": NOT confirmed"), flush=True)
        if not record["killed"]:
            raise SystemExit("Mutation not killed by assertions; production bytes restored. Inspect private log.")
    code, text = run_filter(None, output / "restored-full-suite.log")
    report["restoredBaselineExitCode"] = code
    report["productionRestored"] = all(case["sourceRestored"] for case in report["cases"])
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    if code or re.search(r"^error:", text, re.MULTILINE) or not re.search(r"Executed \d+ tests?, with 0 failures", text):
        raise SystemExit("Restored baseline did not pass; inspect log. All mutated source bytes were restored.")
    print("All selected mutations killed; restored production integration suite passed.")


if __name__ == "__main__":
    main()
