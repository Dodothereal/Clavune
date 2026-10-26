#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Python captures each compiler/test status directly, never through a tee pipeline.
exec python3 - "$@" <<'PY'
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description="Exact batch and bridge-under-fakes contracts; no backend/model execution.")
parser.add_argument("--sanitize", action="store_true")
parser.add_argument("--build-only", action="store_true", help="Build fresh payloads and emit their manifest; do not execute them.")
args = parser.parse_args()
root = Path.cwd().resolve()
output = root / ".build/native-contracts"
if ((root / ".build").is_symlink() or output.is_symlink()
        or not output.resolve().is_relative_to(root)):
    raise SystemExit("Unsafe native output directory.")
output.mkdir(parents=True, exist_ok=True)
lock_path = output / ".writer.lock"
if lock_path.is_symlink():
    raise SystemExit("Unsafe native writer lock.")
lock = lock_path.open("a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit("Another native contract writer owns this namespace; no build started.")
runs = output / "runs"
runs.mkdir(exist_ok=True)
if runs.is_symlink():
    raise SystemExit("Unsafe native evidence directory.")
run = Path(tempfile.mkdtemp(prefix="sanitized-" if args.sanitize else "normal-", dir=runs))
manifest_path = run / "manifest.json"
report = {"schemaVersion": 1, "status": "running", "mode": "sanitized" if args.sanitize else "normal",
          "buildOnly": args.build_only, "workingDirectory": str(root), "commands": [], "payloads": {},
          "coverage": "Exact extracted batch and actual bridge under fakes, not GGML/Metal/model-initializer/OOM integration."}
stop_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
interrupted_signal = None
launching_child = False

class NativeInterrupted(RuntimeError):
    def __init__(self, signum):
        self.signum = signum
        super().__init__("Interrupted by " + signal.Signals(signum).name)

def interrupt_run(signum, _frame):
    global interrupted_signal
    interrupted_signal = signum
    # A second catchable stop must not interrupt owned-child cleanup/reporting.
    for stop_signal in stop_signals:
        signal.signal(stop_signal, signal.SIG_IGN)
    # Do not lose a newly created child's handle between Popen and assignment.
    if not launching_child:
        raise NativeInterrupted(signum)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def relative(path):
    return str(path.relative_to(root))

def save():
    temporary = manifest_path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(manifest_path)

def command(label, argv, env=None, timeout=180):
    global launching_child
    log = run / ("%02d-" % len(report["commands"]) + label + ".log")
    record = {"label": label, "command": argv, "log": relative(log), "status": "running"}
    report["commands"].append(record)
    save()
    with log.open("xb") as stream:
        process = None
        def stop_owned_process_group():
            if process is not None:
                previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, stop_signals)
                try:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        try:
            launching_child = True
            try:
                process = subprocess.Popen(argv, cwd=root, env=env, stdout=stream,
                                           stderr=subprocess.STDOUT, start_new_session=True)
            finally:
                launching_child = False
            if interrupted_signal is not None:
                raise NativeInterrupted(interrupted_signal)
            record.update(status="completed", exitCode=process.wait(timeout=timeout))
        except subprocess.TimeoutExpired:
            stop_owned_process_group()
            record.update(status="timeout", exitCode=None)
        except OSError as error:
            stop_owned_process_group()
            record.update(status="launch-error", exitCode=None, error=str(error))
        except BaseException:
            stop_owned_process_group()
            record.update(status="interrupted", exitCode=None)
            save()
            raise
        stream.flush()
        os.fsync(stream.fileno())
    save()
    text = log.read_text(errors="replace")
    if record["status"] != "completed":
        raise RuntimeError(label + ": " + record["status"] + "; invalid evidence")
    return record, text

def checked(label, argv):
    record, text = command(label, argv)
    if record["exitCode"] != 0:
        raise RuntimeError(label + " failed; invalid evidence (see " + record["log"] + ")")
    return record, text

def verify_sources():
    for name, expected in source_hashes.items():
        path = root / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise RuntimeError("Compile input changed: " + name)
    for name, expected in generated_hashes.items():
        path = generated / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise RuntimeError("Owned generated input changed: " + name)
    checked("verify-inputs", [sys.executable, "Scripts/prepare-native-contract-inputs.py", "--verify-only"])

