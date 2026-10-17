"""Buyer ordering: catalog, order creation, plant recommendations (agent),
confirmation with atomic reservation, cancellation, delivery acknowledgement
and issue reporting. Also the role-shaped order detail used by dispatchers and
plant managers.
"""

import from core.model {
    Order, OrderLine, HasOrder, HasLine, Shipment, SpecParam, AgentRun, Claim,
    HasClaim, TimelineEvent, HasEvent, DeliverySite
}
import from core.enums { Role, OrderStatus, ShipmentStatus, AckMethod, ClaimType, ClaimStatus, OfferStatus, TruckStatus, EvidenceKind }
import from core.hub {
    get_hub, get_order, get_line, get_shipment, get_site, get_org, get_plant, get_lot,
    get_account, get_truck, get_run, all_minerals, grades_of, mineral_by_code,
    grade_by_code, sites_of, lines_of, shipments_of_order, all_orders, all_plants,
    offers_of, get_reservation, name_of_plant, get_slot
}
import from core.access {
    AppError, Caller, current_caller, require_roles, can_view_order, require_order_visible,
    not_found, invalid, bad_state, conflict, deny, overlaps
}
import from core.state_machines { assert_order, assert_shipment }
import from core.audit { audit, timeline, notify_dispatchers, notify_plant_managers, notify, notify_order_buyer }
import from core.views { ActionResult, TimelineEntryView, EvidenceView, ClaimView }
import from core.config { settings }
import from core.util { now, new_ref, clean_text, fmt_time }
import from catalog.grades { resolve_spec, spec_problems }
import from scheduling.slots { ensure_all_slots }
import from reservations.reserve { reservation_problems, lot_problems, next_free_slot, reserve_line, release_reservation, free_slot_of }
import from planning.workflow { PlanningWorkflow, run_view, AgentRunView, runs_of }
import from delivery.tracking { connectivity_of, last_ping }
import from evidence.store { evidence_views, count_of_kind }
import from orders.rollup { refresh_order_status }
import from payments.ledger { on_completed }
import from claims.store { open_claim, claim_view }

obj GradeOption {
    has code: str,
        name: str,
        description: str,
        params: list[SpecParam] = [];
}

obj MineralOption {
    has code: str,
        name: str,
        description: str,
        grades: list[GradeOption] = [],
        plant_count: int = 0;
}

obj SiteOption {
    has id: str,
        name: str,
        address: str,
        lat: float,
        lng: float,
        contact_name: str;
}

obj BuyerCatalog {
    has ok: bool,
        code: str = "",
        message: str = "",
        minerals: list[MineralOption] = [],
        sites: list[SiteOption] = [],
        currency: str = "LKR",
        max_load_t: float = 40.0;
}

obj OrderLineInput {
    has mineral_code: str,
        grade_code: str,
        quantity_t: float,
        spec_overrides: list[SpecParam] = [];
}

obj LineSelection {
    has line_id: str,
        option_id: str;
}

obj OrderLineView {
    has id: str,
        line_no: int,
        mineral_code: str,
        mineral_name: str,
        grade_code: str,
        grade_name: str,
        quantity_t: float,
        spec: list[SpecParam] = [];
}

obj ShipmentView {
    has id: str,
        ref: str,
        line_id: str,
        status: str,
        plant_id: str,
        plant_name: str,
        lot_code: str,
        lot_quality: str,
        quantity_t: float,
        slot_start: float,
        eta_ts: float,
        distance_km: float,
        driver_name: str,
        truck_plate: str,
        loader_name: str,
        loaded_qty_t: float,
        load_ticket_no: str,
        departed_at: float,
        unloaded_at: float,
        handover_note: str,
        ack_method: str,
        acknowledged_at: float,
        received_qty_t: float,
        completed_at: float,
        connectivity: str,
        last_ping_at: float,
        handover_pin: str = "",
        evidence: list[EvidenceView] = [],
        can_acknowledge: bool = False,
        can_report_issue: bool = False,
        can_track: bool = False,
        can_message: bool = False;
}

