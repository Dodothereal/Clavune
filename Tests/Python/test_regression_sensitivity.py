"""Synthetic evidence-gate tests: no Swift, native backend, model, or OS fixture."""
import importlib.util
from pathlib import Path
import signal
import shlex
import os
import json
import subprocess
import sys
import time
import tempfile
import unittest
from unittest import mock
import plistlib

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("regression_sensitivity", ROOT / "Scripts/test-regression-sensitivity.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
def make_path_word(path):
    """Encode a literal path in the synthetic Make dependency grammar."""
    return "".join("\\" + char if char in "\\ \t:#" else char for char in str(path))


NAME = "ClavuneCoreTests.ExampleTests/testExpected"
SITE = {"file": "Tests/ClavuneCoreTests/ExampleTests.swift", "line": 42,
        "pattern": r"XCTAssertEqual failed: expected marker"}


# Exact sanitized retained Swift 6.4 argv; placeholders expand only in fixtures.
HOST_LINK_ARGS = {'XCTest': ['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
            '-Xlinker',
            '-reproducible',
            '-target',
            'arm64-apple-macos14.0',
            '-Xlinker',
            '-bundle',
            '-sdk',
            '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk',
            '-Xlinker',
            '-no_warn_duplicate_libraries',
            '-L<O>/Intermediates.noindex/EagerLinkingTBDs/Debug',
            '-L<P>',
            '-L/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib',
            '-F<O>/Intermediates.noindex/EagerLinkingTBDs/Debug',
            '-F<P>/PackageFrameworks',
            '-F<P>',
            '-Fsystem',
            '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks',
            '@<T>/ClavuneCoreTests.LinkFileList',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '/usr/lib/swift',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '@loader_path',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '<P>/PackageFrameworks',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '@loader_path/../../..',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '@loader_path/Frameworks',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '@loader_path/../Frameworks',
            '-Xlinker',
            '-rpath',
            '-Xlinker',
            '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx',
            '-Xlinker',
            '-dead_strip',
            '-Xlinker',
            '-object_path_lto',
            '-Xlinker',
            '<T>/ClavuneCoreTests_lto.o',
            '-Xclang-linker',
            '-rdynamic',
            '-Xlinker',
            '-no_deduplicate',
            '-Xlinker',
            '-dependency_info',
            '-Xlinker',
            '<T>/ClavuneCoreTests_dependency_info.dat',
            '-link-objc-runtime',
            '-L/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx',
            '-L/usr/lib/swift',
            '-Xlinker',
            '-add_ast_path',
            '-Xlinker',
            '<T>/ClavuneCoreTests.swiftmodule',
            '-lc++',
            '-framework',
            'Accelerate',
            '-framework',
            'Metal',
            '-framework',
            'Foundation',
            '-framework',
            'MetalKit',
            '-lwhisper',
            '-lggml',
            '-lggml-cpu',
            '-lggml-blas',
            '-lggml-metal',
            '-lggml-base',
            '-lc++',
            '-L<S>/.build/backend/src',
            '-L<S>/.build/backend/ggml/src',
            '-L<S>/.build/backend/ggml/src/ggml-cpu',
            '-L<S>/.build/backend/ggml/src/ggml-blas',
            '-L<S>/.build/backend/ggml/src/ggml-metal',
            '-Xlinker',
            '-needed_framework',
            '-Xlinker',
            'XCTest',
            '-framework',
            'XCTest',
            '-Xlinker',
            '-needed-lXCTestSwiftSupport',
            '-lXCTestSwiftSupport',
            '-Xlinker',
            '-no_adhoc_codesign',
            '-o',
            '<E>',
            '-no-stdlib-rpath'],
 'Core': ['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang',
          '-Xlinker',
          '-reproducible',
          '-target',
          'arm64-apple-macos14.0',
          '-r',
          '-isysroot',
          '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk',
          '-O0',
          '-Xlinker',
          '-no_warn_duplicate_libraries',
          '-F<O>/Intermediates.noindex/EagerLinkingTBDs/Debug',
          '-F<P>/PackageFrameworks',
          '-F<P>',
          '-iframework',
          '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks',
          '-filelist',
          '<C>/ClavuneCore.LinkFileList',
          '-nostdlib',
          '-Xlinker',
          '-object_path_lto',
          '-Xlinker',
          '<C>/ClavuneCore_lto.o',
          '-Xlinker',
          '-no_deduplicate',
          '-Xlinker',
          '-dependency_info',
          '-Xlinker',
          '<C>/ClavuneCore_dependency_info.dat',
          '-fobjc-link-runtime',
          '-L/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx',
          '-L/usr/lib/swift',
          '-Xlinker',
          '-add_ast_path',
          '-Xlinker',
          '<C>/ClavuneCore.swiftmodule',
          '-o',
          '<P>/ClavuneCore.o'],
 'TestableApp': ['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang',
                 '-Xlinker',
                 '-reproducible',
                 '-target',
                 'arm64-apple-macos14.0',
                 '-r',
                 '-isysroot',
                 '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk',
                 '-O0',
                 '-Xlinker',
                 '-no_warn_duplicate_libraries',
                 '-F<O>/Intermediates.noindex/EagerLinkingTBDs/Debug',
                 '-F<P>/PackageFrameworks',
                 '-F<P>',
                 '-iframework',
                 '/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks',
                 '-filelist',
                 '<A>/ClavuneApp--52AC4B1E48BB6C07-testable.LinkFileList',
                 '-nostdlib',
                 '-Xlinker',
                 '-object_path_lto',
                 '-Xlinker',
                 '<A>/ClavuneApp--52AC4B1E48BB6C07-testable_lto.o',
                 '-Xlinker',
                 '-no_deduplicate',
                 '-Xlinker',
                 '-dependency_info',
                 '-Xlinker',
                 '<A>/ClavuneApp--52AC4B1E48BB6C07-testable_dependency_info.dat',
                 '-fobjc-link-runtime',
                 '-L/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx',
                 '-L/usr/lib/swift',
                 '-Xlinker',
                 '-add_ast_path',
                 '-Xlinker',
                 '<A>/ClavuneApp.swiftmodule',
                 '-o',
                 '<P>/ExecutableModules/ClavuneApp--52AC4B1E48BB6C07-testable.o']}

def log(name=NAME, failure=True, message="XCTAssertEqual failed: expected marker", line=42):
    cls, method = name.split("/")
    result = [f"Test Case '-[{cls} {method}]' started."]
    if failure:
        result.append(f"/owned/Tests/ClavuneCoreTests/ExampleTests.swift:{line}: error: -[{cls} {method}] : {message}")
    result += [f"Test Case '-[{cls} {method}]' {'failed' if failure else 'passed'} (0.001 seconds).",
               f"Executed 1 test, with {int(failure)} failure (0 unexpected) in 0.001 seconds"]
    return "\n".join(result)


class XCTestDiscoveryTests(unittest.TestCase):
    def discover(self, sources):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "Tests/ClavuneCoreTests"
            tests.mkdir(parents=True)
            for filename, text in sources.items():
                (tests / filename).write_text(text)
            return RUNNER.all_xctests(root)

    def test_actual_suite_includes_all_four_indirect_classes(self):
        names = RUNNER.all_xctests(ROOT)
        expected = {
            "CaptureProgressCallbackTests": {
                "testPreparingStartingAcceptsProgressWithoutClaimingFirstSample",
                "testRecordingForwardsExactPairsToLeafWithoutPublishingCoordinator",
                "testStoppingClosingAcceptsFinalProgressThenTranscribingRejectsLatePeak",
                "testFailedSameSessionRejectsRetainedProductionProgress",
                "testCancelledAndPriorSessionCallbacksCannotOverwriteNewSession",
            },
            "HotkeyCommandTests": {
                "testThrowingRegistrarKeepsErrorUntilExplicitRetry",
                "testBusyCommandIsIgnoredThroughLoadPreparingRecordingStoppingAndDecode",
                "testBusyCommandIsIgnoredDuringPermissionAndCaptureCloseDrain",
                "testBusyCommandIsIgnoredDuringImportPickerAdmissionAndUnload",
                "testRetainedFakeRegistrationRoutesHoldAndToggleEdges",
                "testFakeHotkeySecureInputRevalidationCancelsWithoutDecode",
            },
            "ProgressDispatchCompletionTests": {
                "testCapturedCallbackRemainsAsynchronousAndIsAwaitedToCompletion",
                "testEachCapturedInvocationHasItsOwnCompletionHandle",
            },
            "WatchdogQueuedTickTests": {
                "testCancelledTimerQueuedTickRevalidatesCurrentSessionInsteadOfResurrectingOldOne",
                "testWatchdogRemainsActiveDuringClosedMicrophoneDecodeAndStopsOnCancel",
                "testQueuedWatchdogAfterReviewAndDiscardDoesNotStartNewWork",
            },
        }
        for owner, methods in expected.items():
            with self.subTest(owner=owner):
                prefix = "ClavuneCoreTests." + owner + "/"
                actual = {name.removeprefix(prefix) for name in names if name.startswith(prefix)}
                self.assertEqual(actual, methods)
        self.assertFalse(any(".UIFixtureAssertions/" in name for name in names))
        self.assertEqual(len(names), len(set(names)))

    def test_direct_and_cross_file_multilevel_inheritance(self):
        self.assertEqual(self.discover({
            "A.swift": "final class Indirect: Middle {\n    @MainActor func testIndirect() async throws {}\n}",
            "B.swift": "class Middle: Base {}",
            "C.swift": "class Base: XCTestCase {}",
            "D.swift": "final class Direct: XCTestCase {\n    func testDirect() {}\n}",
        }), ["ClavuneCoreTests.Indirect/testIndirect", "ClavuneCoreTests.Direct/testDirect"])

    def test_whitespace_and_non_test_helpers(self):
        self.assertEqual(self.discover({
            "A.swift": "final class ExampleTests :\n    XCTestCase {\n"
                       "    private final class Helper: Unknown {}\n    func testExpected() {}\n}",
            "Helpers.swift": "class Unrelated: Unknown {}",
        }), [NAME])

    def test_top_level_non_test_helpers_do_not_make_test_owner_ambiguous(self):
        self.assertEqual(self.discover({
            "ExampleTests.swift": "private final class HeldWrite: @unchecked Sendable {}\n"
                                  "private final class HeldAudioRead: @unchecked Sendable {}\n"
                                  "final class ExampleTests: XCTestCase { func testExpected() {} }",
        }), [NAME])

    def test_selected_text_boundary_helper_is_allowed_without_broadening_unknown_bases(self):
        self.assertEqual(self.discover({
            "ExampleTests.swift": "private final class FakeBoundary: ConditionalSelectedTextBoundary {}\n"
                                  "final class ExampleTests: XCTestCase { func testExpected() {} }",
        }), [NAME])
        with self.assertRaises(RUNNER.EvidenceError):
            self.discover({
                "ExampleTests.swift": "private final class UnknownHelper: OtherProtocol {}\n"
                                      "final class ExampleTests: XCTestCase { func testExpected() {} }",
            })

    def test_unknown_unsupported_and_cyclic_inheritance_fail_closed(self):
        for header, extra in [
            ("Missing", ""),
            ("Base", "class Base: Missing {}"),
            ("Base", "class Base: Example {}"),
            ("Example", ""),
            ("XCTestCase, SomeProtocol", ""),
            ("Base<Int>", "class Base<T>: XCTestCase {}"),
            ("XCTest.XCTestCase", ""),
            ("Base", "class Base {}"),
        ]:
            with self.subTest(header=header, extra=extra), self.assertRaises(RUNNER.EvidenceError):
                self.discover({"A.swift": "final class Example: " + header + " {\n    func testOne() {}\n}",
                               "B.swift": extra})

    def test_duplicates_and_ambiguous_owners_fail_closed(self):
        for sources in [
            {"A.swift": "class Example: XCTestCase { func testOne() {} func testOne() {} }"},
            {"A.swift": "class Example: XCTestCase { func testOne() {} }",
             "B.swift": "class Example: XCTestCase {}"},
            {"A.swift": "class Example: Base { func testOne() {} }",
             "B.swift": "class Base: XCTestCase {}\nclass Base: Missing {}"},
            {"A.swift": "class Example: XCTestCase { func testOne() {} }\nclass Other: XCTestCase {}"},
            {"A.swift": "class Example: XCTestCase { func testOne() {} }\nclass Other: Missing {}"},
            {"A.swift": "class XCTestCase {}\nclass Example: XCTestCase { func testOne() {} }"},
        ]:
            with self.subTest(sources=sources), self.assertRaises(RUNNER.EvidenceError):
                self.discover(sources)

    def test_test_bearing_base_is_not_silently_under_enumerated(self):
        for body in ["", "func testChild() {}"]:
            with self.subTest(body=body), self.assertRaises(RUNNER.EvidenceError):
                self.discover({"A.swift": "class Child: Base { " + body + " }",
                               "B.swift": "class Base: XCTestCase { func testBase() {} }"})

    def test_empty_and_ownerless_inventories_fail_closed(self):
        for text in ["", "class Helper: XCTestCase {}", "func testOrphan() {}"]:
            with self.subTest(text=text), self.assertRaises(RUNNER.EvidenceError):
                self.discover({"A.swift": text})


class RegressionSensitivityTests(unittest.TestCase):
    def classify(self, text, code=1, **options):
        return RUNNER.classify_xctest(text, code, [NAME], [SITE], mutant=True, **options)["outcome"]

    def test_zero_selected_tests_is_invalid(self):
        self.assertEqual(self.classify("Executed 0 tests, with 0 failures (0 unexpected) in 0.0 seconds", 0), "invalid")

    def test_wrong_named_test_with_matching_assertion_is_invalid(self):
        self.assertEqual(self.classify(log(name="ClavuneCoreTests.OtherTests/testWrong")), "invalid")

    def test_valid_intended_assertion_failure_is_killed(self):
        self.assertEqual(self.classify(log()), "killed")

    def test_build_failure_preserves_but_never_executes_stale_product(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary).resolve() / "stale"
            payload.write_text("stale")
            invoked = []
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.build_then_execute(lambda: {"exitCode": 65, "logComplete": True},
                    lambda: [payload], lambda *args: invoked.append(args))
            self.assertEqual(invoked, [])
            self.assertEqual(payload.read_text(), "stale")

    def test_missing_product_is_invalid_without_execution(self):
        invoked = []
        with self.assertRaises(RUNNER.EvidenceError):
            RUNNER.build_then_execute(lambda: {"exitCode": 0, "logComplete": True},
                                     lambda: [], lambda *args: invoked.append(args))
        self.assertEqual(invoked, [])

    def test_ambiguous_payload_is_invalid(self):
        with tempfile.TemporaryDirectory() as temporary:
            a, b = Path(temporary).resolve() / "a", Path(temporary).resolve() / "b"
            a.write_text("a"); b.write_text("b")
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.build_then_execute(lambda: {"exitCode": 0, "logComplete": True},
                                         lambda: [a, b], lambda *args: self.fail("must not execute"))

    def test_assertion_outside_intended_record_is_invalid(self):
        self.assertEqual(self.classify(log(failure=False) + "\n" + log()), "invalid")

    def test_wrong_source_line_is_invalid(self):
        self.assertEqual(self.classify(log(line=43)), "invalid")

    def test_unrelated_assertion_is_invalid(self):
        self.assertEqual(self.classify(log(message="XCTAssertEqual failed: unrelated")), "invalid")

    def test_successful_mutant_survives(self):
        self.assertEqual(self.classify(log(failure=False), 0), "survived")

    def test_crash_and_infrastructure_failures_are_invalid(self):
        self.assertEqual(self.classify(log(), -signal.SIGABRT), "invalid")
        self.assertEqual(self.classify(log() + "\nerror: accessing build database: disk I/O error"), "invalid")

    def test_liveness_requires_explicit_declaration_and_finished_process(self):
        site = dict(SITE, pattern="Asynchronous wait failed: permission answer")
        text = log(message="Asynchronous wait failed: permission answer")
        self.assertEqual(RUNNER.classify_xctest(text, 1, [NAME], [site], True, False)["outcome"], "invalid")
        self.assertEqual(RUNNER.classify_xctest(text, 1, [NAME], [site], True, True)["outcome"], "killed")
        self.assertEqual(RUNNER.classify_xctest(text, None, [NAME], [site], True, True)["outcome"], "invalid")

    def test_native_abort_requires_exact_named_source_bound_check(self):
        name = "BridgeContractTests.adversarial_decoder_defaults"
        expected = {"expression": "!params.print_progress", "file": "Tests/Native/BridgeContractTests.cpp", "line": 191}
        text = "\n".join(["NATIVE_TEST_COUNT 1", "NATIVE_TEST_START " + name,
            "Contract check failed: !params.print_progress (Tests/Native/BridgeContractTests.cpp:191)"])
        self.assertEqual(RUNNER.classify_native(text, -signal.SIGABRT, name, expected, True)["outcome"], "killed")
        self.assertEqual(RUNNER.classify_native(text, -signal.SIGSEGV, name, expected, True)["outcome"], "invalid")
        self.assertEqual(RUNNER.classify_native(text.replace(":191)", ":192)"), -signal.SIGABRT, name, expected, True)["outcome"], "invalid")

    def test_contradictory_native_markers_are_invalid(self):
        name = "BridgeContractTests.adversarial_decoder_defaults"
        base = "\n".join(["NATIVE_TEST_COUNT 1", "NATIVE_TEST_START " + name,
                           "NATIVE_TEST_PASS " + name, "NATIVE_TEST_COMPLETE 1"])
        self.assertEqual(RUNNER.classify_native(base, 0, name)["outcome"], "passed")
        for extra in ["NATIVE_TEST_COUNT 0", "NATIVE_TEST_PASS wrong", "NATIVE_TEST_COMPLETE 99", "NATIVE_TEST_START"]:
            self.assertEqual(RUNNER.classify_native(base + "\n" + extra, 0, name)["outcome"], "invalid")

    def test_unexplained_signals_and_diagnostics_are_invalid(self):
        for extra in ["error: Exited with unexpected signal code 6", "LeakSanitizer has encountered a fatal error",
                      "error: unavailable build service", "libc++abi: terminating due to unrelated exception",
                      "Test Case malformed"]:
            self.assertEqual(self.classify(log() + "\n" + extra), "invalid")
        self.assertEqual(self.classify(log(), 137), "invalid")

    def test_summary_chronology_and_contradictions_are_invalid(self):
        summary = "Executed 1 test, with 1 failure (0 unexpected) in 0.01 seconds"
        self.assertEqual(self.classify(summary + "\n" + log()), "invalid")
        self.assertEqual(self.classify(log().replace(" started.\n", " started.\n" + summary + "\n")), "invalid")
        self.assertEqual(self.classify(log().replace("Executed 1 test", "Executed 2 tests")), "invalid")

    def test_nested_xctest_suite_summaries_pass(self):
        text = "Test Suite 'Selected tests' started at now.\nTest Suite 'ExampleTests' started at now.\n" + log()
        text = text[:text.rindex("Executed ")] + "Test Suite 'ExampleTests' failed at now.\n" + text[text.rindex("Executed "):]
        text += "\nTest Suite 'Selected tests' failed at now.\nExecuted 1 test, with 1 failure (0 unexpected) in 0.001 seconds"
        self.assertEqual(self.classify(text), "killed")

    def test_guarded_restore_preserves_intervening_user_edit(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / "source.swift"
            path.write_bytes(b"original")
            RUNNER.guard_replace(path, b"original", b"mutant")
            path.write_bytes(b"intervening")
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.guard_replace(path, b"mutant", b"original")
            self.assertEqual(path.read_bytes(), b"intervening")

    def test_copy_has_independent_inode_and_preserves_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            origin, copied = root / "origin", root / "copy"
            origin.mkdir(); copied.mkdir()
            (origin / "source.swift").write_bytes(b"original")
            RUNNER.copy_file(origin, copied, "source.swift")
            self.assertNotEqual((origin / "source.swift").stat().st_ino, (copied / "source.swift").stat().st_ino)
            RUNNER.guard_replace(copied / "source.swift", b"original", b"mutant", copied)
            self.assertEqual((origin / "source.swift").read_bytes(), b"original")

    def test_restore_refuses_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / "real").mkdir(); (root / "real/source").write_bytes(b"mutant")
            (root / "link").symlink_to(root / "real", target_is_directory=True)
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.guard_replace(root / "link/source", b"mutant", b"original", root)
            self.assertEqual((root / "real/source").read_bytes(), b"mutant")

    def test_restore_refuses_symlinked_source_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve(); real = parent / "real"; real.mkdir()
            (real / "source").write_bytes(b"mutant")
            root = parent / "owned"; root.symlink_to(real, target_is_directory=True)
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.guard_replace(root / "source", b"mutant", b"original", root)
            self.assertEqual((real / "source").read_bytes(), b"mutant")

    def test_new_compile_input_invalidates_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); (root / "Sources").mkdir()
            (root / "Sources/one.swift").write_text("one")
            RUNNER.fingerprints(root, ["Sources/one.swift"])
            (root / "Sources/two.swift").write_text("two")
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.fingerprints(root, ["Sources/one.swift"])

    def test_redaction_keeps_technical_relative_paths_without_user_name(self):
        private = "/" + "Users/fixture-person/project"
        value = {"path": private + "/Sources/Test.swift", "other": "/home/fixture-person/cache"}
        result = RUNNER.redact(value, {private: "<project>"})
        self.assertEqual(result["path"], "<project>/Sources/Test.swift")
        self.assertNotIn("fixture-person", json.dumps(result))

    def test_command_timeout_is_invalid_and_direct_status_recorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            result = RUNNER.run_command([sys.executable, "-c", "import time; time.sleep(30)"],
                                        root, os.environ.copy(), root / "timeout.log", timeout=0.05)
            self.assertTrue(result["timedOut"])
            self.assertFalse(RUNNER.command_ok(result))
            self.assertTrue((root / "timeout.log.command.json").is_file())
            status = RUNNER.run_command([sys.executable, "-c", "raise SystemExit(65)"],
                                       root, os.environ.copy(), root / "exit.log")
            self.assertEqual(status["exitCode"], 65)

    def test_catchable_stop_records_interruption_and_cleans_owned_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            ready = root / "ready"
            runner_file = str(ROOT / "Scripts/test-regression-sensitivity.py")
            child_code = "from pathlib import Path; import time; Path(" + repr(str(ready)) + ").write_text('ready'); time.sleep(30)"
            driver = ("import importlib.util, signal, os; from pathlib import Path; "
                "s=importlib.util.spec_from_file_location('r', " + repr(runner_file) + "); "
                "r=importlib.util.module_from_spec(s); s.loader.exec_module(r); "
                "[signal.signal(v,r.interrupt) for v in r.STOP_SIGNALS]; "
                "r.run_command(" + repr([sys.executable, "-c", child_code]) + ", Path(" + repr(str(root)) + "), os.environ.copy(), Path(" + repr(str(root / "child.log")) + "))")
            process = subprocess.Popen([sys.executable, "-c", driver], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=8)
                record = json.loads((root / "child.log.command.json").read_text())
                self.assertIn("RunInterrupted", record["error"])
                self.assertFalse(RUNNER.command_ok(record))
            finally:
                if process.poll() is None:
                    process.kill(); process.communicate()


