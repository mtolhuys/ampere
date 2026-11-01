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


class Notifications(unittest.TestCase):
    """Titles reach the notification server over D-Bus, never in an argv."""

    def test_a_method_call_round_trips(self):
        args = ["Ampere", 0, "icon", "Amp finished a turn", SECRET, ["default", "Open"], [], -1]
        data = ampere.method_call(7, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                                  "org.freedesktop.Notifications", "Notify", "susssasa{sv}i", args)
        kind, fields, body, length = ampere.take_message(data + b"rest")
        self.assertEqual((kind, length), (1, len(data)))
        self.assertEqual(fields[3], "Notify")
        self.assertEqual(fields[8], "susssasa{sv}i")
        self.assertEqual(body, ["Ampere", 0, "icon", "Amp finished a turn", SECRET])
        self.assertIsNone(ampere.take_message(data[:-1]))

    def test_signatures_split(self):
        self.assertEqual(ampere.split_signature("susssasa{sv}i"), ["s", "u", "s", "s", "s", "as", "a{sv}", "i"])
        self.assertEqual(ampere.split_signature("a(yv)u"), ["a(yv)", "u"])

    def test_bus_addresses(self):
        self.assertEqual(ampere.bus_path("unix:path=/run/user/1000/bus"), "/run/user/1000/bus")
        self.assertEqual(ampere.bus_path("unix:abstract=x,guid=1"), "\0x")
        with self.assertRaises(OSError):
            ampere.bus_path("tcp:host=localhost")

    def test_notify_takes_its_text_from_the_environment(self):
        env = {"PATH": "/usr/bin", "HOME": tempfile.gettempdir(), "LANG": "C.UTF-8"}
        done = subprocess.run([HELPER, "notify"], capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(json.loads(done.stdout)["error"], "notify needs a title")
        env["AMPERE_NOTIFY"] = json.dumps({"title": "Amp finished a turn", "body": SECRET, "url": "https://ampcode.com/"})
        env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/nonexistent/bus"
        done = subprocess.run([HELPER, "notify"], capture_output=True, text=True, env=env, timeout=20)
        self.assertEqual(json.loads(done.stdout), {"ok": True})


FAKE_SERVER = r"""
import sys
from gi.repository import Gio, GLib
XML = '<node><interface name="org.freedesktop.Notifications"><method name="Notify">' + "".join(
    '<arg type="%s" direction="in"/>' % t for t in ["s", "u", "s", "s", "s", "as", "a{sv}", "i"]) + '<arg type="u" direction="out"/></method></interface></node>'
conn = Gio.DBusConnection.new_for_address_sync(sys.argv[1], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
loop = GLib.MainLoop()
def call(conn, sender, path, iface, method, params, invocation):
    args = params.unpack()
    with open(sys.argv[2], "w") as f:
        f.write(repr(args))
    invocation.return_value(GLib.Variant("(u)", (7,)))
    GLib.timeout_add(200, lambda: conn.emit_signal(None, "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "ActionInvoked", GLib.Variant("(us)", (7, "open"))) or False)
conn.register_object("/org/freedesktop/Notifications", Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], call, None, None)
Gio.bus_own_name_on_connection(conn, "org.freedesktop.Notifications", 0, lambda *a: print("ready", flush=True), None)
GLib.timeout_add_seconds(20, loop.quit)
loop.run()
"""


def have_gi():
    return subprocess.run(["/usr/bin/python3", "-c", "import gi"], capture_output=True).returncode == 0 and os.path.exists("/usr/bin/dbus-daemon")


@unittest.skipUnless(have_gi(), "needs python-gobject and dbus-daemon")
class NotificationRoundTrip(unittest.TestCase):
    """A real bus, a stand-in notification server that clicks Open: the waiter
    sends the title over D-Bus and opens the thread."""

    def test_open_opens_the_thread(self):
        home = tempfile.mkdtemp()
        launcher_dir = os.path.join(home, ".local/share/omarchy/bin")
        os.makedirs(launcher_dir)
        opened = os.path.join(home, "opened")
        with open(os.path.join(launcher_dir, "omarchy-launch-browser"), "w") as f:
            f.write('#!/usr/bin/bash\nprintf %%s "$1" > "%s"\n' % opened)
        os.chmod(os.path.join(launcher_dir, "omarchy-launch-browser"), 0o755)
        daemon = subprocess.Popen(["/usr/bin/dbus-daemon", "--session", "--nofork", "--print-address",
                                   "--address=unix:abstract=ampere-test-%d" % os.getpid()], stdout=subprocess.PIPE, text=True)
        try:
            address = daemon.stdout.readline().strip()
            seen = os.path.join(home, "notify-args")
            server = subprocess.Popen(["/usr/bin/python3", "-c", FAKE_SERVER, address, seen], stdout=subprocess.PIPE, text=True)
            self.assertEqual(server.stdout.readline().strip(), "ready")
            url = "https://ampcode.com/threads/" + TID
            env = {"PATH": "/usr/bin", "HOME": home, "LANG": "C.UTF-8", "DBUS_SESSION_BUS_ADDRESS": address,
                   "AMPERE_NOTIFY": json.dumps({"title": "Amp finished a turn", "body": SECRET, "url": url})}
            done = subprocess.run([HELPER, "notify"], capture_output=True, text=True, env=env, timeout=20)
            self.assertEqual(json.loads(done.stdout), {"ok": True})
            for _ in range(100):
                if os.path.exists(opened):
                    break
                time.sleep(0.1)
            with open(seen) as f:
                args = f.read()
            self.assertIn(SECRET, args)
            self.assertIn("'Ampere'", args)
            self.assertIn("['default', 'Open', 'open', 'Open thread']", args)
            with open(opened) as f:
                self.assertEqual(f.read(), url)
            server.kill()
            server.wait()
            server.stdout.close()
        finally:
            daemon.kill()
            daemon.wait()
            daemon.stdout.close()


class Cli(unittest.TestCase):
    def test_refusals_are_json(self):
        self.assertEqual(run("thread", "archive", "nope")[1]["ok"], False)
        self.assertEqual(run("open", "https://evil.io/")[1]["error"], "only ampcode.com pages open from here")
        self.assertEqual(run("term", "rm")[1]["error"], "unknown preset")
        self.assertEqual(run("thread", "rename", TID, "x", env_extra={"AMPERE_AMP": "/usr/bin/true"})[1]["error"], "unknown thread action rename")
        self.assertEqual(run("search", "x")[0], 2)
        code, out = run("nonsense")
        self.assertEqual(code, 2)

    def test_missing_amp(self):
        code, out = run("snapshot", env_extra={"AMPERE_AMP": "/nonexistent/amp"})
        self.assertEqual((code, out), (1, {"ok": False, "error": "amp-missing"}))


if __name__ == "__main__":
    unittest.main(verbosity=1)
