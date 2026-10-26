"""Bounded, fail-closed mutation evidence in an owned source copy.

No production source is edited. Every stage has a fresh build directory; build
success, selected payload, named test, and source-bound assertions are separate
gates. The split Swift build/direct XCTest route requires host validation.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
BASE = "227063b5f54c40ce01df6ae762e7efbea381a53e"
APP = "Sources/ClavuneApp/AppCoordinator.swift"
SERVICE = "Sources/ClavuneCore/CaptureService.swift"
TEST_SOURCE = "Tests/ClavuneCoreTests/AppCoordinatorIntegrationTests.swift"
PREFIX = "ClavuneCoreTests.AppCoordinatorIntegrationTests/"
MAX_LOG = 16 * 1024 * 1024
STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
launching_child = False
interrupted_signal = None


class EvidenceError(RuntimeError):
    pass


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    # Unique records are append-only. An interrupted write is not evidence.
    with Path(path).open("x") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())


def read_log(path):
    if path.stat().st_size > MAX_LOG:
        raise EvidenceError("Log exceeds bounded parser budget")
    return path.read_text(errors="replace")


CASE_LINE = re.compile(r"^Test Case '-\[(?P<class>[\w.]+) (?P<method>\w+)\]' (?P<state>started|passed|failed)(?:[ .(].*)?$")
FAIL_LINE = re.compile(r"^(?P<file>.+\.swift):(?P<line>\d+):(?:\d+:)? error: -\[(?P<class>[\w.]+) (?P<method>\w+)\] : (?P<message>.*)$")
SUMMARY = re.compile(r"^\s*Executed (\d+) tests?, with (\d+) failures?(?: \((\d+) unexpected\))? in ")
INFRA = re.compile(r"(?:disk I/O error|accessing build database|AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|Sanitizer CHECK failed|unexpected signal|Program crashed|Caught signal|Abort trap|Segmentation fault|Bus error|libc\+\+abi|terminate called|fatal error|runtime error:|Library not loaded:|Could not load test bundle|error: fatalError)", re.I)


def classify_xctest(text, status, selected, expected=(), mutant=False, liveness=False):
    """Parse only exact XCTest records. Swift Testing's zero-test footer is unrelated."""
    result = {"outcome": "invalid", "reason": "incomplete or ambiguous XCTest evidence", "tests": [], "failures": []}
    if status not in (0, 1) or INFRA.search(text) or not selected or len(set(selected)) != len(selected):
        return result
    active = None
    ended = []
    summaries = []
    suites = []
    pending_summary = None
    saw_suite = False
    for line in text.splitlines():
        suite = re.fullmatch(r"Test Suite '(.+)' (started|passed|failed) at .+", line)
        if suite:
            saw_suite = True
            if active is not None or pending_summary is not None:
                return result
            name, state = suite.groups()
            if state == "started":
                suites.append((name, len(ended), len(result["failures"])))
            else:
                if not suites or suites[-1][0] != name:
                    return result
                _, start_count, start_failures = suites.pop()
                pending_summary = (len(ended) - start_count, len(result["failures"]) - start_failures, 0)
                if (state == "passed") != (pending_summary[1] == 0):
                    return result
            continue
        summary = SUMMARY.match(line)
        if summary:
            observed = tuple(int(v or 0) for v in summary.groups())
            expected_summary = pending_summary if saw_suite else (len(ended), len(result["failures"]), 0)
            if active is not None or not ended or expected_summary is None or observed != expected_summary:
                return result
            summaries.append(observed)
            pending_summary = None
            continue
        if line.lstrip().startswith("Test Suite ") or "Executed " in line:
            return result
        match = CASE_LINE.fullmatch(line)
        if match:
            name = match["class"] + "/" + match["method"]
            if match["state"] == "started":
                if pending_summary is not None or active is not None or name in result["tests"]:
                    return result
                active = name
                result["tests"].append(name)
            else:
                if active != name:
                    return result
                ended.append((name, match["state"]))
                active = None
            continue
        failure = FAIL_LINE.fullmatch(line)
        if failure:
            name = failure["class"] + "/" + failure["method"]
            if name != active:
                return result
            result["failures"].append({"test": name, "file": failure["file"], "line": int(failure["line"]), "message": failure["message"]})
        elif line.lstrip().startswith("Test Case ") or "error:" in line or "Asynchronous wait failed:" in line or "XCTAssert" in line and "failed" in line:
            # Unknown failure formatting is not silently discarded.
            return result
    if (active is not None or suites or pending_summary is not None or sorted(result["tests"]) != sorted(selected)
            or len(ended) != len(selected) or not summaries
            or summaries[-1] != (len(selected), len(result["failures"]), 0)
            or any(count <= 0 or count > len(selected) or failures > len(result["failures"]) or unexpected
                   for count, failures, unexpected in summaries)):
        return result
    if status == 0 and all(state == "passed" for _, state in ended) and not result["failures"]:
        result.update(outcome="survived" if mutant else "passed", reason="exact selected tests passed")
        return result
    if not mutant or status == 0 or len(selected) != 1 or ended != [(selected[0], "failed")] or not expected:
        return result
    matched = []
    for failure in result["failures"]:
        matches = [i for i, site in enumerate(expected)
                   if failure["file"].endswith("/" + site["file"]) or failure["file"] == site["file"]]
        matches = [i for i in matches if failure["line"] == expected[i]["line"]
                   and re.fullmatch(expected[i]["pattern"], failure["message"])]
        if not matches:
            result["reason"] = "undeclared or unrelated assertion"
            return result
        matched.extend(matches)
    if not result["failures"] or 0 not in matched:
        result["reason"] = "intended assertion absent"
        return result
    if any("Asynchronous wait failed:" in f["message"] for f in result["failures"]) and not liveness:
        result["reason"] = "undeclared liveness assertion"
        return result
    result.update(outcome="killed", reason="declared bounded liveness assertion" if liveness else "source-bound intended assertion")
    return result


def classify_native(text, status, name, expected=None, mutant=False):
    lines = text.splitlines()
    result = {"outcome": "invalid", "reason": "incomplete native evidence", "tests": [], "failures": []}
    if INFRA.search(text) or [line for line in lines if line.startswith("NATIVE_TEST_COUNT ")] != ["NATIVE_TEST_COUNT 1"] or lines.count("NATIVE_TEST_START " + name) != 1:
        return result
    if [line for line in lines if line.startswith("NATIVE_TEST_START ")] != ["NATIVE_TEST_START " + name]:
        return result
    result["tests"] = [name]
    start = lines.index("NATIVE_TEST_START " + name)
    markers = [line for line in lines if line.lstrip().startswith("NATIVE_TEST")]
    expected_markers = ["NATIVE_TEST_COUNT 1", "NATIVE_TEST_START " + name]
    if status == 0:
        expected_markers += ["NATIVE_TEST_PASS " + name, "NATIVE_TEST_COMPLETE 1"]
    if markers != expected_markers or any("error:" in line for line in lines):
        return result
    checks = [line for line in lines if line.startswith("Contract check failed: ")]
    if status == 0 and not checks and [line for line in lines if line.startswith("NATIVE_TEST_PASS ")] == ["NATIVE_TEST_PASS " + name] and [line for line in lines if line.startswith("NATIVE_TEST_COMPLETE ")] == ["NATIVE_TEST_COMPLETE 1"]:
        if lines.index("NATIVE_TEST_COUNT 1") < start < lines.index("NATIVE_TEST_PASS " + name) < lines.index("NATIVE_TEST_COMPLETE 1"):
            result.update(outcome="survived" if mutant else "passed", reason="exact native test passed")
        return result
    if mutant and status == -signal.SIGABRT and expected and len(checks) == 1:
        line = checks[0]
        wanted = "Contract check failed: " + expected["expression"] + " (" + expected["file"] + ":" + str(expected["line"]) + ")"
        if line == wanted and lines.index("NATIVE_TEST_COUNT 1") < start < lines.index(line) and not any(l.startswith(("NATIVE_TEST_PASS ", "NATIVE_TEST_COMPLETE ")) for l in lines):
            result.update(outcome="killed", reason="source-bound CONTRACT_CHECK abort", failures=[line])
    return result


