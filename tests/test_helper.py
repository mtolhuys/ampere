# python3 -I tests/test_helper.py: bin/ampere's parsers and guards, loaded
# from the file without running it.
import sys
sys.dont_write_bytecode = True
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "bin", "ampere")
loader = importlib.machinery.SourceFileLoader("ampere", HELPER)
spec = importlib.util.spec_from_loader("ampere", loader)
ampere = importlib.util.module_from_spec(spec)
loader.exec_module(ampere)

USAGE = """Signed in as someone@example.com (someone)
**Amp Megawatt Tier:** agent usage $19.23 of $20 remaining (96%), orb usage 623.5h of 750h a1.small orb hours remaining (83%) - period 2026-10-29 to 2026-11-29, resets upon renewal in 27 days
**Individual credits:** $0 remaining - https://ampcode.com/settings

## How Usage Is Charged
"""

TID = "T-01a19782-5e8b-77ce-80b8-f242bd33c53c"
TID2 = "T-01a19780-50eb-714f-96f4-bf44311496ab"


def run(*args, env_extra=None):
    env = {"PATH": "/usr/bin", "HOME": tempfile.gettempdir(), "LANG": "C.UTF-8"}
    env.update(env_extra or {})
    done = subprocess.run([HELPER, *args], capture_output=True, text=True, env=env, timeout=20)
    return done.returncode, json.loads(done.stdout.strip().splitlines()[-1])


class Usage(unittest.TestCase):
    def test_megawatt(self):
        u = ampere.parse_usage(USAGE)
        self.assertTrue(u["signedIn"])
        self.assertEqual(u["user"], "someone")
        self.assertEqual(u["tier"], "Amp Megawatt Tier")
        self.assertEqual(u["agent"], {"remaining": 19.23, "total": 20.0, "percent": 96})
        self.assertEqual(u["orb"], {"remaining": 623.5, "total": 750.0, "size": "a1.small", "percent": 83})
        self.assertEqual(u["period"], {"start": "2026-10-29", "end": "2026-11-29", "resetsInDays": 27})
        self.assertEqual(u["credits"], 0.0)
        self.assertEqual(len(u["lines"]), 2)
        self.assertNotIn("https://", u["lines"][1])

    def test_unknown_shape_keeps_lines(self):
        u = ampere.parse_usage("Signed in as a@b.c (a)\n**Amp Free:** $10 of daily allowance left\n")
        self.assertIsNone(u["agent"])
        self.assertEqual(u["tier"], "Amp Free")
        self.assertEqual(u["lines"], ["Amp Free: $10 of daily allowance left"])

    def test_signed_out(self):
        self.assertFalse(ampere.parse_usage("Not signed in. Run amp login.")["signedIn"])


class Runners(unittest.TestCase):
    def test_groups_dirs_under_runner(self):
        r = ampere.parse_runners("deploy  ~/Projects/a\n  ~/Projects/b\nother  /srv/c\n")
        self.assertEqual([x["name"] for x in r], ["deploy", "other"])
        self.assertEqual(r[0]["dirs"], [ampere.HOME + "/Projects/a", ampere.HOME + "/Projects/b"])
        self.assertEqual(r[1]["dirs"], ["/srv/c"])


class Merge(unittest.TestCase):
    def test_live_and_listed(self):
        listed = [
            {"id": TID, "title": "A", "updated": "2026-11-01T10:00:00Z", "tree": "file:///nonexistent", "messageCount": 3},
            {"id": TID2, "title": "B", "updated": "2026-11-01T11:00:00Z", "tree": "file://" + ROOT, "messageCount": 1},
            {"id": "bogus", "title": "C"},
        ]
        live = [{"id": TID, "title": "A2", "project": "p", "status": "working", "working": True, "executorConnected": True, "updatedAt": "2026-11-01T12:00:00Z"}]
        rows = ampere.merge_threads(live, listed)
        self.assertEqual([r["id"] for r in rows], [TID, TID2])
        self.assertTrue(rows[0]["working"])
        self.assertEqual(rows[0]["title"], "A2")
        self.assertEqual(rows[0]["dir"], "")
        self.assertTrue(rows[0]["remote"])
        self.assertEqual(rows[1]["dir"], os.path.realpath(ROOT))
        self.assertEqual(rows[1]["project"], os.path.basename(ROOT))
        self.assertEqual(rows[1]["url"], "https://ampcode.com/threads/" + TID2)

    def test_titles_lose_control_characters(self):
        rows = ampere.merge_threads([], [{"id": TID, "title": "a\x1b[31mb\x07c"}])
        self.assertEqual(rows[0]["title"], "abc")


class Guards(unittest.TestCase):
    def test_thread_ids(self):
        self.assertEqual(ampere.need_thread(TID), TID)
        for bad in ("", "T-1", "--help", TID + " ; rm", "../T"):
            with self.assertRaises(ampere.Fail):
                ampere.need_thread(bad)

    def test_urls(self):
        self.assertTrue(ampere.AMP_URL.match("https://ampcode.com/threads/" + TID))
        self.assertTrue(ampere.AMP_URL.match("https://ampcode.com/"))
        for bad in ("http://ampcode.com/", "https://ampcode.com.evil.io/", "https://evil.io/?https://ampcode.com", "file:///etc/passwd"):
            self.assertFalse(ampere.AMP_URL.match(bad), bad)

    def test_safe_dir_stays_home(self):
        self.assertEqual(ampere.safe_dir("/etc"), ampere.HOME)
        self.assertEqual(ampere.safe_dir(""), ampere.HOME)

    def test_flags(self):
        extra, orb, prompt, rest = ampere.flags(["/d", "--mode", "high", "--fast", "--orb", "--prompt", " hi "])
        self.assertEqual(extra, ["-m", "high", "--fast"])
        self.assertTrue(orb)
        self.assertEqual(prompt, "hi")
        self.assertEqual(rest, ["/d"])
        self.assertEqual(ampere.flags(["--mode", "rm -rf"])[0], [])


class SessionPath(unittest.TestCase):
    def test_keeps_absolute_entries_once(self):
        old = os.environ.get("AMPERE_SESSION_PATH")
        os.environ["AMPERE_SESSION_PATH"] = "/a/bin::relative:/usr/bin:/a/bin:."
        try:
            env = ampere.session_env()
        finally:
            if old is None:
                del os.environ["AMPERE_SESSION_PATH"]
            else:
                os.environ["AMPERE_SESSION_PATH"] = old
        self.assertEqual(env["PATH"], "/a/bin:/usr/bin")
        self.assertNotIn("AMPERE_SESSION_PATH", env)


class Cli(unittest.TestCase):
    def test_refusals_are_json(self):
        self.assertEqual(run("thread", "archive", "nope")[1]["ok"], False)
        self.assertEqual(run("open", "https://evil.io/")[1]["error"], "only ampcode.com pages open from here")
        self.assertEqual(run("term", "rm")[1]["error"], "unknown preset")
        code, out = run("nonsense")
        self.assertEqual(code, 2)

    def test_missing_amp(self):
        code, out = run("snapshot", env_extra={"AMPERE_AMP": "/nonexistent/amp"})
        self.assertEqual((code, out), (1, {"ok": False, "error": "amp-missing"}))


if __name__ == "__main__":
    unittest.main(verbosity=1)
