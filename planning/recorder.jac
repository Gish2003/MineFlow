"""Records the tool invocations of one planning/recovery run.

Every planning tool calls `trace(...)` from inside its own body, so a log entry
exists only if the tool actually executed - whether the LLM chose to call it or
the deterministic fallback did. A ContextVar scopes the recorder to the current
request, so concurrent runs never mix their logs.
"""

import time;
import dataclasses;
import from contextvars { ContextVar }
import from core.model { ToolCallLog }
import from core.util { to_json, clip }

obj RunRecorder {
    has order_id: str = "",
        line_ids: list[str] = [],
        shipment_ids: list[str] = [],
        calls: list[ToolCallLog] = [],
        seq: int = 0;

    def record(tool: str, args: dict[str, any], result: any, ok: bool, started: float, error: str = "") {
        self.seq += 1;
        self.calls.append(
            ToolCallLog(
                seq=self.seq,
                tool=tool,
                args_json=clip(to_json(args), 600),
                result_json=clip(to_json(plain(result)), 1800),
                ok=ok,
                duration_ms=round((time.perf_counter() - started) * 1000.0, 1),
                error=clip(error, 300)
            )
        );
    }
}

glob _active: ContextVar[RunRecorder | None] = ContextVar("mineflow_run_recorder", `default=None);

def plain(value: any) -> any {
    if dataclasses.is_dataclass(value) and not isinstance(value, type) {
        try {
            return dataclasses.asdict(value);
        } except Exception {
            return str(value);
        }
    }
    if isinstance(value, list) {
        return [plain(v) for v in value];
    }
    return value;
}

def begin_run(order_id: str, line_ids: list[str], shipment_ids: list[str] = []) -> RunRecorder {
    rec = RunRecorder(order_id=order_id, line_ids=line_ids, shipment_ids=shipment_ids);
    _active.set(rec);
    return rec;
}

def end_run {
    _active.set(None);
}

def active -> RunRecorder | None {
    return _active.get();
}

def started -> float {
    return time.perf_counter();
}

def trace(tool: str, args: dict[str, any], result: any, t0: float, ok: bool = True, error: str = "") {
    rec = _active.get();
    if rec is not None {
        rec.record(tool, args, result, ok, t0, error);
    }
}

"""Tools may only touch lines/shipments of the run being planned."""
def line_in_scope(line_id: str) -> bool {
    rec = _active.get();
    return rec is not None and line_id in rec.line_ids;
}

def shipment_in_scope(shipment_id: str) -> bool {
    rec = _active.get();
    return rec is not None and shipment_id in rec.shipment_ids;
}
