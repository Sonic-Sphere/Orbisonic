#!/usr/bin/env python3
"""
Orbisonic crash-soak test harness.

Drives the running Orbisonic app through its local web control API to load and
briefly play tracks across the entire local music library, recording for each
file whether it PLAYED, ERRORED, HUNG, or CRASHED the app.

Why this exists: the renderer maps any source layout (mono .. 9.1.6, Atmos,
52ch) onto 31 sphere outputs, and several format/channel/sample-rate paths have
historically crashed or hung the app (reentrant graph reconfig, sample-rate
mismatch, oversized channel counts). This harness exercises every distinct
format path so we can confirm nothing crashes before a sphere session.

It is resilient: if a file crashes the app, the harness relaunches it and
continues. It is resumable: results are appended to a JSONL file and already
tested paths are skipped on re-run.

Track addressing: the web API resolves a track command by FNV-1a-64 hash of the
track's file path (LocalMusicTrack.id == path). The displayed track list is
capped at 80, but the command resolver matches against the FULL library, so we
can drive all files by hashing their paths -- no API change needed.

Run ON the Sphere Mac (where Orbisonic + the files + the web server live):

    python3 scripts/crash-soak-test.py --mode representative   # fast smoke
    python3 scripts/crash-soak-test.py --mode full             # every file

Requires: Orbisonic running with the web control server enabled, and a probe
catalog at /tmp/probe.jsonl (one JSON object per file with keys:
path, container, nAudioStreams, codec, profile, channels, layout,
sampleRate, bps). Produce it with the companion probe script if missing.
"""

import argparse
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:37943/Orbisonic"
APP = os.path.expanduser("~/Documents/Orbisonic/Orbisonic.app")
APP_BIN = APP + "/Contents/MacOS/Orbisonic"
APP_MATCH = "Orbisonic.app/Contents/MacOS/Orbisonic"
BUNDLE_ID = "audio.orbisonic.app.current"
CRASH_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")
# Capturing stderr is the only way to recover an uncaught NSException's reason
# string (the crash report records only "abort() called"). We launch the
# Mach-O directly with the bundle's lone LSEnvironment var so the
# "*** Terminating app due to uncaught exception ..." line lands in this log.
STDERR_LOG = "/tmp/orbisonic-stderr.log"
LAUNCH_ENV = {"SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE": "legacy"}
DEFAULT_PROBE = "/tmp/probe.jsonl"
DEFAULT_RESULTS = "/tmp/crash-soak-results.jsonl"

# How long to wait for a load to reach "playing" before declaring a hang.
LOAD_TIMEOUT_S = 40.0
# Poll cadence while waiting for a load to resolve.
POLL_INTERVAL_S = 0.5
# Let confirmed playback run this long so the real-time render loop executes
# (some crashes surface a beat after audio starts, not at load).
PLAY_HOLD_S = 3.0
# After a crash, wait this long for the relaunched app's web API to come back.
RELAUNCH_TIMEOUT_S = 90.0

ERROR_KEYWORDS = (
    "error", "unsupported", "failed", "failure", "cannot",
    "could not", "unable", "invalid", "no audio",
)
LOADING_KEYWORDS = ("loading", "preparing", "starting playback", "opening")


def fnv1a64(s: str) -> str:
    h = 14695981039346656037
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def read_token() -> str:
    for domain in ("audio.orbisonic.app.current", "audio.orbisonic.app"):
        try:
            out = subprocess.run(
                ["defaults", "read", domain, "Orbisonic.webControlToken"],
                capture_output=True, text=True, timeout=10,
            )
            tok = out.stdout.strip()
            if tok:
                return tok
        except Exception:
            pass
    return ""


