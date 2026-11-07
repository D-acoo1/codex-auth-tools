#!/usr/bin/env python3
"""Exercise account switching against synthetic desktop persistence."""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("auth_fixtures", ROOT / "tests/keepalive-auth.py")
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class LocalDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("CODEX_AUTH_TEST_TMPDIR"))
        root = Path(self.temp.name)
        self.codex, self.ac = root / "codex", root / "ac"
        self.codex.mkdir()
        self.module = fixtures.load_ca_module(self.codex, self.ac)
        self.env = {**os.environ, "CODEX_HOME": str(self.codex), "CODEX_AC_HOME": str(self.ac)}
        self.owners = {}
        for alias in ("source", "current", "third"):
            auth = fixtures.make_auth("user-" + alias, "account-" + alias, alias + "@example.test",
                                      expires_at=int(time.time()) + 86400, refresh_token="fake-" + alias,
                                      access_label="fake-access-" + alias)
            source = root / (alias + ".json")
            fixtures.write_json(source, auth)
            self.module.import_auth(alias, source, "test")
            self.owners[alias] = self.module.desktop_owner(self.module.auth_info(source))
        self.module.copy_private(root / "current.json", self.codex / "auth.json")
        self.path = self.codex / ".codex-global-state.json"
        self.saved = {
            "globals": {"local-projects": {"p": {"name": "Project", "rootPaths": ["/example/project"]}},
                        "pinned-project-ids": ["p"], "thread-project-assignments": {"old-chat": {"projectId": "p"}},
                        "projectless-thread-ids": ["old-loose-chat"], "project-order": ["p"],
                        "thread-workspace-root-hints": {"old-chat": "/example/project"}},
            "atoms": {"thread-descriptions-v1": {"old-chat": "Old description"},
                      "sidebar-project-expanded-v1-codex:p": True,
                      "unified-sidebar-pinned-order-v1": ["codex:project:p", "chatgpt:project:source-cloud"],
                      "chatgpt-sidebar-state-v2": {"private": "source-cloud-cache"},
                      "plugin-oauth-install-reconciliation-by-state-v1": {"source": "private"}},
        }
        self.saved["globals"]["app-server-projects-migration-by-host"] = {
            "local:/example": {"version": 1, "projectsMigrated": True, "threadAssignmentsMigrated": False}}
        self.state = {
            self.module.DESKTOP_STATE_KEY: {"owner": self.owners["current"], "inactive": {self.owners["source"]: copy.deepcopy(self.saved)}},
            "projectless-thread-ids": ["new-chat"],
            "thread-workspace-root-hints": {"new-chat": "/example/new"},
            "electron-persisted-atom-state": {"thread-descriptions-v1": {"new-chat": "New description"},
                                               "chatgpt-sidebar-state-v2": {"private": "current-cloud-cache"}},
            "host-id-remote-control-allowed": ["current-host"],
        }
        fixtures.write_json(self.path, self.state)

    def tearDown(self):
        self.temp.cleanup()

    def run_ca(self, *args):
        return subprocess.run([sys.executable, str(ROOT / "codex-auth/lib/codex-ac.py"), *args],
                              env=self.env, text=True, capture_output=True)

    def share(self):
        result = self.run_ca("local-data", "share", "--from", "source")
        self.assertEqual(result.returncode, 0, result.stderr)
        return fixtures.read_json(self.path)

    def test_restore_preserves_new_local_data_and_account_caches(self):
        auth = (self.codex / "auth.json").read_bytes()
        state = self.share()
        self.assertEqual(state["local-projects"], self.saved["globals"]["local-projects"])
        self.assertEqual(state["projectless-thread-ids"], ["old-loose-chat", "new-chat"])
        self.assertEqual(set(state["thread-workspace-root-hints"]), {"old-chat", "new-chat"})
        self.assertEqual(set(state["electron-persisted-atom-state"]["thread-descriptions-v1"]), {"old-chat", "new-chat"})
        self.assertEqual(state["electron-persisted-atom-state"]["chatgpt-sidebar-state-v2"], {"private": "current-cloud-cache"})
        self.assertNotIn("plugin-oauth-install-reconciliation-by-state-v1", state["electron-persisted-atom-state"])
        self.assertEqual(state[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["source"]], self.saved)
        self.assertEqual(state["host-id-remote-control-allowed"], ["current-host"])
        self.assertEqual((self.codex / "auth.json").read_bytes(), auth)
        self.assertTrue(fixtures.read_json(self.ac / "registry.json")["shared_local_data"])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_switch_mirrors_latest_state_without_reviving_deletions(self):
        state = self.share()
        state["local-projects"] = {"new-project": {"name": "Latest", "rootPaths": ["/latest"]}}
        state["pinned-project-ids"] = []
        state["project-order"] = ["new-project"]
        state.pop("thread-project-assignments")
        state["electron-persisted-atom-state"]["unified-sidebar-pinned-order-v1"] = ["codex:project:new-project", "chatgpt:project:current-cloud"]
        fixtures.write_json(self.path, state)
        result = self.run_ca("switch", "source", "--skip-expiry-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        written = fixtures.read_json(self.path)
        target = written[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["source"]]
        self.assertEqual(target["globals"]["local-projects"], state["local-projects"])
        self.assertEqual(target["globals"]["pinned-project-ids"], [])
        self.assertNotIn("thread-project-assignments", target["globals"])
        self.assertEqual(target["atoms"]["unified-sidebar-pinned-order-v1"], ["codex:project:new-project", "chatgpt:project:source-cloud"])
        self.assertEqual(target["atoms"]["chatgpt-sidebar-state-v2"], self.saved["atoms"]["chatgpt-sidebar-state-v2"])
        self.assertEqual(self.module.auth_info(self.codex / "auth.json")["chatgpt_user_id"], "user-source")
        # Load the target cache as the desktop does after a login, then switch to an unseen account.
        written.update(target["globals"])
        written["electron-persisted-atom-state"] = target["atoms"]
        written[self.module.DESKTOP_STATE_KEY]["owner"] = self.owners["source"]
        del written[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["source"]]
        fixtures.write_json(self.path, written)
        result = self.run_ca("switch", "third", "--skip-expiry-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        third = fixtures.read_json(self.path)[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["third"]]
        self.assertEqual(third["globals"]["local-projects"], state["local-projects"])
        self.assertEqual(third["atoms"]["unified-sidebar-pinned-order-v1"], ["codex:project:new-project"])
        self.assertNotIn("chatgpt-sidebar-state-v2", third["atoms"])

    def test_default_and_disable_leave_desktop_state_untouched(self):
        before = self.path.read_bytes()
        result = self.run_ca("switch", "third", "--skip-expiry-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), before)
        self.share()
        result = self.run_ca("local-data", "separate")
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.path.read_bytes()
        result = self.run_ca("switch", "source", "--skip-expiry-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_source_or_target_does_not_switch_auth(self):
        before, auth = self.path.read_bytes(), (self.codex / "auth.json").read_bytes()
        result = self.run_ca("local-data", "share", "--from", "third")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual((self.codex / "auth.json").read_bytes(), auth)
        state = self.share()
        state[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["third"]] = {"atoms": [], "globals": {}}
        fixtures.write_json(self.path, state)
        before = self.path.read_bytes()
        result = self.run_ca("switch", "third", "--skip-expiry-check")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual((self.codex / "auth.json").read_bytes(), auth)

    def test_app_final_flush_precedes_snapshot_and_reopen(self):
        self.share()
        events = []
        def stop():
            state = fixtures.read_json(self.path)
            state["local-projects"]["last-write"] = {"name": "Flushed", "rootPaths": []}
            fixtures.write_json(self.path, state)
            events.append("closed")
            return Path("/example/ChatGPT.app")
        args = argparse.Namespace(alias="third", restart_app=False, no_backup=True, skip_expiry_check=True)
        with patch.object(self.module, "stop_desktop_app", stop), patch.object(self.module.subprocess, "run") as run:
            run.side_effect = lambda *a, **k: events.append("opened")
            self.assertEqual(self.module.cmd_switch(args), 0)
        self.assertEqual(events, ["closed", "opened"])
        target = fixtures.read_json(self.path)[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["third"]]
        self.assertIn("last-write", target["globals"]["local-projects"])

    def test_quit_failure_keeps_auth_and_state(self):
        self.share()
        before, auth = self.path.read_bytes(), (self.codex / "auth.json").read_bytes()
        args = argparse.Namespace(alias="third", restart_app=False, no_backup=True, skip_expiry_check=True)
        with patch.object(self.module, "stop_desktop_app", side_effect=SystemExit("still running")):
            with self.assertRaises(SystemExit):
                self.module.cmd_switch(args)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual((self.codex / "auth.json").read_bytes(), auth)


if __name__ == "__main__":
    unittest.main()
