"""Exception register and the Exception Recovery workflow.

Operational problems (plant unavailable, slot lost, stock shortage, driver
cancellation, vehicle issue, late loading, ...) become `ExceptionCase` records
linked to the affected shipment/order/plant. The recovery agent (or labelled
fallback) gathers fresh evidence with tools and proposes validated
alternatives; nothing changes until a dispatcher approves one, and every
approval is re-validated against live state at that moment.
"""

import from core.model { ExceptionCase, HasException, Shipment, Order, HasRun, AgentRun, DriverOffer, HasOffer }
import from core.enums {
    ExceptionType, ExceptionStatus, ShipmentStatus, Role, OfferStatus, TruckStatus,
    ReservationStatus, AgentRunStatus
}
import from core.hub {
    get_hub, get_exception, get_shipment, get_order, get_line, get_lot, get_slot, get_plant,
    get_run, get_truck, get_account, all_exceptions, all_shipments, offers_of, name_of_plant,
    get_reservation
}
import from core.access {
    AppError, Caller, current_caller, require_roles, can_view_exception, dispatcher_covers_plant,
    require_dispatch_scope, not_found, invalid, bad_state, conflict
}
import from core.state_machines { assert_exception, assert_shipment }
import from core.audit { audit, timeline, notify, notify_dispatchers, notify_plant_managers, notify_order_buyer }
import from core.views { ActionResult }
import from core.util { now, new_ref, clean_text, fmt_time, clip }
import from planning.workflow { execute_recovery, run_view, AgentRunView, runs_of }
import from planning.tools { driver_candidates, truck_candidates }
import from reservations.reserve { rereserve_problems, rereserve }
import from orders.rollup { refresh_order_status }
import from payments.ledger { driver_pay }
import from core.hub { mineral_by_code }
import from scheduling.slots { ensure_all_slots }

obj ExceptionView {
    has id: str,
        ref: str,
        ex_type: str,
        severity: str,
        status: str,
        summary: str,
        detail: str,
        order_id: str,
        order_ref: str,
        shipment_id: str,
        shipment_ref: str,
        shipment_status: str,
        plant_name: str,
        created_by_name: str,
        created_at: float,
        resolved_at: float,
        resolution: str,
        latest_run_id: str = "",
        can_run_recovery: bool = False;
}

obj ExceptionListResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        exceptions: list[ExceptionView] = [],
        counts: dict[str, int] = {};
}

obj ExceptionDetailResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: ExceptionView | None = None,
        runs: list[AgentRunView] = [];
}

glob OPEN_EX: list[str] = ["OPEN", "RECOVERY_PROPOSED", "NO_FEASIBLE_OPTION"];

"""Create (or reuse) an open exception for this shipment/type and alert people."""
def raise_exception(
    ex_type: ExceptionType,
    severity: str,
    summary: str,
    detail: str,
    sh: Shipment | None,
    plant_id: str,
    created_by: str
) -> ExceptionCase {
    sid = jid(sh) if sh is not None else "";
    for ex in all_exceptions() {
        if ex.ex_type == ex_type and ex.shipment_id == sid and ex.plant_id == plant_id and str(ex.status) in OPEN_EX {
            ex.detail = clip(detail, 1000);
            return ex;
        }
    }
    ex = ExceptionCase(
        ref=new_ref("EX"), ex_type=ex_type, severity=severity, summary=clip(summary, 200), detail=clip(detail, 1000),
        order_id=sh.order_id if sh is not None else "", shipment_id=sid, plant_id=plant_id,
        created_by=created_by, created_at=now()
    );
    get_hub() +>:HasException():+> ex;
    notify_dispatchers(plant_id, "error" if severity == "HIGH" else "warning", ex.ref + " · " + str(ex_type).replace("_", " ").lower(), summary, "/dispatch/exceptions/" + jid(ex));
    if sh is not None {
        timeline(sh.order_id, "EXCEPTION", summary, detail, sid);
    }
    return ex;
}

