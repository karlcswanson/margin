"""In-process event bus with a replay buffer.

Every event gets a monotonically increasing `seq`. Clients reconnect with
`?since=<last seq>` and receive whatever they missed (if still buffered).
"""
from __future__ import annotations

import asyncio
import time
from collections import deque
from typing import Any


class EventBus:
    def __init__(self, buffer_size: int = 2000) -> None:
        self._seq = 0
        self._buffer: deque[dict[str, Any]] = deque(maxlen=buffer_size)
        self._subscribers: set[asyncio.Queue[dict[str, Any]]] = set()

    @property
    def seq(self) -> int:
        return self._seq

    def publish(self, type_: str, **data: Any) -> dict[str, Any]:
        self._seq += 1
        event = {"seq": self._seq, "type": type_, "ts": time.time(), **data}
        self._buffer.append(event)
        for q in list(self._subscribers):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                # Slow client: drop it; it will reconnect with ?since= and catch up.
                self._subscribers.discard(q)
        return event

    def replay(self, since: int) -> list[dict[str, Any]]:
        return [e for e in self._buffer if e["seq"] > since]

    def subscribe(self) -> asyncio.Queue[dict[str, Any]]:
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=1000)
        self._subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[dict[str, Any]]) -> None:
        self._subscribers.discard(q)
