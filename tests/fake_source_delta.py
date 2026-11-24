#!/usr/bin/env python3
"""Small protocol peer. Does not implement the Markdown renderer."""
import json
import os
from pathlib import Path
import sys


def emit(kind, request, **fields):
    print(json.dumps(dict(type=kind, id=request["id"], **fields)), flush=True)


cache = {}
log = Path(os.environ["MARKDOWN_DELTA_LOG"])
miss = Path(os.environ["MARKDOWN_DELTA_MISS"])
for wire in sys.stdin.buffer:
    r = json.loads(wire)
    kind = r["type"]
    audit = {key: r[key] for key in ("type", "id", "session", "base", "from", "del", "remember_source", "incremental")
             if key in r}
    audit["wire_bytes"] = len(wire)
    audit["pid"] = os.getpid()
    with log.open("a", encoding="utf-8") as out:
        out.write(json.dumps(audit) + "\n")
    if kind == "ping":
        caps = {"render": True, "incremental": True}
        if os.environ.get("MARKDOWN_DELTA_CAP") == "1":
            caps["render_source_delta"] = True
        emit("pong", r, capabilities=caps, protocol_version=4, version="fixture")
    elif kind == "forget":
        cache.pop(r["session"], None)
    elif kind in ("render", "render_delta"):
        session = r["session"]
        retain = False
        if kind == "render_delta":
            if miss.exists():
                miss.unlink()
                cache.pop(session, None)
            base = cache.get(session)
            if base is None or base[0] != r["base"]:
                emit("render_source_missing", r)
                continue
            index, count, inserted = r["from"], r["del"], r["insert"]
            hold = base[1]
            lines = hold[:index] + inserted + hold[index + count:]
            retain = True
        else:
            lines = r["lines"]
            retain = r.get("remember_source", False)
        if retain:
            cache[session] = (r["id"], lines)
        else:
            cache.pop(session, None)
        # Mirror two exact source lines so the real Vim preview observes
        # correctness, including unrelated retained document content.
        output = [{"t": lines[0], "s": 1}, {"t": lines[1499], "s": 1500}]
        emit("render_result", r, width=r["width"], total=2, src_sum=1501,
             lines=output, toc=[], links=[], blocks=[],
             **({"source_rev": r["id"]} if retain else {}))
