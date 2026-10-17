"""Read-only evidence tools for the Dispatch Planning / Exception Recovery agents.

Each tool is a plain Jac function the LLM can call through
`by llm(tools=[...])`; the deterministic fallback planner calls the very same
functions. Tools never mutate the graph, only accept line/shipment ids that
belong to the run being planned, and log themselves via `planning.recorder`.
"""

import from core.model { Order, OrderLine, Plant, StockLot, Shipment, Account, Truck, PlanOption }
import from core.enums { PlantStatus, LotQuality, Role, TruckStatus }
import from core.hub {
    get_plant, get_lot, get_line, get_order, get_shipment, get_slot, get_truck,
    get_account, all_plants, lots_of, mineral_by_code, all_trucks, all_accounts,
    all_shipments, get_exception
}
import from core.geo { road_km, haversine_km }
import from core.util { now, fmt_time }
import from catalog.grades { check_lot_for_line, GradeCheck }
import from inventory.availability { availability, LotAvailability }
import from scheduling.slots { estimate_wait, LoadingEstimate, open_slot_views, SlotView, slot_problems, loaders_of_plant, local_hour }
import from planning.metrics { build_option, option_score, trip_for, ideal_slot_start, latest_slot_start }
import from planning.recorder { trace, started, line_in_scope, shipment_in_scope }

obj CandidatePlant {
    has plant_id: str,
        name: str,
        region: str,
        status: str,
        status_note: str,
        lots_of_mineral: int,
        road_km_to_site: float;
}

obj PlantInventory {
    has plant_id: str,
        plant_name: str,
        plant_status: str,
        mineral_code: str,
        lots: list[LotAvailability] = [],
        error: str = "";
}

obj EtaEstimate {
    has plant_id: str,
        line_id: str,
        distance_km: float = 0.0,
        travel_minutes: float = 0.0,
        loading_minutes: float = 0.0,
        slot_start: str = "",
        eta: str = "",
        window: str = "",
        within_window: bool = False,
        note: str = "Simulated route: straight-line distance x 1.35 road factor at 45 km/h.",
        error: str = "";
}

obj FeasibilityReport {
    has plant_id: str,
        line_id: str,
        feasible: bool,
        reasons: list[str] = [],
        option: PlanOption | None = None,
        error: str = "";
}

obj OptionComparison {
    has line_id: str,
        rows: list[PlanOption] = [],
        cheapest_plant_id: str = "",
        earliest_plant_id: str = "",
        error: str = "";
}

obj DriverCandidate {
    has driver_id: str,
        name: str,
        eligible: bool,
        reasons: list[str],
        km_to_plant: float,
        active_jobs: int;
}

obj TruckCandidate {
    has truck_id: str,
        plate: str,
        payload_t: float,
        body_type: str,
        status: str,
        eligible: bool,
        reasons: list[str];
}

obj LoaderCandidate {
    has loader_id: str,
        name: str,
        eligible: bool,
        reasons: list[str],
        assigned_jobs_same_hour: int;
}

obj ExceptionContext {
    has exception_id: str,
        ex_type: str,
        summary: str,
        detail: str,
        shipment_id: str = "",
        shipment_status: str = "",
        line_id: str = "",
        current_plant_id: str = "",
        current_plant_name: str = "",
        current_plant_status: str = "",
        current_lot_id: str = "",
        current_slot_start: str = "",
        quantity_t: float = 0.0,
        mineral_code: str = "",
        grade_code: str = "",
        window: str = "",
        driver_id: str = "",
        truck_id: str = "",
        error: str = "";
}

def _line_ctx(line_id: str) -> tuple[OrderLine | None, Order | None, str] {
    if not line_in_scope(line_id) {
        return (None, None, "line_id is not part of this planning run");
    }
    line = get_line(line_id);
    if line is None {
        return (None, None, "line not found");
    }
    order = get_order(line.order_id);
    if order is None {
        return (None, None, "order not found");
    }
    return (line, order, "");
}

