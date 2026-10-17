"""Dispatcher operations: overview, order queue, assignment (agent-assisted),
approval with recorded overrides, fleet, loading schedule and audit trail.
Every query is limited to the dispatcher's plant scope.
"""

import from core.model {
    MineFlowHub, HasOrder, Order, OrderLine, HasLine, Shipment, HasShipment, DriverOffer,
    HasOffer, Truck, AuditEvent, ActionOption, Plant
}
import from core.enums { Role, ShipmentStatus, OfferStatus, TruckStatus, OrderStatus, ConnectivityStatus }
import from core.hub {
    get_hub, get_order, get_shipment, get_line, get_lot, get_slot, get_plant, get_account,
    get_truck, get_run, all_trucks, all_accounts, all_shipments, all_audit, all_plants,
    all_exceptions, all_claims, mineral_by_code, offers_of, shipments_of_order, name_of_plant, get_org
}
import from core.access {
    AppError, Caller, require_roles, dispatcher_covers_plant, require_dispatch_scope,
    not_found, invalid, bad_state, conflict, overlaps
}
import from core.state_machines { assert_shipment }
import from core.audit { audit, timeline, notify, notify_order_buyer }
import from core.views { ActionResult }
import from core.util { now, clean_text, fmt_time }
import from scheduling.slots { slot_view, SlotView, plant_slots, day_start, loaders_on_shift, ensure_slots, DAY }
import from planning.tools { driver_candidates, truck_candidates, loader_candidates, DriverCandidate, TruckCandidate, LoaderCandidate, active_jobs_of_driver }
import from planning.workflow { execute_assignment_planning, run_view, AgentRunView, runs_of }
import from delivery.tracking { connectivity_of, last_ping }
import from orders.rollup { refresh_order_status }
import from payments.ledger { driver_pay }
import from dispatch.exceptions { sweep_late_loading, OPEN_EX }

obj QueueShipment {
    has id: str,
        ref: str,
        status: str,
        plant_name: str,
        quantity_t: float,
        grade_code: str,
        slot_start: float,
        driver_name: str,
        truck_plate: str,
        loader_name: str,
        connectivity: str,
        eta_ts: float,
        late: bool;
}

obj QueueRow {
    has order_id: str,
        ref: str,
        status: str,
        buyer_org: str,
        site_name: str,
        window_start: float,
        window_end: float,
        total_t: float,
        shipments: list[QueueShipment] = [],
        flags: list[str] = [],
        next_action: str = "";
}

obj QueueResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        rows: list[QueueRow] = [],
        counts: dict[str, int] = {};
}

obj OverviewKpis {
    has awaiting_dispatch: int,
        offered: int,
        scheduled: int,
        loading: int,
        in_transit: int,
        awaiting_ack: int,
        completed_7d: int,
        on_time_pct: float,
        open_exceptions: int,
        open_claims: int,
        trucks_available: int,
        trucks_total: int,
        trucks_workshop: int,
        offline_trucks: int;
}

obj OnRoadItem {
    has shipment_id: str,
        ref: str,
        truck_plate: str,
        driver_name: str,
        site_name: str,
        connectivity: str,
        eta_ts: float,
        window_end: float,
        progress: float,
        at_risk: bool;
}

obj OverviewResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        kpis: OverviewKpis | None = None,
        on_road: list[OnRoadItem] = [],
        trips_by_day: list[dict[str, float]] = [],
        scope_names: list[str] = [];
}

obj AssignmentOptions {
    has ok: bool,
        code: str = "",
        message: str = "",
        shipment: QueueShipment | None = None,
        drivers: list[DriverCandidate] = [],
        trucks: list[TruckCandidate] = [],
        loaders: list[LoaderCandidate] = [],
        recommended_driver_id: str = "",
        recommended_truck_id: str = "",
        recommended_loader_id: str = "",
        agent_runs: list[AgentRunView] = [];
}

obj FleetTruck {
    has id: str,
        plate: str,
        payload_t: float,
        body_type: str,
        status: str,
        note: str,
        current_job: str,
        driver_name: str;
}

obj FleetDriver {
    has id: str,
        name: str,
        license_class: str,
        active_jobs: int,
        current_job: str,
        connectivity: str;
}

