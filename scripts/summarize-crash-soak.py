#!/usr/bin/env python3
"""
Summarize Orbisonic crash-soak results into a human-readable report.

Reads the JSONL produced by crash-soak-test.py and prints: an overall tally,
breakdowns by codec / channel count / sample rate, and explicit lists of every
file that CRASHED, HUNG, or ERRORED (real errors separated from expected
non-audio files). Use --markdown to emit a report body for the test-plan doc.
"""
import argparse
import collections
import json
import os
import sys

DEFAULT_RESULTS = "/tmp/crash-soak-results.jsonl"


def load(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    # De-dup by path, keeping the last (most recent) result.
    by_path = {}
    for r in rows:
        by_path[r.get("path")] = r
    return list(by_path.values())


def tally_by(rows, key):
    out = collections.defaultdict(lambda: collections.Counter())
    for r in rows:
        out[r.get(key)][r.get("verdict")] += 1
    return out


def fmt_tally_table(title, table):
    lines = [f"### {title}", "", "| value | play | error | hang | crash |",
             "|---|---|---|---|---|"]
    def sortkey(k):
        return (k is None, str(k))
    for k in sorted(table.keys(), key=sortkey):
        c = table[k]
        lines.append(f"| {k} | {c['play']} | {c['error']} | {c['hang']} | {c['crash']} |")
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=DEFAULT_RESULTS)
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.results):
        print(f"no results at {args.results}", file=sys.stderr)
        return 2
    rows = load(args.results)

    overall = collections.Counter(r.get("verdict") for r in rows)
    crashes = [r for r in rows if r.get("verdict") == "crash"]
    hangs = [r for r in rows if r.get("verdict") == "hang"]
    errors = [r for r in rows if r.get("verdict") == "error"]
    real_errors = [r for r in errors if not r.get("expectedNonAudio")]
    expected_nonaudio = [r for r in errors if r.get("expectedNonAudio")]
    plays = [r for r in rows if r.get("verdict") == "play"]

    def desc(r):
        return (f"{r.get('codec')}/{r.get('channels')}ch/"
                f"{r.get('sampleRate')}Hz/{r.get('bps')}bps "
                f"[{r.get('profile') or '-'}] {os.path.basename(r.get('path',''))}")

    out = []
    out.append("## Results summary\n")
    out.append(f"- Total files tested: **{len(rows)}**")
    out.append(f"- Played OK: **{overall['play']}**")
    out.append(f"- Errored (real): **{len(real_errors)}**")
    out.append(f"- Errored (expected non-audio): **{len(expected_nonaudio)}**")
    out.append(f"- Hung: **{overall['hang']}**")
    out.append(f"- **Crashed: {overall['crash']}**")
    out.append("")

    out.append(fmt_tally_table("By codec", tally_by(rows, "codec")))
    out.append(fmt_tally_table("By channel count", tally_by(rows, "channels")))
    out.append(fmt_tally_table("By sample rate", tally_by(rows, "sampleRate")))

    out.append("## Crashes\n")
    if not crashes:
        out.append("None. \n")
    else:
        # Group crashes by captured exception signature.
        by_exc = collections.defaultdict(list)
        for r in crashes:
            by_exc[(r.get("exception") or "unknown").strip()].append(r)
        for exc, items in sorted(by_exc.items(), key=lambda kv: -len(kv[1])):
            out.append(f"**{len(items)}x** `{exc[:160]}`\n")
            for r in items:
                out.append(f"- {desc(r)}  (load {r.get('load_s')}s)")
            out.append("")

    out.append("## Hangs\n")
    if not hangs:
        out.append("None.\n")
    else:
        for r in hangs:
            out.append(f"- {desc(r)}  ({r.get('detail','')[:90]})")
        out.append("")

    out.append("## Real errors (non-crash load failures)\n")
    if not real_errors:
        out.append("None.\n")
    else:
        by_msg = collections.defaultdict(list)
        for r in real_errors:
            # Coarsely bucket by the leading clause of the error message.
            d = (r.get("detail") or "").split(":")[0].strip() or "(no detail)"
            by_msg[d].append(r)
        for msg, items in sorted(by_msg.items(), key=lambda kv: -len(kv[1])):
            out.append(f"**{len(items)}x** {msg}\n")
            for r in items[:40]:
                out.append(f"- {desc(r)} -> {(r.get('detail') or '')[:110]}")
            if len(items) > 40:
                out.append(f"- ... and {len(items)-40} more")
            out.append("")

    out.append("## Expected non-audio (flagged, not bugs)\n")
    for r in expected_nonaudio:
        out.append(f"- {os.path.basename(r.get('path',''))}")
    out.append("")

    text = "\n".join(out)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