def window_text(o: Order) -> str {
    return fmt_time(o.window_start) + " to " + fmt_time(o.window_end);
}

# ------------------------------------------------------------ supply tools
def list_candidate_plants(line_id: str) -> list[CandidatePlant] {
    t0 = started();
    (line, order, err) = _line_ctx(line_id);
    out: list[CandidatePlant] = [];
    if line is not None and order is not None {
        for p in sorted(all_plants(), key=lambda (x: Plant) { x.name; }) {
            if line.mineral_code not in p.minerals {
                continue;
            }
            count = len([l for l in lots_of(p) if l.mineral_code == line.mineral_code]);
            out.append(CandidatePlant(
                plant_id=jid(p), name=p.name, region=p.region, status=str(p.status),
                status_note=p.status_note, lots_of_mineral=count,
                road_km_to_site=road_km(p.lat, p.lng, order.dest_lat, order.dest_lng)
            ));
        }
    }
    trace("list_candidate_plants", {"line_id": line_id}, out if not err else err, t0, not err, err);
    return out;
}
sem list_candidate_plants = "List every plant that produces the mineral of an order line (unranked, alphabetical), with status and road distance to the delivery site.";
sem list_candidate_plants.line_id = "The order line id from the brief.";

def get_plant_inventory(plant_id: str, mineral_code: str) -> PlantInventory {
    t0 = started();
    p = get_plant(plant_id);
    if p is None {
        res = PlantInventory(plant_id=plant_id, plant_name="", plant_status="", mineral_code=mineral_code, error="plant not found");
        trace("get_plant_inventory", {"plant_id": plant_id, "mineral_code": mineral_code}, res, t0, False, res.error);
        return res;
    }
    rows = [availability(l) for l in lots_of(p) if l.mineral_code == mineral_code];
    res = PlantInventory(plant_id=plant_id, plant_name=p.name, plant_status=str(p.status), mineral_code=mineral_code, lots=rows);
    trace("get_plant_inventory", {"plant_id": plant_id, "mineral_code": mineral_code}, res, t0);
    return res;
}
sem get_plant_inventory = "Get stock lots of one mineral at a plant: grade code, assay, quality status (VERIFIED/PENDING/QUALITY_HOLD), measured, reserved and available tonnes, price per tonne.";
sem get_plant_inventory.plant_id = "Plant id returned by list_candidate_plants.";
sem get_plant_inventory.mineral_code = "Mineral code, e.g. LIMESTONE.";

def check_grade_compatibility(lot_id: str, line_id: str) -> GradeCheck {
    t0 = started();
    (line, _, err) = _line_ctx(line_id);
    lot = get_lot(lot_id);
    if line is None or lot is None {
        msg = err or "lot not found";
        res = GradeCheck(lot_id=lot_id, lot_code="", mineral_code="", lot_grade="", requested_grade="", compatible=False, quality="", reasons=[msg]);
        trace("check_grade_compatibility", {"lot_id": lot_id, "line_id": line_id}, res, t0, False, msg);
        return res;
    }
    res = check_lot_for_line(lot, line);
    trace("check_grade_compatibility", {"lot_id": lot_id, "line_id": line_id}, res, t0);
    return res;
}
sem check_grade_compatibility = "Check a stock lot's assay and grade code against the line's grade specification, parameter by parameter. Blends and grade substitution are not allowed.";
sem check_grade_compatibility.lot_id = "Stock lot id from get_plant_inventory.";
sem check_grade_compatibility.line_id = "Order line id.";