obj FleetResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        trucks: list[FleetTruck] = [],
        drivers: list[FleetDriver] = [];
}

obj ScheduleRow {
    has plant_id: str,
        plant_name: str,
        slots: list[SlotView] = [],
        loaders: list[str] = [];
}

obj ScheduleResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        day_start: float = 0.0,
        plants: list[ScheduleRow] = [];
}

obj AuditView {
    has at: float,
        actor_name: str,
        actor_role: str,
        action: str,
        entity_type: str,
        entity_id: str,
        summary: str,
        reason: str;
}

obj AuditResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        events: list[AuditView] = [];
}

obj RunResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        run: AgentRunView | None = None;
}

def queue_shipment(sh: Shipment) -> QueueShipment {
    line = get_line(sh.line_id);
    slot = get_slot(sh.slot_id);
    driver = get_account(sh.driver_id);
    loader = get_account(sh.loader_id);
    truck = get_truck(sh.truck_id);
    late = False;
    if slot is not None and str(sh.status) in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED"] and slot.start_ts + 20 * 60 < now() {
        late = True;
    }
    eta = sh.departed_at + sh.eta_minutes * 60.0 if sh.departed_at > 0 else 0.0;
    return QueueShipment(
        id=jid(sh), ref=sh.ref, status=str(sh.status), plant_name=name_of_plant(sh.plant_id),
        quantity_t=sh.quantity_t, grade_code=line.grade_code if line is not None else "",
        slot_start=slot.start_ts if slot is not None else 0.0,
        driver_name=driver.display_name if driver is not None else "",
        truck_plate=truck.plate if truck is not None else "",
        loader_name=loader.display_name if loader is not None else "",
        connectivity=str(connectivity_of(sh)) if str(sh.status) in ["LOADED", "IN_TRANSIT"] else "",
        eta_ts=eta, late=late
    );
}

"""Walks hub -> orders -> lines -> shipments and collects queue rows in scope.
Traversal is breadth-first, so lines/shipments find their row by order id."""
walker:priv DispatchQueueScanner {
    has scope: list[str],
        view: str = "ACTIVE",
        rows: list[QueueRow] = [],
        index: dict[str, QueueRow] = {};

    can start with MineFlowHub entry {
        visit [here ->:HasOrder:-> [?:Order]];
    }

    can on_order with Order entry {
        if not overlaps(here.plant_ids + here.candidate_plant_ids, self.scope) {
            skip;
        }
        closed = str(here.status) in ["COMPLETED", "CANCELLED"];
        if self.view == "ACTIVE" and (closed or str(here.status) in ["DRAFT"]) {
            skip;
        }
        if self.view == "DONE" and not closed {
            skip;
        }
        org = get_org(here.buyer_org_id);
        row = QueueRow(
            order_id=jid(here), ref=here.ref, status=str(here.status), buyer_org=org.name if org is not None else "",
            site_name=here.site_name, window_start=here.window_start, window_end=here.window_end, total_t=0.0
        );
        self.rows.append(row);
        self.index[jid(here)] = row;
        visit [here ->:HasLine:-> [?:OrderLine]];
    }

    can on_line with OrderLine entry {
        row = self.index.get(here.order_id);
        if row is None {
            skip;
        }
        row.total_t = round(row.total_t + here.quantity_t, 2);
        visit [here ->:HasShipment:-> [?:Shipment]];
    }

    can on_shipment with Shipment entry {
        row = self.index.get(here.order_id);
        if row is None {
            skip;
        }
        qs = queue_shipment(here);
        row.shipments.append(qs);
        if qs.late and "LATE_LOADING" not in row.flags {
            row.flags.append("LATE_LOADING");
        }
        if qs.connectivity == "OFFLINE" and "OFFLINE" not in row.flags {
            row.flags.append("OFFLINE");
        }
        if qs.status == "EXCEPTION" and "EXCEPTION" not in row.flags {
            row.flags.append("EXCEPTION");
        }
        if qs.status in ["AWAITING_DISPATCH", "EXCEPTION"] {
            row.next_action = "Assign driver, truck and loader";
        }
    }
}