obj OrderSummaryView {
    has id: str,
        ref: str,
        status: str,
        created_at: float,
        updated_at: float,
        window_start: float,
        window_end: float,
        site_name: str,
        lines_text: str,
        total_t: float,
        shipments_total: int,
        shipments_done: int,
        plant_names: list[str],
        next_action: str,
        buyer_name: str,
        buyer_org: str;
}

obj OrderDetailView {
    has summary: OrderSummaryView,
        site_address: str,
        site_contact: str,
        dest_lat: float,
        dest_lng: float,
        notes: str,
        lines: list[OrderLineView] = [],
        shipments: list[ShipmentView] = [],
        timeline: list[TimelineEntryView] = [],
        runs: list[AgentRunView] = [],
        claims: list[ClaimView] = [],
        can_request_plan: bool = False,
        can_confirm: bool = False,
        can_cancel: bool = False,
        viewer_role: str = "";
}

obj OrderDetailResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: OrderDetailView | None = None;
}

obj OrderListResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        orders: list[OrderSummaryView] = [];
}

obj PlanResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        order_status: str = "",
        run: AgentRunView | None = None;
}

# ------------------------------------------------------------- view builders
def next_action_for(o: Order, role: Role) -> str {
    s = o.status;
    if role == Role.BUYER {
        if s == OrderStatus.DRAFT or s == OrderStatus.NO_FEASIBLE_OPTION {
            return "Get plant recommendations";
        }
        if s == OrderStatus.OPTIONS_READY {
            return "Choose and confirm an option";
        }
        if s == OrderStatus.DELIVERED {
            return "Acknowledge delivery or report an issue";
        }
        if s == OrderStatus.IN_PROGRESS {
            return "Track your delivery";
        }
        if s == OrderStatus.DISPUTED {
            return "Follow your claim";
        }
        return "";
    }
    if role == Role.DISPATCHER {
        if s == OrderStatus.RESERVED or s == OrderStatus.EXCEPTION {
            return "Assign driver, truck and loader";
        }
        if s == OrderStatus.DISPUTED {
            return "Review claim";
        }
    }
    return "";
}

def summary_view(o: Order, role: Role) -> OrderSummaryView {
    lines = lines_of(o);
    ships = shipments_of_order(o);
    buyer = get_account(o.buyer_id);
    org = get_org(o.buyer_org_id);
    parts = [str(l.quantity_t) + " t " + l.grade_code for l in lines];
    return OrderSummaryView(
        id=jid(o), ref=o.ref, status=str(o.status), created_at=o.created_at, updated_at=o.updated_at,
        window_start=o.window_start, window_end=o.window_end, site_name=o.site_name,
        lines_text=" + ".join(parts), total_t=round(sum([l.quantity_t for l in lines]), 2),
        shipments_total=len([s for s in ships if s.status != ShipmentStatus.CANCELLED]),
        shipments_done=len([s for s in ships if s.status == ShipmentStatus.COMPLETED]),
        plant_names=[name_of_plant(pid) for pid in o.plant_ids],
        next_action=next_action_for(o, role),
        buyer_name=buyer.display_name if buyer is not None else "",
        buyer_org=org.name if org is not None else ""
    );
}

def line_view(l: OrderLine) -> OrderLineView {
    m = mineral_by_code(l.mineral_code);
    g = grade_by_code(l.mineral_code, l.grade_code);
    return OrderLineView(
        id=jid(l), line_no=l.line_no, mineral_code=l.mineral_code,
        mineral_name=m.name if m is not None else l.mineral_code, grade_code=l.grade_code,
        grade_name=g.name if g is not None else l.grade_code, quantity_t=l.quantity_t, spec=l.spec
    );
}

