#!/usr/bin/env python3
"""Capture a command's exact stdout, stderr, arguments, and exit status."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import uuid


CAPTURE_ERROR = 125


def parse_arguments(argv: list[str]) -> tuple[Path, list[str]]:
    try:
        separator = argv.index("--")
    except ValueError as error:
        raise ValueError("expected -- followed by a command and its arguments") from error
    options = argv[:separator]
    command = argv[separator + 1 :]
    if len(options) != 2 or options[0] != "--output-root" or not options[1]:
        raise ValueError("usage: capture-command.py --output-root DIR -- COMMAND [ARG ...]")
    if not command or not command[0]:
        raise ValueError("a command is required after --")
    return Path(options[1]), command


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def prepare_output_root(raw_root: Path) -> Path:
    if raw_root.is_absolute():
        if raw_root.is_symlink():
            raise OSError("refusing a symlink output directory")
        # Resolve every existing ancestor before creating anything. This also
        # handles conventional macOS aliases such as /tmp -> /private/tmp.
        root = raw_root.parent.resolve(strict=False) / raw_root.name
    else:
        root = Path.cwd() / raw_root
        cursor = Path.cwd()
        for component in raw_root.parts:
            if component in {"", "."}:
                continue
            if component == "..":
                cursor = cursor.parent
            else:
                cursor = cursor / component
            if cursor.is_symlink():
                raise OSError("refusing a symlink in the relative output path")
    if root.is_symlink():
        raise OSError("refusing a symlink output directory")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink() or not root.is_dir():
        raise OSError("output root is not a regular directory")
    return root.resolve(strict=True)


def create_private_file(path: Path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    return os.fdopen(descriptor, "wb")


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def save_manifest(path: Path, report: dict) -> None:
    temporary = path.parent / (".manifest-" + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    except BaseException:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def terminate_child(process: subprocess.Popen, signum: int = signal.SIGTERM) -> None:
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline and process_group_exists(process.pid):
        process.poll()
        time.sleep(0.05)
    if process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    process.wait()


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def shell_exit_status(child_status: int) -> int:
    return child_status if child_status >= 0 else min(255, 128 - child_status)


def run(output_root: Path, command: list[str]) -> int:
    try:
        root = prepare_output_root(output_root)
        run_directory = Path(tempfile.mkdtemp(prefix="run-", dir=root))
        os.chmod(run_directory, 0o700)
        stdout_path = run_directory / "stdout.log"
        stderr_path = run_directory / "stderr.log"
        manifest_path = run_directory / "manifest.json"
        stdout_log = create_private_file(stdout_path)
        stderr_log = create_private_file(stderr_path)
        report = {
            "schemaVersion": 1,
            "status": "prepared",
            "command": command,
            "workingDirectory": str(Path.cwd()),
            "evidenceDirectory": str(run_directory),
            "startedAtUTC": utc_now(),
            "logs": {
                "stdout": {"path": "stdout.log", "complete": False, "byteCount": 0},
                "stderr": {"path": "stderr.log", "complete": False, "byteCount": 0},
            },
            "childExitCode": None,
        }
        save_manifest(manifest_path, report)
    except (OSError, ValueError) as error:
        print("capture-command: could not prepare evidence; command was not started: " + str(error), file=sys.stderr)
        return CAPTURE_ERROR

    process = None
    caught_signal = None
    capture_failure = None
    previous_handlers = {}

    def forward_signal(signum, _frame):
        nonlocal caught_signal
        if caught_signal is None:
            caught_signal = signum
            if process is not None:
                try:
                    os.killpg(process.pid, signum)
                except ProcessLookupError:
                    pass

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous_handlers[signum] = signal.signal(signum, forward_signal)

    try:
        if caught_signal is not None:
            report.update(status="interrupted-before-launch", completedAtUTC=utc_now())
            for log in (stdout_log, stderr_log):
                log.flush()
                os.fsync(log.fileno())
            report["logs"]["stdout"].update(complete=True, sha256=hashlib.sha256().hexdigest())
            report["logs"]["stderr"].update(complete=True, sha256=hashlib.sha256().hexdigest())
            save_manifest(manifest_path, report)
            return 128 + caught_signal
        try:
            process = subprocess.Popen(
                command,
                cwd=Path.cwd(),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=0,
                start_new_session=True,
            )
        except OSError as error:
            report.update(status="launch-error", launchError=str(error), completedAtUTC=utc_now())
            save_manifest(manifest_path, report)
            print("capture-command: command could not be started: " + str(error), file=sys.stderr)
            return 127

        hashes = {"stdout": hashlib.sha256(), "stderr": hashlib.sha256()}
        destinations = {"stdout": stdout_log, "stderr": stderr_log}
        consoles = {"stdout": sys.stdout.buffer, "stderr": sys.stderr.buffer}
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        termination_deadline = None
        try:
            while selector.get_map() or process.poll() is None or termination_deadline is not None:
                if caught_signal is not None and termination_deadline is None:
                    termination_deadline = time.monotonic() + 2
                if termination_deadline is not None and not process_group_exists(process.pid):
                    termination_deadline = None
                if termination_deadline is not None and time.monotonic() >= termination_deadline:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    termination_deadline = None
                if selector.get_map():
                    events = selector.select(timeout=0.1)
                else:
                    time.sleep(0.1)
                    events = []
                for key, _ in events:
                    stream_name = key.data
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    try:
                        destinations[stream_name].write(chunk)
                        destinations[stream_name].flush()
                    except OSError as error:
                        capture_failure = "cannot write " + stream_name + " log: " + str(error)
                        terminate_child(process)
                        break
                    hashes[stream_name].update(chunk)
                    report["logs"][stream_name]["byteCount"] += len(chunk)
                    try:
                        consoles[stream_name].write(chunk)
                        consoles[stream_name].flush()
                    except OSError:
                        # The private log remains authoritative if a caller closes its pipe.
                        pass
                if capture_failure is not None:
                    break
        finally:
            selector.close()

        if capture_failure is not None:
            for stream in (process.stdout, process.stderr):
                try:
                    stream.close()
                except OSError:
                    pass
            child_status = process.wait()
            report.update(status="capture-error", captureError=capture_failure,
                          childExitCode=child_status, completedAtUTC=utc_now())
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
            stdout_log.flush()
            stderr_log.flush()
            save_manifest(manifest_path, report)
            print("capture-command: " + capture_failure + "; child was stopped; evidence is incomplete",
                  file=sys.stderr)
            return CAPTURE_ERROR

        child_status = process.wait()
        process.stdout.close()
        process.stderr.close()
        for stream_name, log in destinations.items():
            log.flush()
            os.fsync(log.fileno())
            report["logs"][stream_name].update(complete=True, sha256=hashes[stream_name].hexdigest())
        report.update(status="interrupted" if caught_signal is not None else "completed",
                      childExitCode=child_status, completedAtUTC=utc_now())
        save_manifest(manifest_path, report)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if caught_signal is not None:
            return 128 + caught_signal
        return shell_exit_status(child_status)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        if process is not None and process.poll() is None:
            terminate_child(process)
        for stream in (process.stdout, process.stderr) if process is not None else ():
            try:
                stream.close()
            except OSError:
                pass
        report.update(status="capture-error", captureError=str(error), completedAtUTC=utc_now())
        try:
            save_manifest(manifest_path, report)
        except OSError:
            pass
        print("capture-command: evidence could not be completed: " + str(error), file=sys.stderr)
        return CAPTURE_ERROR
    finally:
        try:
            stdout_log.close()
            stderr_log.close()
        except OSError:
            pass
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def main() -> int:
    try:
        output_root, command = parse_arguments(sys.argv[1:])
    except ValueError as error:
        print("capture-command: " + str(error), file=sys.stderr)
        return CAPTURE_ERROR
    return run(output_root, command)


if __name__ == "__main__":
    raise SystemExit(main())
