"""Loader workflow (mobile-first UI). A loader sees only jobs assigned to them
plus unassigned (eligible) jobs at their own plant(s). Loading is authorized
only after the loader verifies the stock lot, the truck plate and the order
against the reservation; finishing requires a quantity and a load ticket and
draws down the physical stock.
"""

import from core.model { Shipment }
import from core.enums { Role, ShipmentStatus, LedgerKind, ExceptionType }
import from core.hub {
    get_shipment, get_order, get_line, get_lot, get_slot, get_plant, get_account, get_truck,
    all_shipments, mineral_by_code, all_ledger
}
import from core.access { AppError, Caller, require_roles, loader_eligible, not_found, invalid, bad_state, conflict }
import from core.state_machines { assert_shipment }
import from core.audit { audit, timeline, notify, notify_dispatchers }
import from core.views { ActionResult, EvidenceView }
import from core.util { now, clean_text, fmt_time }
import from evidence.store { evidence_views }
import from orders.rollup { refresh_order_status }
import from reservations.reserve { consume_for_loading }
import from payments.ledger { on_loading_finished }
import from dispatch.exceptions { raise_exception }

obj LoaderJobView {
    has shipment_id: str,
        ref: str,
        status: str,
        order_ref: str,
        plant_name: str,
        plant_lat: float,
        plant_lng: float,
        bay: int,
        slot_start: float,
        slot_end: float,
        present_by: float,
        mineral_name: str,
        grade_code: str,
        quantity_t: float,
        lot_code: str,
        stockpile: str,
        truck_plate: str,
        truck_payload_t: float,
        driver_name: str,
        driver_checked_in: bool,
        loader_checked_in: bool,
        verified: bool,
        loading_started_at: float,
        loading_ended_at: float,
        loaded_qty_t: float,
        load_ticket_no: str,
        assigned_to_me: bool,
        next_step: str,
        fee_status: str = "",
        fee_amount: float = 0.0,
        evidence: list[EvidenceView] = [];
}

obj LoaderHome {
    has ok: bool,
        code: str = "",
        message: str = "",
        jobs: list[LoaderJobView] = [],
        eligible: list[LoaderJobView] = [],
        done: list[LoaderJobView] = [];
}

obj LoaderJobResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: LoaderJobView | None = None;
}

def loader_next_step(sh: Shipment) -> str {
    if sh.status in [ShipmentStatus.OFFERED, ShipmentStatus.SCHEDULED, ShipmentStatus.AWAITING_DISPATCH] {
        return "Check in at your bay before the slot";
    }
    if sh.status == ShipmentStatus.AWAITING_LOADING {
        if sh.loader_checked_in_at <= 0 {
            return "Check in at your bay";
        }
        if sh.driver_checked_in_at <= 0 {
            return "Wait for the truck to check in";
        }
        return "Verify lot, truck and order, then start loading";
    }
    if sh.status == ShipmentStatus.LOADING {
        return "Record loaded quantity and the load ticket";
    }
    return "";
}

def loader_job_view(c: Caller, sh: Shipment) -> LoaderJobView {
    o = get_order(sh.order_id);
    p = get_plant(sh.plant_id);
    line = get_line(sh.line_id);
    lot = get_lot(sh.lot_id);
    m = mineral_by_code(line.mineral_code) if line is not None else None;
    slot = get_slot(sh.slot_id);
    truck = get_truck(sh.truck_id);
    driver = get_account(sh.driver_id);
    fee_status = "";
    fee_amount = 0.0;
    for e in all_ledger() {
        if e.shipment_id == jid(sh) and e.kind == LedgerKind.LOADER_FEE and e.payee_id == c.account_id {
            fee_status = str(e.status);
            fee_amount = e.amount;
        }
    }
    return LoaderJobView(
        shipment_id=jid(sh), ref=sh.ref, status=str(sh.status), order_ref=o.ref if o is not None else "",
        plant_name=p.name if p is not None else "", plant_lat=p.lat if p is not None else 0.0, plant_lng=p.lng if p is not None else 0.0,
        bay=slot.bay if slot is not None else 0, slot_start=slot.start_ts if slot is not None else 0.0,
        slot_end=slot.end_ts if slot is not None else 0.0, present_by=(slot.start_ts - 15 * 60) if slot is not None else 0.0,
        mineral_name=m.name if m is not None else "", grade_code=line.grade_code if line is not None else "",
        quantity_t=sh.quantity_t, lot_code=lot.code if lot is not None else "", stockpile=lot.stockpile if lot is not None else "",
        truck_plate=truck.plate if truck is not None else "", truck_payload_t=truck.payload_t if truck is not None else 0.0,
        driver_name=driver.display_name if driver is not None else "", driver_checked_in=sh.driver_checked_in_at > 0,
        loader_checked_in=sh.loader_checked_in_at > 0, verified=sh.verified_at > 0, loading_started_at=sh.loading_started_at,
        loading_ended_at=sh.loading_ended_at, loaded_qty_t=sh.loaded_qty_t, load_ticket_no=sh.load_ticket_no,
        assigned_to_me=sh.loader_id == c.account_id, next_step=loader_next_step(sh) if sh.loader_id == c.account_id else "Claim this job",
        fee_status=fee_status, fee_amount=fee_amount, evidence=evidence_views(sh)
    );
}

