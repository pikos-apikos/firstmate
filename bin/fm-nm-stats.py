#!/usr/bin/env python3
"""Summarize `no-mistakes stats --run` without summing resumed raw counters.

Only the versioned CLI's round-delta table supplies token totals. Unknown or
unrecognized usage stays unknown; repeated findings count nonzero finding
rounds, not proof that the same individual finding recurred. Scope compares
the CLI's first/last reported review work snapshots. Signals request supervisor
attention only and never authorize a fix, a gate response, or another run.
"""
import re
import sys
from pathlib import Path


def summarize(run, content):
    unknown = f"telemetry: run={run} models=unknown invocations=unknown input=unknown cached=unknown output=unknown"
    if not re.search(r"^run " + re.escape(run) + r" \(", content):
        return unknown
    invocations, usage = [], []
    section = None
    for line in content.splitlines():
        if line.startswith("STEP"):
            section = "usage" if "Δ IN (round)" in line else "invocations"
            continue
        if not line.strip():
            section = None
            continue
        fields = re.split(r"\s{2,}", line.strip())
        if section == "invocations":
            # A cancelled invocation can have an empty session KEY.
            if len(fields) == 15:
                fields.insert(6, "")
            if len(fields) != 16 or not fields[1].isdigit():
                return unknown
            invocations.append(fields)
        elif section == "usage":
            if len(fields) != 13 or not fields[1].isdigit():
                return unknown
            usage.append(fields)
    if not invocations:
        return unknown
    models = sorted({r[4] if r[4] != "-" else "unknown" for r in invocations})
    # Match rows in order: several invocations can share step/round/purpose.
    identities = [(r[0], r[1], r[2], r[5]) for r in invocations]
    usage_ids = [tuple(r[:4]) for r in usage]
    counters = []
    for column in (4, 6, 5):
        if usage_ids != identities:
            counters.append("unknown")
            continue
        values = [int(r[column]) if r[column].isdigit() else None for r in usage]
        missing = values.count(None)
        total = sum(v for v in values if v is not None)
        counters.append(str(total) + (f"+unknown({missing})" if missing else ""))
    signals = []
    purposes = {}
    for row in invocations:
        if row[12].isdigit() and int(row[12]) > 0:
            purposes.setdefault((row[0], row[2]), set()).add(row[1])
    repeated = max((len(rounds) for rounds in purposes.values()), default=0)
    if repeated >= 3:
        signals.append(f"repeated-finding-rounds={repeated}")
    work = [tuple(map(int, r[13].split("/"))) for r in invocations
            if r[2] == "review" and re.fullmatch(r"\d+/\d+", r[13])]
    if len(work) >= 2 and any(last > first for first, last in zip(work[0], work[-1])):
        signals.append("growing-scope=%d/%d->%d/%d" % (*work[0], *work[-1]))
    return (f"telemetry: run={run} models={','.join(models)} invocations={len(invocations)} "
            f"input={counters[0]} cached={counters[1]} output={counters[2]}"
            + (" attention: " + " ".join(signals) if signals else ""))


if __name__ == "__main__":
    print(summarize(sys.argv[1], Path(sys.argv[2]).read_text(encoding="utf-8")))