def:protect dispatch_queue(view: str = "ACTIVE", poll: int = 0) -> QueueResult {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER]);
        w = get_hub() spawn DispatchQueueScanner(scope=c.account.dispatch_plant_ids, view=view);
        rows = sorted(w.rows, key=lambda (r: QueueRow) { (0 if r.next_action else 1, r.window_start); });
        counts: dict[str, int] = {};
        for r in rows {
            for s in r.shipments {
                counts[s.status] = counts.get(s.status, 0) + 1;
            }
        }
        return QueueResult(ok=True, rows=rows, counts=counts);
    } except AppError as e {
        return QueueResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect ops_overview(poll: int = 0) -> OverviewResult {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER]);
        sweep_late_loading(c);
        scope = c.account.dispatch_plant_ids;
        ships = [s for s in all_shipments() if s.plant_id in scope];
        status_counts: dict[str, int] = {};
        for s in ships {
            status_counts[str(s.status)] = status_counts.get(str(s.status), 0) + 1;
        }
        t = now();
        recent = [s for s in ships if s.status == ShipmentStatus.COMPLETED and s.completed_at > t - 7 * DAY];
        on_time = 0;
        for s in recent {
            o = get_order(s.order_id);
            if o is not None and (s.unloaded_at or s.completed_at) <= o.window_end {
                on_time += 1;
            }
        }
        on_road: list[OnRoadItem] = [];
        offline = 0;
        for s in ships {
            if s.status != ShipmentStatus.IN_TRANSIT {
                continue;
            }
            o = get_order(s.order_id);
            truck = get_truck(s.truck_id);
            driver = get_account(s.driver_id);
            conn = str(connectivity_of(s));
            if conn == "OFFLINE" {
                offline += 1;
            }
            eta = s.departed_at + s.eta_minutes * 60.0;
            elapsed = (t - s.departed_at) / max(1.0, s.eta_minutes * 60.0);
            on_road.append(OnRoadItem(
                shipment_id=jid(s), ref=s.ref, truck_plate=truck.plate if truck is not None else "",
                driver_name=driver.display_name if driver is not None else "", site_name=o.site_name if o is not None else "",
                connectivity=conn, eta_ts=eta, window_end=o.window_end if o is not None else 0.0,
                progress=round(min(1.0, max(0.0, elapsed)), 2), at_risk=o is not None and eta > o.window_end
            ));
        }
        on_road = sorted(on_road, key=lambda (x: OnRoadItem) { (0 if x.at_risk else (1 if x.connectivity == "OFFLINE" else 2), x.eta_ts); });
        trucks = all_trucks();
        trips: list[dict[str, float]] = [];
        today = day_start(t);
        for i in range(6, -1, -1) {
            d0 = today - i * DAY;
            done = [s for s in ships if s.departed_at >= d0 and s.departed_at < d0 + DAY];
            ok = 0;
            for s in done {
                o = get_order(s.order_id);
                if o is not None and s.status == ShipmentStatus.COMPLETED and (s.unloaded_at or s.completed_at) <= o.window_end {
                    ok += 1;
                }
            }
            trips.append({"day": d0, "trips": float(len(done)), "on_time": float(ok)});
        }
        kpis = OverviewKpis(
            awaiting_dispatch=status_counts.get("AWAITING_DISPATCH", 0) + status_counts.get("EXCEPTION", 0), offered=status_counts.get("OFFERED", 0),
            scheduled=status_counts.get("SCHEDULED", 0), loading=status_counts.get("AWAITING_LOADING", 0) + status_counts.get("LOADING", 0) + status_counts.get("LOADED", 0),
            in_transit=status_counts.get("IN_TRANSIT", 0), awaiting_ack=status_counts.get("DELIVERED", 0),
            completed_7d=len(recent), on_time_pct=round(100.0 * on_time / len(recent), 1) if recent else 100.0,
            open_exceptions=len([e for e in all_exceptions() if e.plant_id in scope and str(e.status) in OPEN_EX]),
            open_claims=len([cl for cl in all_claims() if cl.plant_id in scope and str(cl.status) in ["OPEN", "UNDER_REVIEW"]]),
            trucks_available=len([tr for tr in trucks if tr.status == TruckStatus.AVAILABLE]), trucks_total=len(trucks),
            trucks_workshop=len([tr for tr in trucks if tr.status == TruckStatus.MAINTENANCE]), offline_trucks=offline
        );
        return OverviewResult(ok=True, kpis=kpis, on_road=on_road, trips_by_day=trips, scope_names=[name_of_plant(p) for p in scope]);
    } except AppError as e {
        return OverviewResult(ok=False, code=e.code, message=e.message);
    }
}

