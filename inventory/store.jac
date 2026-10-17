"""Mining plant store manager: inventory, stock lots, quality records,
reservations, plant status, production/restocking plans and delays.

A store manager can only touch the plants listed on their account. Changes that
break existing reservations (quality hold, stock drop, plant unavailable,
loading delay) never silently oversell: affected loads move to EXCEPTION and
dispatch gets a recovery case.
"""

import from core.model {
    Plant, StockLot, HoldsLot, QualityRecord, HasQualityRecord, Reservation, DelayNotice,
    HasDelay, ProductionPlan, HasProductionPlan
}
import from core.enums { Role, LotQuality, PlantStatus, DelayKind, ExceptionType, ReservationStatus }
import from core.hub {
    get_plant, get_lot, get_order, get_org, get_shipment, get_slot, get_account, lots_of,
    mineral_by_code, grade_by_code, all_claims, all_shipments, fetch, grades_of, reservations_of_lot
}
import from core.access {
    AppError, Caller, require_roles, require_plant_manager, manages_plant, not_found, invalid,
    bad_state, conflict
}
import from core.audit { audit, notify_dispatchers }
import from core.views { ActionResult }
import from core.util { now, clean_text, fmt_time }
import from inventory.availability { LotAvailability, availability, plant_inventory, reserved_on }
import from inventory.impact { scan_plant, flag_shipments }
import from evidence.store { evidence_views }
import from core.views { EvidenceView }
import from scheduling.slots { DAY }
import from dispatch.exceptions { raise_exception }

obj PlantSummary {
    has id: str,
        code: str,
        name: str,
        region: str,
        status: str,
        status_note: str,
        minerals: list[str],
        measured_t: float,
        reserved_t: float,
        held_t: float,
        available_t: float,
        lots: int,
        pending_lots: int,
        active_delays: int,
        upcoming_loads: int,
        open_claims: int;
}

obj QualityRecordView {
    has id: str,
        lot_id: str,
        lot_code: str,
        lab: str,
        tested_at: float,
        results: dict[str, float],
        verdict: str,
        certificate_no: str,
        recorded_by_name: str,
        notes: str,
        evidence: list[EvidenceView] = [];
}

obj ReservationView {
    has id: str,
        lot_code: str,
        order_ref: str,
        buyer_org: str,
        quantity_t: float,
        status: str,
        shipment_ref: str,
        shipment_status: str,
        slot_start: float,
        created_at: float;
}

obj DelayView {
    has id: str,
        kind: str,
        severity: str,
        start_ts: float,
        end_ts: float,
        description: str,
        active: bool,
        created_at: float;
}

obj ProductionPlanView {
    has id: str,
        mineral_code: str,
        grade_code: str,
        expected_t: float,
        expected_at: float,
        status: str,
        note: str;
}

obj GradeRef {
    has mineral_code: str,
        grade_code: str,
        name: str,
        param_keys: list[str];
}

obj PlantsResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        plants: list[PlantSummary] = [];
}

obj PlantDetail {
    has ok: bool,
        code: str = "",
        message: str = "",
        plant: PlantSummary | None = None,
        lots: list[LotAvailability] = [],
        grades: list[GradeRef] = [],
        quality: list[QualityRecordView] = [],
        reservations: list[ReservationView] = [],
        delays: list[DelayView] = [],
        plans: list[ProductionPlanView] = [];
}