def estimate_loading_wait(plant_id: str, line_id: str) -> LoadingEstimate {
    t0 = started();
    (line, order, err) = _line_ctx(line_id);
    p = get_plant(plant_id);
    if line is None or order is None or p is None {
        msg = err or "plant not found";
        res = LoadingEstimate(plant_id=plant_id, found=False, note=msg);
        trace("estimate_loading_wait", {"plant_id": plant_id, "line_id": line_id}, res, t0, False, msg);
        return res;
    }
    res = estimate_wait(p, ideal_slot_start(order, p, line.quantity_t), line.quantity_t, latest_slot_start(order, p, line.quantity_t));
    trace("estimate_loading_wait", {"plant_id": plant_id, "line_id": line_id}, res, t0);
    return res;
}
sem estimate_loading_wait = "Estimate the earliest serviceable loading slot at a plant for a line (free bay and free loader on shift, after existing reservations) and the expected wait in minutes. This is an estimate, not a guarantee.";
sem estimate_loading_wait.plant_id = "Plant id.";
sem estimate_loading_wait.line_id = "Order line id.";

def estimate_delivery_eta(plant_id: str, line_id: str, slot_start_ts: float) -> EtaEstimate {
    t0 = started();
    (line, order, err) = _line_ctx(line_id);
    p = get_plant(plant_id);
    if line is None or order is None or p is None {
        msg = err or "plant not found";
        res = EtaEstimate(plant_id=plant_id, line_id=line_id, error=msg);
        trace("estimate_delivery_eta", {"plant_id": plant_id, "line_id": line_id, "slot_start_ts": slot_start_ts}, res, t0, False, msg);
        return res;
    }
    trip = trip_for(order, p, slot_start_ts, line.quantity_t);
    res = EtaEstimate(
        plant_id=plant_id, line_id=line_id, distance_km=trip.distance_km, travel_minutes=trip.travel_minutes,
        loading_minutes=trip.loading_minutes, slot_start=fmt_time(slot_start_ts), eta=fmt_time(trip.eta_ts),
        window=window_text(order), within_window=trip.eta_ts <= order.window_end
    );
    trace("estimate_delivery_eta", {"plant_id": plant_id, "line_id": line_id, "slot_start_ts": slot_start_ts}, res, t0);
    return res;
}
sem estimate_delivery_eta = "Estimate road distance, loading time, travel time and arrival time from a plant to the line's delivery site for a given loading slot start (unix seconds), and whether it lands inside the delivery window.";
sem estimate_delivery_eta.plant_id = "Plant id.";
sem estimate_delivery_eta.line_id = "Order line id.";
sem estimate_delivery_eta.slot_start_ts = "Loading slot start as unix timestamp (seconds), e.g. slot_start from estimate_loading_wait.";

"""Deterministic feasibility gates for one plant (also used by the fallback)."""
def feasibility(p: Plant, line: OrderLine, order: Order) -> FeasibilityReport {
    reasons: list[str] = [];
    if p.status == PlantStatus.UNAVAILABLE {
        return FeasibilityReport(plant_id=jid(p), line_id=jid(line), feasible=False, reasons=["Plant unavailable: " + p.status_note]);
    }
    best: PlanOption | None = None;
    est = estimate_wait(p, ideal_slot_start(order, p, line.quantity_t), line.quantity_t, latest_slot_start(order, p, line.quantity_t));
    if not est.found {
        reasons.append("No serviceable loading slot that can meet the delivery window.");
    }
    compatible_found = False;
    for lot in lots_of(p) {
        if lot.mineral_code != line.mineral_code {
            continue;
        }
        g = check_lot_for_line(lot, line);
        if not g.compatible {
            continue;
        }
        compatible_found = True;
        avail = availability(lot);
        if avail.available_t + 1e-9 < line.quantity_t {
            reasons.append(f"Lot {lot.code} has only {avail.available_t} t available.");
            continue;
        }
        if not est.found {
            continue;
        }
        opt = build_option("", 0, order, line, p, lot, est);
        opt.score = option_score(opt);
        if not opt.within_window {
            reasons.append(f"Lot {lot.code}: estimated arrival {fmt_time(opt.eta_ts)} is after the window.");
            continue;
        }
        if best is None or opt.score < best.score {
            best = opt;
        }
    }
    if not compatible_found {
        reasons.append("No lot of grade " + line.grade_code + " meets the specification here.");
    }
    return FeasibilityReport(plant_id=jid(p), line_id=jid(line), feasible=best is not None, reasons=[] if best is not None else reasons, option=best);
}

