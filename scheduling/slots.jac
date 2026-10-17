"""Loading slots, loader capacity and loading-wait ESTIMATES.

A plant has `bays` loading bays and operating hours; hourly slots are
materialized a few days ahead. A slot is serviceable when it is open, the plant
is not unavailable, no loading/equipment delay covers it, and a loader on shift
is still free in that hour. Wait times are estimates, never a promise of a
queue-free slot.
"""

import from core.model { Plant, LoadingSlot, HasSlot, DelayNotice, HasDelay, Account }
import from core.enums { SlotStatus, PlantStatus, DelayKind, Role }
import from core.hub { get_slot, all_plants, all_accounts }
import from core.config { settings }
import from core.util { now }

glob DAY: float = 86400.0,
     HOUR: float = 3600.0;

obj LoadingEstimate {
    has plant_id: str,
        found: bool,
        slot_id: str = "",
        slot_start: float = 0.0,
        slot_end: float = 0.0,
        bay: int = 0,
        wait_minutes: float = 0.0,
        loading_minutes: float = 0.0,
        loaders_on_shift: int = 0,
        queue_ahead: int = 0,
        note: str = "Estimate based on reserved slots, loader shifts and plant readiness; not a guarantee.";
}

obj SlotView {
    has id: str,
        plant_id: str,
        bay: int,
        start_ts: float,
        end_ts: float,
        status: str,
        shipment_id: str,
        blocked_reason: str,
        loaders_on_shift: int = 0;
}

def tz_offset -> float {
    return settings().tz_offset_hours * HOUR;
}

def day_start(ts: float) -> float {
    off = tz_offset();
    return ((ts + off) // DAY) * DAY - off;
}

def local_hour(ts: float) -> int {
    return int(((ts - day_start(ts)) // HOUR));
}

"""Materialize hourly slots up to `days` ahead (idempotent). Writes - never call from agent tools."""
def ensure_slots(p: Plant, days: int = 3) {
    today = day_start(now());
    target_end = today + days * DAY;
    start = max(p.slots_until, today);
    if start >= target_end {
        return;
    }
    d = start;
    while d < target_end {
        for h in range(p.open_hour, p.close_hour) {
            s_ts = d + h * HOUR;
            for b in range(1, p.bays + 1) {
                p +>:HasSlot():+> LoadingSlot(plant_id=jid(p), bay=b, start_ts=s_ts, end_ts=s_ts + HOUR);
            }
        }
        d = d + DAY;
    }
    p.slots_until = target_end;
}

def ensure_all_slots(days: int = 3) {
    for p in all_plants() {
        ensure_slots(p, days);
    }
}

def plant_slots(p: Plant, after_ts: float, before_ts: float) -> list[LoadingSlot] {
    rows = [p ->:HasSlot:-> [?:LoadingSlot, start_ts >= after_ts, start_ts <= before_ts]];
    return sorted(rows, key=lambda (s: LoadingSlot) { s.start_ts * 10 + s.bay; });
}

def loaders_of_plant(plant_id: str) -> list[Account] {
    return [a for a in all_accounts() if a.role == Role.LOADER and a.active and plant_id in a.plant_ids];
}

def loaders_on_shift(plant_id: str, ts: float) -> int {
    h = local_hour(ts);
    count = 0;
    for a in loaders_of_plant(plant_id) {
        if a.shift_start_hour <= h and h < a.shift_end_hour {
            count += 1;
        }
    }
    return count;
}

def active_delays(p: Plant) -> list[DelayNotice] {
    return [d for d in [p ->:HasDelay:-> [?:DelayNotice]] if d.active];
}

def blocking_delay(p: Plant, ts: float) -> DelayNotice | None {
    for d in active_delays(p) {
        if (d.kind == DelayKind.LOADING or d.kind == DelayKind.EQUIPMENT) and d.start_ts <= ts and ts < d.end_ts {
            return d;
        }
    }
    return None;
}

def held_in_hour(p: Plant, slot_start: float) -> int {
    return len([s for s in plant_slots(p, slot_start, slot_start) if s.status == SlotStatus.HELD]);
}

"""Why a slot cannot be used right now (empty list = serviceable)."""
def slot_problems(p: Plant, s: LoadingSlot) -> list[str] {
    problems: list[str] = [];
    if s.status != SlotStatus.OPEN {
        problems.append("Slot is " + str(s.status) + ".");
    }
    if p.status == PlantStatus.UNAVAILABLE {
        problems.append("Plant is unavailable: " + (p.status_note or "no reason given") + ".");
    }
    d = blocking_delay(p, s.start_ts);
    if d is not None {
        problems.append("Loading delay in effect: " + d.description);
    }
    if s.start_ts < now() + 15 * 60 {
        problems.append("Slot starts too soon (or is in the past).");
    }
    shift = loaders_on_shift(jid(p), s.start_ts);
    if shift <= held_in_hour(p, s.start_ts) {
        problems.append("No free loader on shift for that hour.");
    }
    return problems;
}

def loading_minutes(p: Plant, quantity_t: float) -> float {
    rate = p.loader_rate_tph if p.loader_rate_tph > 0 else 100.0;
    return round(p.setup_minutes + quantity_t / rate * 60.0, 1);
}

"""First serviceable slot at or after `earliest_ts` (and before `latest_ts`)."""
def estimate_wait(p: Plant, earliest_ts: float, quantity_t: float, latest_ts: float = 0.0) -> LoadingEstimate {
    start = max(earliest_ts, now() + 15 * 60);
    horizon = latest_ts if latest_ts > start else start + 3 * DAY;
    for s in plant_slots(p, day_start(start) - DAY, horizon) {
        if s.start_ts + HOUR <= start {
            continue;
        }
        if slot_problems(p, s) {
            continue;
        }
        queue = held_in_hour(p, s.start_ts);
        gap = max(0.0, (s.start_ts - start) / 60.0);
        return LoadingEstimate(
            plant_id=jid(p),
            found=True,
            slot_id=jid(s),
            slot_start=s.start_ts,
            slot_end=s.end_ts,
            bay=s.bay,
            wait_minutes=round(gap + p.readiness_buffer_min + 8 * queue, 1),
            loading_minutes=loading_minutes(p, quantity_t),
            loaders_on_shift=loaders_on_shift(jid(p), s.start_ts),
            queue_ahead=queue
        );
    }
    return LoadingEstimate(plant_id=jid(p), found=False, note="No serviceable loading slot in the search window.");
}

def slot_view(s: LoadingSlot) -> SlotView {
    return SlotView(
        id=jid(s),
        plant_id=s.plant_id,
        bay=s.bay,
        start_ts=s.start_ts,
        end_ts=s.end_ts,
        status=str(s.status),
        shipment_id=s.shipment_id,
        blocked_reason=s.blocked_reason,
        loaders_on_shift=loaders_on_shift(s.plant_id, s.start_ts)
    );
}

def open_slot_views(p: Plant, after_ts: float, before_ts: float, limit: int = 12) -> list[SlotView] {
    out: list[SlotView] = [];
    for s in plant_slots(p, after_ts, before_ts) {
        if not slot_problems(p, s) {
            out.append(slot_view(s));
            if len(out) >= limit {
                break;
            }
        }
    }
    return out;
}