def plant_summary(p: Plant) -> PlantSummary {
    rows = plant_inventory(p);
    pid = jid(p);
    t = now();
    upcoming = 0;
    for sh in all_shipments() {
        if sh.plant_id == pid and str(sh.status) in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING"] {
            upcoming += 1;
        }
    }
    return PlantSummary(
        id=pid, code=p.code, name=p.name, region=p.region, status=str(p.status), status_note=p.status_note,
        minerals=p.minerals, measured_t=round(sum([r.measured_t for r in rows]), 2),
        reserved_t=round(sum([r.reserved_t for r in rows]), 2), held_t=round(sum([r.quality_held_t for r in rows]), 2),
        available_t=round(sum([r.available_t for r in rows]), 2), lots=len(rows),
        pending_lots=len([r for r in rows if r.quality == "PENDING"]),
        active_delays=len([d for d in [p ->:HasDelay:-> [?:DelayNotice]] if d.active and d.end_ts > t]),
        upcoming_loads=upcoming,
        open_claims=len([c for c in all_claims() if c.plant_id == pid and str(c.status) in ["OPEN", "UNDER_REVIEW"]])
    );
}

def _managed_plant(c: Caller, plant_id: str) -> Plant {
    require_plant_manager(c, plant_id);
    p = get_plant(plant_id);
    if p is None {
        raise not_found("Plant");
    }
    return p;
}

def _managed_lot(c: Caller, lot_id: str) -> StockLot {
    lot = get_lot(lot_id);
    if lot is None or not manages_plant(c, lot.plant_id) {
        raise not_found("Stock lot");
    }
    return lot;
}

def quality_view(q: QualityRecord) -> QualityRecordView {
    lot = get_lot(q.lot_id);
    who = get_account(q.recorded_by);
    return QualityRecordView(
        id=jid(q), lot_id=q.lot_id, lot_code=lot.code if lot is not None else "", lab=q.lab, tested_at=q.tested_at,
        results=q.results, verdict=str(q.verdict), certificate_no=q.certificate_no,
        recorded_by_name=who.display_name if who is not None else "seed", notes=q.notes, evidence=evidence_views(q)
    );
}