def evaluate_plant_feasibility(plant_id: str, line_id: str) -> FeasibilityReport {
    t0 = started();
    (line, order, err) = _line_ctx(line_id);
    p = get_plant(plant_id);
    if line is None or order is None or p is None {
        msg = err or "plant not found";
        res = FeasibilityReport(plant_id=plant_id, line_id=line_id, feasible=False, error=msg);
        trace("evaluate_plant_feasibility", {"plant_id": plant_id, "line_id": line_id}, res, t0, False, msg);
        return res;
    }
    res = feasibility(p, line, order);
    trace("evaluate_plant_feasibility", {"plant_id": plant_id, "line_id": line_id}, res, t0);
    return res;
}
sem evaluate_plant_feasibility = "Run the deterministic feasibility gates for supplying a line from one plant: plant status, grade-compatible lot with enough available stock, a serviceable slot, and arrival inside the window. Returns the best feasible option (lot, slot, ETA, wait, cost) or the reasons it is infeasible.";
sem evaluate_plant_feasibility.plant_id = "Plant id.";
sem evaluate_plant_feasibility.line_id = "Order line id.";

def compare_dispatch_options(line_id: str, plant_ids: list[str]) -> OptionComparison {
    t0 = started();
    (line, order, err) = _line_ctx(line_id);
    if line is None or order is None {
        res = OptionComparison(line_id=line_id, error=err);
        trace("compare_dispatch_options", {"line_id": line_id, "plant_ids": plant_ids}, res, t0, False, err);
        return res;
    }
    rows: list[PlanOption] = [];
    for pid in plant_ids[:6] {
        p = get_plant(pid);
        if p is None {
            continue;
        }
        rep = feasibility(p, line, order);
        if rep.option is not None {
            rows.append(rep.option);
        }
    }
    cheapest = "";
    earliest = "";
    if rows {
        cheapest = sorted(rows, key=lambda (o: PlanOption) { o.total_cost; })[0].plant_id;
        earliest = sorted(rows, key=lambda (o: PlanOption) { o.eta_ts; })[0].plant_id;
    }
    res = OptionComparison(line_id=line_id, rows=rows, cheapest_plant_id=cheapest, earliest_plant_id=earliest);
    trace("compare_dispatch_options", {"line_id": line_id, "plant_ids": plant_ids}, res, t0);
    return res;
}
sem compare_dispatch_options = "Compare the best feasible option of several plants for one line side by side (total cost, wait, ETA, lot quality). Infeasible plants are omitted.";
sem compare_dispatch_options.line_id = "Order line id.";
sem compare_dispatch_options.plant_ids = "Plant ids to compare (max 6).";

# --------------------------------------------------------- assignment tools
def active_jobs_of_driver(driver_id: str) -> int {
    active = ["OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING", "LOADED", "IN_TRANSIT"];
    return len([s for s in all_shipments() if s.driver_id == driver_id and str(s.status) in active]);
}

def truck_busy(truck_id: str, except_shipment: str) -> bool {
    active = ["OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING", "LOADED", "IN_TRANSIT"];
    for s in all_shipments() {
        if s.truck_id == truck_id and jid(s) != except_shipment and str(s.status) in active {
            return True;
        }
    }
    return False;
}

def driver_candidates(sh: Shipment) -> list[DriverCandidate] {
    p = get_plant(sh.plant_id);
    out: list[DriverCandidate] = [];
    for a in all_accounts() {
        if a.role != Role.DRIVER {
            continue;
        }
        reasons: list[str] = [];
        if not a.active {
            reasons.append("Account inactive.");
        }
        if a.license_class != "HEAVY" {
            reasons.append("No heavy-vehicle licence on file.");
        }
        jobs = active_jobs_of_driver(jid(a));
        if jobs > 0 and sh.driver_id != jid(a) {
            reasons.append(f"Already has {jobs} active job(s).");
        }
        km = round(haversine_km(a.home_lat, a.home_lng, p.lat, p.lng), 1) if p is not None else 0.0;
        out.append(DriverCandidate(driver_id=jid(a), name=a.display_name, eligible=len(reasons) == 0, reasons=reasons, km_to_plant=km, active_jobs=jobs));
    }
    return sorted(out, key=lambda (d: DriverCandidate) { (0 if d.eligible else 1, d.km_to_plant); });
}