sanitizer_diagnostic = re.compile(r"runtime error:|AddressSanitizer|UndefinedBehaviorSanitizer|LeakSanitizer|Sanitizer CHECK failed", re.I)
try:
    for stop_signal in stop_signals:
        signal.signal(stop_signal, interrupt_run)
    report["baseRevision"] = None
    report["baseRevisionStatus"] = "unavailable"
    git = shutil.which("git")
    if git:
        revision_record, revision_text = command("source-revision", [git, "rev-parse", "--verify", "HEAD"])
        if revision_record["exitCode"] == 0 and re.fullmatch(r"[0-9a-f]{40}\n?", revision_text):
            report["baseRevision"] = revision_text.strip()
            report["baseRevisionStatus"] = "local-HEAD"
    compiler = shutil.which(os.environ.get("CXX", "c++"))
    if not compiler:
        raise RuntimeError("Installed C++ compiler not found; no downloads attempted")
    compiler = str(Path(compiler).resolve())
    report["compilerPath"] = compiler
    report["compilerSHA256"] = digest(Path(compiler))
    checked("compiler-version", [compiler, "--version"])
    flags = ["-std=c++17", "-O0", "-g", "-Wall", "-Wextra", "-Werror", "-UNDEBUG"]
    if args.sanitize:
        flags += ["-fsanitize=address,undefined", "-fno-sanitize-recover=undefined", "-fno-omit-frame-pointer"]
    report["compilerFlags"] = flags
    report["compilerEnvironment"] = {key: os.environ.get(key) for key in (
        "CXX", "PATH", "CPATH", "CPLUS_INCLUDE_PATH", "C_INCLUDE_PATH", "LIBRARY_PATH",
        "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")}
    # Explicit options prevent an inherited recover/log_path setting hiding diagnostics.
    environment = dict(os.environ)
    if args.sanitize:
        environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
        environment["ASAN_OPTIONS"] = "halt_on_error=1:abort_on_error=0"
    report["sanitizerEnvironment"] = {key: environment.get(key) for key in ("ASAN_OPTIONS", "UBSAN_OPTIONS")}
    checked("prepare-inputs", [sys.executable, "Scripts/prepare-native-contract-inputs.py"])
    inputs_path = output / "generated/compile-inputs.json"
    inputs = json.loads(inputs_path.read_text())
    generated = run / "generated"
    generated.mkdir()
    for name in [*inputs["generatedInputs"], "compile-inputs.json"]:
        shutil.copyfile(output / "generated" / name, generated / name)
    generated_hashes = {path.name: digest(path) for path in generated.iterdir()}
    source_hashes = dict(inputs["compiledInputs"])
    control_source = "Tests/Native/SanitizerFailureControl.cpp"
    source_hashes[control_source] = digest(root / control_source)
    report.update(sourceSHA256=source_hashes, generatedSHA256=generated_hashes,
                  verifiedCompileInputs=relative(generated / "compile-inputs.json"))
    includes = ["-I", relative(generated), "-I", "Sources/NativeBridge/include",
                "-I", ".build/deps/whisper.cpp/include", "-I", ".build/deps/whisper.cpp/src",
                "-I", ".build/deps/whisper.cpp/ggml/include"]
    targets = {"production-batch": ["Tests/Native/ProductionBatchTests.cpp"],
               "bridge-contract": ["Sources/NativeBridge/WhisperBridge.cpp", "Tests/Native/BridgeContractTests.cpp"]}
    if args.sanitize:
        targets["sanitizer-control"] = [control_source]
    for name, sources in targets.items():
        verify_sources()
        payload = run / name
        # -v retains the effective compiler/linker/include paths, not only the frontend name.
        argv = [compiler, *flags, "-v", *includes, *sources, "-o", relative(payload)]
        record, _ = checked("build-" + name, argv)
        if payload.is_symlink() or not payload.is_file() or not os.access(payload, os.X_OK):
            raise RuntimeError(name + ": successful compiler did not produce the expected executable")
        verify_sources()
        report["payloads"][name] = {"path": relative(payload), "sha256": digest(payload),
                                    "buildExitCode": record["exitCode"], "buildCommand": argv,
                                    "buildLog": record["log"], "translationUnits": sources,
                                    "sourceSHA256": dict(source_hashes)}
        save()

    def execute(name, argv=()):
        verify_sources()
        entry = report["payloads"][name]
        payload = root / entry["path"]
        if payload.is_symlink() or digest(payload) != entry["sha256"]:
            raise RuntimeError(name + ": payload changed before execution")
        record, text = command("execute-" + name, [str(payload), *argv], env=environment)
        entry["execution"] = {**record, "executedPayloadSHA256": digest(payload)}
        if digest(payload) != entry["sha256"]:
            raise RuntimeError(name + ": payload changed during execution")
        verify_sources()
        return record["exitCode"], text

    if not args.build_only:
        if args.sanitize:
            code, text = execute("sanitizer-control")
            source_lines = (root / control_source).read_text().splitlines()
            sites = [i for i, line in enumerate(source_lines, 1) if "// UBSAN_CONTROL_SITE" in line]
            if len(sites) != 1:
                raise RuntimeError("Control diagnostic site is absent or ambiguous")
            expected = r"(?:^|\n)(?:[^\n]*[/\\])?SanitizerFailureControl\.cpp:" + str(sites[0]) + r":\d+: runtime error: signed integer overflow: [^\n]+"
            diagnostics = [line for line in text.splitlines() if "runtime error:" in line]
            valid = (code > 0 and text.count("UBSAN_CONTROL_START signed_integer_overflow") == 1
                     and "UBSAN_CONTROL_UNEXPECTED_SURVIVAL" not in text and len(diagnostics) == 1
                     and re.search(expected, text) is not None
                     and not re.search(r"AddressSanitizer|LeakSanitizer|DEADLYSIGNAL|CHECK failed", text, re.I))
            report["sanitizerControl"] = {"valid": valid, "expectedDiagnosticPattern": expected,
                                          "source": control_source, "sourceLine": sites[0], "exitCode": code}
            save()
            if not valid:
                raise RuntimeError("UBSan control lacks its intended source-bound fatal diagnostic; INVALID")
        code, text = execute("production-batch")
        expected_batch = "Exact production batch init/free passed: 10 allocation failures, typed success, empty cleanup, 6 invalid dimensions; 4 cycles."
        if code != 0 or text.count(expected_batch) != 1 or sanitizer_diagnostic.search(text):
            raise RuntimeError("Production batch did not pass cleanly")
        code, text = execute("bridge-contract")
        expected_tests = re.findall(r'\{"(BridgeContractTests\.[A-Za-z_]+)",',
                                    (root / "Tests/Native/BridgeContractTests.cpp").read_text())
        starts = re.findall(r"^NATIVE_TEST_START (\S+)$", text, re.M)
        passes = re.findall(r"^NATIVE_TEST_PASS (\S+)$", text, re.M)
        if (code != 0 or not expected_tests or len(expected_tests) != len(set(expected_tests))
                or starts != expected_tests or passes != expected_tests
                or re.findall(r"^NATIVE_TEST_COUNT (\d+)$", text, re.M) != [str(len(expected_tests))]
                or re.findall(r"^NATIVE_TEST_COMPLETE (\d+)$", text, re.M) != [str(len(expected_tests))]
                or sanitizer_diagnostic.search(text)):
            raise RuntimeError("Bridge contracts did not execute all exact named tests cleanly")
        report["bridgeTests"] = {"expected": expected_tests, "passed": passes, "count": len(passes)}
    verify_sources()
    report["status"] = "built" if args.build_only else "passed"
    save()
    print("NATIVE_CONTRACT_MANIFEST=" + relative(manifest_path), flush=True)
    print("Native contracts " + report["status"] + "; exact batch and bridge under fakes only.")
except NativeInterrupted as error:
    for record in report["commands"]:
        if record["status"] == "running":
            record.update(status="interrupted", exitCode=None)
    report.update(status="interrupted", error=str(error), signal=error.signum)
    save()
    print("NATIVE_CONTRACT_MANIFEST=" + relative(manifest_path), flush=True)
    print("Native contract gate interrupted; invalid evidence: " + str(error), file=sys.stderr)
    raise SystemExit(128 + error.signum)
except (OSError, ValueError, RuntimeError, KeyError) as error:
    report.update(status="invalid", error=str(error))
    save()
    print("NATIVE_CONTRACT_MANIFEST=" + relative(manifest_path), flush=True)
    print("Native contract gate failed: " + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
