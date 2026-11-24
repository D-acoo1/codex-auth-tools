#!/usr/bin/env python3
"""Exercise account switching against synthetic desktop persistence."""
from __future__ import annotations

import argparse
import contextlib
import copy
import importlib.util
import json
import os
import sqlite3
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
        self.module.copy_private(self.codex.parent / "current.json", self.codex / "auth.json")
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

    def scoped_workspace(self, source, roots):
        prefix = "electron-owner-value:"
        return {prefix + key + ":" + source: value for key, value in {
            "electron-saved-workspace-roots": roots, "active-workspace-roots": roots[:1],
            "thread-workspace-root-hints": {p: p for p in roots},
            "thread-projectless-output-directories": {}, "electron-workspace-root-labels": {p: p[1:] for p in roots},
        }.items()}

    def create_sqlite(self, state):
        db = self.codex / ".codex-global-state.sqlite"
        with contextlib.closing(sqlite3.connect(db)) as con, con:
            con.execute("CREATE TABLE settings(scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,"
                        "PRIMARY KEY(scope,key)) WITHOUT ROWID")
            con.execute("PRAGMA user_version=1")
            for k,v in state.items():
                if k.startswith("electron-owner-atoms:"):
                    con.executemany("INSERT INTO settings VALUES(?,?,?)", [(k,a,json.dumps(b)) for a,b in v.items()])
                    v = {}
                con.execute("INSERT INTO settings VALUES('global',?,?)",(k,json.dumps(v)))
        return db

    def test_sqlite_three_account_workspace(self):
        a,b,c = (self.owners[k] for k in ("current","source","third"))
        owner = self.module.RENDERER_OWNER_KEY
        order = self.module.LOCAL_ORDER_ATOMS[0]
        atom = "electron-owner-atoms:"
        key = "electron-owner-value:electron-saved-workspace-roots:"
        state = {owner:a, **self.scoped_workspace(a, ["/keep"]), **self.scoped_workspace(b, ["/deleted"]),
                 atom+a:{order:["codex:project:keep","chatgpt:project:A"]},
                 atom+b:{order:["codex:project:deleted","chatgpt:project:B"], "plugin-state":{"B":1}},
                 "local-projects":{"keep":{}}, "thread-project-assignments":{"chat":"keep"}}
        db = self.create_sqlite(state)
        json_before = self.path.read_bytes()
        chat = self.codex / "session.jsonl"
        chat.write_bytes(b"chat content")
        def set_current(con, owner_id):
            con.execute("UPDATE settings SET value=? WHERE scope='global' AND key=?",(json.dumps(owner_id),owner))
        def get(con,k,scope="global"):
            return json.loads(con.execute("SELECT value FROM settings WHERE scope=? AND key=?",(scope,k)).fetchone()[0])
        def switch(alias):
            result=self.run_ca("switch",alias,"--skip-expiry-check")
            self.assertEqual(result.returncode,0,result.stderr)
        result = self.run_ca("local-data","share")
        self.assertEqual(result.returncode,0,result.stderr)
        switch("source")
        with contextlib.closing(sqlite3.connect(db)) as con, con:
            self.assertEqual(get(con,key+b),["/keep"])
            self.assertEqual(get(con,order,atom+b),["codex:project:keep","chatgpt:project:B"])
            self.assertEqual(get(con,"plugin-state",atom+b),{"B":1})
            set_current(con,b)
            for k,v in self.scoped_workspace(b, ["/keep","/new"]).items():
                con.execute("UPDATE settings SET value=? WHERE scope='global' AND key=?",(json.dumps(v),k))
        switch("third")
        with contextlib.closing(sqlite3.connect(db)) as con, con:
            self.assertEqual(get(con,key+c),["/keep","/new"])
            set_current(con,c)
        switch("current")
        with contextlib.closing(sqlite3.connect(db)) as con, con:
            self.assertEqual(get(con,key+a),["/keep","/new"])
            self.assertEqual(get(con,"thread-project-assignments"),{"chat":"keep"})
        self.assertEqual(self.path.read_bytes(),json_before)
        self.assertEqual(chat.read_bytes(),b"chat content")

    def test_scoped_membership_is_local_without_copying_runtime_roots(self):
        a, b = self.owners["current"], self.owners["source"]
        def record(project, path):
            return {"revision":path, "project":project, "applied":{"cwd":path,"runtimeWorkspaceRoots":[path]},
                    "pending":{"runtimeWorkspaceRoots":[path]}}
        local = {"projectKind":"local", "projectId":"latest"}
        old = {"projectKind":"local", "projectId":"removed"}
        cloud = {"projectKind":"local","projectId":"cloud","projectOrigin":"chatgpt"}
        prefix = self.module.THREAD_STATE
        src = {prefix+"moved":record(local,"/a"),prefix+"new":record(local,"/a"),
               prefix+"cloud":record(cloud,"/a"),prefix+"deleted":record(None,"/a")}
        dst = {prefix+k:record(old,"/b") for k in ["moved","unassigned","deleted","cloud"]}
        state = {**self.scoped_workspace(a, ["/Volumes/offline/project"]),
                 **self.scoped_workspace(b, ["/old"]), "local-projects":{"latest":{}},
                 "projectless-thread-ids":["unassigned"], self.module.ATOM_PREFIX+a:src, self.module.ATOM_PREFIX+b:dst}
        self.module.sync_scoped_workspace(state,a,b)
        updated = state[self.module.ATOM_PREFIX+b]
        self.assertEqual(updated[prefix+"moved"],{**dst[prefix+"moved"],"project":local})
        self.assertIsNone(updated[prefix+"new"]["pending"])
        self.assertIsNone(updated[prefix+"new"]["applied"])
        self.assertIsNone(updated[prefix+"unassigned"]["project"])
        self.assertIsNone(updated[prefix+"deleted"]["project"])
        self.assertEqual(updated[prefix+"cloud"],dst[prefix+"cloud"])
        self.assertEqual(state[self.module.scoped_key(self.module.SCOPED_ROOTS,b)],["/Volumes/offline/project"])

    def test_empty_partial_and_pending_workspaces(self):
        a,b = self.owners["current"], self.owners["source"]
        roots = self.module.scoped_key(self.module.SCOPED_ROOTS,a)
        m = self.module
        good = {m.RENDERER_OWNER_KEY:a,"local-projects":{},**self.scoped_workspace(a,[]),
                **self.scoped_workspace(b,["/last-deleted"])}
        m.sync_scoped_workspace(good,a,b)
        self.assertEqual(good[m.scoped_key(m.SCOPED_ROOTS,b)],[])
        base = {**good, **self.scoped_workspace(b,["/do-not-erase"])}
        self.share()
        auth = (self.codex / "auth.json").read_bytes()
        for change in ({roots:None},{"local-projects":{"still-here":{}}},
                       {m.scoped_key(m.PENDING_DELETIONS,a):{"local": {"x":{}}}},
                       {m.scoped_key(m.PENDING_DELETIONS,b):{"local": {"x":{}}}},
                       {m.RENDERER_OWNER_KEY:b},{m.RENDERER_OWNER_KEY:"signed-out"}):
            with self.subTest(change=list(change)):
                fixtures.write_json(self.path,{**base,**change})
                before=self.path.read_bytes()
                result=self.run_ca("switch","source","--skip-expiry-check")
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(self.path.read_bytes(),before)
                self.assertEqual((self.codex/"auth.json").read_bytes(),auth)

    def test_unknown_sqlite_never_falls_back_to_json(self):
        self.share()
        db=self.create_sqlite({})
        with contextlib.closing(sqlite3.connect(db)) as con, con:
            con.execute("PRAGMA user_version=9")
        before,auth=self.path.read_bytes(),(self.codex/"auth.json").read_bytes()
        result=self.run_ca("switch","source","--skip-expiry-check")
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.path.read_bytes(),before)
        self.assertEqual((self.codex/"auth.json").read_bytes(),auth)

    def test_pre_auth_failure_restores_staged_workspace(self):
        a,b=self.owners["current"],self.owners["source"]
        self.share()
        reg=self.module.load_registry()
        state={self.module.RENDERER_OWNER_KEY:a,"local-projects":{"x":{}},
               **self.scoped_workspace(a,["/new"]),**self.scoped_workspace(b,["/old"])}
        fixtures.write_json(self.path,state)
        auth=(self.codex/"auth.json").read_bytes()
        for backend in ("json","sqlite"):
            db = self.create_sqlite(state) if backend=="sqlite" else None
            if db:
                with contextlib.closing(sqlite3.connect(db)) as con, con:
                    rows = list(con.execute("SELECT * FROM settings ORDER BY scope,key"))
            before=self.path.read_bytes()
            with self.assertRaisesRegex(RuntimeError,"fixture"):
                with self.module.shared_local_data_switch(reg,reg["accounts"]["source"]):
                    raise RuntimeError("fixture")
            self.assertEqual(self.path.read_bytes(),before)
            self.assertEqual((self.codex/"auth.json").read_bytes(),auth)
            if db:
                with contextlib.closing(sqlite3.connect(db)) as con, con:
                    self.assertEqual(list(con.execute("SELECT scope,key,json(value) FROM settings ORDER BY scope,key")),
                                     [(s,k,json.dumps(json.loads(v),separators=(",",":"))) for s,k,v in rows])
        for backup in (self.ac/"backups"/"local-workspace").iterdir():
            self.assertEqual(backup.stat().st_mode & 0o777,0o600)

    def test_owner_scoped_paths_survive_recovery_and_round_trip(self):
        a, b, c = (self.owners[k] for k in ("source", "current", "third"))
        hints = "electron-owner-value:thread-workspace-root-hints:"
        out = "electron-owner-value:thread-projectless-output-directories:"
        writable = "electron-owner-value:thread-writable-roots:"
        untouched = {writable+a: {"one": ["/private/grant"]}, hints+c: {"three": "/three"},
                     "electron-account-remote-preference:host:"+a: True,
                     "electron-persisted-atom-state": {"account-private": "private"}}
        def save(state):
            fixtures.write_json(self.path, state)
        state = {**self.scoped_workspace(a, ["/one"]), **self.scoped_workspace(b, ["/two"]), **untouched, self.module.RENDERER_OWNER_KEY: b,
                 hints+a: {"one": "/one", "same": "/old-location", "remote": "ssh://host/path"},
                 hints+b: {"two": "/two", "same": "/new-location"}, out+a: {"loose": "/output"}}
        save(state)
        current = self.share()
        self.assertEqual(current[hints+b], {"one": "/one", "two": "/two", "same": "/new-location"})
        self.assertEqual(current[out+b], {"loose": "/output"})
        self.assertEqual(current[hints+a], state[hints+a])
        result = self.run_ca("switch", "source", "--skip-expiry-check")
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = fixtures.read_json(self.path)
        self.assertEqual(saved[hints+a], {**current[hints+b], "remote": "ssh://host/path"})
        self.assertEqual(saved[hints+b], current[hints+b])
        self.assertNotIn(writable+b, saved)
        for k, v in untouched.items():
            self.assertEqual(saved[k], v)
        saved[self.module.RENDERER_OWNER_KEY] = a
        save(saved)
        self.assertEqual(self.run_ca("switch", "current", "--skip-expiry-check").returncode, 0)
        self.assertEqual(fixtures.read_json(self.path), saved)
        self.assertEqual(self.run_ca("local-data", "separate").returncode, 0)
        before = self.path.read_bytes()
        self.assertEqual(self.run_ca("switch", "third", "--skip-expiry-check").returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_scoped_map_or_unidentified_owner_preserves_both_files(self):
        self.share()
        owner = self.owners["current"]
        src = "electron-owner-value:thread-workspace-root-hints:" + owner
        dst = "electron-owner-value:thread-workspace-root-hints:" + self.owners["third"]
        for state in ({src: {"one": "/one"}}, {self.module.RENDERER_OWNER_KEY: owner, src: [], dst: {}},
                      {self.module.RENDERER_OWNER_KEY: owner, src: {"one": "/one"}, dst: None}):
            fixtures.write_json(self.path, state)
            before, auth = self.path.read_bytes(), (self.codex / "auth.json").read_bytes()
            self.assertNotEqual(self.run_ca("switch", "third", "--skip-expiry-check").returncode, 0)
            self.assertEqual(self.path.read_bytes(), before)
            self.assertEqual((self.codex / "auth.json").read_bytes(), auth)

    def test_legacy_switch_replaces_stale_locations(self):
        state = self.share()
        locations = state[self.module.DESKTOP_STATE_KEY]["inactive"][self.owners["source"]]["globals"]
        locations["thread-workspace-root-hints"] = {"old-chat": "/moved", "target-only": "/target-only"}
        state["thread-workspace-root-hints"] = {"old-chat": "/previous", "new-chat": "/new"}
        self.module.mirror_local_data(state, self.owners["source"])
        self.assertEqual(locations["thread-workspace-root-hints"],
                         {"old-chat": "/previous", "new-chat": "/new"})

    def test_merge_must_remain_readable_by_next_switch(self):
        self.share()
        a = self.owners["current"]
        key = "electron-owner-value:thread-workspace-root-hints:"
        fixtures.write_json(self.path, {self.module.RENDERER_OWNER_KEY: a, **self.scoped_workspace(a, ["/root"]), key+a: {"chat": "/"+"x"*1024}})
        before, auth = self.path.read_bytes(), (self.codex / "auth.json").read_bytes()
        with patch.object(self.module, "DESKTOP_STATE_LIMIT", len(before)+64):
            with self.assertRaises(SystemExit):
                with self.module.shared_local_data_switch({"shared_local_data": True}, self.module.load_registry()["accounts"]["third"]):
                    self.fail("oversized merge must not switch credentials")
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual((self.codex / "auth.json").read_bytes(), auth)


if __name__ == "__main__":
    unittest.main()