"""Lazy detection of late loading: slot started 20+ minutes ago, nobody checked in."""
def sweep_late_loading(c: Caller) {
    t = now();
    for sh in all_shipments() {
        if not dispatcher_covers_plant(c, sh.plant_id) {
            continue;
        }
        if str(sh.status) not in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED"] {
            continue;
        }
        slot = get_slot(sh.slot_id);
        if slot is None or slot.start_ts + 20 * 60 > t or slot.start_ts < t - 12 * 3600 {
            continue;
        }
        if sh.driver_checked_in_at > 0 or sh.loader_checked_in_at > 0 {
            continue;
        }
        raise_exception(ExceptionType.LATE_LOADING, "MEDIUM", sh.ref + " missed its loading slot at " + fmt_time(slot.start_ts), "Nobody has checked in for the slot. Re-plan the slot or reassign.", sh, sh.plant_id, "system");
    }
}

def exception_view(c: Caller, ex: ExceptionCase) -> ExceptionView {
    sh = get_shipment(ex.shipment_id);
    o = get_order(ex.order_id);
    author = get_account(ex.created_by);
    return ExceptionView(
        id=jid(ex), ref=ex.ref, ex_type=str(ex.ex_type), severity=ex.severity, status=str(ex.status),
        summary=ex.summary, detail=ex.detail, order_id=ex.order_id, order_ref=o.ref if o is not None else "",
        shipment_id=ex.shipment_id, shipment_ref=sh.ref if sh is not None else "",
        shipment_status=str(sh.status) if sh is not None else "", plant_name=name_of_plant(ex.plant_id),
        created_by_name=author.display_name if author is not None else "MineFlow system",
        created_at=ex.created_at, resolved_at=ex.resolved_at, resolution=ex.resolution,
        latest_run_id=ex.last_run_id,
        can_run_recovery=sh is not None and str(ex.status) in OPEN_EX and dispatcher_covers_plant(c, ex.plant_id)
    );
}

def:protect exceptions_list(status_filter: str = "OPEN", poll: int = 0) -> ExceptionListResult {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER, Role.STORE_MANAGER, Role.ADMIN]);
        if c.has_role(Role.DISPATCHER) {
            sweep_late_loading(c);
        }
        rows: list[ExceptionView] = [];
        counts: dict[str, int] = {"OPEN": 0, "RESOLVED": 0, "ALL": 0};
        for ex in sorted(all_exceptions(), key=lambda (x: ExceptionCase) { -x.created_at; }) {
            if not can_view_exception(c, ex) {
                continue;
            }
            is_open = str(ex.status) in OPEN_EX;
            counts["ALL"] = counts["ALL"] + 1;
            counts["OPEN" if is_open else "RESOLVED"] = counts["OPEN" if is_open else "RESOLVED"] + 1;
            if status_filter == "OPEN" and not is_open {
                continue;
            }
            if status_filter == "RESOLVED" and is_open {
                continue;
            }
            rows.append(exception_view(c, ex));
        }
        return ExceptionListResult(ok=True, exceptions=rows, counts=counts);
    } except AppError as e {
        return ExceptionListResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect exception_detail(exception_id: str, poll: int = 0) -> ExceptionDetailResult {
    _ = poll;
    try {
        c = current_caller();
        ex = get_exception(exception_id);
        if ex is None or not can_view_exception(c, ex) {
            raise not_found("Exception");
        }
        return ExceptionDetailResult(ok=True, data=exception_view(c, ex), runs=[run_view(r) for r in runs_of(ex)][:5]);
    } except AppError as e {
        return ExceptionDetailResult(ok=False, code=e.code, message=e.message);
    }
}

"""Run the Exception Recovery Agent (or labelled fallback). Proposes only."""
def:protect run_recovery(exception_id: str) -> ExceptionDetailResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        ex = get_exception(exception_id);
        if ex is None or not can_view_exception(c, ex) {
            raise not_found("Exception");
        }
        require_dispatch_scope(c, ex.plant_id);
        if str(ex.status) not in OPEN_EX {
            raise bad_state("This exception is already closed.");
        }
        sh = get_shipment(ex.shipment_id);
        if sh is None {
            raise bad_state("This exception is not linked to a shipment that can be re-planned.");
        }
        ensure_all_slots(3);
        run = execute_recovery(ex, sh, c.account_id);
        target = ExceptionStatus.RECOVERY_PROPOSED if run.status == AgentRunStatus.SUCCEEDED else ExceptionStatus.NO_FEASIBLE_OPTION;
        if ex.status != target {
            assert_exception(ex.status, target);
            ex.status = target;
        }
        ex.last_run_id = jid(run);
        audit(c, "RECOVERY_RUN", "ExceptionCase", exception_id, ex.ref + ": " + str(run.status) + " via " + str(run.mode) + ", " + str(len(run.tool_calls)) + " tool calls", "", [ex.plant_id]);
        return ExceptionDetailResult(ok=True, data=exception_view(c, ex), runs=[run_view(r) for r in runs_of(ex)][:5]);
    } except AppError as e {
        return ExceptionDetailResult(ok=False, code=e.code, message=e.message);
    }
}