def truck_candidates(sh: Shipment, mineral_bodies: list[str]) -> list[TruckCandidate] {
    out: list[TruckCandidate] = [];
    for t in all_trucks() {
        reasons: list[str] = [];
        if t.status == TruckStatus.MAINTENANCE {
            reasons.append("In maintenance: " + t.note);
        }
        if t.payload_t + 1e-9 < sh.quantity_t {
            reasons.append(f"Payload {t.payload_t} t is below the {sh.quantity_t} t load.");
        }
        if mineral_bodies and t.body_type not in mineral_bodies {
            reasons.append("Body type " + t.body_type + " not allowed for this mineral (" + ", ".join(mineral_bodies) + ").");
        }
        if truck_busy(jid(t), jid(sh)) {
            reasons.append("Committed to another active job.");
        }
        out.append(TruckCandidate(truck_id=jid(t), plate=t.plate, payload_t=t.payload_t, body_type=t.body_type, status=str(t.status), eligible=len(reasons) == 0, reasons=reasons));
    }
    return sorted(out, key=lambda (c: TruckCandidate) { (0 if c.eligible else 1, c.payload_t); });
}

def loader_candidates(sh: Shipment) -> list[LoaderCandidate] {
    slot = get_slot(sh.slot_id);
    out: list[LoaderCandidate] = [];
    for a in loaders_of_plant(sh.plant_id) {
        reasons: list[str] = [];
        same_hour = 0;
        if slot is not None {
            from_h = local_hour(slot.start_ts);
            if not (a.shift_start_hour <= from_h and from_h < a.shift_end_hour) {
                reasons.append(f"Off shift at that hour (works {a.shift_start_hour}:00-{a.shift_end_hour}:00).");
            }
            for s in all_shipments() {
                other = get_slot(s.slot_id);
                if s.loader_id == jid(a) and jid(s) != jid(sh) and other is not None and abs(other.start_ts - slot.start_ts) < 3600 and str(s.status) not in ["COMPLETED", "CANCELLED", "DELIVERED", "IN_TRANSIT", "LOADED"] {
                    same_hour += 1;
                }
            }
            if same_hour > 0 {
                reasons.append("Already loading another truck in that hour.");
            }
        }
        out.append(LoaderCandidate(loader_id=jid(a), name=a.display_name, eligible=len(reasons) == 0, reasons=reasons, assigned_jobs_same_hour=same_hour));
    }
    return sorted(out, key=lambda (c: LoaderCandidate) { 0 if c.eligible else 1; });
}

def list_eligible_drivers(shipment_id: str) -> list[DriverCandidate] {
    t0 = started();
    sh = get_shipment(shipment_id);
    if not shipment_in_scope(shipment_id) or sh is None {
        trace("list_eligible_drivers", {"shipment_id": shipment_id}, "shipment not part of this run", t0, False, "out of scope");
        return [];
    }
    res = driver_candidates(sh);
    trace("list_eligible_drivers", {"shipment_id": shipment_id}, res, t0);
    return res;
}
sem list_eligible_drivers = "List drivers for a shipment with eligibility (licence, availability, no overlapping job) and reasons, plus distance from home base to the plant. Proximity alone must not decide.";
sem list_eligible_drivers.shipment_id = "Shipment id from the brief.";

