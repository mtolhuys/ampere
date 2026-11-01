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
import time
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
        extra, orb, rest = ampere.flags(["/d", "--mode", "high", "--fast", "--orb"])
        self.assertEqual(extra, ["-m", "high", "--fast"])
        self.assertTrue(orb)
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


SECRET = "rotate the staging key, it is hunter2"


class PromptPrivacy(unittest.TestCase):
    """A prompt reaches Amp through stdin or a private file, never an argv."""

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.runtime = tempfile.mkdtemp()
        os.chmod(self.runtime, 0o700)

    def test_exec_pipes_the_prompt(self):
        amp = os.path.join(self.home, "amp")
        with open(amp, "w") as f:
            f.write('#!/usr/bin/bash\nprintf "%s\\n" "$@" > "$HOME/argv.tmp"; cat > "$HOME/stdin"; mv "$HOME/argv.tmp" "$HOME/argv"\n')
        os.chmod(amp, 0o755)
        env = {"PATH": "/usr/bin", "HOME": self.home, "LANG": "C.UTF-8", "AMPERE_AMP": amp, "AMPERE_PROMPT": SECRET}
        done = subprocess.run([HELPER, "exec", self.home, "--mode", "high"], capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(json.loads(done.stdout)["ok"], True, done.stdout + done.stderr)
        argv_file = os.path.join(self.home, "argv")
        for _ in range(100):
            if os.path.exists(argv_file):
                break
            time.sleep(0.05)
        with open(argv_file) as f:
            argv = f.read().split("\n")
        self.assertEqual(argv[:3], ["-x", "-m", "high"])
        self.assertNotIn(SECRET, " ".join(argv))
        with open(os.path.join(self.home, "stdin")) as f:
            self.assertEqual(f.read(), SECRET)

    def test_exec_refuses_an_empty_prompt(self):
        env = {"PATH": "/usr/bin", "HOME": self.home, "LANG": "C.UTF-8", "AMPERE_AMP": "/usr/bin/true"}
        done = subprocess.run([HELPER, "exec", self.home], capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(json.loads(done.stdout)["error"], "an empty prompt")

    def test_new_hands_a_private_file_to_the_terminal(self):
        seen = []
        saved = (ampere.terminal, ampere.need_amp, ampere.emit, dict(os.environ))
        ampere.terminal = lambda argv, cwd, **kw: seen.append(argv)
        ampere.need_amp = lambda: "/usr/bin/amp"
        ampere.emit = lambda value: None
        os.environ.update(AMPERE_PROMPT=SECRET, XDG_RUNTIME_DIR=self.runtime)
        try:
            ampere.cmd_new([ampere.HOME])
        finally:
            ampere.terminal, ampere.need_amp, ampere.emit = saved[:3]
            os.environ.clear()
            os.environ.update(saved[3])
        argv = seen[0]
        self.assertNotIn(SECRET, " ".join(argv))
        path = argv[4]
        folder = os.path.dirname(path)
        self.assertEqual(oct(os.stat(folder).st_mode & 0o777), "0o700")
        self.assertEqual(oct(os.stat(path).st_mode & 0o777), "0o600")
        with open(path) as f:
            self.assertEqual(f.read(), SECRET + "\n")
        # What the terminal runs: the prompt piped into amp, the file gone.
        out = subprocess.run(argv[:3] + ["/usr/bin/cat", path], capture_output=True, text=True, timeout=10)
        self.assertEqual(out.stdout, SECRET + "\n")
        self.assertFalse(os.path.exists(path))

    def test_private_dir_refuses_a_shared_one(self):
        folder = os.path.join(self.runtime, "io.github.mtolhuys.ampere")
        os.mkdir(folder, 0o755)
        os.chmod(folder, 0o755)
        saved = os.environ.get("XDG_RUNTIME_DIR")
        os.environ["XDG_RUNTIME_DIR"] = self.runtime
        try:
            with self.assertRaises(ampere.Fail):
                ampere.private_dir()
        finally:
            if saved is None:
                del os.environ["XDG_RUNTIME_DIR"]
            else:
                os.environ["XDG_RUNTIME_DIR"] = saved


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