def shipment_view(c: Caller, o: Order, sh: Shipment) -> ShipmentView {
    p = get_plant(sh.plant_id);
    lot = get_lot(sh.lot_id);
    driver = get_account(sh.driver_id);
    loader = get_account(sh.loader_id);
    truck = get_truck(sh.truck_id);
    slot = get_slot(sh.slot_id);
    last = last_ping(sh);
    is_buyer = c.has_role(Role.BUYER) and o.buyer_id == c.account_id;
    show_pin = is_buyer and sh.status in [ShipmentStatus.LOADED, ShipmentStatus.IN_TRANSIT, ShipmentStatus.DELIVERED];
    eta = 0.0;
    if sh.departed_at > 0 {
        eta = sh.departed_at + sh.eta_minutes * 60.0;
    } elif slot is not None and p is not None {
        eta = slot.start_ts + (p.readiness_buffer_min + 20) * 60.0 + sh.eta_minutes * 60.0;
    }
    trackable = [ShipmentStatus.LOADED, ShipmentStatus.IN_TRANSIT, ShipmentStatus.DELIVERED];
    return ShipmentView(
        id=jid(sh), ref=sh.ref, line_id=sh.line_id, status=str(sh.status), plant_id=sh.plant_id,
        plant_name=p.name if p is not None else "", lot_code=lot.code if lot is not None else "",
        lot_quality=str(lot.quality) if lot is not None else "", quantity_t=sh.quantity_t,
        slot_start=slot.start_ts if slot is not None else 0.0, eta_ts=eta, distance_km=sh.distance_km,
        driver_name=driver.display_name if driver is not None else "",
        truck_plate=truck.plate if truck is not None else "",
        loader_name=loader.display_name if loader is not None else "",
        loaded_qty_t=sh.loaded_qty_t, load_ticket_no=sh.load_ticket_no, departed_at=sh.departed_at,
        unloaded_at=sh.unloaded_at, handover_note=sh.handover_note, ack_method=str(sh.ack_method),
        acknowledged_at=sh.acknowledged_at, received_qty_t=sh.received_qty_t, completed_at=sh.completed_at,
        connectivity=str(connectivity_of(sh)), last_ping_at=last.at if last is not None else 0.0,
        handover_pin=sh.handover_pin if show_pin else "",
        evidence=evidence_views(sh),
        can_acknowledge=is_buyer and sh.status == ShipmentStatus.DELIVERED,
        can_report_issue=is_buyer and sh.status in [ShipmentStatus.DELIVERED, ShipmentStatus.COMPLETED],
        can_track=sh.status in trackable,
        can_message=(is_buyer or c.has_role(Role.DISPATCHER)) and sh.driver_id != "" and sh.status not in [ShipmentStatus.CANCELLED]
    );
}

def timeline_views(o: Order) -> list[TimelineEntryView] {
    rows = sorted([o ->:HasEvent:-> [?:TimelineEvent]], key=lambda (e: TimelineEvent) { e.at; });
    return [TimelineEntryView(at=e.at, kind=e.kind, title=e.title, detail=e.detail, actor_name=e.actor_name, actor_role=e.actor_role, shipment_id=e.shipment_id) for e in rows];
}

def detail_view(c: Caller, o: Order) -> OrderDetailView {
    role = c.account.role;
    is_buyer = role == Role.BUYER and o.buyer_id == c.account_id;
    ships = shipments_of_order(o);
    pre_loading = all(str(s.status) in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "CANCELLED"] for s in ships);
    claims = [claim_view(c, cl) for cl in [o ->:HasClaim:-> [?:Claim]]];
    return OrderDetailView(
        summary=summary_view(o, role), site_address=o.site_address, site_contact=o.site_contact,
        dest_lat=o.dest_lat, dest_lng=o.dest_lng, notes=o.notes,
        lines=[line_view(l) for l in lines_of(o)],
        shipments=[shipment_view(c, o, s) for s in ships],
        timeline=timeline_views(o),
        runs=[run_view(r) for r in runs_of(o)][:6],
        claims=claims,
        can_request_plan=is_buyer and o.status in [OrderStatus.DRAFT, OrderStatus.OPTIONS_READY, OrderStatus.NO_FEASIBLE_OPTION],
        can_confirm=is_buyer and o.status == OrderStatus.OPTIONS_READY,
        can_cancel=is_buyer and o.status not in [OrderStatus.CANCELLED, OrderStatus.COMPLETED, OrderStatus.DISPUTED, OrderStatus.DELIVERED] and pre_loading,
        viewer_role=str(role)
    );
}