def _my_loading(c: Caller, shipment_id: str) -> Shipment {
    sh = get_shipment(shipment_id);
    if sh is None or sh.loader_id != c.account_id {
        raise not_found("Loading job");
    }
    return sh;
}

def:protect loader_home(poll: int = 0) -> LoaderHome {
    _ = poll;
    try {
        c = require_roles([Role.LOADER]);
        jobs: list[LoaderJobView] = [];
        eligible: list[LoaderJobView] = [];
        done: list[LoaderJobView] = [];
        for sh in all_shipments() {
            if sh.loader_id == c.account_id {
                if str(sh.status) in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING"] {
                    jobs.append(loader_job_view(c, sh));
                } elif str(sh.status) != "CANCELLED" {
                    done.append(loader_job_view(c, sh));
                }
            } elif loader_eligible(c, sh) {
                eligible.append(loader_job_view(c, sh));
            }
        }
        return LoaderHome(
            ok=True, jobs=sorted(jobs, key=lambda (j: LoaderJobView) { j.slot_start; }),
            eligible=sorted(eligible, key=lambda (j: LoaderJobView) { j.slot_start; })[:10],
            done=sorted(done, key=lambda (j: LoaderJobView) { -j.slot_start; })[:10]
        );
    } except AppError as e {
        return LoaderHome(ok=False, code=e.code, message=e.message);
    }
}

