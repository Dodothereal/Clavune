import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[2]
CAPTURE = PROJECT / "Scripts/capture-command.py"


class CaptureCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="clavune-capture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.output = self.root / "new" / "nested" / "evidence"

    def invoke(self, output, command):
        return subprocess.run(
            [sys.executable, str(CAPTURE), "--output-root", str(output), "--", *command],
            cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8,
        )

    def run_directory(self, output):
        runs = sorted(output.glob("run-*"))
        self.assertEqual(len(runs), 1)
        return runs[0]

    def test_preserves_exact_arguments_binary_streams_and_creates_parent(self):
        arguments = ["space arg", "$(literal; do not run)", "quote'and\"unicode-ä"]
        driver = (
            "import json, os, sys; "
            "os.write(1, b'out\\x00\\xff\\n'); "
            "os.write(2, b'err\\x00\\xfe\\n'); "
            "print('ARGS=' + json.dumps(sys.argv[1:], ensure_ascii=False))"
        )
        child = self.invoke(self.output, [sys.executable, "-c", driver, *arguments])

        self.assertEqual(child.returncode, 0, child.stderr.decode(errors="replace"))
        run = self.run_directory(self.output)
        manifest = json.loads((run / "manifest.json").read_text())
        expected_command = [sys.executable, "-c", driver, *arguments]
        self.assertEqual(manifest["command"], expected_command)
        self.assertEqual(manifest["status"], "completed")
        self.assertEqual(manifest["childExitCode"], 0)
        self.assertEqual((run / "stdout.log").read_bytes(), child.stdout)
        self.assertEqual((run / "stderr.log").read_bytes(), b"err\x00\xfe\n")
        self.assertTrue(manifest["logs"]["stdout"]["complete"])
        self.assertTrue(manifest["logs"]["stderr"]["complete"])
        self.assertEqual(manifest["logs"]["stdout"]["byteCount"], len(child.stdout))
        self.assertTrue(manifest["logs"]["stdout"]["sha256"])
        self.assertEqual(child.stderr, b"err\x00\xfe\n")
        self.assertEqual((run.stat().st_mode & 0o077), 0)
        self.assertEqual((run / "stdout.log").stat().st_mode & 0o077, 0)

    def test_returns_child_nonzero_status_and_records_complete_logs(self):
        child = self.invoke(self.output, [sys.executable, "-c", "import sys; print('before-failure'); sys.exit(37)"])

        self.assertEqual(child.returncode, 37)
        run = self.run_directory(self.output)
        manifest = json.loads((run / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "completed")
        self.assertEqual(manifest["childExitCode"], 37)
        self.assertEqual((run / "stdout.log").read_bytes(), child.stdout)
        self.assertIn(b"before-failure\n", child.stdout)
        self.assertTrue(manifest["logs"]["stdout"]["complete"])

    def test_reads_large_stdout_and_stderr_concurrently(self):
        driver = (
            "import os; "
            "[(os.write(1, b'O' * 4096), os.write(2, b'E' * 4096)) for _ in range(256)]"
        )

        child = self.invoke(self.output, [sys.executable, "-c", driver])

        self.assertEqual(child.returncode, 0, child.stderr[-1000:].decode(errors="replace"))
        run = self.run_directory(self.output)
        self.assertEqual((run / "stdout.log").read_bytes(), b"O" * (4096 * 256))
        self.assertEqual((run / "stderr.log").read_bytes(), b"E" * (4096 * 256))

    def test_child_signal_is_recorded_and_mapped_to_shell_status(self):
        child = self.invoke(
            self.output,
            [sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"],
        )

        self.assertEqual(child.returncode, 128 + signal.SIGTERM)
        run = self.run_directory(self.output)
        manifest = json.loads((run / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "completed")
        self.assertEqual(manifest["childExitCode"], -signal.SIGTERM)

    def test_symlink_output_root_fails_before_child_launch(self):
        target = self.root / "target"
        target.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(target, target_is_directory=True)
        marker = self.root / "child-started"
        driver = "from pathlib import Path; Path(" + repr(str(marker)) + ").write_text('started')"

        result = self.invoke(linked, [sys.executable, "-c", driver])

        self.assertEqual(result.returncode, 125)
        self.assertIn(b"command was not started", result.stderr)
        self.assertFalse(marker.exists())
        self.assertEqual(list(target.iterdir()), [])

    def test_absolute_output_parent_symlink_is_resolved_before_creation(self):
        target = self.root / "real-parent"
        target.mkdir()
        link = self.root / "parent-link"
        link.symlink_to(target, target_is_directory=True)
        requested = link / "evidence"

        result = self.invoke(requested, [sys.executable, "-c", "print('captured')"])

        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertEqual(requested.resolve(), target / "evidence")
        run = self.run_directory(target / "evidence")
        manifest = json.loads((run / "manifest.json").read_text())
        self.assertEqual(Path(manifest["evidenceDirectory"]).parent, target / "evidence")
        self.assertEqual((run / "stdout.log").read_bytes(), b"captured\n")

    def interrupt_wrapper(self, command, control, heartbeat):
        wrapper = subprocess.Popen(
            [sys.executable, str(CAPTURE), "--output-root", str(self.output), "--", *command],
            cwd=PROJECT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
        completed = False
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not control.exists():
                if wrapper.poll() is not None:
                    break
                time.sleep(0.02)
            self.assertTrue(control.exists(), "synthetic child did not publish its control record")
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline and not heartbeat.exists():
                time.sleep(0.02)
            self.assertTrue(heartbeat.exists(), "synthetic child did not begin its heartbeat")
            os.kill(wrapper.pid, signal.SIGTERM)
            output, errors = wrapper.communicate(timeout=6)
            self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM,
                             errors.decode(errors="replace") + output.decode(errors="replace"))
            completed = True
            previous = heartbeat.read_text()
            time.sleep(0.12)
            self.assertEqual(heartbeat.read_text(), previous,
                             "owned process group remained alive after wrapper exit")
        finally:
            if not completed:
                if wrapper.poll() is None:
                    wrapper.kill()
                try:
                    wrapper.communicate(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
                if control.exists():
                    try:
                        process_group = json.loads(control.read_text())["processGroup"]
                        os.killpg(process_group, signal.SIGKILL)
                    except (OSError, KeyError, ValueError, json.JSONDecodeError):
                        pass

    def test_signal_escalates_after_leader_exits_with_inherited_pipes_open(self):
        heartbeat = self.root / "grandchild-heartbeat"
        control = self.root / "grandchild-control.json"
        worker = (
            "import pathlib, signal, sys, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "path=pathlib.Path(sys.argv[1]); "
            "exec(\"while True:\\n path.write_text(str(time.monotonic_ns())); time.sleep(0.02)\")"
        )
        parent = (
            "import json, os, pathlib, signal, subprocess, sys, time; "
            "worker=" + repr(worker) + "; "
            "child=subprocess.Popen([sys.executable, '-c', worker, sys.argv[1]]); "
            "pathlib.Path(sys.argv[2]).write_text(json.dumps({'processGroup': os.getpgrp(), 'child': child.pid})); "
            "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); time.sleep(30)"
        )
        self.interrupt_wrapper([sys.executable, "-c", parent, str(heartbeat), str(control)], control, heartbeat)
        run = self.run_directory(self.output)
        manifest = json.loads((run / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "interrupted")
        self.assertTrue(manifest["logs"]["stdout"]["complete"])
        self.assertTrue(manifest["logs"]["stderr"]["complete"])

    def test_signal_escalates_when_child_closes_both_output_pipes(self):
        heartbeat = self.root / "closed-pipe-heartbeat"
        control = self.root / "closed-pipe-control.json"
        child = (
            "import json, os, pathlib, signal, sys, time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "pathlib.Path(sys.argv[1]).write_text(json.dumps({'processGroup': os.getpgrp(), 'child': os.getpid()})); "
            "os.close(1); os.close(2); path=pathlib.Path(sys.argv[2]); "
            "exec(\"while True:\\n path.write_text(str(time.monotonic_ns())); time.sleep(0.02)\")"
        )
        self.interrupt_wrapper([sys.executable, "-c", child, str(control), str(heartbeat)], control, heartbeat)
        run = self.run_directory(self.output)
        manifest = json.loads((run / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "interrupted")
        self.assertTrue(manifest["logs"]["stdout"]["complete"])
        self.assertTrue(manifest["logs"]["stderr"]["complete"])

    def test_swift_wrapper_preserves_stdout_for_command_substitution(self):
        binaries = self.root / "bin"
        binaries.mkdir()
        fake_swift = binaries / "swift"
        fake_swift.write_text(
            "#!" + sys.executable + "\n"
            "import os, sys\n"
            "os.write(1, b'/synthetic/build path\\n')\n"
            "os.write(2, b'synthetic diagnostic\\n')\n"
        )
        fake_swift.chmod(0o700)
        capture_root = self.root / "swift-logs"
        environment = dict(os.environ)
        environment["PATH"] = str(binaries) + os.pathsep + environment.get("PATH", "")
        environment["CLAVUNE_SWIFT_CAPTURE_ROOT"] = str(capture_root)

        wrapped = subprocess.run(
            ["bash", "-c", 'bin="$(bash Scripts/swift.sh build --show-bin-path)" || exit $?; '
             'test "$bin" = "/synthetic/build path" || exit 89; printf "%s\\n" "$bin"'],
            cwd=PROJECT, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8,
        )

        self.assertEqual(wrapped.returncode, 0, wrapped.stderr.decode(errors="replace"))
        self.assertEqual(wrapped.stdout, b"/synthetic/build path\n")
        self.assertEqual(wrapped.stderr, b"synthetic diagnostic\n")
        run = self.run_directory(capture_root)
        manifest = json.loads((run / "manifest.json").read_text())
        self.assertEqual(manifest["command"][:3], ["swift", "build", "--show-bin-path"])
        self.assertEqual((run / "stdout.log").read_bytes(), wrapped.stdout)
        self.assertEqual((run / "stderr.log").read_bytes(), b"synthetic diagnostic\n")
        self.assertEqual(manifest["childExitCode"], 0)


if __name__ == "__main__":
    unittest.main()
