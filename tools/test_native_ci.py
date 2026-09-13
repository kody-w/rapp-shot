#!/usr/bin/env python3
"""Unit checks for the safe CI runner. No real process or screen operation."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import native_ci


class NativeCITests(unittest.TestCase):
    def test_environment_is_project_local_and_noninteractive(self):
        work = native_ci.ROOT / ".test-artifacts" / "unit-ci"
        with patch.dict(native_ci.os.environ, {"GIT_CONFIG_PARAMETERS": "inherited-private-settings"}):
            env = native_ci.isolated_environment(work)
        self.assertNotIn("GIT_CONFIG_PARAMETERS", env)
        self.assertEqual(env["TMPDIR"], str(work / "compiler-work"))
        self.assertEqual(env["SHOT_HOME"], str(work / "shot-home"))
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], "/dev/null")
        self.assertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        self.assertEqual(env["GIT_CONFIG_VALUE_1"], "")

    def test_valid_startup_and_real_dependency_pins(self):
        native_ci.verify_startup({
            "uiStartup": "passed", "captureState": "idle", "hasImage": False,
            "captureAttempts": 0, "permissionRequests": 0, "sourceEnumerationAttempts": 0,
            "clipboardWritten": False, "visibleMainWindows": 1,
        })
        native_ci.verify_pins()

    def test_capture_permission_clipboard_and_missing_window_fail(self):
        good = {
            "uiStartup": "passed", "captureState": "idle", "hasImage": False,
            "captureAttempts": 0, "permissionRequests": 0, "sourceEnumerationAttempts": 0,
            "clipboardWritten": False, "visibleMainWindows": 1,
        }
        for key, value in [("captureAttempts", 1), ("permissionRequests", 1),
                           ("sourceEnumerationAttempts", 1), ("clipboardWritten", True),
                           ("hasImage", True), ("visibleMainWindows", 0)]:
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                native_ci.verify_startup({**good, key: value})
        with self.assertRaises(RuntimeError):
            native_ci.verify_startup({})

    def test_a_moved_dependency_revision_fails(self):
        content = json.loads(native_ci.LOCKS[0].read_text())
        content["pins"][0]["state"]["revision"] = "0" * 40
        with patch.object(Path, "read_text", return_value=json.dumps(content)), self.assertRaises(RuntimeError):
            native_ci.verify_pins()


if __name__ == "__main__":
    unittest.main()
