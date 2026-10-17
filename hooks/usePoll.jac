"""Reusable polling tick. Readers are cached for 60s on a stable argument, so
pages that want live-ish data pass the returned sequence number as the
endpoint's `poll` argument to bust that cache on a timer."""

import from "react" { useEffect }

def:pub usePoll(interval_ms: int = 15000) -> int {
    has seq: int = 0;

    useEffect(lambda {
        id = setInterval(lambda { seq = seq + 1; }, interval_ms);
        return lambda { clearInterval(id); };
    }, []);

    return seq;
}
