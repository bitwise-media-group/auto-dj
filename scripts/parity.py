#!/usr/bin/env python3
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
"""Compares a Go plan with a Swift plan by cue beat and prints a mover report (ADR 0018).

    scripts/parity.py plan go.json swift.json      # plan.json (apply)
    scripts/parity.py set go.json swift.json       # set-plan.json (set --plan-out)

Gate: >= 98 % of cues on the same beat, none moved by more than a phrase (16 beats), and
every mover listed here for review. Exits 1 when the gate fails.
"""
import json
import sys

PHRASE = 16


def plan_cues(items):
    out = {}
    for x in items:
        for c in x.get("hot") or []:
            out[(x["title"], "hot " + c["name"])] = c["beat"]
        n = {}
        for c in x.get("mem") or []:
            k = c["name"]
            n[k] = n.get(k, 0) + 1
            out[(x["title"], "mem %s #%d" % (k, n[k]))] = c["beat"]
    return out


def set_cues(doc):
    out = {("order", "order"): tuple(doc.get("order") or [])}
    for a in doc.get("actions") or []:
        t = a.get("title") or a.get("id")
        for slot in ("e", "g", "E", "G"):
            v = a.get(slot)
            if v:
                out[(t, slot.upper() + " " + v.get("name", v.get("Name", "")))] = v.get("beat", v.get("Beat"))
        for k in ("bass_swap_beat", "exit_beat"):
            if a.get(k) is not None:
                out[(t, k)] = a[k]
        n = {}
        for m in a.get("markers") or []:
            name = m.get("name", m.get("Name"))
            n[name] = n.get(name, 0) + 1
            out[(t, "marker %s #%d" % (name, n[name]))] = m.get("beat", m.get("Beat"))
    return out


def main():
    kind, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
    ga, sa = json.load(open(a)), json.load(open(b))
    f = plan_cues if kind == "plan" else set_cues
    go, sw = f(ga), f(sa)
    keys = sorted(set(go) | set(sw), key=str)
    same = moved = big = only = 0
    for k in keys:
        x, y = go.get(k), sw.get(k)
        if x == y:
            same += 1
            continue
        if x is None or y is None:
            only += 1
            print("ONLY-%s  %-40s %-24s %s" % ("SWIFT" if x is None else "GO", k[0][:40], k[1], x if y is None else y))
            continue
        moved += 1
        far = isinstance(x, int) and isinstance(y, int) and abs(x - y) > PHRASE
        big += far
        print("%s %-40s %-24s %s -> %s" % ("MOVED!" if far else "moved ", k[0][:40], k[1], x, y))
    n = len(keys)
    pct = 100.0 * same / max(n, 1)
    print("\n%d cues: %d same (%.1f%%), %d moved (%d by more than a phrase), %d on one side only"
          % (n, same, pct, moved, big, only))
    ok = pct >= 98 and big == 0
    print("GATE", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
