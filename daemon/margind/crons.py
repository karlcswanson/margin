"""When Claude's scheduled wakeups fire next. Claude Code reports a session's
wakeups on its Stop hook as 5-field cron expressions in local time; the app
shows "Claude will check back at 3:40"."""
from __future__ import annotations

import time
from datetime import datetime, timedelta

RANGES = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]   # minute hour day month weekday
LOOKAHEAD = 366 * 24 * 60                                 # minutes


def _field(spec: str, lo: int, hi: int) -> set[int]:
    out: set[int] = set()
    for part in spec.split(","):
        rng, _, step = part.partition("/")
        if rng == "*":
            a, b = lo, hi
        elif "-" in rng:
            a, b = (int(x) for x in rng.split("-", 1))
        else:
            a = b = int(rng)
            if step:
                b = hi
        n = int(step) if step else 1
        if n < 1 or a < lo or b > hi or a > b:
            raise ValueError(f"bad cron field {spec!r}")
        out.update(range(a, b + 1, n))
    return out


def next_fire(expr: str, after: float | None = None) -> float | None:
    """The next time `expr` matches, strictly after `after` (default now), or
    None if it never does within a year or can't be read."""
    try:
        fields = expr.split()
        if len(fields) != 5:
            return None
        minute, hour, dom, month, dow = (_field(f, lo, hi) for f, (lo, hi) in zip(fields, RANGES))
    except ValueError:
        return None
    if 7 in dow:
        dow = (dow - {7}) | {0}
    # Standard cron: when both day fields are restricted, either one matching is enough.
    either = fields[2] != "*" and fields[4] != "*"
    t = datetime.fromtimestamp(time.time() if after is None else after).replace(second=0, microsecond=0)
    for _ in range(LOOKAHEAD):
        t += timedelta(minutes=1)
        if t.minute not in minute or t.hour not in hour or t.month not in month:
            continue
        day, wday = t.day in dom, (t.weekday() + 1) % 7 in dow
        if (day or wday) if either else (day and wday):
            return t.timestamp()
    return None