def _scoped_shipment(c: Caller, shipment_id: str) -> Shipment {
    sh = get_shipment(shipment_id);
    if sh is None or not dispatcher_covers_plant(c, sh.plant_id) {
        raise not_found("Shipment");
    }
    return sh;
}

def _bodies(sh: Shipment) -> list[str] {
    lot = get_lot(sh.lot_id);
    m = mineral_by_code(lot.mineral_code) if lot is not None else None;
    return m.allowed_bodies if m is not None else [];
}

def:protect assignment_options(shipment_id: str, poll: int = 0) -> AssignmentOptions {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER]);
        sh = _scoped_shipment(c, shipment_id);
        drivers = driver_candidates(sh);
        trucks = truck_candidates(sh, _bodies(sh));
        loaders = loader_candidates(sh);
        o = get_order(sh.order_id);
        runs = [run_view(r) for r in runs_of(o) if str(r.kind) == "ASSIGNMENT_PLANNING"][:3] if o is not None else [];
        rec_d = "";
        rec_t = "";
        rec_l = "";
        for r in runs {
            for a in r.actions {
                if a.shipment_id == shipment_id and not rec_d {
                    rec_d = a.driver_id;
                    rec_t = a.truck_id;
                    rec_l = a.loader_id;
                }
            }
        }
        if not rec_d {
            rec_d = drivers[0].driver_id if drivers and drivers[0].eligible else "";
            rec_t = trucks[0].truck_id if trucks and trucks[0].eligible else "";
            rec_l = loaders[0].loader_id if loaders and loaders[0].eligible else "";
        }
        return AssignmentOptions(
            ok=True, shipment=queue_shipment(sh), drivers=drivers, trucks=trucks, loaders=loaders,
            recommended_driver_id=rec_d, recommended_truck_id=rec_t, recommended_loader_id=rec_l, agent_runs=runs
        );
    } except AppError as e {
        return AssignmentOptions(ok=False, code=e.code, message=e.message);
    }
}

"""Ask the Dispatch Planning Agent (or fallback) for assignments. Proposes only."""
def:protect plan_assignments(order_id: str) -> RunResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        o = get_order(order_id);
        if o is None or not overlaps(o.plant_ids, c.account.dispatch_plant_ids) {
            raise not_found("Order");
        }
        ships = [s for s in shipments_of_order(o) if s.status in [ShipmentStatus.AWAITING_DISPATCH] and dispatcher_covers_plant(c, s.plant_id)];
        if not ships {
            raise bad_state("No loads on this order are waiting for assignment.");
        }
        run = execute_assignment_planning(o, ships, c.account_id);
        audit(c, "ASSIGNMENT_PLANNING_RUN", "Order", order_id, o.ref + ": " + str(run.status) + " via " + str(run.mode) + ", " + str(len(run.tool_calls)) + " tool calls", "", o.plant_ids);
        return RunResult(ok=True, run=run_view(run));
    } except AppError as e {
        return RunResult(ok=False, code=e.code, message=e.message);
    }
}

