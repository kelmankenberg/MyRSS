import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / "state.py"
spec = importlib.util.spec_from_file_location("private_state", HELPER)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "reading" / "state.json"
        self.data = {"feeds": [{"url": "https://example.com/feed"}],
                     "session": {"searchText": "private search"},
                     "readIds": ["private-id"], "savedArticles": [{"title": "Saved"}]}
        previous = os.umask(0o022)
        self.addCleanup(os.umask, previous)

    def mode(self, path):
        return stat.S_IMODE(path.stat().st_mode)

    def test_first_save_and_atomic_updates_are_private_under_umask_022(self):
        original_replace = os.replace

        def checked_replace(source, destination, **kwargs):
            info = os.stat(source, dir_fd=kwargs["src_dir_fd"])
            self.assertEqual(stat.S_IMODE(info.st_mode), 0o600)
            self.assertEqual(self.mode(self.path.parent), 0o700)
            return original_replace(source, destination, **kwargs)

        with patch.object(state.os, "replace", side_effect=checked_replace):
            state.access_state(self.path, self.data)
            state.access_state(self.path, {**self.data, "readIds": ["updated"]})
        self.assertEqual(self.mode(self.path), 0o600)
        self.assertEqual(state.access_state(self.path)["readIds"], ["updated"])
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_loading_repairs_existing_modes_without_losing_data(self):
        self.path.parent.mkdir(mode=0o755)
        self.path.write_text(json.dumps(self.data))
        self.assertEqual(self.mode(self.path), 0o644)
        self.assertEqual(state.access_state(self.path), self.data)
        self.assertEqual(self.mode(self.path.parent), 0o700)
        self.assertEqual(self.mode(self.path), 0o600)

    def test_failed_permissions_do_not_replace_existing_state(self):
        state.access_state(self.path, self.data)
        with patch.object(state.os, "fchmod", side_effect=PermissionError("Denied")):
            with self.assertRaises(PermissionError):
                state.access_state(self.path, {"feeds": []})
        self.assertEqual(state.access_state(self.path), self.data)

    def test_failed_replace_preserves_state_and_removes_private_temporary(self):
        state.access_state(self.path, self.data)
        with patch.object(state.os, "replace", side_effect=OSError("Disk error")):
            with self.assertRaises(OSError):
                state.access_state(self.path, {"feeds": []})
        self.assertEqual(state.access_state(self.path), self.data)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_symlink_and_hardlink_state_are_rejected(self):
        self.path.parent.mkdir()
        target = Path(self.temporary.name) / "target"
        target.write_text(json.dumps(self.data))
        self.path.symlink_to(target)
        with self.assertRaises(OSError):
            state.access_state(self.path)
        self.path.unlink()
        os.link(target, self.path)
        with self.assertRaises(ValueError):
            state.access_state(self.path)
        self.assertEqual(self.mode(target), 0o644)

    def test_symlink_directory_is_rejected(self):
        target = Path(self.temporary.name) / "target"
        target.mkdir()
        self.path.parent.symlink_to(target)
        with self.assertRaises(OSError):
            state.access_state(self.path, self.data)
        self.assertEqual(self.mode(target), 0o755)

    def test_invalid_existing_state_is_not_overwritten(self):
        self.path.parent.mkdir()
        self.path.write_text("{invalid")
        with self.assertRaises(ValueError):
            state.access_state(self.path, self.data)
        self.assertEqual(self.path.read_text(), "{invalid")

    def test_cli_round_trip_and_visible_errors(self):
        saved = subprocess.run(["python3", str(HELPER), "save", str(self.path)],
                               input=json.dumps(self.data) + "\n", text=True, capture_output=True)
        self.assertEqual(saved.returncode, 0, saved.stdout + saved.stderr)
        loaded = subprocess.run(["python3", str(HELPER), "load", str(self.path)],
                                text=True, capture_output=True)
        self.assertEqual(json.loads(loaded.stdout)["state"], self.data)
        self.assertEqual(self.mode(self.path), 0o600)
        failed = subprocess.run(["python3", str(HELPER), "save", str(self.path)],
                                input="invalid\n", text=True, capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(json.loads(failed.stdout)["ok"])