class SwiftbuildRecordParserTests(unittest.TestCase):
    def test_duplicate_output_map_keys_are_invalid(self):
        with self.assertRaises(RUNNER.EvidenceError):
            json.loads('{"source":{},"source":{}}', object_pairs_hook=RUNNER.unique_json_pairs)

    def test_make_dependencies_preserve_exact_escaped_paths(self):
        text = "/owned/build/File.o : /owned/source/File.swift /SDK/Some\\ Framework/Header.h \\\n /owned/source/Other.swift\n"
        rules = RUNNER.dependency_rules(text)
        self.assertEqual(rules, [(["/owned/build/File.o"], ["/owned/source/File.swift", "/SDK/Some Framework/Header.h", "/owned/source/Other.swift"])])

    def test_ambiguous_or_empty_dependency_rules_are_invalid(self):
        for text in ["", "object:one:two", "object:", "object: $(SOURCE)"]:
            with self.subTest(text=text), self.assertRaises(RUNNER.EvidenceError):
                RUNNER.dependency_rules(text)

    def test_artifact_outside_fresh_stage_is_invalid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); scratch = root / "fresh"; scratch.mkdir()
            old = root / "old.o"; old.write_bytes(b"stale")
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.owned_build_file(scratch, str(old))
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.owned_build_file(scratch, "old.o")

    def test_absolute_source_key_disambiguates_same_basename(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); source = root / "source"; source.mkdir()
            scratch = root / "scratch"; scratch.mkdir()
            (source / "File.swift").write_text("fixed")
            obj = scratch / "File.o"; obj.write_bytes(b"new object")
            dep = scratch / "File.d"; dep.write_text(make_path_word(obj) + ": " + make_path_word(source / "File.swift") + "\n")
            mapping = scratch / "Target-OutputFileMap.json"
            mapping.write_text(json.dumps({str(root / "wrong/File.swift"): {"object": str(obj), "dependencies": str(dep)}}))
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.swift_source_candidates(source, scratch, ["File.swift"])
            mapping.write_text(json.dumps({str(source / "File.swift"): {"object": str(obj), "dependencies": str(dep)}}))
            found = RUNNER.swift_source_candidates(source, scratch, ["File.swift"])
            self.assertEqual(found["File.swift"][0]["object"], obj)

    def test_response_file_supports_observed_one_line_and_quoted_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            files = [root / "one.o", root / "two with space.o"]
            for file in files:
                file.write_bytes(b"object")
            response = root / "Target.LinkFileList"
            response.write_text(" ".join(shlex.quote(str(file)) for file in files))
            self.assertEqual(RUNNER.response_paths(response, root), files)
            for text, reason in [
                ("@" + shlex.quote(str(files[0])), "Options or nested response files"),
                ("-lUnexpected", "Options or nested response files"),
                (shlex.quote(str(files[0])) + " " + shlex.quote(str(files[0])), "Empty, oversized or duplicate linker input list"),
                ('"unterminated', "Malformed linker response/file-list quoting"),
            ]:
                response.write_text(text)
                with self.subTest(text=text), self.assertRaisesRegex(RUNNER.EvidenceError, reason):
                    RUNNER.response_paths(response, root)

    def test_owned_fixture_root_resolves_symlinked_temp_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            real = parent / "real"; real.mkdir()
            alias = parent / "alias"; alias.symlink_to(real, target_is_directory=True)
            with tempfile.TemporaryDirectory(dir=alias) as nested:
                root = Path(nested).resolve()
                artifact = root / "object.o"; artifact.write_bytes(b"object")
                self.assertEqual(RUNNER.owned_build_file(root, str(artifact)), artifact)
                spelling = Path(nested) / "object.o"
                self.assertNotEqual(spelling, artifact)
                with self.assertRaises(RUNNER.EvidenceError):
                    RUNNER.owned_build_file(root, str(spelling))

    def test_build_record_symlink_inside_scratch_is_invalid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve(); actual = root / "actual.o"; actual.write_bytes(b"object")
            alias = root / "alias.o"; alias.symlink_to(actual)
            with self.assertRaises(RUNNER.EvidenceError):
                RUNNER.owned_build_file(root, str(alias))


