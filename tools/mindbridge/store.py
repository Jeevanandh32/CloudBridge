"""SQLite store for predict-mode samples.

Default path ~/.mindbridge/signals.db, or the MINDBRIDGE_DB environment variable. The store
must never live inside the repo: samples are live telemetry, not source.
"""
from __future__ import annotations

import os
import sqlite3
import time
from pathlib import Path

from .detect import Sample
from .model import REPO_ROOT

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    ts REAL NOT NULL, signal TEXT NOT NULL, component TEXT NOT NULL,
    value REAL NOT NULL, unit TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '',
    collector TEXT NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX IF NOT EXISTS samples_key ON samples (signal, component, ts);
CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts);
CREATE TABLE IF NOT EXISTS runs (
    ts REAL NOT NULL, collector TEXT NOT NULL, status TEXT NOT NULL,
    message TEXT NOT NULL DEFAULT '', samples INTEGER NOT NULL DEFAULT 0, duration_s REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS runs_key ON runs (collector, ts);
"""


def default_path() -> Path:
    env = os.environ.get("MINDBRIDGE_DB")
    return Path(env).expanduser() if env else Path.home() / ".mindbridge" / "signals.db"


class Store:
    def __init__(self, path: Path | str | None = None):
        self.path = Path(path).expanduser().resolve() if path else default_path().resolve()
        if self.path == REPO_ROOT or REPO_ROOT in self.path.parents:
            raise ValueError(f"refusing to keep the signal store inside the repo ({self.path}); "
                             "set MINDBRIDGE_DB to a path outside it")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(self.path))
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    def add_samples(self, samples: list[Sample], collector: str = "") -> int:
        self.db.executemany(
            "INSERT OR IGNORE INTO samples (ts, signal, component, value, unit, detail, collector) VALUES (?,?,?,?,?,?,?)",
            [(s.ts, s.signal, s.component, float(s.value), s.unit, s.detail, collector) for s in samples])
        self.db.commit()
        return len(samples)  # re-sent CloudWatch datapoints (same ts) are ignored by the unique index

    def add_run(self, collector: str, status: str, message: str = "", samples: int = 0,
                duration_s: float = 0.0, ts: float | None = None) -> None:
        self.db.execute("INSERT INTO runs (ts, collector, status, message, samples, duration_s) VALUES (?,?,?,?,?,?)",
                        (ts or time.time(), collector, status, message, samples, duration_s))
        self.db.commit()

    def samples(self, since: float | None = None, signal: str | None = None) -> list[Sample]:
        q, args = "SELECT ts, signal, component, value, unit, detail FROM samples WHERE 1=1", []
        if since is not None:
            q += " AND ts >= ?"
            args.append(since)
        if signal is not None:
            q += " AND signal = ?"
            args.append(signal)
        q += " ORDER BY ts"
        return [Sample(*row) for row in self.db.execute(q, args)]

    def last_runs(self) -> list[dict]:
        rows = self.db.execute(
            "SELECT r.collector, r.ts, r.status, r.message, r.samples, r.duration_s FROM runs r "
            "JOIN (SELECT collector, MAX(ts) AS m FROM runs GROUP BY collector) x "
            "ON r.collector = x.collector AND r.ts = x.m ORDER BY r.collector")
        return [dict(zip(("collector", "ts", "status", "message", "samples", "duration_s"), r)) for r in rows]
