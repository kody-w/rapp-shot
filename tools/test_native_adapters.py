#!/usr/bin/env python3
"""No-capture adapter tests. Every process launch is mocked."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import types
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse
import uuid


ROOT = Path(__file__).resolve().parent.parent


class BasicAgent:
    def __init__(self, *_args):
        pass


def load_adapters():
    base = types.ModuleType("agents.basic_agent")
    base.BasicAgent = BasicAgent
    agents = types.ModuleType("agents")
    with patch.dict(sys.modules, {"agents": agents, "agents.basic_agent": base}):
        loaded = []
        for index, path in enumerate([
            ROOT / "rapp_shot/singleton/rapp_shot_agent.py",
            ROOT / "rapp_shot/twin/agents/rapp_shot_agent.py",
        ]):
            spec = importlib.util.spec_from_file_location(f"shot_adapter_{index}", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            loaded.append(module)
        return loaded


class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adapters = load_adapters()

    def test_native_discovery_validates_bundle_and_respects_cli_override(self):
        directory = ROOT / ".test-artifacts" / ("adapter-" + str(uuid.uuid4()))
        app = directory / "RAPPShot.app"
        executable = app / "Contents/MacOS/RAPPShot"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture executable; never run\n")
        executable.chmod(0o700)
        info = app / "Contents/Info.plist"
        try:
            with info.open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": "io.rapp.shot"}, stream)
            for module in self.adapters:
                with self.subTest(adapter=module.__name__):
                    with patch.dict(os.environ, {"RAPP_SHOT_APP": str(app), "SHOT_CLI": ""}):
                        self.assertEqual(module._native_app(), str(app))
                    with patch.dict(os.environ, {"RAPP_SHOT_APP": str(app), "SHOT_CLI": "/explicit/shot"}):
                        self.assertIsNone(module._native_app())
            with info.open("wb") as stream:
                plistlib.dump(["not a bundle dictionary"], stream)
            for module in self.adapters:
                real_access = os.access
                with patch.dict(os.environ, {"RAPP_SHOT_APP": str(app), "SHOT_CLI": ""}), \
                     patch.object(module.os, "access", side_effect=lambda path, mode: real_access(path, mode) if str(path).startswith(str(directory)) else False):
                    self.assertIsNone(module._native_app())
        finally:
            shutil.rmtree(directory)

    def test_capture_is_staged_without_capture_or_clipboard_execution(self):
        for module in self.adapters:
            for mode in ("region", "window", "screen"):
                with self.subTest(adapter=module.__name__, mode=mode), \
                     patch.object(module, "_native_app", return_value="/fixture/RAPPShot.app"), \
                     patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
                    response = module.RappShotAgent().perform(action="capture", mode=mode, auto=True, copy=True)
                    args = run.call_args.args[0]
                    self.assertEqual(args[:3], ["/usr/bin/open", "-a", "/fixture/RAPPShot.app"])
                    fields = parse_qs(urlparse(args[3]).query)
                    self.assertEqual(fields["mode"], [mode])
                    self.assertEqual(fields["auto"], ["true"])
                    self.assertEqual(fields["copy"], ["true"])
                    self.assertIn("No capture, clipboard write, or export was performed", response)
                    self.assertEqual(run.call_args.kwargs["timeout"], 30)
                    self.assertNotIn("shell", run.call_args.kwargs)

    def test_annotation_paths_and_text_round_trip_without_shell_or_plus_encoding(self):
        for module in self.adapters:
            command, notice = module._native_command("/fixture/RAPPShot.app", [
                "annotate", "/fixture/image with spaces.png",
                "--text", "30,40,a note; $(unexecuted) + punctuation",
                "--crop", "10,20,100,200", "--copy"
            ])
            self.assertIn("%20", command[-1])
            self.assertNotIn("+", command[-1])
            fields = parse_qs(urlparse(command[-1]).query)
            self.assertEqual(fields["image"], ["/fixture/image with spaces.png"])
            self.assertEqual(fields["text"], ["30,40,a note; $(unexecuted) + punctuation"])
            self.assertIn("staged annotate", notice)

    def test_read_only_native_doctor_and_list_use_bounded_executable_modes(self):
        for module in self.adapters:
            for action, expected in [
                (["doctor"], ["--diagnose"]),
                (["list", "--limit", "9"], ["--agent-list", "--limit", "9"])
            ]:
                command, notice = module._native_command("/fixture/RAPPShot.app", action)
                self.assertEqual(command[1:], expected)
                self.assertIsNone(notice)
            with self.assertRaises(ValueError):
                module._native_command("/fixture/RAPPShot.app", ["list", "--limit", "1000"])
            with self.assertRaises(ValueError):
                module._native_command("/fixture/RAPPShot.app", ["annotate", "--shell", "anything"])

    def test_cli_fallback_preserves_existing_actions_and_headless_restrictions(self):
        for module in self.adapters:
            with patch.object(module, "_native_app", return_value=None), \
                 patch.object(module, "_cli", return_value="/legacy/shot"), \
                 patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "fixture result", "")) as run:
                response = module.RappShotAgent().perform(action="capture", mode="screen", auto=True)
                self.assertEqual(run.call_args.args[0], ["/legacy/shot", "capture", "--mode", "screen", "--auto-redact"])
                self.assertEqual(response, "fixture result")
                run.reset_mock()
                response = module.RappShotAgent().perform(action="capture", mode="region")
                self.assertIn("cannot run headlessly", response)
                run.assert_not_called()
                self.assertEqual(module.RappShotAgent.ACTIONS, ("doctor", "capture", "ocr", "redact", "annotate", "list"))

    def test_nonzero_exit_is_an_error_even_with_success_shaped_stdout(self):
        for module in self.adapters:
            with patch.object(module, "_native_app", return_value=None), \
                 patch.object(module, "_cli", return_value="/legacy/shot"), \
                 patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 4, "painted a result", "NOT SAFE TO SHARE")):
                output, error = module._run(["redact", "--auto"])
                self.assertIsNone(output)
                self.assertIn("exited 4", error)
                self.assertIn("NOT SAFE TO SHARE", error)

    def test_failed_native_open_does_not_downgrade_to_a_cli_capture(self):
        for module in self.adapters:
            with patch.object(module, "_native_app", return_value="/fixture/RAPPShot.app"), \
                 patch.object(module, "_cli") as cli, \
                 patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "Launch failed")) as run:
                output, error = module._run(["capture", "--mode", "screen"])
                self.assertIsNone(output)
                self.assertIn("Launch failed", error)
                self.assertEqual(run.call_count, 1)
                cli.assert_not_called()

    def test_both_adapters_have_identical_compatibility_logic(self):
        self.assertEqual((ROOT / "rapp_shot/singleton/rapp_shot_agent.py").read_bytes(),
                         (ROOT / "rapp_shot/twin/agents/rapp_shot_agent.py").read_bytes())


if __name__ == "__main__":
    unittest.main()