def list_eligible_trucks(shipment_id: str) -> list[TruckCandidate] {
    t0 = started();
    sh = get_shipment(shipment_id);
    if not shipment_in_scope(shipment_id) or sh is None {
        trace("list_eligible_trucks", {"shipment_id": shipment_id}, "shipment not part of this run", t0, False, "out of scope");
        return [];
    }
    lot = get_lot(sh.lot_id);
    m = mineral_by_code(lot.mineral_code) if lot is not None else None;
    res = truck_candidates(sh, m.allowed_bodies if m is not None else []);
    trace("list_eligible_trucks", {"shipment_id": shipment_id}, res, t0);
    return res;
}
sem list_eligible_trucks = "List trucks with eligibility for a shipment: payload capacity, body type allowed for the mineral, maintenance status and existing commitments.";
sem list_eligible_trucks.shipment_id = "Shipment id from the brief.";

def list_eligible_loaders(shipment_id: str) -> list[LoaderCandidate] {
    t0 = started();
    sh = get_shipment(shipment_id);
    if not shipment_in_scope(shipment_id) or sh is None {
        trace("list_eligible_loaders", {"shipment_id": shipment_id}, "shipment not part of this run", t0, False, "out of scope");
        return [];
    }
    res = loader_candidates(sh);
    trace("list_eligible_loaders", {"shipment_id": shipment_id}, res, t0);
    return res;
}
sem list_eligible_loaders = "List loaders at the shipment's plant with shift coverage for its slot and whether they are already loading another truck in that hour.";
sem list_eligible_loaders.shipment_id = "Shipment id from the brief.";

def find_open_slots(plant_id: str, line_id: str) -> list[SlotView] {
    t0 = started();
    (line, order, err) = _line_ctx(line_id);
    p = get_plant(plant_id);
    if line is None or order is None or p is None {
        msg = err or "plant not found";
        trace("find_open_slots", {"plant_id": plant_id, "line_id": line_id}, msg, t0, False, msg);
        return [];
    }
    res = open_slot_views(p, ideal_slot_start(order, p, line.quantity_t), latest_slot_start(order, p, line.quantity_t), 8);
    trace("find_open_slots", {"plant_id": plant_id, "line_id": line_id}, res, t0);
    return res;
}
sem find_open_slots = "List serviceable open loading slots at a plant that can still meet the line's delivery window (up to 8).";
sem find_open_slots.plant_id = "Plant id.";
sem find_open_slots.line_id = "Order line id.";

def get_exception_context(exception_id: str) -> ExceptionContext {
    t0 = started();
    ex = get_exception(exception_id);
    if ex is None {
        res = ExceptionContext(exception_id=exception_id, ex_type="", summary="", detail="", error="exception not found");
        trace("get_exception_context", {"exception_id": exception_id}, res, t0, False, res.error);
        return res;
    }
    res = ExceptionContext(exception_id=exception_id, ex_type=str(ex.ex_type), summary=ex.summary, detail=ex.detail);
    sh = get_shipment(ex.shipment_id);
    if sh is not None and shipment_in_scope(ex.shipment_id) {
        p = get_plant(sh.plant_id);
        line = get_line(sh.line_id);
        order = get_order(sh.order_id);
        slot = get_slot(sh.slot_id);
        res.shipment_id = jid(sh);
        res.shipment_status = str(sh.status);
        res.line_id = sh.line_id;
        res.current_plant_id = sh.plant_id;
        res.current_plant_name = p.name if p is not None else "";
        res.current_plant_status = str(p.status) + (" - " + p.status_note if p is not None and p.status_note else "") if p is not None else "";
        res.current_lot_id = sh.lot_id;
        res.current_slot_start = fmt_time(slot.start_ts) if slot is not None else "";
        res.quantity_t = sh.quantity_t;
        res.driver_id = sh.driver_id;
        res.truck_id = sh.truck_id;
        if line is not None {
            res.mineral_code = line.mineral_code;
            res.grade_code = line.grade_code;
        }
        if order is not None {
            res.window = window_text(order);
        }
    }
    trace("get_exception_context", {"exception_id": exception_id}, res, t0);
    return res;
}
sem get_exception_context = "Get what went wrong: exception type and details, the affected shipment, its current plant/lot/slot, quantity, grade, delivery window and current driver/truck.";
sem get_exception_context.exception_id = "Exception id from the brief.";
