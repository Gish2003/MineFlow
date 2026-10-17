"""Truck driver workflow (mobile-first UI): offers, pickup, journey, proof of
delivery and handover. Drivers only ever see offers addressed to them and their
own assignments. Completion requires the required steps and evidence:
loaded + confirmed ticket -> in transit -> unloading photo + handover record
(DELIVERED) -> buyer acknowledgement in-app or valid handover PIN (COMPLETED).
"""

import from core.model { Shipment, DriverOffer, Order }
import from core.enums { Role, ShipmentStatus, OfferStatus, TruckStatus, EvidenceKind, AckMethod, ExceptionType }
import from core.hub {
    get_shipment, get_order, get_line, get_lot, get_slot, get_plant, get_account, get_truck,
    get_offer, all_shipments, offers_of, mineral_by_code, name_of_plant
}
import from core.access { AppError, Caller, require_roles, not_found, invalid, bad_state, conflict, deny }
import from core.state_machines { assert_shipment }
import from core.audit { audit, timeline, notify, notify_dispatchers, notify_order_buyer }
import from core.views { ActionResult, EvidenceView }
import from core.config { settings }
import from core.util { now, clean_text, fmt_time }
import from planning.tools { active_jobs_of_driver, truck_busy }
import from delivery.tracking { connectivity_of }
import from evidence.store { evidence_views, count_of_kind }
import from orders.rollup { refresh_order_status }
import from payments.ledger { on_completed }
import from dispatch.exceptions { raise_exception }

obj OfferView {
    has id: str,
        shipment_id: str,
        shipment_ref: str,
        plant_name: str,
        plant_lat: float,
        plant_lng: float,
        dest_name: str,
        dest_address: str,
        dest_lat: float,
        dest_lng: float,
        mineral_name: str,
        grade_code: str,
        quantity_t: float,
        slot_start: float,
        window_end: float,
        distance_km: float,
        travel_minutes: float,
        truck_plate: str,
        truck_payload_t: float,
        truck_body: str,
        pay_amount: float,
        currency: str,
        note: str,
        created_at: float;
}

obj DriverJobView {
    has shipment_id: str,
        ref: str,
        status: str,
        order_ref: str,
        plant_name: str,
        plant_lat: float,
        plant_lng: float,
        dest_name: str,
        dest_address: str,
        site_contact: str,
        dest_lat: float,
        dest_lng: float,
        mineral_name: str,
        grade_code: str,
        quantity_t: float,
        lot_code: str,
        stockpile: str,
        bay: int,
        slot_start: float,
        window_start: float,
        window_end: float,
        truck_plate: str,
        loader_name: str,
        driver_checked_in: bool,
        loader_checked_in: bool,
        loaded_qty_t: float,
        load_ticket_no: str,
        ticket_confirmed: bool,
        departed_at: float,
        eta_minutes: float,
        distance_km: float,
        unloading_photos: int,
        handover_recorded: bool,
        pin_attempts_left: int,
        connectivity: str,
        pay_amount: float,
        next_step: str,
        evidence: list[EvidenceView] = [];
}

obj DriverHome {
    has ok: bool,
        code: str = "",
        message: str = "",
        offers: list[OfferView] = [],
        jobs: list[DriverJobView] = [],
        completed: list[DriverJobView] = [];
}

obj DriverJobResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: DriverJobView | None = None;
}