class SwiftbuildBindingTests(unittest.TestCase):
    @staticmethod
    def make_fixture(source, scratch):
        """Synthetic records shaped from the retained Swift 6.4 host excerpts."""
        intermediate = scratch / "out/Intermediates.noindex/Clavune.build/Debug"
        products = scratch / "out/Products/Debug"
        payload = products / "ClavuneCoreTests.xctest/Contents/MacOS/ClavuneCoreTests"
        payload.parent.mkdir(parents=True)
        payload.write_bytes(b"synthetic XCTest payload, never executable")
        (payload.parent.parent / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "ClavuneCoreTests"}))
        records = {}
        objects = {}
        maps = {}
        for relative, target, module in [
            (RUNNER.APP, "ClavuneApp--52AC4B1E48BB6C07-testable-t", "ClavuneApp--52AC4B1E48BB6C07-testable"),
            (RUNNER.APP, "Clavune-p", "Clavune"),
            (RUNNER.SERVICE, "ClavuneCore-t", "ClavuneCore"),
            (RUNNER.TEST_SOURCE, "ClavuneCoreTests-p", "ClavuneCoreTests"),
        ]:
            directory = intermediate / (target + ".build/Objects-normal/arm64")
            directory.mkdir(parents=True)
            obj = directory / (Path(relative).stem + ".o"); obj.write_bytes(module.encode())
            dep = obj.with_suffix(".d"); dep.write_text(make_path_word(obj) + " : " + make_path_word(source / relative) + "\n")
            output_map = directory / (module + "-OutputFileMap.json")
            output_map.write_text(json.dumps({str(source / relative): {"object": str(obj), "dependencies": str(dep),
                "index-unit-output-path": "/Clavune.build/Debug/ignored-index-only.o"}}))
            objects[module] = obj; maps[module] = output_map

        def add_link(output, inputs, module, final=False):
            output.parent.mkdir(parents=True, exist_ok=True)
            if not output.exists(): output.write_bytes(b"synthetic relocatable")
            file_list = objects[module].parent / (module + ".LinkFileList")
            # The actual final list is whitespace-separated on one physical line.
            file_list.write_text(" ".join(shlex.quote(str(path)) for path in inputs))
            args = (["/fixture/swiftc", "-Xlinker", "-bundle", "@" + str(file_list)] if final else
                    ["/fixture/clang", "-r", "-filelist", str(file_list)]) + ["-o", str(output)]
            if final: args += ["-no-stdlib-rpath"]
            identifier = "P2:fixture-" + module + ":Ld " + str(output) + " normal"
            records[identifier] = {"tool": "shell", "description": "Ld " + str(output) + " normal",
                "args": args, "inputs": list(map(str, inputs)) + [str(file_list)],
                "outputs": [str(output), "<Linked Binary " + str(output) + ">", str(output) + "_lto.o", "<TRIGGER: Ld " + str(output) + " normal>"],
                "working-directory": str(source)}
            return file_list

        core = products / "ClavuneCore.o"
        app = products / "ExecutableModules/ClavuneApp--52AC4B1E48BB6C07-testable.o"
        core_list = add_link(core, [objects["ClavuneCore"]], "ClavuneCore")
        app_list = add_link(app, [objects["ClavuneApp--52AC4B1E48BB6C07-testable"]], "ClavuneApp--52AC4B1E48BB6C07-testable")
        final_list = add_link(payload, [objects["ClavuneCoreTests"], core, app], "ClavuneCoreTests", True)
        manifest = scratch / "out/Intermediates.noindex/XCBuildData/fixture.xcbuilddata/manifest.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({"client": {}, "targets": {}, "nodes": {}, "commands": records}))
        return {"payload": payload, "manifest": manifest, "objects": objects, "maps": maps,
                "finalList": final_list, "coreList": core_list, "appList": app_list}

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source"; self.source.mkdir()
        self.scratch = self.root / "scratch"; self.scratch.mkdir()
        for relative in [RUNNER.APP, RUNNER.SERVICE, RUNNER.TEST_SOURCE]:
            path = self.source / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_text("fixed source")
        self.fixture = self.make_fixture(self.source, self.scratch)

    def binding(self):
        return RUNNER.swiftbuild_binding(self.source, self.scratch, self.fixture["payload"])

    def edit_manifest(self, edit):
        data = json.loads(self.fixture["manifest"].read_text()); edit(data)
        self.fixture["manifest"].write_text(json.dumps(data))

    def test_complete_graph_with_spaces_in_owned_paths(self):
        source = self.root / "source with spaces"; source.mkdir()
        scratch = self.root / "scratch with spaces"; scratch.mkdir()
        for relative in [RUNNER.APP, RUNNER.SERVICE, RUNNER.TEST_SOURCE]:
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixed source")
        fixture = self.make_fixture(source, scratch)
        binding = RUNNER.swiftbuild_binding(source, scratch, fixture["payload"])
        self.assertEqual(len(binding["linkRecords"]), 3)
        RUNNER.verify_swiftbuild_binding(scratch, binding)

    def test_actual_host_shaped_graph_selects_testable_not_product_object(self):
        binding = self.binding()
        self.assertEqual(binding["sources"][RUNNER.APP]["object"], str(self.fixture["objects"]["ClavuneApp--52AC4B1E48BB6C07-testable"]))
        self.assertEqual(len(binding["linkRecords"]), 3)
        RUNNER.verify_swiftbuild_binding(self.scratch, binding)

    def test_complete_retained_host_argv_with_contextual_rpaths_is_supported(self):
        placeholders = {"<S>": self.source, "<O>": self.scratch / "out",
                        "<P>": self.scratch / "out/Products/Debug", "<E>": self.fixture["payload"],
                        "<T>": self.fixture["finalList"].parent, "<C>": self.fixture["coreList"].parent,
                        "<A>": self.fixture["appList"].parent}
        def expand(value):
            for key, path in placeholders.items():
                value = value.replace(key, str(path))
            return value
        def edit(data):
            for record in data["commands"].values():
                kind = ("XCTest" if "-bundle" in record["args"] else
                        "Core" if "ClavuneCore.LinkFileList" in " ".join(record["args"]) else "TestableApp")
                record["args"] = list(map(expand, HOST_LINK_ARGS[kind]))
                for flag in ["-object_path_lto", "-dependency_info"]:
                    index = record["args"].index(flag)
                    self.assertEqual(record["args"][index + 1], "-Xlinker")
                    record["outputs"].append(record["args"][index + 2])
        self.edit_manifest(edit)
        self.assertEqual(len(self.binding()["linkRecords"]), 3)
        original = self.fixture["manifest"].read_bytes()
        for extra in [["@loader_path"], ["-Xlinker", "@loader_path"],
                      ["-Xlinker", "-rpath", "-Xlinker", "@override.rsp"]]:
            self.fixture["manifest"].write_bytes(original)
            self.edit_manifest(lambda data: next(record for record in data["commands"].values()
                if "-bundle" in record["args"])["args"].extend(extra))
            with self.subTest(extra=extra), self.assertRaises(RUNNER.EvidenceError):
                self.binding()

    def test_same_source_twice_on_payload_chain_is_ambiguous(self):
        product = str(self.fixture["objects"]["Clavune"])
        with self.fixture["finalList"].open("a") as output: output.write(" " + shlex.quote(product))
        self.edit_manifest(lambda data: next(record for record in data["commands"].values() if "-bundle" in record["args"])["inputs"].append(product))
        with self.assertRaisesRegex(RUNNER.EvidenceError, "Required source object is absent or ambiguous"):
            self.binding()

    def test_declared_link_inputs_must_corroborate_response_objects(self):
        missing = str(self.fixture["objects"]["ClavuneCore"])
        self.edit_manifest(lambda data: next(record for record in data["commands"].values() if missing in record["inputs"])["inputs"].remove(missing))
        with self.assertRaises(RUNNER.EvidenceError): self.binding()

    def test_link_command_output_must_equal_selected_payload(self):
        def edit(data):
            record = next(record for record in data["commands"].values() if "-bundle" in record["args"])
            record["args"][record["args"].index("-o") + 1] = str(self.scratch / "wrong-payload")
        self.edit_manifest(edit)
        with self.assertRaises(RUNNER.EvidenceError): self.binding()

    def test_dependency_rule_wrong_source_is_invalid(self):
        obj = self.fixture["objects"]["ClavuneCore"]
        obj.with_suffix(".d").write_text(make_path_word(obj) + " : " + make_path_word(self.root / "other/CaptureService.swift") + "\n")
        with self.assertRaises(RUNNER.EvidenceError): self.binding()

    def test_binding_artifact_changes_are_rejected(self):
        binding = self.binding()
        self.fixture["coreList"].write_text("changed")
        with self.assertRaises(RUNNER.EvidenceError): RUNNER.verify_swiftbuild_binding(self.scratch, binding)

    def test_duplicate_manifest_is_invalid(self):
        duplicate = self.scratch / "out/Intermediates.noindex/XCBuildData/second.xcbuilddata/manifest.json"
        duplicate.parent.mkdir(); duplicate.write_bytes(self.fixture["manifest"].read_bytes())
        with self.assertRaises(RUNNER.EvidenceError): self.binding()

    def test_basename_only_host_log_with_bound_graph_passes_real_stage(self):
        evidence = self.root / "evidence"; evidence.mkdir()
        owned = self.root / "owned"; owned.mkdir()
        selected = ["ClavuneCoreTests.AppCoordinatorIntegrationTests/testFixture"]
        stage_calls = []
        def command(argv, cwd, environment, logfile, timeout=0):
            stage_calls.append(argv)
            if "--build-tests" in argv:
                scratch = Path(argv[argv.index("--scratch-path") + 1])
                self.make_fixture(cwd, scratch)
                logfile.write_text("Compile AppCoordinator.swift\n    builtin-SwiftPerFileCompile AppCoordinator.swift\n"
                    "Compile CaptureService.swift\n    builtin-SwiftPerFileCompile CaptureService.swift\n"
                    "Compile AppCoordinatorIntegrationTests.swift\n    builtin-SwiftPerFileCompile AppCoordinatorIntegrationTests.swift\n"
                    "Build complete! (18,85 sec)\n")
            else:
                logfile.write_text(log(name=selected[0], failure=False))
            return {"exitCode": 0, "logComplete": True, "timedOut": False}
        tools = {"swift": "/fixture/swift", "xctest": "/fixture/xctest", "platformPath": "/fixture/platform"}
        with mock.patch.object(RUNNER, "run_command", side_effect=command):
            result = RUNNER.stage(self.source, [RUNNER.APP, RUNNER.SERVICE, RUNNER.TEST_SOURCE], evidence, owned,
                                  "baseline", tools, selected)
        self.assertEqual(result["outcome"], "passed", result.get("reason"))
        self.assertEqual(len(stage_calls), 2)
        self.assertIn("compileBinding", result)

    def test_additional_response_or_direct_object_arguments_are_invalid(self):
        original = self.fixture["manifest"].read_bytes()
        product = str(self.fixture["objects"]["Clavune"])
        for extra in [["@" + str(self.scratch / "override.rsp")], ["-Wl,-o," + str(self.scratch / "wrong")],
                      ["-o" + str(self.scratch / "wrong")], [product]]:
            self.fixture["manifest"].write_bytes(original)
            def edit(data):
                record = next(record for record in data["commands"].values() if "-bundle" in record["args"])
                record["args"] += extra
                record["inputs"] += extra
            self.edit_manifest(edit)
            with self.subTest(extra=extra), self.assertRaises(RUNNER.EvidenceError): self.binding()

    def test_selected_response_must_be_a_direct_driver_input(self):
        original = self.fixture["manifest"].read_bytes()
        response = "@" + str(self.fixture["finalList"])
        contexts = [["-Xlinker", "-rpath", "-Xlinker"],
                    ["-Xlinker", "-add_ast_path", "-Xlinker"],
                    ["-Xlinker"], ["-Xclang-linker"],
                    ["-sdk"], ["-target"], ["-Fsystem"], ["-iframework"],
                    ["-framework"], ["-o"], ["-unobserved-option"], ["-load-plugin-library"]]
        for context in contexts:
            self.fixture["manifest"].write_bytes(original)
            def edit(data):
                record = next(record for record in data["commands"].values() if "-bundle" in record["args"])
                index = record["args"].index(response)
                record["args"][index:index + 1] = context + [response]
            self.edit_manifest(edit)
            with self.subTest(context=context), self.assertRaises(RUNNER.EvidenceError):
                self.binding()

    def test_intermediate_filelist_must_be_a_genuine_driver_option(self):
        original = self.fixture["manifest"].read_bytes()
        for context in [["-Xlinker"], ["-Xclang-linker"], ["-sdk"], ["-target"],
                        ["-unobserved-option"]]:
            self.fixture["manifest"].write_bytes(original)
            def edit(data):
                record = next(record for record in data["commands"].values()
                              if str(self.fixture["coreList"]) in record["inputs"])
                index = record["args"].index("-filelist")
                record["args"][index:index] = context
            self.edit_manifest(edit)
            with self.subTest(context=context), self.assertRaises(RUNNER.EvidenceError):
                self.binding()

    def test_new_or_changed_unselected_output_map_invalidates_binding(self):
        binding = self.binding()
        product_map = self.fixture["maps"]["Clavune"]
        original = product_map.read_bytes()
        product_map.write_text("{}")
        with self.assertRaises(RUNNER.EvidenceError): RUNNER.verify_swiftbuild_binding(self.scratch, binding)
        product_map.write_bytes(original)
        extra = product_map.with_name("Extra-OutputFileMap.json"); extra.write_bytes(original)
        with self.assertRaises(RUNNER.EvidenceError): RUNNER.verify_swiftbuild_binding(self.scratch, binding)

    def test_map_added_after_candidate_scan_is_not_adopted_into_inventory(self):
        original = RUNNER.swift_source_candidates
        def candidates(*args, **kwargs):
            result = original(*args, **kwargs)
            existing = self.fixture["maps"]["ClavuneApp--52AC4B1E48BB6C07-testable"]
            existing.with_name("Extra-OutputFileMap.json").write_bytes(existing.read_bytes())
            return result
        with mock.patch.object(RUNNER, "swift_source_candidates", side_effect=candidates):
            with self.assertRaises(RUNNER.EvidenceError): self.binding()

    def test_shared_graph_object_cannot_reset_hash_on_second_visit(self):
        obj = self.fixture["objects"]["ClavuneCore"]
        with self.fixture["appList"].open("a") as stream: stream.write(" " + shlex.quote(str(obj)))
        self.edit_manifest(lambda data: next(record for record in data["commands"].values()
            if str(self.fixture["appList"]) in record["inputs"])["inputs"].append(str(obj)))
        original = RUNNER.sha
        visits = 0
        def sha(path):
            nonlocal visits
            if path == obj:
                visits += 1
                if visits == 2: path.write_bytes(b"changed object")
            return original(path)
        with mock.patch.object(RUNNER, "sha", side_effect=sha):
            with self.assertRaisesRegex(RUNNER.EvidenceError, "Link graph object changed between visits"):
                self.binding()

    def test_record_hash_binds_exact_parsed_bytes_not_later_reread(self):
        target = self.fixture["maps"]["ClavuneCore"]
        original_reader = RUNNER.read_build_json
        def reader(path, *args, **kwargs):
            parsed = original_reader(path, *args, **kwargs)
            if path == target:
                path.write_text("{}")
            return parsed
        with mock.patch.object(RUNNER, "read_build_json", side_effect=reader):
            with self.assertRaises(RUNNER.EvidenceError): self.binding()


if __name__ == "__main__":
    unittest.main()