# ------------------------------------------------------------------ endpoints
def:protect buyer_catalog -> BuyerCatalog {
    try {
        c = require_roles([Role.BUYER]);
        minerals: list[MineralOption] = [];
        plants = all_plants();
        for m in sorted(all_minerals(), key=lambda (x: any) { x.name; }) {
            grades = [GradeOption(code=g.code, name=g.name, description=g.description, params=g.params) for g in grades_of(m)];
            minerals.append(MineralOption(code=m.code, name=m.name, description=m.description, grades=grades, plant_count=len([p for p in plants if m.code in p.minerals])));
        }
        org = c.org;
        sites: list[SiteOption] = [];
        if org is not None {
            sites = [SiteOption(id=jid(s), name=s.name, address=s.address, lat=s.lat, lng=s.lng, contact_name=s.contact_name) for s in sites_of(org)];
        }
        cfg = settings();
        return BuyerCatalog(ok=True, minerals=minerals, sites=sites, currency=cfg.currency, max_load_t=cfg.max_load_t);
    } except AppError as e {
        return BuyerCatalog(ok=False, code=e.code, message=e.message);
    }
}

def:protect create_order(site_id: str, window_start: float, window_end: float, lines: list[OrderLineInput], notes: str = "") -> ActionResult {
    try {
        c = require_roles([Role.BUYER]);
        site = get_site(site_id);
        if site is None or site.org_id != c.account.org_id {
            raise invalid("Choose one of your organization's delivery sites.");
        }
        t = now();
        if window_start < t + 3600 {
            raise invalid("The delivery window must start at least one hour from now.");
        }
        if window_end - window_start < 2 * 3600 {
            raise invalid("The delivery window must be at least two hours long.");
        }
        if window_start > t + 14 * 86400 {
            raise invalid("Orders can be placed up to 14 days ahead.");
        }
        if not lines or len(lines) > 6 {
            raise invalid("Add between one and six loads.");
        }
        max_t = settings().max_load_t;
        resolved: list[list[SpecParam]] = [];
        for (i, ln) in enumerate(lines) {
            g = grade_by_code(ln.mineral_code, ln.grade_code);
            if g is None {
                raise invalid(f"Load {i + 1}: unknown mineral/grade.");
            }
            if ln.quantity_t <= 0 or ln.quantity_t > max_t {
                raise invalid(f"Load {i + 1}: quantity must be between 0 and {max_t} t (one truckload per load).");
            }
            problems = spec_problems(g, ln.spec_overrides);
            if problems {
                raise invalid(f"Load {i + 1}: " + " ".join(problems));
            }
            resolved.append(resolve_spec(g, ln.spec_overrides));
        }
        o = Order(
            ref=new_ref("ORD"), buyer_id=c.account_id, buyer_org_id=c.account.org_id,
            site_name=site.name, site_address=site.address, dest_lat=site.lat, dest_lng=site.lng,
            site_contact=site.contact_name, window_start=window_start, window_end=window_end,
            notes=clean_text(notes, 500), created_at=t, updated_at=t
        );
        get_hub() +>:HasOrder():+> o;
        for (i, ln) in enumerate(lines) {
            o +>:HasLine():+> OrderLine(order_id=jid(o), line_no=i + 1, mineral_code=ln.mineral_code, grade_code=ln.grade_code, quantity_t=round(ln.quantity_t, 3), spec=resolved[i]);
        }
        timeline(jid(o), "ORDER", "Order placed", " + ".join([str(ln.quantity_t) + " t " + ln.grade_code for ln in lines]), "", c);
        audit(c, "ORDER_CREATED", "Order", jid(o), o.ref + " to " + site.name);
        return ActionResult(ok=True, id=jid(o), message="Order " + o.ref + " created.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect my_orders(status_filter: str = "", poll: int = 0) -> OrderListResult {
    _ = poll;
    try {
        c = require_roles([Role.BUYER]);
        aid = c.account_id;
        rows = [o for o in [get_hub() ->:HasOrder:-> [?:Order, buyer_id == aid]]];
        rows = sorted(rows, key=lambda (o: Order) { -o.created_at; });
        out = [summary_view(o, Role.BUYER) for o in rows if not status_filter or str(o.status) == status_filter];
        return OrderListResult(ok=True, orders=out);
    } except AppError as e {
        return OrderListResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect order_detail(order_id: str, poll: int = 0) -> OrderDetailResult {
    _ = poll;
    try {
        c = current_caller();
        o = require_order_visible(c, order_id);
        return OrderDetailResult(ok=True, data=detail_view(c, o));
    } except AppError as e {
        return OrderDetailResult(ok=False, code=e.code, message=e.message);
    }
}

"""Run the Dispatch Planning Agent (or labelled fallback) for the buyer's order."""
def:protect request_recommendations(order_id: str) -> PlanResult {
    try {
        c = require_roles([Role.BUYER]);
        o = get_order(order_id);
        if o is None or o.buyer_id != c.account_id {
            raise not_found("Order");
        }
        if o.status not in [OrderStatus.DRAFT, OrderStatus.OPTIONS_READY, OrderStatus.NO_FEASIBLE_OPTION] {
            raise bad_state("Recommendations can only be requested before the order is reserved.");
        }
        assert_order(o.status, OrderStatus.PLANNING);
        ensure_all_slots(3);
        o.status = OrderStatus.PLANNING;
        w = o spawn PlanningWorkflow(requested_by=c.account_id);
        run = get_run(w.run_id);
        if run is None {
            raise RuntimeError("Planning run was not recorded.");
        }
        target = OrderStatus.OPTIONS_READY if str(run.status) == "SUCCEEDED" else OrderStatus.NO_FEASIBLE_OPTION;
        o.status = target;
        o.selected_run_id = jid(run);
        o.updated_at = now();
        mode = "AI agent" if str(run.mode) == "LLM" else "deterministic fallback";
        timeline(order_id, "PLAN", "Plant recommendations ready (" + mode + ")" if target == OrderStatus.OPTIONS_READY else "No feasible plant found (" + mode + ")", run.explanation[:300], "", c);
        audit(c, "PLANNING_RUN", "Order", order_id, o.ref + ": " + str(run.status) + " via " + str(run.mode) + ", " + str(len(run.tool_calls)) + " tool calls");
        return PlanResult(ok=True, order_status=str(target), run=run_view(run));
    } except AppError as e {
        return PlanResult(ok=False, code=e.code, message=e.message);
    }
}

"""Re-validate the buyer's chosen options and reserve stock + slots atomically."""
def:protect confirm_order_option(order_id: str, run_id: str, selections: list[LineSelection]) -> ActionResult {
    try {
        c = require_roles([Role.BUYER]);
        o = get_order(order_id);
        if o is None or o.buyer_id != c.account_id {
            raise not_found("Order");
        }
        if o.status != OrderStatus.OPTIONS_READY {
            raise bad_state("This order has no open recommendation to confirm.");
        }
        if run_id != o.selected_run_id {
            raise conflict("These recommendations are out of date; refresh the order.");
        }
        run = get_run(run_id);
        if run is None {
            raise not_found("Recommendation run");
        }
        lines = lines_of(o);
        chosen: dict[str, str] = {s.line_id: s.option_id for s in selections};
        plans: list[list[any]] = [];
        claimed: dict[str, float] = {};
        used: list[str] = [];
        problems: list[str] = [];
        moved: list[str] = [];
        for line in lines {
            lid = jid(line);
            if lid not in chosen {
                raise invalid("Choose an option for load " + str(line.line_no) + ".");
            }
            opt = None;
            for candidate in run.options {
                if candidate.line_id == lid and candidate.option_id == chosen[lid] {
                    opt = candidate;
                }
            }
            if opt is None {
                raise invalid("Unknown option for load " + str(line.line_no) + ".");
            }
            lot = get_lot(opt.lot_id);
            found = lot_problems(line, lot, claimed);
            plant = get_plant(lot.plant_id) if lot is not None else None;
            if found or lot is None or plant is None {
                problems = problems + ["Load " + str(line.line_no) + ": " + p for p in (found or ["Plant no longer exists."])];
                continue;
            }
            slot = get_slot(opt.slot_id);
            slot_issues = reservation_problems(o, line, lot, slot, claimed, used);
            if slot_issues {
                alt = next_free_slot(o, line, plant, used);
                if alt is None {
                    problems = problems + ["Load " + str(line.line_no) + ": " + p for p in slot_issues];
                    continue;
                }
                slot = alt;
                moved.append("Load " + str(line.line_no) + " moved to the next free slot " + fmt_time(alt.start_ts));
            }
            claimed[jid(lot)] = claimed.get(jid(lot), 0.0) + line.quantity_t;
            used.append(jid(slot));
            plans.append([line, lot, slot]);
        }
        if problems {
            raise conflict("Stock or plant availability changed since the recommendation, so nothing was reserved. " + " ".join(problems) + " Request new recommendations.");
        }
        assert_order(o.status, OrderStatus.RESERVED);
        for plan in plans {
            sh = reserve_line(o, plan[0], plan[1], plan[2]);
            timeline(order_id, "RESERVED", "Reserved " + str(sh.quantity_t) + " t at " + name_of_plant(sh.plant_id) + " (lot " + plan[1].code + ")", "Loading slot held for " + sh.ref, jid(sh), c);
            notify_dispatchers(sh.plant_id, "info", "New reserved load " + sh.ref, o.ref + " - assign driver, truck and loader.", "/dispatch/orders/" + order_id);
            notify_plant_managers(sh.plant_id, "info", "Stock reserved: " + plan[1].code, str(sh.quantity_t) + " t for " + o.ref);
        }
        o.status = OrderStatus.RESERVED;
        o.updated_at = now();
        audit(c, "ORDER_CONFIRMED", "Order", order_id, o.ref + " reserved from run " + run_id, "", o.plant_ids);
        note = (" " + "; ".join(moved) + ".") if moved else "";
        return ActionResult(ok=True, id=order_id, message="Stock and loading slots reserved. A dispatcher will assign the truck." + note);
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect cancel_order(order_id: str, reason: str) -> ActionResult {
    try {
        c = require_roles([Role.BUYER]);
        o = get_order(order_id);
        if o is None or o.buyer_id != c.account_id {
            raise not_found("Order");
        }
        why = clean_text(reason, 300);
        if len(why) < 3 {
            raise invalid("Give a short reason for cancelling.");
        }
        ships = shipments_of_order(o);
        for sh in ships {
            if str(sh.status) not in ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "CANCELLED"] {
                raise bad_state("Loads that are already at the plant or later cannot be cancelled here; contact dispatch.");
            }
        }
        assert_order(o.status, OrderStatus.CANCELLED);
        for sh in ships {
            if sh.status == ShipmentStatus.CANCELLED {
                continue;
            }
            res = get_reservation(sh.reservation_id);
            if res is not None {
                release_reservation(res, "Order cancelled by buyer");
            }
            free_slot_of(sh);
            for off in offers_of(sh) {
                if off.status == OfferStatus.OFFERED {
                    off.status = OfferStatus.WITHDRAWN;
                    notify(off.driver_id, "warning", "Offer withdrawn", sh.ref + " was cancelled by the buyer.");
                }
            }
            truck = get_truck(sh.truck_id);
            if truck is not None and truck.status == TruckStatus.IN_USE {
                truck.status = TruckStatus.AVAILABLE;
            }
            if sh.driver_id {
                notify(sh.driver_id, "warning", "Job cancelled", sh.ref + " was cancelled by the buyer.");
            }
            if sh.loader_id {
                notify(sh.loader_id, "warning", "Loading job cancelled", sh.ref + " was cancelled.");
            }
            notify_dispatchers(sh.plant_id, "warning", "Order cancelled: " + o.ref, why);
            sh.status = ShipmentStatus.CANCELLED;
            sh.updated_at = now();
        }
        o.status = OrderStatus.CANCELLED;
        o.updated_at = now();
        timeline(order_id, "CANCELLED", "Order cancelled", why, "", c);
        audit(c, "ORDER_CANCELLED", "Order", order_id, o.ref, why, o.plant_ids);
        return ActionResult(ok=True, id=order_id, message="Order cancelled; reservations released.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def _buyer_shipment(c: Caller, shipment_id: str) -> tuple[Order, Shipment] {
    sh = get_shipment(shipment_id);
    o = get_order(sh.order_id) if sh is not None else None;
    if sh is None or o is None or o.buyer_id != c.account_id {
        raise not_found("Delivery");
    }
    return (o, sh);
}

"""Buyer confirms receipt in-app (an alternative to the driver's handover PIN)."""
def:protect acknowledge_delivery(shipment_id: str, received_qty_t: float, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.BUYER]);
        (o, sh) = _buyer_shipment(c, shipment_id);
        if sh.status != ShipmentStatus.DELIVERED {
            raise bad_state("Only a delivered load awaiting acknowledgement can be confirmed.");
        }
        if count_of_kind(sh, EvidenceKind.UNLOADING_PHOTO) == 0 or sh.handover_recorded_at <= 0 {
            raise bad_state("Proof of delivery is incomplete; the driver has not recorded the handover yet.");
        }
        if received_qty_t <= 0 {
            raise invalid("Enter the quantity you received.");
        }
        ref_qty = sh.loaded_qty_t if sh.loaded_qty_t > 0 else sh.quantity_t;
        if abs(received_qty_t - ref_qty) > ref_qty * 0.02 {
            raise AppError(code="MISMATCH", message=f"Received {received_qty_t} t differs from the loaded {ref_qty} t by more than 2 %. Report a quantity issue instead of acknowledging.");
        }
        assert_shipment(sh.status, ShipmentStatus.COMPLETED);
        sh.status = ShipmentStatus.COMPLETED;
        sh.ack_method = AckMethod.IN_APP;
        sh.acknowledged_at = now();
        sh.received_qty_t = round(received_qty_t, 3);
        sh.completed_at = now();
        sh.updated_at = now();
        on_completed(sh);
        refresh_order_status(o);
        timeline(jid(o), "ACKNOWLEDGED", "Receipt acknowledged in-app: " + str(received_qty_t) + " t", clean_text(note, 300), shipment_id, c);
        if sh.driver_id {
            notify(sh.driver_id, "success", "Buyer acknowledged " + sh.ref, "Delivery completed.");
        }
        audit(c, "DELIVERY_ACKNOWLEDGED", "Shipment", shipment_id, sh.ref + " received " + str(received_qty_t) + " t", "", [sh.plant_id]);
        return ActionResult(ok=True, id=shipment_id, message="Delivery acknowledged - thank you.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect report_issue(shipment_id: str, claim_type: str, description: str, received_qty_t: float = 0.0) -> ActionResult {
    try {
        c = require_roles([Role.BUYER]);
        (o, sh) = _buyer_shipment(c, shipment_id);
        if sh.status not in [ShipmentStatus.DELIVERED, ShipmentStatus.COMPLETED, ShipmentStatus.DISPUTED] {
            raise bad_state("Issues can be reported once the load has been delivered.");
        }
        try {
            ct = ClaimType(claim_type);
        } except ValueError {
            raise invalid("Choose the type of issue.");
        }
        text = clean_text(description, 1500);
        if len(text) < 10 {
            raise invalid("Describe the issue in at least a sentence.");
        }
        if ct == ClaimType.QUANTITY and received_qty_t <= 0 {
            raise invalid("Enter the quantity you actually received.");
        }
        cl = open_claim(c, o, sh, ct, text, round(received_qty_t, 3));
        if sh.status == ShipmentStatus.DELIVERED {
            assert_shipment(sh.status, ShipmentStatus.DISPUTED);
            sh.status = ShipmentStatus.DISPUTED;
            if received_qty_t > 0 {
                sh.received_qty_t = round(received_qty_t, 3);
            }
            sh.updated_at = now();
        }
        refresh_order_status(o);
        if o.status != OrderStatus.DISPUTED and sh.status == ShipmentStatus.COMPLETED {
            o.status = OrderStatus.DISPUTED;
        }
        return ActionResult(ok=True, id=jid(cl), message="Claim " + cl.ref + " opened. Dispatch and the plant have been notified.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