def:protect manager_plants(poll: int = 0) -> PlantsResult {
    _ = poll;
    try {
        c = require_roles([Role.STORE_MANAGER]);
        out: list[PlantSummary] = [];
        for pid in c.account.plant_ids {
            p = get_plant(pid);
            if p is not None {
                out.append(plant_summary(p));
            }
        }
        return PlantsResult(ok=True, plants=out);
    } except AppError as e {
        return PlantsResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect plant_detail(plant_id: str, poll: int = 0) -> PlantDetail {
    _ = poll;
    try {
        c = require_roles([Role.STORE_MANAGER]);
        p = _managed_plant(c, plant_id);
        lots = lots_of(p);
        grades: list[GradeRef] = [];
        for code in p.minerals {
            m = mineral_by_code(code);
            if m is None {
                continue;
            }
            for g in grades_of(m) {
                grades.append(GradeRef(mineral_code=code, grade_code=g.code, name=g.name, param_keys=[x.key for x in g.params]));
            }
        }
        quality: list[QualityRecordView] = [];
        reservations: list[ReservationView] = [];
        for lot in lots {
            quality = quality + [quality_view(q) for q in [lot ->:HasQualityRecord:-> [?:QualityRecord]]];
            for r in reservations_of_lot(lot) {
                o = get_order(r.order_id);
                sh = get_shipment(r.shipment_id);
                slot = get_slot(sh.slot_id) if sh is not None else None;
                org = get_org(o.buyer_org_id) if o is not None else None;
                reservations.append(ReservationView(
                    id=jid(r), lot_code=lot.code, order_ref=o.ref if o is not None else "", buyer_org=org.name if org is not None else "",
                    quantity_t=r.quantity_t, status=str(r.status), shipment_ref=sh.ref if sh is not None else "",
                    shipment_status=str(sh.status) if sh is not None else "", slot_start=slot.start_ts if slot is not None else 0.0,
                    created_at=r.created_at
                ));
            }
        }
        delays = [DelayView(id=jid(d), kind=str(d.kind), severity=d.severity, start_ts=d.start_ts, end_ts=d.end_ts, description=d.description, active=d.active, created_at=d.created_at) for d in [p ->:HasDelay:-> [?:DelayNotice]]];
        plans = [ProductionPlanView(id=jid(x), mineral_code=x.mineral_code, grade_code=x.grade_code, expected_t=x.expected_t, expected_at=x.expected_at, status=x.status, note=x.note) for x in [p ->:HasProductionPlan:-> [?:ProductionPlan]]];
        return PlantDetail(
            ok=True, plant=plant_summary(p), lots=[availability(l) for l in sorted(lots, key=lambda (x: StockLot) { x.code; })],
            grades=grades, quality=sorted(quality, key=lambda (q: QualityRecordView) { -q.tested_at; }),
            reservations=sorted(reservations, key=lambda (r: ReservationView) { -r.created_at; }),
            delays=sorted(delays, key=lambda (d: DelayView) { -d.start_ts; }),
            plans=sorted(plans, key=lambda (x: ProductionPlanView) { x.expected_at; })
        );
    } except AppError as e {
        return PlantDetail(ok=False, code=e.code, message=e.message);
    }
}

"""Validate one lot write; shared by the form and the spreadsheet import."""
def lot_write_problems(p: Plant, existing: StockLot | None, code: str, mineral_code: str, grade_code: str, measured_t: float, price_per_t: float, assay: dict[str, float]) -> list[str] {
    problems: list[str] = [];
    if not code or len(code) > 40 {
        problems.append("Lot code is required (max 40 characters).");
    }
    if mineral_code not in p.minerals {
        problems.append("Mineral " + mineral_code + " is not produced at " + p.name + ".");
    }
    g = grade_by_code(mineral_code, grade_code);
    if g is None {
        problems.append("Unknown grade " + grade_code + " for " + mineral_code + ".");
    }
    if measured_t < 0 or measured_t > 1000000 {
        problems.append("Measured quantity must be between 0 and 1,000,000 t.");
    }
    if price_per_t < 0 {
        problems.append("Price cannot be negative.");
    }
    if g is not None {
        keys = [x.key for x in g.params];
        for k in assay.keys() {
            if k not in keys {
                problems.append("Assay field " + k + " is not part of grade " + grade_code + ".");
            }
        }
        for k in keys {
            if k not in assay {
                problems.append("Assay value " + k + " is missing.");
            }
        }
        for v in assay.values() {
            if v < 0 or v > 100 {
                problems.append("Assay values must be percentages between 0 and 100.");
                break;
            }
        }
    }
    if existing is not None {
        if existing.mineral_code != mineral_code or existing.grade_code != grade_code {
            problems.append("A lot's mineral and grade cannot change; create a new lot instead.");
        }
        reserved = reserved_on(existing);
        if measured_t + 1e-9 < reserved {
            problems.append(f"{reserved} t of this lot is reserved for orders; measured stock cannot go below that without releasing or re-planning those loads.");
        }
    }
    return problems;
}

def:protect upsert_lot(plant_id: str, lot_id: str, code: str, mineral_code: str, grade_code: str, stockpile: str, measured_t: float, price_per_t: float, assay: dict[str, float], notes: str = "") -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        p = _managed_plant(c, plant_id);
        existing = _managed_lot(c, lot_id) if lot_id else None;
        if existing is not None and existing.plant_id != plant_id {
            raise invalid("Lot belongs to another plant.");
        }
        code_clean = clean_text(code, 40).upper();
        if existing is None {
            for l in lots_of(p) {
                if l.code == code_clean {
                    raise conflict("Lot code " + code_clean + " already exists at this plant.");
                }
            }
        }
        problems = lot_write_problems(p, existing, code_clean, mineral_code, grade_code, measured_t, price_per_t, assay);
        if problems {
            raise invalid(" ".join(problems));
        }
        t = now();
        if existing is None {
            lot = StockLot(code=code_clean, plant_id=plant_id, mineral_code=mineral_code, grade_code=grade_code, stockpile=clean_text(stockpile, 80), measured_t=round(measured_t, 3), assay=assay, price_per_t=price_per_t, notes=clean_text(notes, 300), updated_at=t);
            p +>:HoldsLot():+> lot;
            audit(c, "LOT_CREATED", "StockLot", jid(lot), code_clean + " " + str(measured_t) + " t (quality PENDING)", "", [plant_id]);
            notify_dispatchers(plant_id, "info", "New stock lot at " + p.name, code_clean + ": " + str(measured_t) + " t " + grade_code + " (pending verification)");
            return ActionResult(ok=True, id=jid(lot), message="Lot created. It stays PENDING until a quality record verifies it.");
        }
        before = existing.measured_t;
        existing.stockpile = clean_text(stockpile, 80);
        existing.measured_t = round(measured_t, 3);
        existing.price_per_t = price_per_t;
        existing.assay = assay;
        existing.notes = clean_text(notes, 300);
        existing.updated_at = t;
        audit(c, "LOT_UPDATED", "StockLot", lot_id, existing.code + f" measured {before} -> {measured_t} t", "", [plant_id]);
        if measured_t < before {
            notify_dispatchers(plant_id, "info", "Stock change at " + p.name, existing.code + f": {before} -> {measured_t} t");
        }
        return ActionResult(ok=True, id=lot_id, message="Lot updated.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Record an inspection; the verdict sets the lot's quality status. Putting a
lot on QUALITY_HOLD flags every not-yet-loaded reservation for recovery."""
def:protect add_quality_record(lot_id: str, lab: str, results: dict[str, float], verdict: str, certificate_no: str = "", notes: str = "") -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        lot = _managed_lot(c, lot_id);
        try {
            v = LotQuality(verdict);
        } except ValueError {
            raise invalid("Verdict must be VERIFIED, PENDING or QUALITY_HOLD.");
        }
        if len(clean_text(lab, 80)) < 2 {
            raise invalid("Enter the laboratory or inspector.");
        }
        for val in results.values() {
            if val < 0 or val > 100 {
                raise invalid("Results must be percentages between 0 and 100.");
            }
        }
        q = QualityRecord(lot_id=lot_id, lab=clean_text(lab, 80), tested_at=now(), results=results, verdict=v, certificate_no=clean_text(certificate_no, 60), recorded_by=c.account_id, notes=clean_text(notes, 400));
        lot +>:HasQualityRecord():+> q;
        previous = lot.quality;
        lot.quality = v;
        if results {
            merged = dict(lot.assay);
            for (k, val) in results.items() {
                merged[k] = val;
            }
            lot.assay = merged;
        }
        lot.updated_at = now();
        flagged = 0;
        if v == LotQuality.QUALITY_HOLD and previous != LotQuality.QUALITY_HOLD {
            p = get_plant(lot.plant_id);
            if p is not None {
                ids = scan_plant(p, [lot_id], False);
                flagged = flag_shipments(c, ids, ExceptionType.STOCK_SHORTAGE, "HIGH", "Lot " + lot.code + " placed on quality hold", "Inspection by " + q.lab + ": " + q.notes);
            }
        }
        audit(c, "QUALITY_RECORDED", "StockLot", lot_id, lot.code + ": " + str(previous) + " -> " + verdict + (f" ({flagged} loads flagged)" if flagged else ""), notes, [lot.plant_id]);
        msg = "Quality record saved." + (f" {flagged} reserved load(s) were flagged for re-planning." if flagged else "");
        return ActionResult(ok=True, id=jid(q), message=msg);
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Report a physical stock loss below what is reserved. Explicit and audited:
the newest affected loads are flagged for recovery instead of overselling."""
def:protect report_stock_loss(lot_id: str, new_measured_t: float, reason: str) -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        lot = _managed_lot(c, lot_id);
        why = clean_text(reason, 400);
        if len(why) < 5 {
            raise invalid("Explain the stock loss.");
        }
        if new_measured_t < 0 or new_measured_t >= lot.measured_t {
            raise invalid("Enter the new, lower measured quantity.");
        }
        p = get_plant(lot.plant_id);
        old = lot.measured_t;
        lot.measured_t = round(new_measured_t, 3);
        lot.updated_at = now();
        flagged = 0;
        if p is not None {
            held = sorted([r for r in reservations_of_lot(lot) if r.status == ReservationStatus.HELD], key=lambda (r: Reservation) { -r.created_at; });
            excess = reserved_on(lot) - new_measured_t;
            victims: list[str] = [];
            for r in held {
                if excess <= 1e-9 {
                    break;
                }
                if r.shipment_id {
                    victims.append(r.shipment_id);
                    excess = excess - r.quantity_t;
                }
            }
            flagged = flag_shipments(c, victims, ExceptionType.STOCK_SHORTAGE, "HIGH", "Stock shortage in lot " + lot.code, why);
        }
        audit(c, "STOCK_LOSS", "StockLot", lot_id, lot.code + f": {old} -> {new_measured_t} t ({flagged} loads flagged)", why, [lot.plant_id]);
        notify_dispatchers(lot.plant_id, "warning", "Stock loss at " + (p.name if p is not None else "plant"), lot.code + f": {old} -> {new_measured_t} t. " + why);
        return ActionResult(ok=True, id=lot_id, message=f"Stock updated. {flagged} reserved load(s) flagged for re-planning.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect set_plant_status(plant_id: str, status: str, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        p = _managed_plant(c, plant_id);
        try {
            st = PlantStatus(status);
        } except ValueError {
            raise invalid("Unknown plant status.");
        }
        text = clean_text(note, 300);
        if st != PlantStatus.OPERATIONAL and len(text) < 5 {
            raise invalid("Explain why the plant is restricted or unavailable.");
        }
        previous = p.status;
        p.status = st;
        p.status_note = text if st != PlantStatus.OPERATIONAL else "";
        flagged = 0;
        if st == PlantStatus.UNAVAILABLE and previous != PlantStatus.UNAVAILABLE {
            ids = scan_plant(p, [], True);
            flagged = flag_shipments(c, ids, ExceptionType.PLANT_UNAVAILABLE, "HIGH", p.name + " is unavailable", text);
        }
        notify_dispatchers(plant_id, "error" if st == PlantStatus.UNAVAILABLE else "info", p.name + " is now " + status.lower(), text);
        audit(c, "PLANT_STATUS", "Plant", plant_id, p.name + ": " + str(previous) + " -> " + status + (f" ({flagged} loads flagged)" if flagged else ""), text, [plant_id]);
        return ActionResult(ok=True, id=plant_id, message=p.name + " marked " + status.lower() + "." + (f" {flagged} load(s) flagged for re-planning." if flagged else ""));
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect add_delay(plant_id: str, kind: str, severity: str, start_ts: float, end_ts: float, description: str) -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        p = _managed_plant(c, plant_id);
        try {
            k = DelayKind(kind);
        } except ValueError {
            raise invalid("Unknown delay type.");
        }
        if severity not in ["LOW", "MEDIUM", "HIGH"] {
            raise invalid("Severity must be LOW, MEDIUM or HIGH.");
        }
        text = clean_text(description, 300);
        if len(text) < 5 {
            raise invalid("Describe the delay.");
        }
        if end_ts <= start_ts or end_ts - start_ts > 14 * DAY or end_ts < now() {
            raise invalid("Enter a valid future time range (max 14 days).");
        }
        d = DelayNotice(plant_id=plant_id, kind=k, severity=severity, start_ts=start_ts, end_ts=end_ts, description=text, created_by=c.account_id, created_at=now());
        p +>:HasDelay():+> d;
        flagged = 0;
        if k in [DelayKind.LOADING, DelayKind.EQUIPMENT] {
            ids = scan_plant(p, [], True, start_ts, end_ts);
            flagged = flag_shipments(c, ids, ExceptionType.SLOT_LOST, severity, "Loading slot lost: " + text, fmt_time(start_ts) + " to " + fmt_time(end_ts));
        } else {
            raise_exception(ExceptionType.PRODUCTION_DELAY, severity, p.name + ": " + str(k).lower() + " delay", text + " (" + fmt_time(start_ts) + " to " + fmt_time(end_ts) + ")", None, plant_id, c.account_id);
        }
        audit(c, "DELAY_FLAGGED", "Plant", plant_id, p.name + " " + kind + " delay " + fmt_time(start_ts) + "-" + fmt_time(end_ts) + (f" ({flagged} loads flagged)" if flagged else ""), text, [plant_id]);
        return ActionResult(ok=True, id=jid(d), message="Delay recorded and dispatch notified." + (f" {flagged} load(s) lost their slot." if flagged else ""));
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect resolve_delay(delay_id: str) -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        n = fetch(delay_id, DelayNotice);
        d = None if n is None else n as DelayNotice;
        if d is None or not manages_plant(c, d.plant_id) {
            raise not_found("Delay");
        }
        d.active = False;
        notify_dispatchers(d.plant_id, "success", "Delay cleared", d.description);
        audit(c, "DELAY_CLEARED", "Plant", d.plant_id, d.description, "", [d.plant_id]);
        return ActionResult(ok=True, id=delay_id, message="Delay cleared.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect add_production_plan(plant_id: str, mineral_code: str, grade_code: str, expected_t: float, expected_at: float, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        p = _managed_plant(c, plant_id);
        if mineral_code not in p.minerals or grade_by_code(mineral_code, grade_code) is None {
            raise invalid("Choose a mineral and grade produced at this plant.");
        }
        if expected_t <= 0 or expected_at < now() {
            raise invalid("Enter a positive quantity and a future date.");
        }
        x = ProductionPlan(plant_id=plant_id, mineral_code=mineral_code, grade_code=grade_code, expected_t=expected_t, expected_at=expected_at, note=clean_text(note, 200));
        p +>:HasProductionPlan():+> x;
        notify_dispatchers(plant_id, "info", "Replenishment planned at " + p.name, str(expected_t) + " t " + grade_code + " by " + fmt_time(expected_at));
        audit(c, "PRODUCTION_PLANNED", "Plant", plant_id, str(expected_t) + " t " + grade_code + " by " + fmt_time(expected_at), "", [plant_id]);
        return ActionResult(ok=True, id=jid(x), message="Production plan added.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect update_production_plan(plan_id: str, status: str, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        n = fetch(plan_id, ProductionPlan);
        x = None if n is None else n as ProductionPlan;
        if x is None or not manages_plant(c, x.plant_id) {
            raise not_found("Production plan");
        }
        if status not in ["PLANNED", "DELAYED", "DONE", "CANCELLED"] {
            raise invalid("Unknown status.");
        }
        x.status = status;
        if note {
            x.note = clean_text(note, 200);
        }
        if status == "DELAYED" {
            notify_dispatchers(x.plant_id, "warning", "Replenishment delayed", x.grade_code + ": " + x.note);
        }
        audit(c, "PRODUCTION_" + status, "ProductionPlan", plan_id, x.grade_code + " " + str(x.expected_t) + " t", note, [x.plant_id]);
        return ActionResult(ok=True, id=plan_id, message="Plan updated.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Free-form readiness/stock note to dispatch for one of the manager's plants."""
def:protect notify_dispatch(plant_id: str, message: str) -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        p = _managed_plant(c, plant_id);
        text = clean_text(message, 400);
        if len(text) < 3 {
            raise invalid("Message is empty.");
        }
        notify_dispatchers(plant_id, "info", p.name + ": message from " + c.account.display_name, text);
        audit(c, "PLANT_NOTE", "Plant", plant_id, text, "", [plant_id]);
        return ActionResult(ok=True, id=plant_id, message="Dispatch notified.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