def stop_owned_group(process):
    if process is None:
        return
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        # An exited leader can still leave descendants in its own process group.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


def run_command(command, cwd, environment, log, timeout=240):
    global launching_child
    record = {"command": list(map(str, command)), "cwd": str(cwd), "exitCode": None,
              "timedOut": False, "logComplete": False}
    process = None
    try:
        with Path(log).open("xb") as output:
            launching_child = True
            try:
                process = subprocess.Popen(record["command"], cwd=cwd, env=environment,
                                           stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            finally:
                launching_child = False
            if interrupted_signal is not None:
                raise RunInterrupted("interrupted by signal " + str(interrupted_signal))
            try:
                record["exitCode"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                record["timedOut"] = True
                stop_owned_group(process)
                record["exitCode"] = process.returncode
            output.flush()
            os.fsync(output.fileno())
        record["logComplete"] = Path(log).stat().st_size <= MAX_LOG
        record["logSHA256"] = sha(log)
    except BaseException as error:
        stop_owned_group(process)
        record["error"] = type(error).__name__ + ": " + str(error)
        if not isinstance(error, OSError):
            write_json(Path(str(log) + ".command.json"), record)
            raise
    write_json(Path(str(log) + ".command.json"), record)
    return record


def command_ok(record):
    return record.get("exitCode") == 0 and record.get("logComplete") and not record.get("timedOut") and not record.get("error")


def build_then_execute(build, products, execute):
    """Small orchestration gate, also exercised with synthetic builders."""
    record = build()
    if not command_ok(record):
        raise EvidenceError("Build failed or evidence incomplete; no product executed")
    candidates = products()
    if len(candidates) != 1 or not candidates[0].is_file() or candidates[0].is_symlink():
        raise EvidenceError("Expected one unambiguous produced test payload")
    payload = candidates[0]
    digest = sha(payload)
    execution = execute(payload, digest)
    if sha(payload) != digest:
        raise EvidenceError("Executed payload changed during test")
    return record, payload, digest, execution
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
CASES.append(("C11-quit-skips-admitted-drain", APP,
              "            await pendingOperation?.value\n", "",
              "testQuitDrainsAlreadyAdmittedModelWorkBeforeUnload"))
NATIVE_CASES = [
    ("N01-temperature-default", "Sources/NativeBridge/WhisperBridge.cpp", "p.temperature_inc = 0.0f;", "", "params.temperature_inc == 0.0f"),
    ("N02-progress-default", "Sources/NativeBridge/WhisperBridge.cpp", "p.print_progress = false;", "", "!params.print_progress"),
    ("N03-timestamps-default", "Sources/NativeBridge/WhisperBridge.cpp", "p.print_timestamps = false;", "", "!params.print_timestamps"),
]
NATIVE_NAME = "BridgeContractTests.adversarial_decoder_defaults"
# First entry is the required intended assertion. Remaining entries explicitly
# declare collateral assertion sites for that same bounded behavioral mutation.
ASSERTIONS = {
    "C01": [("XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [1_000])", r"XCTAssertEqual failed:.*\[.*\].*\[1000\].*")],
    "C02": [("XCTAssertEqual(fixture.resources.counts.value.stopCutoffs, [1_000])", r"XCTAssertEqual failed:.*\[.*\].*\[1000\].*")],
    "C03": [("XCTAssertEqual(fixture.coordinator.session.phase, .cancelled)", r"XCTAssertEqual failed:.*review.*cancelled.*"),
            ("XCTAssertTrue(fixture.coordinator.session.rawTranscript.isEmpty)", r"XCTAssertTrue failed.*")],
    "C04": [("XCTAssertEqual(fixture.resources.counts.value.constructed, 0)", r"XCTAssertEqual failed:.*1.*0.*")],
    "C05": [("XCTAssertEqual(fixture.resources.counts.value.pumped, 0)", r"XCTAssertEqual failed:.*1.*0.*"),
            ("XCTAssertEqual(fixture.resources.counts.value.closed, 1)", r"XCTAssertEqual failed:.*0.*1.*"),
            ("XCTAssertEqual(fixture.coordinator.microphone.state, .closed)", r"XCTAssertEqual failed:.*recording.*closed.*"),
            ("XCTAssertEqual(fixture.coordinator.session.failure, .privacyBlocked)", r"XCTAssertEqual failed:.*")],
    "C06": [("XCTAssertEqual(fixture.coordinator.microphone.state, .closing)", r"XCTAssertEqual failed:.*closed.*closing.*"),
            ("XCTAssertEqual(AppIcon.symbol(for: fixture.coordinator.session.phase,", r"XCTAssertEqual failed:.*mic.fill.*")],
    "C07": [("await fulfillment(of: [terminated], timeout: 2)", r"Asynchronous wait failed:.*quit independent of permission answer.*")],
    "C08": [("XCTAssertFalse(fixture.coordinator.canStart)", r"XCTAssertFalse failed.*"),
            ("XCTAssertTrue(fixture.coordinator.busy)", r"XCTAssertTrue failed.*"),
            ("XCTAssertEqual(fixture.pickerCalls, 0)", r"XCTAssertEqual failed:.*1.*0.*")],
    "C09": [("XCTAssertEqual(fixture.coordinator.session.phase, .idle)", r"XCTAssertEqual failed:.*preparing.*idle.*"),
            ("XCTAssertFalse(fixture.coordinator.busy)", r"XCTAssertFalse failed.*")],
    "C10": [("XCTAssertEqual(fixture.permissionCalls, 0)", r"XCTAssertEqual failed:.*1.*0.*"),
            ("XCTAssertFalse(fixture.permission.pending)", r"XCTAssertFalse failed.*"),
            ("await fulfillment(of: [finished], timeout: 2)", r"Asynchronous wait failed:.*pre-entry cancellation drained.*")],
    "C11": [("XCTAssertEqual(fixture.quitTrace, [.willAwaitAdmittedOperation],", r"XCTAssertEqual failed:.*Quit reached inference unload before admitted model work settled.*"),
            ("XCTAssertEqual(fixture.inference.counts.value.unloads, 0)", r"XCTAssertEqual failed:.*"),
            ("XCTAssertEqual(fixture.terminationCalls, 0)", r"XCTAssertEqual failed:.*"),
            ("XCTAssertEqual(fixture.quitTrace,", r"XCTAssertEqual failed:.*")],
}
LIBRARIES = ["src/libwhisper.a", "ggml/src/libggml.a", "ggml/src/libggml-base.a",
             "ggml/src/libggml-cpu.a", "ggml/src/ggml-blas/libggml-blas.a",
             "ggml/src/ggml-metal/libggml-metal.a"]
ALLOWED_DIRTY = {APP, "Sources/ClavuneApp/CoordinatorEnvironment.swift", "Sources/ClavuneApp/HotkeyService.swift",
                 "Scripts/test-native-contracts.sh", "Scripts/test-regression-sensitivity.py",
                 "Tests/Python/test_regression_sensitivity.py", "README.md", "Docs/BUILD.md", "STATUS.md"}


def checked_file(root, relative):
    if root.is_symlink() or not root.is_dir():
        raise EvidenceError("Input root is not a regular directory")
    path = root / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts or not path.resolve().is_relative_to(root.resolve()):
        raise EvidenceError("Input escaped owned namespace: " + relative)
    if path.is_symlink() or not path.is_file():
        raise EvidenceError("Input is missing or not a regular file: " + relative)
    for parent in path.parents:
        if parent == root:
            break
        if parent.is_symlink():
            raise EvidenceError("Symlinked input parent: " + relative)
    return path


def fingerprints(root, names, inventory=True):
    watched = {"Sources", "Tests", "Scripts", "Config", "Patches", ".build/deps/whisper.cpp", ".build/backend"}
    expected = set(names)
    for relative in watched if inventory else []:
        if not any(name.startswith(relative + "/") for name in expected):
            continue
        actual = set(tree_files(root, relative))
        # Python import caches are not compiler inputs and are never copied.
        actual = {name for name in actual if "__pycache__" not in Path(name).parts and not name.endswith(".pyc")}
        declared = {name for name in expected if name.startswith(relative + "/")}
        if actual != declared:
            raise EvidenceError("Compile-input inventory changed: " + relative)
    return {name: {"sha256": sha(checked_file(root, name)), "mode": stat.S_IMODE((root / name).stat().st_mode)}
            for name in sorted(names)}


def copy_file(source_root, target_root, name):
    source = checked_file(source_root, name)
    target = target_root / name
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as incoming, target.open("xb") as outgoing:
        shutil.copyfileobj(incoming, outgoing)
    os.chmod(target, stat.S_IMODE(source.stat().st_mode))
    if sha(source) != sha(target) or source.stat().st_ino == target.stat().st_ino and source.stat().st_dev == target.stat().st_dev:
        raise EvidenceError("Source copy changed or shared an inode: " + name)


def tree_files(root, relative):
    directory = root / relative
    if directory.is_symlink() or not directory.is_dir():
        raise EvidenceError("Missing regular input directory: " + relative)
    names = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise EvidenceError("Unsafe dependency tree entry")
        if path.is_file():
            names.append(path.relative_to(root).as_posix())
    return names


def guard_replace(path, old, new, root=None):
    """Owned-copy only. Never replace an intervening edit, even during cleanup."""
    root = path.parent if root is None else root
    checked_file(root, path.relative_to(root).as_posix())
    if path.is_symlink() or path.read_bytes() != old:
        raise EvidenceError("Source restoration conflict; intervening bytes preserved")
    mode = stat.S_IMODE(path.stat().st_mode)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with temporary.open("xb") as stream:
        stream.write(new); stream.flush(); os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    checked_file(root, path.relative_to(root).as_posix())
    if path.read_bytes() != old:
        raise EvidenceError("Source changed before replacement; both versions preserved")
    os.replace(temporary, path)
    if path.read_bytes() != new:
        raise EvidenceError("Source replacement could not be verified")


def assertion_sites(source, case):
    case_id, _, _, _, method = case
    text = (source / TEST_SOURCE).read_text()
    start = text.index("func " + method + "(")
    next_method = re.search(r"\n\s*(?:@MainActor )?(?:private )?func ", text[start + 5:])
    end = start + 5 + next_method.start() if next_method else len(text)
    lines = text[:start].count("\n")
    body = text[start:end].splitlines()
    result = []
    for needle, pattern in ASSERTIONS[case_id[:3]]:
        found = [i + lines + 1 for i, line in enumerate(body) if needle in line]
        if not found:
            raise EvidenceError("Declared assertion site absent: " + case_id + ": " + needle)
        # Explicit repeated assertions (C08/C11) are independently recorded.
        for number in found:
            site = {"file": TEST_SOURCE, "line": number, "pattern": pattern}
            if site not in result:
                result.append(site)
    return result


def native_site(source, expression):
    relative = "Tests/Native/BridgeContractTests.cpp"
    found = [i for i, line in enumerate((source / relative).read_text().splitlines(), 1)
             if line.strip() == "CONTRACT_CHECK(" + expression + ");"]
    if len(found) != 1:
        raise EvidenceError("Native expected assertion absent or ambiguous")
    return {"expression": expression, "file": relative, "line": found[0]}


def all_xctests(source):
    # Bounded source convention: one top-level XCTest class per test-bearing
    # file, plus any unrelated top-level helpers, and a simple locally declared
    # superclass chain ending at XCTestCase. Unsupported inheritance fails
    # closed; this is not a Swift parser or a runtime test-discovery replacement.
    declarations = {}
    test_files = []
    for file in sorted((source / "Tests/ClavuneCoreTests").glob("*.swift")):
        text = file.read_text()
        classes = re.findall(
            r"^(?:(?:final|private|fileprivate|internal|public|open)\s+)*"
            r"class\s+(\w+)([^{}]*)\{", text, re.M)
        methods = re.findall(r"\bfunc (test\w+)\(", text)
        for name, header in classes:
            if name == "XCTestCase" or name in declarations:
                raise EvidenceError("Duplicate or ambiguous test class declaration: " + name)
            parent = re.fullmatch(r"\s*:\s*(\w+)\s*", header)
            declarations[name] = (parent[1] if parent else None, methods)
        if methods:
            test_files.append((file, classes, methods))

    def inherits_xctest(owner):
        current = owner
        seen = set()
        while current != "XCTestCase":
            if current in seen or current not in declarations:
                return False
            seen.add(current)
            parent, _ = declarations[current]
            if parent is None:
                return False
            current = parent
        return True

    files = []
    for file, classes, methods in test_files:
        owners = [name for name, _ in classes if inherits_xctest(name)]
        if len(owners) != 1:
            raise EvidenceError("Cannot unambiguously enumerate test source: " + file.name)
        helpers = [header for name, header in classes if name != owners[0]]
        # The selected-text insertion suite has one top-level fake boundary
        # conforming to this exact non-XCTest protocol. Keep the exception
        # narrow: unknown bases/protocols in a test-bearing file still fail.
        allowed_helper = re.compile(
            r"\s*:\s*(?:(?:\w+\s*,\s*)?@unchecked\s+Sendable|"
            r"ConditionalSelectedTextBoundary)\s*")
        if any(header.strip() and not allowed_helper.fullmatch(header)
               for header in helpers):
            raise EvidenceError("Unsupported top-level helper declaration in test source: " + file.name)
        files.append((owners[0], methods))

    # Inherited test methods need runtime enumeration, not an incomplete list
    # of only methods declared on the leaf (including leaves with no methods).
    for parent, _ in declarations.values():
        if parent in declarations and declarations[parent][1]:
            raise EvidenceError("Test-bearing superclass requires runtime discovery")

    names = []
    for owner, methods in files:
        current = owner
        seen = set()
        while current != "XCTestCase":
            if current in seen or current not in declarations:
                raise EvidenceError("Unresolved or cyclic XCTest inheritance: " + owner)
            seen.add(current)
            parent, inherited_methods = declarations[current]
            if parent is None or (current != owner and inherited_methods):
                raise EvidenceError("Unsupported or ambiguous XCTest inheritance: " + owner)
            current = parent
        names.extend("ClavuneCoreTests." + owner + "/" + method for method in methods)
    if not names or len(set(names)) != len(names):
        raise EvidenceError("Invalid declared full-suite test inventory")
    return names


def redact(value, replacements):
    if isinstance(value, dict):
        return {redact(k, replacements): redact(v, replacements) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, replacements) for v in value]
    if isinstance(value, str):
        for original, replacement in sorted(replacements.items(), key=lambda x: -len(x[0])):
            value = value.replace(original, replacement)
        # Do not embed the private-path sentinel rejected by prepare-review.py.
        value = re.sub(r"/(?:" + "Users" + r"|home)/[^/\s'\"]+", "<home>", value)
    return value


def git_output(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, stderr=subprocess.PIPE, timeout=30)


def prepare_snapshot(owned, evidence, expected_base):
    base = git_output("rev-parse", "HEAD").decode().strip()
    if base != expected_base:
        raise EvidenceError("Unexpected base revision; no mutation attempted")
    tracked = git_output("ls-files", "-z").decode().split("\0")
    new = git_output("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")
    changed = git_output("diff", "--name-only", "HEAD", "-z").decode().split("\0")
    for name in filter(None, changed + new):
        if name not in ALLOWED_DIRTY and not name.startswith(("Tests/ClavuneCoreTests/", "Tests/Native/", "Validation/")):
            raise EvidenceError("Unrelated working-tree edit requires review: " + name)
    names = sorted(set(filter(None, tracked + new)))
    original = fingerprints(ROOT, names)
    source = owned / "source"
    source.mkdir()
    for name in names:
        copy_file(ROOT, source, name)
    if fingerprints(ROOT, names) != original or fingerprints(source, names) != original:
        raise EvidenceError("Working-tree input changed during snapshot; original left untouched")
    # Do not share mutable header/archive inodes with the primary checkout.
    dependencies = tree_files(ROOT, ".build/deps/whisper.cpp")
    lock = json.loads((source / "Dependencies.lock.json").read_text())["whisperCpp"]
    archive_candidates = [".build/deps/whisper.cpp.tar.gz", ".planning/whisper.cpp-" + lock["commit"][:8] + ".tar.gz"]
    archive = next((name for name in archive_candidates if (ROOT / name).is_file()), None)
    if archive is None or sha(checked_file(ROOT, archive)) != lock["sourceArchiveSHA256"]:
        raise EvidenceError("Existing verified dependency archive unavailable; no download attempted")
    backend = [".build/backend/" + name for name in LIBRARIES + ["ClavuneBackendFingerprint.h", "clavune-backend-fingerprint.json"]]
    external_names = dependencies + backend + [archive]
    external_before = fingerprints(ROOT, external_names, inventory=False)
    for name in external_names:
        copy_file(ROOT, source, name)
    if fingerprints(ROOT, external_names, inventory=False) != external_before:
        raise EvidenceError("Dependency/backend inputs changed during copy")
    archive_copy = source / archive
    verification = run_command([sys.executable, "Scripts/fetch-backend.py", "--offline", "--archive", str(archive_copy)],
                               source, os.environ.copy(), evidence / "offline-source-verification.log")
    if not command_ok(verification):
        raise EvidenceError("Owned offline dependency reconstruction failed")
    fingerprint = json.loads((source / ".build/backend/clavune-backend-fingerprint.json").read_text())
    accepted_bytes = git_output("show", base + ":Validation/checkpoint.json")
    accepted = json.loads(accepted_bytes)["backend"]["archiveFingerprint"]
    if fingerprint != accepted:
        raise EvidenceError("Backend archives are not the exact accepted base-checkpoint inputs")
    archive_hashes = {name: sha(source / ".build/backend" / name) for name in LIBRARIES}
    digest = hashlib.sha256()
    for name in LIBRARIES:
        digest.update((name + "\0" + archive_hashes[name] + "\n").encode())
    lock_data = (source / "Dependencies.lock.json").read_bytes()
    digest.update(lock_data)
    value = digest.hexdigest()
    if (fingerprint.get("archiveSHA256") != archive_hashes or fingerprint.get("fingerprint") != value
            or fingerprint.get("dependencyLockSHA256") != hashlib.sha256(lock_data).hexdigest()
            or ('#define CLAVUNE_BACKEND_FINGERPRINT "' + value + '"') not in (source / ".build/backend/ClavuneBackendFingerprint.h").read_text()):
        raise EvidenceError("Copied backend fingerprint disagrees with exact archive/lock inputs")
    # Consume only the immutable, independently verified copy from this point.
    inputs = names + tree_files(source, ".build/deps/whisper.cpp") + backend
    for name in dependencies + backend:
        path = source / name
        os.chmod(path, stat.S_IMODE(path.stat().st_mode) & ~0o222)
    initial = fingerprints(source, inputs)
    write_json(evidence / "inputs.json", {"baseRevision": base, "original": original,
               "copiedCompileInputs": initial, "backendFingerprint": value, "acceptedCheckpointSHA256": hashlib.sha256(accepted_bytes).hexdigest(),
               "originalExternalInputs": external_before, "offlineVerification": verification})
    return source, names, original, inputs


def checked_tool(command, cwd, environment, evidence, label):
    record = run_command(command, cwd, environment, evidence / (label + ".log"))
    if not command_ok(record):
        raise EvidenceError("Toolchain discovery failed: " + label)
    return read_log(evidence / (label + ".log")).strip()


def toolchain(source, evidence):
    env = dict(os.environ)
    swift = shutil.which("swift")
    xcrun = shutil.which("xcrun")
    if not swift or not xcrun or sys.platform != "darwin":
        raise EvidenceError("Mac Swift/XCTest toolchain required; synthetic Python fixtures are portable")
    version = checked_tool([swift, "--version"], source, env, evidence, "swift-version")
    if not re.search(r"Swift version 6\.4(?:\D|$)", version):
        raise EvidenceError("Expected reviewed installed Swift 6.4 route")
    xctest = checked_tool([xcrun, "--sdk", "macosx", "--find", "xctest"], source, env, evidence, "xctest-path")
    sdk = checked_tool([xcrun, "--sdk", "macosx", "--show-sdk-path"], source, env, evidence, "sdk-path")
    if any(key.startswith("SWIFTPM_PLATFORM_PATH_") or key.startswith("SWIFT_TESTING_") for key in env):
        raise EvidenceError("Unreviewed SwiftPM platform/testing override present")
    platform = checked_tool([xcrun, "--sdk", "macosx", "--show-sdk-platform-path"], source, env, evidence, "platform-path")
    result = {"swift": str(Path(swift).resolve()), "swiftVersion": version, "xctest": xctest,
              "sdk": sdk, "platformPath": platform, "architecture": os.uname().machine, "platform": sys.platform}
    if not Path(xctest).is_file() or not Path(sdk).is_dir() or not Path(platform).is_dir() or result["architecture"] != "arm64":
        raise EvidenceError("Toolchain paths or architecture do not match reviewed route")
    write_json(evidence / "toolchain.json", result)
    return result



def unique_json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("Ambiguous duplicate key in generated build record")
        result[key] = value
    return result


def read_build_bytes(path, artifacts=None):
    if path.stat().st_size > MAX_LOG:
        raise EvidenceError("Generated build record exceeds bounded parser budget")
    with path.open("rb") as stream:
        data = stream.read(MAX_LOG + 1)
    if len(data) > MAX_LOG:
        raise EvidenceError("Generated build record exceeds bounded parser budget")
    if artifacts is not None:
        digest = hashlib.sha256(data).hexdigest()
        key = str(path)
        if key in artifacts and artifacts[key] != digest:
            raise EvidenceError("Generated build record changed between reads")
        artifacts[key] = digest
    return data


def read_build_json(path, artifacts=None):
    return json.loads(read_build_bytes(path, artifacts), object_pairs_hook=unique_json_pairs)


def read_build_text(path, artifacts=None):
    try:
        return read_build_bytes(path, artifacts).decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise EvidenceError("Invalid generated build-record encoding") from error


def owned_build_file(scratch, spelling):
    """Generated records must identify a regular artifact in this exact stage."""
    if not isinstance(spelling, str) or not spelling:
        raise EvidenceError("Build record artifact path is not a string")
    path = Path(spelling)
    if not path.is_absolute():
        raise EvidenceError("Build record artifact path is not absolute")
    if ".." in path.parts or path != path.resolve():
        raise EvidenceError("Build record artifact has a noncanonical or symlinked path")
    if not path.is_relative_to(scratch):
        raise EvidenceError("Build record points outside this fresh stage")
    return checked_file(scratch, path.relative_to(scratch).as_posix())


def split_make_words(text):
    """Small Make dependency lexer: whitespace and backslash escapes, no expansion."""
    words, word = [], []
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\":
            index += 1
            if index == len(text):
                raise EvidenceError("Incomplete Make dependency escape")
            char = text[index]
            if char == "\n":
                index += 1
                continue
            word.append(char)
        elif char.isspace():
            if word:
                words.append("".join(word)); word = []
        elif char in "$#":
            raise EvidenceError("Unsupported Make dependency expansion/comment")
        else:
            word.append(char)
        index += 1
    if word:
        words.append("".join(word))
    return words


def dependency_rules(text):
    if len(text.encode()) > MAX_LOG:
        raise EvidenceError("Dependency record exceeds bounded parser budget")
    rules = []
    for line in text.replace("\\\n", "").splitlines():
        if not line.strip():
            continue
        separators = [match.start() for match in re.finditer(r"(?<!\\):", line)]
        if len(separators) != 1:
            raise EvidenceError("Unsupported or ambiguous dependency rule")
        index = separators[0]
        targets = split_make_words(line[:index])
        dependencies = split_make_words(line[index + 1:])
        if not targets or not dependencies:
            raise EvidenceError("Incomplete dependency rule")
        rules.append((targets, dependencies))
    if not rules:
        raise EvidenceError("Empty compiler dependency record")
    return rules



def response_paths(path, scratch, artifacts=None):
    """Swiftbuild uses whitespace/quoted response files, not one path per line."""
    text = read_build_text(path, artifacts)
    try:
        words = shlex.split(text, comments=False, posix=True)
    except ValueError as error:
        raise EvidenceError("Malformed linker response/file-list quoting") from error
    if not words or len(words) > 4096 or len(set(words)) != len(words):
        raise EvidenceError("Empty, oversized or duplicate linker input list")
    if any(word.startswith(("-", "@")) for word in words):
        raise EvidenceError("Options or nested response files are not supported in input lists")
    return [owned_build_file(scratch, word) for word in words]


def swift_source_candidates(source, scratch, required, artifacts=None):
    maps = sorted(scratch.rglob("*-OutputFileMap.json"))
    if not maps or len(maps) > 256:
        raise EvidenceError("Missing or excessive Swift output maps")
    candidates = {name: [] for name in required}
    for path in maps:
        path = owned_build_file(scratch, str(path))
        mapping = read_build_json(path, artifacts)
        if not isinstance(mapping, dict):
            raise EvidenceError("Swift output map is not an object")
        for relative in required:
            absolute = str(checked_file(source, relative))
            if absolute not in mapping:
                continue
            outputs = mapping[absolute]
            if not isinstance(outputs, dict) or not {"object", "dependencies"} <= outputs.keys():
                raise EvidenceError("Unsupported Swift compilation output-map entry")
            obj = owned_build_file(scratch, outputs["object"])
            dependency = owned_build_file(scratch, outputs["dependencies"])
            if obj.suffix != ".o" or obj.stat().st_size == 0 or dependency.suffix != ".d":
                raise EvidenceError("Expected produced Swift object/dependency artifact")
            candidates[relative].append({"outputMap": path, "object": obj, "dependencies": dependency})
    if any(not found for found in candidates.values()):
        raise EvidenceError("An exact absolute source key is absent from Swift output maps")
    return candidates


def link_argument_roles(args):
    """Distinguish driver inputs from option values in the observed argv grammar."""
    if not args:
        raise EvidenceError("Empty linker driver command")
    roles = ["compiler"]
    value_options = {"-target", "-sdk", "-isysroot", "-Fsystem", "-iframework",
                     "-framework", "-filelist", "-o", "-Xlinker", "-Xclang-linker"}
    flags = {"-r", "-O0", "-nostdlib", "-fobjc-link-runtime",
             "-link-objc-runtime", "-no-stdlib-rpath", "-lc++", "-lwhisper",
             "-lggml", "-lggml-cpu", "-lggml-blas", "-lggml-metal",
             "-lggml-base", "-lXCTestSwiftSupport"}
    index = 1
    while index < len(args):
        argument = args[index]
        if argument in value_options:
            if index + 1 == len(args):
                raise EvidenceError("Missing linker driver option operand")
            roles.extend(["option", "value:" + argument])
            index += 2
            continue
        if argument in flags or argument.startswith(("-L/", "-F/")):
            roles.append("option")
        elif argument.startswith("@"):
            roles.append("response")
        else:
            # Do not guess the arity of an unobserved driver option: its next
            # token could be an operand that merely resembles a response input.
            raise EvidenceError("Unsupported linker driver argument role")
        index += 1
    return roles


def swiftbuild_binding(source, scratch, payload, required=(APP, SERVICE, TEST_SOURCE)):
    """Bind exact source objects through observed Swiftbuild Ld records to payload.

    Supports the installed non-WMO output-map + .d + XCBuildData schema recorded
    by WO-0004's read-only host handoff. Basename progress lines confer no trust.
    """
    artifacts = {}
    candidates = swift_source_candidates(source, scratch, required, artifacts)
    # This is the inventory actually parsed, not a later scan that could adopt
    # a newly introduced, unexamined candidate.
    map_inventory = sorted(artifacts)
    manifests = [path for path in scratch.rglob("manifest.json") if "XCBuildData" in path.parts]
    if len(manifests) != 1:
        raise EvidenceError("Expected one fresh XCBuildData manifest")
    manifest_path = owned_build_file(scratch, str(manifests[0]))
    manifest = read_build_json(manifest_path, artifacts)
    commands = manifest.get("commands") if isinstance(manifest, dict) else None
    if not isinstance(commands, dict) or len(commands) > 100000:
        raise EvidenceError("Unsupported XCBuildData commands schema")
    by_output = {}
    for identifier, command in commands.items():
        if not isinstance(command, dict) or not str(command.get("description", "")).startswith("Ld "):
            continue
        if (not isinstance(identifier, str) or command.get("tool") != "shell"
                or not isinstance(command.get("working-directory"), str)
                or any(not isinstance(command.get(field), list)
                       or not all(isinstance(value, str) for value in command[field])
                       for field in ["args", "inputs", "outputs"])):
            raise EvidenceError("Unsupported XCBuildData Ld record schema")
        for output in command["outputs"]:
            # Swiftbuild also emits virtual <Linked Binary ...>/<TRIGGER: ...>
            # nodes and ancillary outputs. Only exact argv-selected files link.
            if output.startswith("/"):
                by_output.setdefault(output, []).append((identifier, command))
    discovery = {"outputMaps": map_inventory, "manifests": [str(manifest_path)]}
    links, reachable, visiting = {}, set(), set()

    def visit(output, final=False, depth=0):
        output = owned_build_file(scratch, str(output))
        key = str(output)
        if depth > 16 or len(reachable) > 4096 or key in visiting:
            raise EvidenceError("Cyclic or excessive link-input graph")
        reachable.add(key)
        digest = sha(output)
        if key in artifacts and artifacts[key] != digest:
            raise EvidenceError("Link graph object changed between visits")
        artifacts[key] = digest
        if key in links:
            return
        matches = by_output.get(key, [])
        if not matches:
            if final:
                raise EvidenceError("Selected XCTest payload has no exact Ld output record")
            return
        if len(matches) != 1:
            raise EvidenceError("Ambiguous link-output records")
        identifier, command = matches[0]
        args = command["args"]
        roles = link_argument_roles(args)
        if (command["description"] != "Ld " + key + " normal"
                or not identifier.endswith(":Ld " + key + " normal")
                or command["working-directory"] != str(source)
                or args.count("-o") != 1 or args.index("-o") + 1 >= len(args)
                or roles[args.index("-o")] != "option"
                or args[args.index("-o") + 1] != key):
            raise EvidenceError("Link command does not produce its exact declared output")
        if (any(argument.startswith("-Wl") or argument.startswith("-Xlinker=") for argument in args)
                or any(argument.startswith("-o") and argument not in {"-o", "-object_path_lto", "-objc_abi_version"} for argument in args)):
            raise EvidenceError("Unsupported forwarded or joined linker-output option")
        flattened = []
        index = 0
        while index < len(args):
            if args[index] == "-Xlinker":
                index += 1
                if index == len(args):
                    raise EvidenceError("Incomplete linker argument forwarding")
            flattened.append(args[index])
            index += 1
        for index, argument in enumerate(flattened):
            if argument.endswith((".o", ".a")) and not argument.startswith(("-", "@")):
                if (index == 0 or flattened[index - 1] not in {"-o", "-object_path_lto"}
                        or argument not in command["outputs"] or argument in command["inputs"]):
                    raise EvidenceError("Unparsed direct object/archive input bypasses selected file list")
        compiler = Path(args[0]) if args else Path("")
        if not compiler.is_absolute():
            raise EvidenceError("Link compiler path is not absolute")
        if final:
            if compiler.name != "swiftc" or not any(args[i:i + 2] == ["-Xlinker", "-bundle"] for i in range(len(args) - 1)):
                raise EvidenceError("Expected observed swiftc XCTest bundle link")
            lists = [argument[1:] for index, argument in enumerate(args)
                     if roles[index] == "response" and argument.endswith(".LinkFileList")]
            if "-filelist" in args:
                raise EvidenceError("Unexpected alternate final link input-list form")
        else:
            if (compiler.name not in {"clang", "clang++"} or args.count("-r") != 1
                    or roles[args.index("-r")] != "option" or output.suffix != ".o"):
                raise EvidenceError("Unsupported intermediate link record")
            lists = [args[i + 1] for i, argument in enumerate(args[:-1])
                     if argument == "-filelist" and roles[i] == "option"]
            if args.count("-filelist") != 1:
                raise EvidenceError("Expected one intermediate linker file list")
        if len(lists) != 1:
            raise EvidenceError("Missing or ambiguous selected link input list")
        allowed_response = "@" + lists[0] if final else None
        for index, argument in enumerate(args):
            if "@" not in argument or (argument == allowed_response and roles[index] == "response"):
                continue
            # In the observed argv these are inert ld rpath operands, not
            # driver response files. Accept only that exact forwarding context.
            if (argument in {"@loader_path", "@loader_path/../../..",
                             "@loader_path/Frameworks", "@loader_path/../Frameworks"}
                    and index >= 3 and args[index - 3:index] == ["-Xlinker", "-rpath", "-Xlinker"]
                    and roles[index - 3:index + 1] == ["option", "value:-Xlinker", "option", "value:-Xlinker"]):
                continue
            raise EvidenceError("Unparsed response mechanism could change linker inputs/output")
        file_list = owned_build_file(scratch, lists[0])
        if file_list.suffix != ".LinkFileList" or str(file_list) not in command["inputs"]:
            raise EvidenceError("Link command input list is not declared as an input")
        objects = response_paths(file_list, scratch, artifacts)
        if any(str(item) not in command["inputs"] for item in objects):
            raise EvidenceError("Response-file objects disagree with declared link inputs")
        links[key] = {"recordID": identifier, "args": args, "inputs": command["inputs"],
                      "outputs": command["outputs"], "workingDirectory": command["working-directory"],
                      "fileList": str(file_list), "objects": list(map(str, objects))}
        visiting.add(key)
        for item in objects:
            visit(item, depth=depth + 1)
        visiting.remove(key)

    visit(payload, final=True)
    bindings = {}
    for relative, possibilities in candidates.items():
        chosen = [entry for entry in possibilities if str(entry["object"]) in reachable]
        if len(chosen) != 1:
            raise EvidenceError("Required source object is absent or ambiguous in the selected payload link graph")
        entry = chosen[0]
        absolute = str(checked_file(source, relative))
        rules = dependency_rules(read_build_text(entry["dependencies"], artifacts))
        matching_rules = [dependencies for targets, dependencies in rules if str(entry["object"]) in targets]
        if len(matching_rules) != 1 or absolute not in matching_rules[0]:
            raise EvidenceError("Compiler dependency rule does not bind exact source to selected object")
        bindings[relative] = {key: str(value) for key, value in entry.items()}
        bindings[relative]["sourceSHA256"] = sha(source / relative)
    result = {"sources": bindings, "linkRecords": links, "artifacts": artifacts, "discovery": discovery,
              "schema": "observed-swiftbuild-output-map-make-dependency-xcbuilddata-ld-v1"}
    verify_swiftbuild_binding(scratch, result)
    return result


def verify_swiftbuild_binding(scratch, binding):
    discovery = {"outputMaps": sorted(str(path) for path in scratch.rglob("*-OutputFileMap.json")),
                 "manifests": sorted(str(path) for path in scratch.rglob("manifest.json") if "XCBuildData" in path.parts)}
    if discovery != binding["discovery"]:
        raise EvidenceError("Source-to-payload build-record inventory changed")
    for spelling, expected in binding["artifacts"].items():
        if sha(owned_build_file(scratch, spelling)) != expected:
            raise EvidenceError("Source-to-payload binding artifact changed")

def stage(source, inputs, evidence, owned, label, tools, selected, sites=None, native=False, mutant=False, liveness=False):
    directory = evidence / label
    directory.mkdir()
    build_root = owned / "builds" / label
    build_root.mkdir(parents=True)
    environment = dict(os.environ)
    for name in ["cache", "config", "security", "scratch", "ModuleCache"]:
        (build_root / name).mkdir()
    environment.update(CLANG_MODULE_CACHE_PATH=str(build_root / "ModuleCache"),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(build_root / "ModuleCache"),
                       MACOSX_DEPLOYMENT_TARGET="14.0", SWIFT_TESTING_ENABLED="0")
    before = fingerprints(source, inputs)
    record = {"label": label, "outcome": "invalid", "selectedTests": selected,
              "expectedAssertionSites": sites, "sourceBefore": before,
              "buildRoot": str(build_root), "swiftPMSandboxEnabled": True,
              "environment": {key: environment[key] for key in ["CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE", "MACOSX_DEPLOYMENT_TARGET", "SWIFT_TESTING_ENABLED"]}}
    try:
        if native:
            build_command = ["bash", "Scripts/test-native-contracts.sh", "--build-only"]
        else:
            build_command = [tools["swift"], "build", "--build-tests", "--build-system", "swiftbuild", "--jobs", "2", "--verbose"]
            for option in ["cache", "config", "security", "scratch"]:
                build_command += ["--" + option + "-path", str(build_root / option)]
        build_record = run_command(build_command, source, environment, directory / "build.log", timeout=600)
        record["build"] = build_record
        if not command_ok(build_record) or INFRA.search(read_log(directory / "build.log")):
            raise EvidenceError("Build failure/timeout/diagnostic; no test payload executed")
        if fingerprints(source, inputs) != before:
            raise EvidenceError("Compile inputs changed during build")
        if native:
            matches = re.findall(r"^NATIVE_CONTRACT_MANIFEST=(.+)$", read_log(directory / "build.log"), re.M)
            if len(matches) != 1:
                raise EvidenceError("Native build manifest missing or ambiguous")
            manifest_path = checked_file(source, matches[0])
            manifest = json.loads(manifest_path.read_text())
            if manifest.get("status") != "built" or not manifest.get("buildOnly"):
                raise EvidenceError("Native build did not positively complete")
            product = manifest["payloads"]["bridge-contract"]
            payload = checked_file(source, product["path"])
            if product["buildExitCode"] != 0 or sha(payload) != product["sha256"]:
                raise EvidenceError("Native payload differs from successful build record")
            record["nativeBuildManifest"] = manifest
            command = [str(payload), "--test", selected[0]]
        else:
            bundles = list((build_root / "scratch").rglob("*.xctest"))
            if len(bundles) != 1 or bundles[0].is_symlink() or not bundles[0].is_dir():
                raise EvidenceError("Expected one fresh XCTest bundle")
            bundle = bundles[0]
            bundle_names = tree_files(bundle, "")
            bundle_inventory = fingerprints(bundle, bundle_names)
            info = plistlib.loads(checked_file(bundle, "Contents/Info.plist").read_bytes())
            record["bundleInventory"] = bundle_inventory
            executable = info.get("CFBundleExecutable", "")
            if not executable or Path(executable).name != executable:
                raise EvidenceError("XCTest executable identity is invalid")
            payload = checked_file(bundle, "Contents/MacOS/" + executable)
            # The command names this exact bundle whose Mach-O is hashed below.
            command = [tools["xctest"]] + (["-XCTest", selected[0]] if len(selected) == 1 else []) + [str(bundle)]
            platform = Path(tools["platformPath"])
            for key, additions in {
                "DYLD_LIBRARY_PATH": [str(bundle.parent), str(platform / "Developer/usr/lib")],
                "DYLD_FRAMEWORK_PATH": [str(platform / "Developer/Library/Frameworks"), str(platform / "Developer/Library/PrivateFrameworks")],
            }.items():
                environment[key] = ":".join(additions + ([environment[key]] if environment.get(key) else []))
                record["environment"][key] = environment[key]
            record["testBundle"] = str(bundle)
            record["compileBinding"] = swiftbuild_binding(source, build_root / "scratch", payload)

        payload_sha = sha(payload)
        record["payload"] = {"path": str(payload), "sha256": payload_sha}
        shutil.copy2(payload, directory / "test-payload")
        if sha(directory / "test-payload") != payload_sha:
            raise EvidenceError("Payload evidence copy failed")
        if not native:
            verify_swiftbuild_binding(build_root / "scratch", record["compileBinding"])
            if tree_files(bundle, "") != bundle_names or fingerprints(bundle, bundle_names) != bundle_inventory:
                raise EvidenceError("XCTest bundle selection metadata/resources changed before execution")
        if fingerprints(source, inputs) != before or sha(payload) != payload_sha:
            raise EvidenceError("Compile inputs or payload changed before execution")
        _, _, _, test_record = build_then_execute(
            lambda: build_record, lambda: [payload],
            lambda _payload, _digest: run_command(command, source, environment, directory / "test.log", timeout=120))
        record["execution"] = test_record
        if test_record.get("timedOut") or not test_record.get("logComplete") or test_record.get("error"):
            raise EvidenceError("Test process timeout/launch/log failure")
        if not native:
            verify_swiftbuild_binding(build_root / "scratch", record["compileBinding"])
            if tree_files(bundle, "") != bundle_names or fingerprints(bundle, bundle_names) != bundle_inventory:
                raise EvidenceError("XCTest bundle selection metadata/resources changed during execution")
        if sha(payload) != payload_sha or fingerprints(source, inputs) != before:
            raise EvidenceError("Compile inputs or executed payload changed")
        text = read_log(directory / "test.log")
        classification = (classify_native(text, test_record["exitCode"], selected[0], sites, mutant)
                          if native else classify_xctest(text, test_record["exitCode"], selected, sites or [], mutant, liveness))
        record.update(classification)
    except (EvidenceError, OSError, ValueError, KeyError) as error:
        record["reason"] = str(error)
    finally:
        try:
            record["sourceAfter"] = fingerprints(source, inputs)
        except (EvidenceError, OSError) as error:
            record.update(outcome="invalid", sourceAfterError=str(error))
        write_json(directory / "result.json", record)
    return record


class RunInterrupted(BaseException):
    pass


def interrupt(signum, _frame):
    global interrupted_signal
    interrupted_signal = signum
    for stop_signal in STOP_SIGNALS:
        signal.signal(stop_signal, signal.SIG_IGN)
    if not launching_child:
        raise RunInterrupted("interrupted by signal " + str(signum))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", action="append", help="Exact case ID; repeat to select cases, default all.")
    parser.add_argument("--expected-base", default=BASE, help="Reviewed source HEAD; mismatch stops before copying.")
    args = parser.parse_args()
    wanted = args.case or [case[0] for case in CASES + NATIVE_CASES]
    if len(set(wanted)) != len(wanted) or set(wanted) - {case[0] for case in CASES + NATIVE_CASES}:
        raise SystemExit("Unknown or duplicate mutation case; no source changed")
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_base):
        raise SystemExit("Expected base must be an exact reviewed commit")
    evidence_parent = ROOT / ".planning/regression-sensitivity"
    if not evidence_parent.resolve().is_relative_to(ROOT) or any(p.is_symlink() for p in [ROOT / ".planning", evidence_parent]):
        raise SystemExit("Unsafe evidence namespace")
    evidence_parent.mkdir(parents=True, exist_ok=True)
    lock_path = evidence_parent / ".writer.lock"
    if lock_path.is_symlink():
        raise SystemExit("Unsafe writer lock")
    with lock_path.open("a+") as writer:
        try:
            fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another mutation runner owns this namespace; nothing changed")
        run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex
        evidence = evidence_parent / run_id
        evidence.mkdir(mode=0o700)
        owned = Path(tempfile.mkdtemp(prefix="Clavune-regression-", dir="/tmp")).resolve()
        report = {"schemaVersion": 2, "runID": run_id, "expectedBaseRevision": args.expected_base,
                  "status": "running", "sourceIsolation": "owned independent copy; primary sources never mutated",
                  "ownedRoot": str(owned), "cases": [], "sourceRestored": False,
                  "hostRoute": "split swift build --build-tests and exact xctest bundle; baseline must validate installed route"}
        write_json(evidence / "started.json", report)
        original = None
        names = []
        try:
            for signum in STOP_SIGNALS:
                signal.signal(signum, interrupt)
            source, names, original, inputs = prepare_snapshot(owned, evidence, args.expected_base)
            tools = toolchain(source, evidence)
            fixed = fingerprints(source, inputs)
            for case in CASES + NATIVE_CASES:
                case_id, relative, before, after, test = case
                if case_id not in wanted:
                    continue
                native = case in NATIVE_CASES
                selected = [NATIVE_NAME if native else PREFIX + test]
                sites = native_site(source, test) if native else assertion_sites(source, case)
                current = source / relative
                original_bytes = current.read_bytes()
                if original_bytes.count(before.encode()) != 1:
                    raise EvidenceError("Exact mutation site absent or ambiguous: " + case_id)
                mutant = original_bytes.replace(before.encode(), after.encode(), 1)
                case_dir = evidence / case_id
                case_dir.mkdir()
                (case_dir / "original-source").write_bytes(original_bytes)
                (case_dir / "mutant-source").write_bytes(mutant)
                entry = {"id": case_id, "source": relative, "selectedTests": selected,
                         "originalSHA256": hashlib.sha256(original_bytes).hexdigest(),
                         "mutantSHA256": hashlib.sha256(mutant).hexdigest(), "sourceRestored": False}
                report["cases"].append(entry)
                write_json(case_dir / "recovery.json", {**entry, "ownedSourcePath": str(current),
                           "primarySourceNeverWritten": True, "recoveryPolicy": "Restore only expected mutant bytes. Preserve intervening edits. Never copy this workspace over primary sources."})
                baseline = stage(source, inputs, evidence, owned, case_id + "-baseline", tools, selected, sites, native)
                entry["baseline"] = baseline
                if baseline["outcome"] != "passed":
                    raise EvidenceError(case_id + ": fixed baseline invalid; no mutation applied")
                try:
                    guard_replace(current, original_bytes, mutant, source)
                    entry["mutant"] = stage(source, inputs, evidence, owned, case_id + "-mutant", tools,
                                             selected, sites, native, True, case_id.startswith(("C07", "C10")))
                finally:
                    if current.read_bytes() == mutant:
                        guard_replace(current, mutant, original_bytes, source)
                    if current.read_bytes() != original_bytes:
                        raise EvidenceError(case_id + ": isolated-source conflict; intervening edit preserved")
                    entry["sourceRestored"] = fingerprints(source, inputs) == fixed
                    write_json(case_dir / "restoration.json", {"sourceRestored": entry["sourceRestored"],
                               "sourceSHA256": sha(current), "primarySourceNeverWritten": True})
                # Even an invalid/surviving mutant gets its restored test, if safe.
                if not entry["sourceRestored"]:
                    raise EvidenceError("Restored copy inputs disagree with fixed snapshot")
                entry["restored"] = stage(source, inputs, evidence, owned, case_id + "-restored", tools, selected, sites, native)
                if entry["mutant"]["outcome"] != "killed" or entry["restored"]["outcome"] != "passed":
                    raise EvidenceError(case_id + ": intended mutant/restored evidence gate not satisfied")
                write_json(case_dir / "result.json", entry)
                print(case_id + ": fixed pass, intended assertion kill, exact restored pass", flush=True)
            report["restoredFullSuite"] = stage(source, inputs, evidence, owned, "restored-full-suite", tools, all_xctests(source))
            if report["restoredFullSuite"]["outcome"] != "passed":
                raise EvidenceError("Restored full suite did not pass exact positive test inventory")
            report["sourceRestored"] = fingerprints(source, inputs) == fixed
            report["status"] = "passed" if report["sourceRestored"] else "invalid"
        except (EvidenceError, OSError, ValueError, KeyError, subprocess.SubprocessError, RunInterrupted, KeyboardInterrupt) as error:
            report["status"] = "interrupted" if isinstance(error, (RunInterrupted, KeyboardInterrupt)) else "invalid"
            report["reason"] = str(error)
        finally:
            if original is not None:
                try:
                    report["capturedPrimaryInputsUnchanged"] = fingerprints(ROOT, names) == original
                except (EvidenceError, OSError):
                    report["capturedPrimaryInputsUnchanged"] = False
                if not report["capturedPrimaryInputsUnchanged"]:
                    report["status"] = "invalid"
                    report["primaryChangeNote"] = "Primary input drift detected; user bytes were never overwritten"
            write_json(evidence / "manifest.json", report)
            replacements = {str(owned): "<owned-run>", str(ROOT): "<project>", str(Path.home()): "<home>"}
            write_json(evidence / "redacted-review.json", redact(report, replacements))
            for logfile in list(evidence.rglob("*.log")):
                if logfile.stat().st_size <= MAX_LOG:
                    logfile.with_suffix(".redacted.txt").write_text(redact(read_log(logfile), replacements))
        print("Mutation evidence: " + str(evidence.relative_to(ROOT)) + "/manifest.json", flush=True)
        if report["status"] != "passed":
            raise SystemExit("INVALID evidence; primary sources not mutated. " + report.get("reason", report["status"]))
        print("All selected mutations killed; exact restored full-suite inventory passed.")


if __name__ == "__main__":
    main()