def api_request(path: str, token: str, payload=None, timeout=8.0):
    url = BASE + path
    data = None
    headers = {"x-orbisonic-token": token}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["content-type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if payload is not None else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body) if body.strip().startswith(("{", "[")) else body


def get_state(token: str, timeout=6.0):
    return api_request("/api/state", token, timeout=timeout)


def app_pid() -> int:
    out = subprocess.run(["pgrep", "-f", APP_MATCH], capture_output=True, text=True)
    pids = [int(p) for p in out.stdout.split() if p.strip().isdigit()]
    return pids[0] if pids else 0


def crash_reports():
    return set(glob.glob(os.path.join(CRASH_DIR, "Orbisonic-*.ips")))


def kill_all_instances():
    subprocess.run(
        ["osascript", "-e",
         f'if application id "{BUNDLE_ID}" is running then tell application id "{BUNDLE_ID}" to quit'],
        capture_output=True, text=True)
    time.sleep(1.0)
    subprocess.run(["pkill", "-f", APP_MATCH], capture_output=True, text=True)
    time.sleep(1.0)


def launch_app():
    """Start exactly one instance, Mach-O directly, with stderr captured."""
    kill_all_instances()
    env = dict(os.environ)
    env.update(LAUNCH_ENV)
    logf = open(STDERR_LOG, "ab")
    logf.write(f"\n===== launch {time.strftime('%Y-%m-%dT%H:%M:%S')} =====\n".encode())
    logf.flush()
    subprocess.Popen([APP_BIN], env=env, stdout=logf, stderr=logf,
                     start_new_session=True)


def relaunch_app(token_holder):
    print("    !! relaunching app (capturing stderr)", flush=True)
    launch_app()
    deadline = time.time() + RELAUNCH_TIMEOUT_S
    while time.time() < deadline:
        time.sleep(2.0)
        if app_pid() == 0:
            continue
        token_holder[0] = read_token() or token_holder[0]
        try:
            st = get_state(token_holder[0], timeout=4.0)
            if isinstance(st, dict) and st.get("build"):
                print(f"    .. app back up (pid {app_pid()})", flush=True)
                time.sleep(2.0)
                return True
        except Exception:
            continue
    print("    XX app did NOT come back within timeout", flush=True)
    return False


def tail_stderr_exception():
    """Return the most recent uncaught-exception line from the stderr log, if any."""
    try:
        with open(STDERR_LOG, "r", errors="replace") as f:
            lines = f.readlines()
    except Exception:
        return None
    for line in reversed(lines[-200:]):
        if "uncaught exception" in line or "Terminating app due to" in line:
            return line.strip()
    return None


def classify_state(st: dict, baseline_status: str):
    """Return (verdict, status_text). verdict in {playing, error, loading, stale}.

    Classification keys off build.appStatus, the live human-readable status line
    ("Starting playback...", "Playing X ... with 5.1.", "Could not load X: ...").
    build.lastError is deliberately ignored: it is sticky across tracks (it holds
    the last error ever seen), so it would misattribute a previous track's error
    to the current one. Any state still equal to the pre-play baseline is treated
    as not-yet-updated (stale) so the transition window is not misread.
    """
    player = st.get("player", {}) if isinstance(st, dict) else {}
    build = st.get("build", {}) if isinstance(st, dict) else {}
    app_status = (build.get("appStatus") or "")
    low = app_status.lower()

    if app_status and app_status == baseline_status:
        return "stale", app_status
    if player.get("isPlaying") and low.startswith("playing"):
        return "playing", app_status
    if any(k in low for k in ERROR_KEYWORDS):
        return "error", app_status
    if low.startswith("playing"):
        return "playing", app_status
    if any(k in low for k in LOADING_KEYWORDS):
        return "loading", app_status
    return "loading", app_status


def stop_playback(token: str):
    try:
        api_request("/api/player/control", token, {"action": "stop"}, timeout=6.0)
    except Exception:
        pass


def test_one(entry, token_holder):
    """Load+play one file; return a result dict."""
    path = entry["path"]
    track_id = fnv1a64(path)
    result = {
        "path": path,
        "codec": entry.get("codec"),
        "profile": entry.get("profile"),
        "channels": entry.get("channels"),
        "layout": entry.get("layout"),
        "sampleRate": entry.get("sampleRate"),
        "bps": entry.get("bps"),
        "container": entry.get("container"),
        "nAudioStreams": entry.get("nAudioStreams"),
        "expectedNonAudio": entry.get("nAudioStreams", 1) == 0 or entry.get("codec") in (None, "", "none"),
    }

    pid_before = app_pid()
    reports_before = crash_reports()
    if pid_before == 0:
        if not relaunch_app(token_holder):
            result.update(verdict="crash", detail="app down before test; relaunch failed")
            return result
        # App was relaunched; adopt the new pid so the poll loop below does not
        # mistake the expected 0->newpid transition for a fresh crash.
        pid_before = app_pid()
        reports_before = crash_reports()

    token = token_holder[0]
    # Capture the pre-play status so we can ignore stale state during the
    # load transition (appStatus lags the play command by a moment).
    baseline_status = ""
    try:
        st0 = get_state(token, timeout=5.0)
        baseline_status = (st0.get("build", {}) or {}).get("appStatus", "") if isinstance(st0, dict) else ""
    except Exception:
        pass

    t0 = time.time()
    # Issue the play command.
    try:
        api_request("/api/local-music/track", token,
                    {"action": "play", "id": track_id}, timeout=10.0)
    except urllib.error.URLError as e:
        # Connection refused right after POST may mean it just crashed.
        time.sleep(1.0)
        if app_pid() == 0 or app_pid() != pid_before:
            new = crash_reports() - reports_before
            result.update(verdict="crash", load_s=round(time.time() - t0, 2),
                          detail=f"crash on play command ({e})",
                          crashReport=sorted(new)[-1] if new else None)
            relaunch_app(token_holder)
            return result
        result.update(verdict="error", load_s=round(time.time() - t0, 2),
                      detail=f"play command failed: {e}")
        return result

    # Poll for resolution.
    verdict, status_text = "loading", ""
    deadline = t0 + LOAD_TIMEOUT_S
    last_seen = ""
    api_fail_streak = 0
    time.sleep(0.4)  # let the play command register before first classification
    while time.time() < deadline:
        cur_pid = app_pid()
        if cur_pid == 0 or cur_pid != pid_before:
            new = crash_reports() - reports_before
            result.update(verdict="crash", load_s=round(time.time() - t0, 2),
                          detail=f"process gone during load (pid {pid_before}->{cur_pid})",
                          crashReport=sorted(new)[-1] if new else None)
            relaunch_app(token_holder)
            return result
        try:
            st = get_state(token_holder[0], timeout=5.0)
            api_fail_streak = 0
        except Exception:
            api_fail_streak += 1
            # Process alive but API unresponsive for a stretch => main-thread hang.
            if api_fail_streak >= 8:
                result.update(verdict="hang", load_s=round(time.time() - t0, 2),
                              detail="API unresponsive while process alive (main-thread block)")
                return result
            time.sleep(POLL_INTERVAL_S)
            continue
        verdict, status_text = classify_state(st, baseline_status)
        if verdict == "stale":
            time.sleep(POLL_INTERVAL_S)
            continue
        last_seen = status_text
        if verdict == "playing":
            load_s = round(time.time() - t0, 2)
            # Hold playback to let the render loop run; watch for a late crash.
            hold_deadline = time.time() + PLAY_HOLD_S
            while time.time() < hold_deadline:
                time.sleep(0.5)
                cur_pid = app_pid()
                if cur_pid == 0 or cur_pid != pid_before:
                    new = crash_reports() - reports_before
                    result.update(verdict="crash", load_s=load_s,
                                  detail="process gone shortly after playback start",
                                  crashReport=sorted(new)[-1] if new else None)
                    relaunch_app(token_holder)
                    return result
            result.update(verdict="play", load_s=load_s, detail=status_text)
            return result
        if verdict == "error":
            result.update(verdict="error", load_s=round(time.time() - t0, 2),
                          detail=status_text)
            return result
        time.sleep(POLL_INTERVAL_S)

    # Timed out without reaching playing or a clear error.
    cur_pid = app_pid()
    if cur_pid == 0 or cur_pid != pid_before:
        new = crash_reports() - reports_before
        result.update(verdict="crash", load_s=round(time.time() - t0, 2),
                      detail="process gone at timeout",
                      crashReport=sorted(new)[-1] if new else None)
        relaunch_app(token_holder)
        return result
    result.update(verdict="hang", load_s=round(time.time() - t0, 2),
                  detail=f"no playback within {LOAD_TIMEOUT_S:.0f}s; last status='{last_seen}'")
    return result


def load_probe(path):
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return entries


def bucket_key(e):
    return (e.get("codec"), e.get("channels"), e.get("sampleRate"),
            e.get("profile"), e.get("container"), e.get("bps"))


def representative(entries):
    """One file per distinct (codec, channels, rate, profile, container, depth)."""
    seen = {}
    for e in entries:
        seen.setdefault(bucket_key(e), e)
    return list(seen.values())


def already_done(results_path):
    done = {}
    if not os.path.exists(results_path):
        return done
    with open(results_path) as f:
        for line in f:
            try:
                r = json.loads(line)
                done[r["path"]] = r.get("verdict")
            except Exception:
                pass
    return done


def main():
    ap = argparse.ArgumentParser(description="Orbisonic crash-soak test harness")
    ap.add_argument("--mode", choices=["representative", "full"], default="representative")
    ap.add_argument("--probe", default=DEFAULT_PROBE)
    ap.add_argument("--results", default=DEFAULT_RESULTS)
    ap.add_argument("--rerun", action="store_true",
                    help="re-test paths even if a prior result exists")
    ap.add_argument("--rerun-failures", action="store_true",
                    help="re-test only paths whose prior verdict was crash/hang/error")
    ap.add_argument("--limit", type=int, default=0, help="stop after N files (0=all)")
    ap.add_argument("--no-relaunch-start", action="store_true",
                    help="do not relaunch the app under stderr capture at startup")
    args = ap.parse_args()

    entries = load_probe(args.probe)
    if not entries:
        print(f"No probe entries at {args.probe}", file=sys.stderr)
        return 2

    if args.mode == "representative":
        entries = representative(entries)
    entries.sort(key=lambda e: (str(e.get("codec")), e.get("channels") or 0,
                                e.get("sampleRate") or 0, e["path"]))

    done = already_done(args.results)

    def should_skip(e):
        v = done.get(e["path"])
        if v is None:
            return False
        if args.rerun:
            return False
        if args.rerun_failures and v in ("crash", "hang", "error"):
            return False
        return True

    queue = [e for e in entries if not should_skip(e)]
    if args.limit:
        queue = queue[:args.limit]

    # Always (re)launch under stderr capture so every crash's NSException reason
    # is recoverable; a pre-existing instance launched via Finder/open would not
    # have its stderr captured.
    if not args.no_relaunch_start:
        print("Launching Orbisonic under stderr capture ...", flush=True)
        launch_app()
        deadline = time.time() + RELAUNCH_TIMEOUT_S
        up = False
        while time.time() < deadline:
            time.sleep(2.0)
            if app_pid() == 0:
                continue
            tok = read_token()
            try:
                if isinstance(get_state(tok or "", timeout=4.0), dict):
                    up = True
                    break
            except Exception:
                continue
        if not up:
            print("App did not come up under capture; aborting", file=sys.stderr)
            return 2

    token_holder = [read_token()]
    if not token_holder[0]:
        print("Could not read web control token from defaults", file=sys.stderr)
        return 2

    print(f"mode={args.mode} files={len(queue)} (catalog={len(entries)}, "
          f"already-done={len(done)}) results={args.results}", flush=True)

    tally = {"play": 0, "error": 0, "hang": 0, "crash": 0}
    out = open(args.results, "a")
    try:
        for i, e in enumerate(queue, 1):
            name = os.path.basename(e["path"])
            ch = e.get("channels")
            codec = e.get("codec")
            print(f"[{i}/{len(queue)}] {codec}/{ch}ch {name[:60]}", flush=True)
            res = test_one(e, token_holder)
            res["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            if res["verdict"] == "crash":
                res["exception"] = tail_stderr_exception()
            out.write(json.dumps(res) + "\n")
            out.flush()
            tally[res["verdict"]] = tally.get(res["verdict"], 0) + 1
            flag = ""
            if res["verdict"] == "error" and res.get("expectedNonAudio"):
                flag = " (expected: non-audio)"
            print(f"    -> {res['verdict'].upper()} "
                  f"{res.get('load_s','?')}s {res.get('detail','')[:80]}{flag}", flush=True)
            if res.get("exception"):
                print(f"       EXC: {res['exception'][:160]}", flush=True)
            stop_playback(token_holder[0])
            time.sleep(1.0)
    finally:
        out.close()

    print("\n==== TALLY ====", flush=True)
    for k in ("play", "error", "hang", "crash"):
        print(f"  {k:6}: {tally.get(k,0)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