"""Dispatcher approves one validated recovery option; it is re-validated now."""
def:protect apply_recovery_option(exception_id: str, run_id: str, option_id: str, reason: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        ex = get_exception(exception_id);
        if ex is None or not can_view_exception(c, ex) {
            raise not_found("Exception");
        }
        require_dispatch_scope(c, ex.plant_id);
        if str(ex.status) not in OPEN_EX {
            raise bad_state("This exception is already closed.");
        }
        run = get_run(run_id);
        if run is None or run.subject_id != exception_id {
            raise not_found("Recovery run");
        }
        opt = None;
        for a in run.actions {
            if a.option_id == option_id {
                opt = a;
            }
        }
        if opt is None {
            raise invalid("Unknown recovery option.");
        }
        sh = get_shipment(opt.shipment_id);
        o = get_order(sh.order_id) if sh is not None else None;
        line = get_line(sh.line_id) if sh is not None else None;
        if sh is None or o is None or line is None {
            raise not_found("Shipment");
        }
        why = clean_text(reason, 500);
        summary = "";
        if opt.action == "REASSIGN_DRIVER" {
            if str(sh.status) not in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "EXCEPTION"] {
                raise bad_state("The load has progressed; a driver can no longer be swapped here.");
            }
            lot = get_lot(sh.lot_id);
            m = mineral_by_code(lot.mineral_code) if lot is not None else None;
            drivers = {d.driver_id: d for d in driver_candidates(sh)};
            trucks = {t.truck_id: t for t in truck_candidates(sh, m.allowed_bodies if m is not None else [])};
            if opt.driver_id not in drivers or not drivers[opt.driver_id].eligible or opt.truck_id not in trucks or not trucks[opt.truck_id].eligible {
                raise conflict("That driver or truck is no longer eligible; run recovery again.");
            }
            for off in offers_of(sh) {
                if off.status in [OfferStatus.OFFERED, OfferStatus.ACCEPTED] {
                    off.status = OfferStatus.WITHDRAWN;
                    if off.driver_id != opt.driver_id {
                        notify(off.driver_id, "warning", "Job reassigned", sh.ref + " was reassigned by dispatch.");
                    }
                }
            }
            old_truck = get_truck(sh.truck_id);
            if old_truck is not None and old_truck.status == TruckStatus.IN_USE {
                old_truck.status = TruckStatus.AVAILABLE;
            }
            sh +>:HasOffer():+> DriverOffer(shipment_id=jid(sh), driver_id=opt.driver_id, truck_id=opt.truck_id, pay_amount=driver_pay(sh.distance_km), created_at=now(), note="Reassignment after " + str(ex.ex_type).replace("_", " ").lower());
            sh.driver_id = "";
            sh.truck_id = opt.truck_id;
            sh.status = ShipmentStatus.OFFERED;
            notify(opt.driver_id, "info", "New delivery offer " + sh.ref, "Pickup at " + name_of_plant(sh.plant_id) + ". Please accept or reject.", "/driver");
            summary = "Offered " + sh.ref + " to a replacement driver";
        } else {
            lot = get_lot(opt.lot_id);
            slot = get_slot(opt.slot_id);
            if str(sh.status) not in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "AWAITING_LOADING", "EXCEPTION"] {
                raise bad_state("The load has progressed; supply can no longer be switched.");
            }
            problems = rereserve_problems(o, line, sh, lot, slot);
            if problems or lot is None or slot is None {
                raise conflict("This option is no longer feasible: " + " ".join(problems) + " Run recovery again.");
            }
            plant_changed = lot.plant_id != sh.plant_id;
            rereserve(o, line, sh, lot, slot, "Recovery " + ex.ref + ": " + option_id);
            if plant_changed {
                if sh.loader_id {
                    notify(sh.loader_id, "warning", "Loading job moved", sh.ref + " moved to another plant.");
                }
                sh.loader_id = "";
                for off in offers_of(sh) {
                    if off.status in [OfferStatus.OFFERED, OfferStatus.ACCEPTED] {
                        off.status = OfferStatus.WITHDRAWN;
                        notify(off.driver_id, "warning", "Job changed", sh.ref + " now loads at " + name_of_plant(lot.plant_id) + "; dispatch will re-offer it.");
                    }
                }
                truck = get_truck(sh.truck_id);
                if truck is not None and truck.status == TruckStatus.IN_USE {
                    truck.status = TruckStatus.AVAILABLE;
                }
                sh.driver_id = "";
                sh.truck_id = "";
                sh.status = ShipmentStatus.AWAITING_DISPATCH;
            } else {
                sh.status = ShipmentStatus.SCHEDULED if sh.driver_id else ShipmentStatus.AWAITING_DISPATCH;
                if sh.driver_id {
                    notify(sh.driver_id, "info", "Slot changed for " + sh.ref, "New loading slot " + fmt_time(slot.start_ts) + ".");
                }
                if sh.loader_id {
                    notify(sh.loader_id, "info", "Slot changed for " + sh.ref, "New loading slot " + fmt_time(slot.start_ts) + ".");
                }
            }
            summary = sh.ref + " now loads at " + name_of_plant(lot.plant_id) + " (lot " + lot.code + ", slot " + fmt_time(slot.start_ts) + ")";
        }
        sh.updated_at = now();
        assert_exception(ex.status, ExceptionStatus.RESOLVED);
        ex.status = ExceptionStatus.RESOLVED;
        ex.resolved_at = now();
        ex.resolution = summary + (" - " + why if why else "");
        run.applied_option_id = option_id;
        refresh_order_status(o);
        timeline(jid(o), "RECOVERY", "Plan changed: " + summary, (run.what_changed + " " + opt.rationale).strip(), jid(sh), c);
        notify_order_buyer(o, "info", "Your delivery plan changed", summary + ". Reason: " + (run.what_changed or ex.summary)[:200]);
        audit(c, "RECOVERY_APPLIED", "ExceptionCase", exception_id, summary, why, [ex.plant_id, sh.plant_id]);
        return ActionResult(ok=True, id=exception_id, message=summary);
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect close_exception(exception_id: str, outcome: str, reason: str) -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        ex = get_exception(exception_id);
        if ex is None or not can_view_exception(c, ex) {
            raise not_found("Exception");
        }
        require_dispatch_scope(c, ex.plant_id);
        if outcome not in ["RESOLVED", "DISMISSED"] {
            raise invalid("Choose an outcome: RESOLVED or DISMISSED.");
        }
        why = clean_text(reason, 500);
        if len(why) < 5 {
            raise invalid("An outcome needs a reason - free text alone is not enough, but a reason is required.");
        }
        dst = ExceptionStatus(outcome);
        assert_exception(ex.status, dst);
        ex.status = dst;
        ex.resolved_at = now();
        ex.resolution = why;
        audit(c, "EXCEPTION_" + outcome, "ExceptionCase", exception_id, ex.ref + " " + outcome.lower(), why, [ex.plant_id]);
        return ActionResult(ok=True, id=exception_id, message=ex.ref + " " + outcome.lower() + ".");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