def offer_view(off: DriverOffer, sh: Shipment) -> OfferView {
    o = get_order(sh.order_id);
    p = get_plant(sh.plant_id);
    line = get_line(sh.line_id);
    m = mineral_by_code(line.mineral_code) if line is not None else None;
    slot = get_slot(sh.slot_id);
    truck = get_truck(off.truck_id);
    return OfferView(
        id=jid(off), shipment_id=jid(sh), shipment_ref=sh.ref, plant_name=p.name if p is not None else "",
        plant_lat=p.lat if p is not None else 0.0, plant_lng=p.lng if p is not None else 0.0,
        dest_name=o.site_name if o is not None else "", dest_address=o.site_address if o is not None else "",
        dest_lat=o.dest_lat if o is not None else 0.0, dest_lng=o.dest_lng if o is not None else 0.0,
        mineral_name=m.name if m is not None else "", grade_code=line.grade_code if line is not None else "",
        quantity_t=sh.quantity_t, slot_start=slot.start_ts if slot is not None else 0.0,
        window_end=o.window_end if o is not None else 0.0, distance_km=sh.distance_km, travel_minutes=sh.eta_minutes,
        truck_plate=truck.plate if truck is not None else "", truck_payload_t=truck.payload_t if truck is not None else 0.0,
        truck_body=truck.body_type if truck is not None else "", pay_amount=off.pay_amount, currency=settings().currency,
        note=off.note, created_at=off.created_at
    );
}

def next_step_for(sh: Shipment) -> str {
    s = sh.status;
    if s == ShipmentStatus.SCHEDULED {
        return "Drive to the plant and check in";
    }
    if s == ShipmentStatus.AWAITING_LOADING {
        return "Wait at the bay - the loader verifies material and truck";
    }
    if s == ShipmentStatus.LOADING {
        return "Loading in progress";
    }
    if s == ShipmentStatus.LOADED {
        return "Confirm the load ticket and start the journey";
    }
    if s == ShipmentStatus.IN_TRANSIT {
        return "Share location; on arrival upload unloading photos and record handover";
    }
    if s == ShipmentStatus.DELIVERED {
        return "Ask the receiver for their handover PIN";
    }
    return "";
}

def job_view(sh: Shipment) -> DriverJobView {
    o = get_order(sh.order_id);
    p = get_plant(sh.plant_id);
    line = get_line(sh.line_id);
    lot = get_lot(sh.lot_id);
    m = mineral_by_code(line.mineral_code) if line is not None else None;
    slot = get_slot(sh.slot_id);
    truck = get_truck(sh.truck_id);
    loader = get_account(sh.loader_id);
    pay = 0.0;
    for off in offers_of(sh) {
        if off.driver_id == sh.driver_id and off.status == OfferStatus.ACCEPTED {
            pay = off.pay_amount;
        }
    }
    return DriverJobView(
        shipment_id=jid(sh), ref=sh.ref, status=str(sh.status), order_ref=o.ref if o is not None else "",
        plant_name=p.name if p is not None else "", plant_lat=p.lat if p is not None else 0.0, plant_lng=p.lng if p is not None else 0.0,
        dest_name=o.site_name if o is not None else "", dest_address=o.site_address if o is not None else "",
        site_contact=o.site_contact if o is not None else "", dest_lat=o.dest_lat if o is not None else 0.0,
        dest_lng=o.dest_lng if o is not None else 0.0, mineral_name=m.name if m is not None else "",
        grade_code=line.grade_code if line is not None else "", quantity_t=sh.quantity_t,
        lot_code=lot.code if lot is not None else "", stockpile=lot.stockpile if lot is not None else "",
        bay=slot.bay if slot is not None else 0, slot_start=slot.start_ts if slot is not None else 0.0,
        window_start=o.window_start if o is not None else 0.0, window_end=o.window_end if o is not None else 0.0,
        truck_plate=truck.plate if truck is not None else "", loader_name=loader.display_name if loader is not None else "",
        driver_checked_in=sh.driver_checked_in_at > 0, loader_checked_in=sh.loader_checked_in_at > 0,
        loaded_qty_t=sh.loaded_qty_t, load_ticket_no=sh.load_ticket_no if sh.status != ShipmentStatus.LOADING else "",
        ticket_confirmed=sh.ticket_confirmed_at > 0, departed_at=sh.departed_at, eta_minutes=sh.eta_minutes,
        distance_km=sh.distance_km, unloading_photos=count_of_kind(sh, EvidenceKind.UNLOADING_PHOTO),
        handover_recorded=sh.handover_recorded_at > 0, pin_attempts_left=max(0, 5 - sh.pin_attempts),
        connectivity=str(connectivity_of(sh)), pay_amount=pay, next_step=next_step_for(sh), evidence=evidence_views(sh)
    );
}

