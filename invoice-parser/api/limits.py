"""In-memory sliding-window rate limits. They reset when the process does,
which is fine for a service whose only state is counting."""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque


class Limiter:
    def __init__(self, limit: int, window_seconds: float):
        self.limit = limit
        self.window = window_seconds
        self.hits: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self.lock:
            hits = self.hits[key]
            while hits and now - hits[0] > self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return False
            hits.append(now)
            return True


# A phone attaching a day's receipts stays far below these.
PARSE_PER_MINUTE = Limiter(20, 60)
PARSE_PER_DAY = Limiter(400, 24 * 3600)
INSTALLS_PER_HOUR = Limiter(10, 3600)