def:protect loader_job(shipment_id: str, poll: int = 0) -> LoaderJobResult {
    _ = poll;
    try {
        c = require_roles([Role.LOADER]);
        sh = get_shipment(shipment_id);
        if sh is None or not (sh.loader_id == c.account_id or loader_eligible(c, sh)) {
            raise not_found("Loading job");
        }
        return LoaderJobResult(ok=True, data=loader_job_view(c, sh));
    } except AppError as e {
        return LoaderJobResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect claim_loading_job(shipment_id: str) -> ActionResult {
    try {
        c = require_roles([Role.LOADER]);
        sh = get_shipment(shipment_id);
        if sh is None or not loader_eligible(c, sh) {
            raise not_found("Loading job");
        }
        slot = get_slot(sh.slot_id);
        if slot is not None {
            for other in all_shipments() {
                os = get_slot(other.slot_id);
                if other.loader_id == c.account_id and os is not None and abs(os.start_ts - slot.start_ts) < 3600 and str(other.status) in ["SCHEDULED", "AWAITING_LOADING", "LOADING", "OFFERED", "AWAITING_DISPATCH"] {
                    raise conflict("You already have a loading job in that hour (" + other.ref + ").");
                }
            }
        }
        sh.loader_id = c.account_id;
        sh.updated_at = now();
        notify_dispatchers(sh.plant_id, "info", c.account.display_name + " took loading job " + sh.ref);
        audit(c, "LOADING_JOB_CLAIMED", "Shipment", shipment_id, sh.ref, "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Job is yours.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Manual check-in (labelled in the UI: no GPS/geofence)."""
def:protect loader_check_in(shipment_id: str) -> ActionResult {
    try {
        c = require_roles([Role.LOADER]);
        sh = _my_loading(c, shipment_id);
        if sh.status not in [ShipmentStatus.SCHEDULED, ShipmentStatus.AWAITING_LOADING] {
            raise bad_state("Check-in opens once a driver has accepted the job.");
        }
        sh.loader_checked_in_at = sh.loader_checked_in_at or now();
        if sh.status == ShipmentStatus.SCHEDULED {
            assert_shipment(sh.status, ShipmentStatus.AWAITING_LOADING);
            sh.status = ShipmentStatus.AWAITING_LOADING;
        }
        sh.updated_at = now();
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
        }
        notify_dispatchers(sh.plant_id, "info", "Loader ready for " + sh.ref, c.account.display_name + " checked in (manual).");
        return ActionResult(ok=True, id=shipment_id, message="Checked in at your bay.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def _norm(s: str) -> str {
    return s.upper().replace(" ", "").replace("-", "");
}

"""Verify the material (lot), the truck and the order before loading starts."""
def:protect verify_and_start_loading(shipment_id: str, lot_code: str, truck_plate: str, order_ref: str) -> ActionResult {
    try {
        c = require_roles([Role.LOADER]);
        sh = _my_loading(c, shipment_id);
        if sh.status != ShipmentStatus.AWAITING_LOADING {
            raise bad_state("This job is not waiting for loading.");
        }
        if sh.loader_checked_in_at <= 0 {
            raise bad_state("Check in at your bay first.");
        }
        if sh.driver_checked_in_at <= 0 {
            raise bad_state("The truck has not checked in yet.");
        }
        lot = get_lot(sh.lot_id);
        truck = get_truck(sh.truck_id);
        o = get_order(sh.order_id);
        mismatches: list[str] = [];
        if lot is None or _norm(lot_code) != _norm(lot.code) {
            mismatches.append("stock lot");
        }
        if truck is None or _norm(truck_plate) != _norm(truck.plate) {
            mismatches.append("truck plate");
        }
        if o is None or _norm(order_ref) != _norm(o.ref) {
            mismatches.append("order reference");
        }
        if mismatches {
            return ActionResult(ok=False, code="VERIFICATION_FAILED", message="Do not load: " + ", ".join(mismatches) + " does not match the reservation. Check with dispatch.");
        }
        assert_shipment(sh.status, ShipmentStatus.LOADING);
        t = now();
        sh.verified_at = t;
        sh.loading_started_at = t;
        sh.status = ShipmentStatus.LOADING;
        sh.updated_at = t;
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "LOADING", "Verified lot " + lot_code.upper() + " / " + truck_plate.upper() + "; loading started", "", shipment_id, c);
        }
        audit(c, "LOADING_STARTED", "Shipment", shipment_id, sh.ref + " verified lot/truck/order", "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Verified. Loading started.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect finish_loading(shipment_id: str, loaded_qty_t: float, ticket_no: str) -> ActionResult {
    try {
        c = require_roles([Role.LOADER]);
        sh = _my_loading(c, shipment_id);
        if sh.status != ShipmentStatus.LOADING {
            raise bad_state("Loading has not started.");
        }
        ticket = clean_text(ticket_no, 40);
        if len(ticket) < 3 {
            raise invalid("Enter the load ticket number.");
        }
        truck = get_truck(sh.truck_id);
        lot = get_lot(sh.lot_id);
        if loaded_qty_t <= 0 {
            raise invalid("Enter the loaded quantity.");
        }
        if truck is not None and loaded_qty_t > truck.payload_t {
            raise invalid("Loaded quantity exceeds the truck payload (" + str(truck.payload_t) + " t).");
        }
        if abs(loaded_qty_t - sh.quantity_t) > sh.quantity_t * 0.05 {
            raise invalid("Loaded quantity must be within 5 % of the ordered " + str(sh.quantity_t) + " t.");
        }
        if lot is not None and loaded_qty_t > lot.measured_t + 1e-6 {
            raise invalid("Lot " + lot.code + " only holds " + str(lot.measured_t) + " t on record; update stock first.");
        }
        assert_shipment(sh.status, ShipmentStatus.LOADED);
        t = now();
        sh.loading_ended_at = t;
        sh.loaded_qty_t = round(loaded_qty_t, 3);
        sh.load_ticket_no = ticket;
        sh.status = ShipmentStatus.LOADED;
        sh.updated_at = t;
        consume_for_loading(sh, sh.loaded_qty_t);
        on_loading_finished(sh);
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "LOADED", "Loaded " + str(sh.loaded_qty_t) + " t - ticket " + ticket, "", shipment_id, c);
        }
        if sh.driver_id {
            notify(sh.driver_id, "info", sh.ref + " loaded", "Confirm ticket " + ticket + " and start the journey.", "/driver/jobs/" + shipment_id);
        }
        notify_dispatchers(sh.plant_id, "info", sh.ref + " loaded", str(sh.loaded_qty_t) + " t, ticket " + ticket);
        audit(c, "LOADING_FINISHED", "Shipment", shipment_id, sh.ref + " " + str(sh.loaded_qty_t) + " t ticket " + ticket, "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Loading recorded. The driver will confirm the ticket.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Arrival / queue / delay / ready notifications to dispatch."""
def:protect loader_update(shipment_id: str, kind: str, note: str = "", delay_minutes: int = 0) -> ActionResult {
    try {
        c = require_roles([Role.LOADER]);
        sh = _my_loading(c, shipment_id);
        if kind not in ["ARRIVED", "QUEUE", "DELAY", "READY"] {
            raise invalid("Unknown update type.");
        }
        text = clean_text(note, 300);
        title = {"ARRIVED": "Loader at bay", "QUEUE": "Queue at bay", "DELAY": "Loading delay", "READY": "Bay ready"}[kind];
        if kind == "DELAY" {
            if delay_minutes <= 0 or delay_minutes > 480 {
                raise invalid("Delay must be between 1 and 480 minutes.");
            }
            raise_exception(ExceptionType.LATE_LOADING, "MEDIUM", sh.ref + ": loading delayed ~" + str(delay_minutes) + " min", text or "Reported by loader", sh, sh.plant_id, c.account_id);
        } else {
            notify_dispatchers(sh.plant_id, "info", title + ": " + sh.ref, (c.account.display_name + " - " + text) if text else c.account.display_name);
        }
        if sh.driver_id and kind in ["READY", "DELAY", "QUEUE"] {
            notify(sh.driver_id, "info", title + " for " + sh.ref, text or "Update from the loader.");
        }
        audit(c, "LOADER_UPDATE_" + kind, "Shipment", shipment_id, sh.ref + " " + title, text, [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Dispatch notified.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