def _my_job(c: Caller, shipment_id: str) -> Shipment {
    sh = get_shipment(shipment_id);
    if sh is None or sh.driver_id != c.account_id {
        raise not_found("Assignment");
    }
    return sh;
}

def:protect driver_home(poll: int = 0) -> DriverHome {
    _ = poll;
    try {
        c = require_roles([Role.DRIVER]);
        offers: list[OfferView] = [];
        jobs: list[DriverJobView] = [];
        done: list[DriverJobView] = [];
        for sh in all_shipments() {
            if sh.status == ShipmentStatus.OFFERED {
                for off in offers_of(sh) {
                    if off.driver_id == c.account_id and off.status == OfferStatus.OFFERED {
                        offers.append(offer_view(off, sh));
                    }
                }
            }
            if sh.driver_id != c.account_id {
                continue;
            }
            if str(sh.status) in ["COMPLETED", "DISPUTED", "CANCELLED"] {
                done.append(job_view(sh));
            } else {
                jobs.append(job_view(sh));
            }
        }
        return DriverHome(
            ok=True, offers=sorted(offers, key=lambda (o: OfferView) { o.slot_start; }),
            jobs=sorted(jobs, key=lambda (j: DriverJobView) { j.slot_start; }),
            completed=sorted(done, key=lambda (j: DriverJobView) { -j.slot_start; })[:10]
        );
    } except AppError as e {
        return DriverHome(ok=False, code=e.code, message=e.message);
    }
}