"""Approve a dispatch: offer the load to a driver+truck and assign the loader.
Choosing anything other than the recommendation requires a recorded reason."""
def:protect approve_dispatch(shipment_id: str, driver_id: str, truck_id: str, loader_id: str, override_reason: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        sh = _scoped_shipment(c, shipment_id);
        if sh.status not in [ShipmentStatus.AWAITING_DISPATCH, ShipmentStatus.EXCEPTION] {
            raise bad_state("Only loads awaiting dispatch can be offered (current: " + str(sh.status) + ").");
        }
        opts = assignment_options(shipment_id);
        drivers = {d.driver_id: d for d in opts.drivers};
        trucks = {t.truck_id: t for t in opts.trucks};
        loaders = {l.loader_id: l for l in opts.loaders};
        if driver_id not in drivers or not drivers[driver_id].eligible {
            raise invalid("Driver is not eligible: " + ("; ".join(drivers[driver_id].reasons) if driver_id in drivers else "unknown driver"));
        }
        if truck_id not in trucks or not trucks[truck_id].eligible {
            raise invalid("Truck is not eligible: " + ("; ".join(trucks[truck_id].reasons) if truck_id in trucks else "unknown truck"));
        }
        if loader_id and (loader_id not in loaders or not loaders[loader_id].eligible) {
            raise invalid("Loader is not eligible for this slot.");
        }
        why = clean_text(override_reason, 500);
        overridden = driver_id != opts.recommended_driver_id or truck_id != opts.recommended_truck_id or (loader_id != opts.recommended_loader_id and opts.recommended_loader_id != "");
        if overridden and len(why) < 5 {
            raise AppError(code="OVERRIDE_REASON_REQUIRED", message="Your choice differs from the recommendation - record a reason for the override.");
        }
        if sh.status == ShipmentStatus.EXCEPTION {
            assert_shipment(sh.status, ShipmentStatus.AWAITING_DISPATCH);
            sh.status = ShipmentStatus.AWAITING_DISPATCH;
        }
        assert_shipment(sh.status, ShipmentStatus.OFFERED);
        for off in offers_of(sh) {
            if off.status == OfferStatus.OFFERED {
                off.status = OfferStatus.WITHDRAWN;
            }
        }
        sh +>:HasOffer():+> DriverOffer(shipment_id=shipment_id, driver_id=driver_id, truck_id=truck_id, pay_amount=driver_pay(sh.distance_km), created_at=now());
        sh.truck_id = truck_id;
        sh.loader_id = loader_id;
        sh.status = ShipmentStatus.OFFERED;
        sh.updated_at = now();
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            timeline(jid(o), "OFFERED", "Load " + sh.ref + " offered to " + drivers[driver_id].name + " (" + trucks[truck_id].plate + ")", "Override: " + why if overridden else "Recommended assignment approved", shipment_id, c);
        }
        notify(driver_id, "info", "New delivery offer " + sh.ref, "Pickup at " + name_of_plant(sh.plant_id) + ". Please accept or reject.", "/driver");
        if loader_id {
            notify(loader_id, "info", "Loading job assigned " + sh.ref, "Truck " + trucks[truck_id].plate + " at " + name_of_plant(sh.plant_id), "/loader");
        }
        audit(c, "DISPATCH_OVERRIDE" if overridden else "DISPATCH_APPROVED", "Shipment", shipment_id, sh.ref + " -> " + drivers[driver_id].name + " / " + trucks[truck_id].plate, why, [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Offer sent to " + drivers[driver_id].name + ".");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect withdraw_offer(shipment_id: str, reason: str) -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        sh = _scoped_shipment(c, shipment_id);
        if sh.status != ShipmentStatus.OFFERED {
            raise bad_state("There is no pending offer on this load.");
        }
        why = clean_text(reason, 300);
        if len(why) < 3 {
            raise invalid("Give a reason.");
        }
        assert_shipment(sh.status, ShipmentStatus.AWAITING_DISPATCH);
        for off in offers_of(sh) {
            if off.status == OfferStatus.OFFERED {
                off.status = OfferStatus.WITHDRAWN;
                notify(off.driver_id, "warning", "Offer withdrawn", sh.ref + ": " + why);
            }
        }
        sh.status = ShipmentStatus.AWAITING_DISPATCH;
        sh.truck_id = "";
        sh.updated_at = now();
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
        }
        audit(c, "OFFER_WITHDRAWN", "Shipment", shipment_id, sh.ref, why, [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Offer withdrawn.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect fleet_overview(poll: int = 0) -> FleetResult {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER, Role.ADMIN]);
        _ = c;
        active = ["OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING", "LOADED", "IN_TRANSIT"];
        ships = [s for s in all_shipments() if str(s.status) in active];
        trucks: list[FleetTruck] = [];
        for t in all_trucks() {
            job = [s for s in ships if s.truck_id == jid(t)];
            drv = get_account(job[0].driver_id) if job else None;
            trucks.append(FleetTruck(
                id=jid(t), plate=t.plate, payload_t=t.payload_t, body_type=t.body_type, status=str(t.status), note=t.note,
                current_job=job[0].ref + " · " + str(job[0].status) if job else "", driver_name=drv.display_name if drv is not None else ""
            ));
        }
        drivers: list[FleetDriver] = [];
        for a in all_accounts() {
            if a.role != Role.DRIVER {
                continue;
            }
            job = [s for s in ships if s.driver_id == jid(a)];
            drivers.append(FleetDriver(
                id=jid(a), name=a.display_name, license_class=a.license_class, active_jobs=len(job),
                current_job=job[0].ref + " · " + str(job[0].status) if job else "",
                connectivity=str(connectivity_of(job[0])) if job and str(job[0].status) in ["LOADED", "IN_TRANSIT"] else ""
            ));
        }
        return FleetResult(ok=True, trucks=trucks, drivers=drivers);
    } except AppError as e {
        return FleetResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect set_truck_status(truck_id: str, status: str, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        t = get_truck(truck_id);
        if t is None {
            raise not_found("Truck");
        }
        if status not in ["AVAILABLE", "MAINTENANCE"] {
            raise invalid("Status must be AVAILABLE or MAINTENANCE.");
        }
        busy = [s for s in all_shipments() if s.truck_id == truck_id and str(s.status) in ["OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING", "LOADED", "IN_TRANSIT"]];
        if busy and status == "MAINTENANCE" {
            raise bad_state("Truck is committed to " + busy[0].ref + "; reassign that load first.");
        }
        t.status = TruckStatus(status);
        t.note = clean_text(note, 200);
        audit(c, "TRUCK_STATUS", "Truck", truck_id, t.plate + " -> " + status, note);
        return ActionResult(ok=True, id=truck_id, message=t.plate + " marked " + status.lower() + ".");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Loading schedule for plants in scope (day_offset 0 = today)."""
def:protect loading_schedule(day_offset: int = 0, poll: int = 0) -> ScheduleResult {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER, Role.STORE_MANAGER]);
        scope = c.account.dispatch_plant_ids if c.has_role(Role.DISPATCHER) else c.account.plant_ids;
        d0 = day_start(now()) + max(0, min(day_offset, 6)) * DAY;
        rows: list[ScheduleRow] = [];
        for pid in scope {
            p = get_plant(pid);
            if p is None {
                continue;
            }
            slots = [slot_view(s) for s in plant_slots(p, d0, d0 + DAY - 1) if s.bay <= p.bays or s.shipment_id];
            loaders = [a.display_name + " (" + str(a.shift_start_hour) + ":00-" + str(a.shift_end_hour) + ":00)" for a in all_accounts() if a.role == Role.LOADER and pid in a.plant_ids];
            rows.append(ScheduleRow(plant_id=pid, plant_name=p.name, slots=slots, loaders=loaders));
        }
        return ScheduleResult(ok=True, day_start=d0, plants=rows);
    } except AppError as e {
        return ScheduleResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect audit_trail(limit: int = 100, poll: int = 0) -> AuditResult {
    _ = poll;
    try {
        c = require_roles([Role.DISPATCHER, Role.ADMIN]);
        rows: list[AuditView] = [];
        for e in sorted(all_audit(), key=lambda (x: AuditEvent) { -x.at; }) {
            if c.has_role(Role.DISPATCHER) and not overlaps(e.plant_ids, c.account.dispatch_plant_ids) {
                continue;
            }
            rows.append(AuditView(at=e.at, actor_name=e.actor_name, actor_role=e.actor_role, action=e.action, entity_type=e.entity_type, entity_id=e.entity_id, summary=e.summary, reason=e.reason));
            if len(rows) >= min(max(limit, 1), 300) {
                break;
            }
        }
        return AuditResult(ok=True, events=rows);
    } except AppError as e {
        return AuditResult(ok=False, code=e.code, message=e.message);
    }
}
