#!/usr/bin/env python3
"""Génère N logs JSON de démo (NDJSON) pour l'index Quickwit demo-logs.

    qw-demo-logs.py [N]  > logs.ndjson
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
services = ["api", "checkout", "payment", "catalog", "auth"]
levels = ["INFO"] * 14 + ["WARN"] * 4 + ["ERROR"] * 2
messages = {
    "INFO": ["request completed", "user logged in", "cache hit for key {k}", "order {k} created"],
    "WARN": ["slow query took {ms} ms", "retrying request to {svc}", "cache miss for key {k}"],
    "ERROR": ["connection refused by {svc}", "timeout while calling {svc}", "payment declined for order {k}"],
}
now = datetime.now(timezone.utc)
for i in range(N):
    lvl = random.choice(levels)
    svc = random.choice(services)
    ms = random.randint(2, 40) if lvl == "INFO" else random.randint(200, 5000)
    msg = random.choice(messages[lvl]).format(k=random.randint(1000, 9999), ms=ms, svc=random.choice(services))
    ts = now - timedelta(seconds=random.randint(0, 3600))
    print(json.dumps({
        "timestamp": ts.isoformat().replace("+00:00", "Z"),
        "level": lvl,
        "service": svc,
        "message": msg,
        "latency_ms": ms,
        "trace_id": f"{random.getrandbits(64):016x}",
    }))