def:protect driver_job(shipment_id: str, poll: int = 0) -> DriverJobResult {
    _ = poll;
    try {
        c = require_roles([Role.DRIVER]);
        return DriverJobResult(ok=True, data=job_view(_my_job(c, shipment_id)));
    } except AppError as e {
        return DriverJobResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect respond_offer(offer_id: str, accept: bool, reason: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        off = get_offer(offer_id);
        if off is None or off.driver_id != c.account_id {
            raise not_found("Offer");
        }
        sh = get_shipment(off.shipment_id);
        if sh is None {
            raise not_found("Offer");
        }
        if off.status != OfferStatus.OFFERED or sh.status != ShipmentStatus.OFFERED {
            raise bad_state("This offer is no longer open.");
        }
        o = get_order(sh.order_id);
        if accept {
            if active_jobs_of_driver(c.account_id) > 0 {
                raise conflict("Finish or hand back your current job before accepting another.");
            }
            truck = get_truck(off.truck_id);
            if truck is None or truck.status == TruckStatus.MAINTENANCE or truck_busy(off.truck_id, jid(sh)) {
                raise conflict("The offered truck is no longer available; dispatch will re-offer.");
            }
            assert_shipment(sh.status, ShipmentStatus.SCHEDULED);
            off.status = OfferStatus.ACCEPTED;
            off.responded_at = now();
            sh.driver_id = c.account_id;
            sh.truck_id = off.truck_id;
            truck.status = TruckStatus.IN_USE;
            sh.status = ShipmentStatus.SCHEDULED;
            sh.updated_at = now();
            if o is not None {
                refresh_order_status(o);
                timeline(jid(o), "ASSIGNED", "Driver " + c.account.display_name + " accepted (" + truck.plate + ")", "", jid(sh), c);
                notify_order_buyer(o, "info", "Driver assigned to " + sh.ref, c.account.display_name + " · " + truck.plate);
            }
            notify_dispatchers(sh.plant_id, "success", "Offer accepted: " + sh.ref, c.account.display_name + " accepted.");
            audit(c, "OFFER_ACCEPTED", "Shipment", jid(sh), sh.ref, "", [sh.plant_id]);
            return ActionResult(ok=True, id=jid(sh), message="Job accepted. Head to " + name_of_plant(sh.plant_id) + ".");
        }
        why = clean_text(reason, 300);
        if len(why) < 3 {
            raise invalid("Tell dispatch why you are rejecting.");
        }
        assert_shipment(sh.status, ShipmentStatus.AWAITING_DISPATCH);
        off.status = OfferStatus.REJECTED;
        off.responded_at = now();
        off.note = why;
        sh.status = ShipmentStatus.AWAITING_DISPATCH;
        sh.truck_id = "";
        sh.updated_at = now();
        if o is not None {
            refresh_order_status(o);
        }
        raise_exception(ExceptionType.DRIVER_REJECTED, "LOW", sh.ref + " offer rejected by " + c.account.display_name, why, sh, sh.plant_id, c.account_id);
        audit(c, "OFFER_REJECTED", "Shipment", jid(sh), sh.ref, why, [sh.plant_id]);
        return ActionResult(ok=True, id=jid(sh), message="Offer rejected. Dispatch has been told.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Manual check-in at the plant (labelled in the UI: no GPS geofence)."""
def:protect driver_check_in(shipment_id: str) -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        if sh.status not in [ShipmentStatus.SCHEDULED, ShipmentStatus.AWAITING_LOADING] {
            raise bad_state("Check-in is only possible before loading.");
        }
        if sh.driver_checked_in_at > 0 {
            return ActionResult(ok=True, id=shipment_id, message="Already checked in.");
        }
        sh.driver_checked_in_at = now();
        if sh.status == ShipmentStatus.SCHEDULED {
            assert_shipment(sh.status, ShipmentStatus.AWAITING_LOADING);
            sh.status = ShipmentStatus.AWAITING_LOADING;
        }
        sh.updated_at = now();
        if sh.loader_id {
            notify(sh.loader_id, "info", "Truck arrived for " + sh.ref, c.account.display_name + " checked in at the plant.", "/loader/jobs/" + shipment_id);
        }
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "CHECK_IN", "Driver checked in at " + name_of_plant(sh.plant_id) + " (manual check-in)", "", shipment_id, c);
        }
        return ActionResult(ok=True, id=shipment_id, message="Checked in. Wait for the loader at your bay.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def _norm(s: str) -> str {
    return s.upper().replace(" ", "").replace("-", "");
}

"""Driver confirms the loaded material/ticket, then the journey starts."""
def:protect confirm_ticket_and_depart(shipment_id: str, ticket_no: str) -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        if sh.status != ShipmentStatus.LOADED {
            raise bad_state("The load is not finished yet.");
        }
        if not ticket_no.strip() or _norm(ticket_no) != _norm(sh.load_ticket_no) {
            raise invalid("Ticket number does not match the load ticket recorded by the loader. Check the paper ticket.");
        }
        assert_shipment(sh.status, ShipmentStatus.IN_TRANSIT);
        t = now();
        sh.ticket_confirmed_at = t;
        sh.departed_at = t;
        sh.status = ShipmentStatus.IN_TRANSIT;
        sh.updated_at = t;
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "DEPARTED", "On the way: " + str(sh.loaded_qty_t) + " t, ticket " + sh.load_ticket_no, "Estimated arrival " + fmt_time(t + sh.eta_minutes * 60.0) + " (estimate)", shipment_id, c);
            notify_order_buyer(o, "info", sh.ref + " is on the way", "Estimated arrival " + fmt_time(t + sh.eta_minutes * 60.0) + ".");
        }
        audit(c, "JOURNEY_STARTED", "Shipment", shipment_id, sh.ref + " ticket " + sh.load_ticket_no, "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Journey started. Share your location while driving.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Record unloading + handover. Requires an unloading photo already uploaded;
the photo alone never closes the delivery - the buyer still has to acknowledge."""
def:protect record_unloading(shipment_id: str, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        if sh.status != ShipmentStatus.IN_TRANSIT {
            raise bad_state("Unloading can only be recorded for a load in transit.");
        }
        if count_of_kind(sh, EvidenceKind.UNLOADING_PHOTO) == 0 {
            raise AppError(code="EVIDENCE_REQUIRED", message="Upload at least one unloading photo first.");
        }
        assert_shipment(sh.status, ShipmentStatus.DELIVERED);
        t = now();
        sh.arrived_at = sh.arrived_at or t;
        sh.unloaded_at = t;
        sh.handover_recorded_at = t;
        sh.handover_note = clean_text(note, 500);
        sh.status = ShipmentStatus.DELIVERED;
        sh.updated_at = t;
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "DELIVERED", "Unloaded at " + o.site_name + " - awaiting acknowledgement", sh.handover_note, shipment_id, c);
            notify_order_buyer(o, "warning", "Please confirm delivery of " + sh.ref, "Acknowledge in the app or give the driver your handover PIN.");
        }
        audit(c, "UNLOADED", "Shipment", shipment_id, sh.ref, "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Handover recorded. Ask the receiver for their PIN or to acknowledge in the app.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect submit_handover_pin(shipment_id: str, pin: str, received_qty_t: float = 0.0) -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        if sh.status != ShipmentStatus.DELIVERED {
            raise bad_state("The handover PIN is used after unloading is recorded.");
        }
        if sh.pin_attempts >= 5 {
            raise AppError(code="PIN_LOCKED", message="Too many wrong PINs. The buyer must acknowledge in the app or contact dispatch.");
        }
        if pin.strip() != sh.handover_pin {
            sh.pin_attempts = sh.pin_attempts + 1;
            if sh.pin_attempts >= 5 {
                raise_exception(ExceptionType.HANDOVER_LOCKED, "MEDIUM", sh.ref + " handover PIN locked", "Five wrong PIN attempts at the delivery site.", sh, sh.plant_id, c.account_id);
            }
            return ActionResult(ok=False, code="WRONG_PIN", message="Wrong PIN. " + str(max(0, 5 - sh.pin_attempts)) + " attempts left.");
        }
        qty = received_qty_t if received_qty_t > 0 else sh.loaded_qty_t;
        if abs(qty - sh.loaded_qty_t) > sh.loaded_qty_t * 0.02 {
            raise AppError(code="MISMATCH", message="The receiver counted a different quantity. They should report a quantity issue in the app instead.");
        }
        assert_shipment(sh.status, ShipmentStatus.COMPLETED);
        t = now();
        sh.ack_method = AckMethod.HANDOVER_PIN;
        sh.acknowledged_at = t;
        sh.received_qty_t = round(qty, 3);
        sh.completed_at = t;
        sh.status = ShipmentStatus.COMPLETED;
        sh.updated_at = t;
        truck = get_truck(sh.truck_id);
        if truck is not None and truck.status == TruckStatus.IN_USE {
            truck.status = TruckStatus.AVAILABLE;
        }
        on_completed(sh);
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "ACKNOWLEDGED", "Receipt confirmed with handover PIN: " + str(qty) + " t", "", shipment_id, c);
            notify_order_buyer(o, "success", sh.ref + " delivered and confirmed", "Handover PIN accepted.");
        }
        audit(c, "HANDOVER_PIN_ACCEPTED", "Shipment", shipment_id, sh.ref + " " + str(qty) + " t", "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Delivery completed. Payout is pending approval.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Driver hands the job back before loading (creates a recovery exception)."""
def:protect driver_cancel(shipment_id: str, reason: str) -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        if sh.status not in [ShipmentStatus.SCHEDULED, ShipmentStatus.AWAITING_LOADING] {
            raise bad_state("A job can only be handed back before loading starts; otherwise report a vehicle issue.");
        }
        why = clean_text(reason, 400);
        if len(why) < 3 {
            raise invalid("Tell dispatch why you are cancelling.");
        }
        assert_shipment(sh.status, ShipmentStatus.AWAITING_DISPATCH);
        for off in offers_of(sh) {
            if off.driver_id == c.account_id and off.status == OfferStatus.ACCEPTED {
                off.status = OfferStatus.WITHDRAWN;
                off.note = "Cancelled by driver: " + why;
            }
        }
        truck = get_truck(sh.truck_id);
        if truck is not None and truck.status == TruckStatus.IN_USE {
            truck.status = TruckStatus.AVAILABLE;
        }
        sh.driver_id = "";
        sh.truck_id = "";
        sh.driver_checked_in_at = 0.0;
        sh.status = ShipmentStatus.AWAITING_DISPATCH;
        sh.updated_at = now();
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
        }
        if sh.loader_id {
            notify(sh.loader_id, "warning", "Driver cancelled " + sh.ref, "Wait for dispatch to assign another truck.");
        }
        raise_exception(ExceptionType.DRIVER_CANCELLED, "HIGH", sh.ref + ": driver " + c.account.display_name + " cancelled", why, sh, sh.plant_id, c.account_id);
        audit(c, "DRIVER_CANCELLED", "Shipment", shipment_id, sh.ref, why, [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Job handed back to dispatch.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect report_vehicle_issue(shipment_id: str, note: str) -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        text = clean_text(note, 500);
        if len(text) < 5 {
            raise invalid("Describe the problem.");
        }
        if sh.status in [ShipmentStatus.SCHEDULED, ShipmentStatus.AWAITING_LOADING] {
            truck = get_truck(sh.truck_id);
            assert_shipment(sh.status, ShipmentStatus.AWAITING_DISPATCH);
            for off in offers_of(sh) {
                if off.status == OfferStatus.ACCEPTED {
                    off.status = OfferStatus.WITHDRAWN;
                }
            }
            if truck is not None {
                truck.status = TruckStatus.MAINTENANCE;
                truck.note = text[:120];
            }
            sh.driver_id = "";
            sh.truck_id = "";
            sh.status = ShipmentStatus.AWAITING_DISPATCH;
            sh.updated_at = now();
            o = get_order(sh.order_id);
            if o is not None {
                refresh_order_status(o);
            }
            raise_exception(ExceptionType.VEHICLE_ISSUE, "HIGH", sh.ref + ": vehicle issue before loading", text, sh, sh.plant_id, c.account_id);
            return ActionResult(ok=True, id=shipment_id, message="Reported. The truck is marked in workshop and the job returned to dispatch.");
        }
        if sh.status in [ShipmentStatus.LOADING, ShipmentStatus.LOADED, ShipmentStatus.IN_TRANSIT] {
            raise_exception(ExceptionType.VEHICLE_ISSUE, "HIGH", sh.ref + ": vehicle issue with load on board", text, sh, sh.plant_id, c.account_id);
            return ActionResult(ok=True, id=shipment_id, message="Reported to dispatch. Delivery status is unchanged until dispatch decides.");
        }
        raise bad_state("Nothing to report for this job state.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect report_route_delay(shipment_id: str, delay_minutes: int, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DRIVER]);
        sh = _my_job(c, shipment_id);
        if sh.status != ShipmentStatus.IN_TRANSIT {
            raise bad_state("Route delays are reported while in transit.");
        }
        if delay_minutes <= 0 or delay_minutes > 600 {
            raise invalid("Delay must be between 1 and 600 minutes.");
        }
        sh.eta_minutes = sh.eta_minutes + delay_minutes;
        sh.updated_at = now();
        o = get_order(sh.order_id);
        eta = sh.departed_at + sh.eta_minutes * 60.0;
        sev = "MEDIUM" if o is not None and eta > o.window_end else "LOW";
        raise_exception(ExceptionType.ROUTE_DELAY, sev, sh.ref + " delayed ~" + str(delay_minutes) + " min", clean_text(note, 300) or "Driver-reported delay", sh, sh.plant_id, c.account_id);
        if o is not None {
            notify_order_buyer(o, "warning", sh.ref + " delayed", "New estimated arrival " + fmt_time(eta) + " (estimate).");
        }
        return ActionResult(ok=True, id=shipment_id, message="Delay reported; ETA updated.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
