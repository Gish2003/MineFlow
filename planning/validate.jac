"""Deterministic validation of agent (or fallback) drafts.

Nothing proposed by a model is trusted: ids must exist and belong together,
grade/stock/slot/window gates are re-run, and every displayed metric is
recomputed. Invalid proposals are kept as `RejectedOption`s with reasons so the
run history shows exactly what was refused and why.
"""

import from core.model { Order, OrderLine, PlanOption, RejectedOption, ActionOption, Shipment }
import from core.enums { PlantStatus, ReservationStatus }
import from core.hub { get_plant, get_lot, get_slot, get_shipment, get_line, get_order, get_reservation, mineral_by_code }
import from catalog.grades { check_lot_for_line }
import from inventory.availability { availability }
import from scheduling.slots { estimate_wait, slot_problems, LoadingEstimate }
import from planning.metrics { build_option, option_score, ideal_slot_start, latest_slot_start }
import from planning.tools { driver_candidates, truck_candidates, loader_candidates }
import from planning.agent { SupplyPlanDraft, AssignmentPlanDraft, RecoveryDraft, RecoveryAction }

obj SupplyValidation {
    has options: list[PlanOption] = [],
        rejected: list[RejectedOption] = [],
        infeasible_lines: list[str] = [];
}

obj ActionValidation {
    has actions: list[ActionOption] = [],
        rejected: list[RejectedOption] = [];
}

def _option_for(order: Order, line: OrderLine, plant_id: str, lot_id: str, slot_id: str, source: str, rationale: str, idx: int, rejected: list[RejectedOption], credit_lot_id: str = "", credit_t: float = 0.0) -> PlanOption | None {
    reasons: list[str] = [];
    p = get_plant(plant_id);
    lot = get_lot(lot_id);
    if p is None {
        reasons.append("Unknown plant id.");
    }
    if lot is None {
        reasons.append("Unknown lot id.");
    }
    if p is not None and lot is not None and lot.plant_id != plant_id {
        reasons.append("Lot does not belong to that plant.");
    }
    if p is not None and p.status == PlantStatus.UNAVAILABLE {
        reasons.append("Plant is unavailable.");
    }
    if reasons or p is None or lot is None {
        rejected.append(RejectedOption(line_id=jid(line), plant_id=plant_id, lot_id=lot_id, reasons=reasons, source=source));
        return None;
    }
    grade = check_lot_for_line(lot, line);
    if not grade.compatible {
        reasons = reasons + grade.reasons;
    }
    credit = credit_t if lot_id == credit_lot_id else 0.0;
    if availability(lot).available_t + credit + 1e-9 < line.quantity_t {
        reasons.append("Not enough available stock in the lot.");
    }
    est: LoadingEstimate | None = None;
    slot = get_slot(slot_id);
    note = "";
    if slot is not None and slot.plant_id == plant_id and not slot_problems(p, slot) {
        est = LoadingEstimate(plant_id=plant_id, found=True, slot_id=slot_id, slot_start=slot.start_ts, slot_end=slot.end_ts, bay=slot.bay, wait_minutes=float(p.readiness_buffer_min), loading_minutes=0.0);
    } else {
        fixed = estimate_wait(p, ideal_slot_start(order, p, line.quantity_t), line.quantity_t, latest_slot_start(order, p, line.quantity_t));
        if fixed.found {
            est = fixed;
            note = " (validator replaced an unusable proposed slot with the earliest serviceable slot)";
        } else {
            reasons.append("No serviceable loading slot can meet the window.");
        }
    }
    if reasons or est is None {
        rejected.append(RejectedOption(line_id=jid(line), plant_id=plant_id, lot_id=lot_id, reasons=reasons, source=source));
        return None;
    }
    opt = build_option(str(line.line_no) + "-" + str(idx), idx, order, line, p, lot, est, rationale + note);
    if not opt.within_window {
        rejected.append(RejectedOption(line_id=jid(line), plant_id=plant_id, lot_id=lot_id, reasons=["Estimated arrival is after the delivery window."], source=source));
        return None;
    }
    opt.score = option_score(opt);
    return opt;
}

def validate_supply_plan(order: Order, lines: list[OrderLine], draft: SupplyPlanDraft, source: str) -> SupplyValidation {
    out = SupplyValidation();
    known = [jid(l) for l in lines];
    for lp in draft.lines {
        if lp.line_id not in known {
            out.rejected.append(RejectedOption(line_id=lp.line_id, plant_id="", lot_id="", reasons=["Draft referenced a line that is not on this order."], source=source));
        }
    }
    for line in lines {
        lid = jid(line);
        idx = 0;
        seen: list[str] = [];
        for lp in draft.lines {
            if lp.line_id != lid {
                continue;
            }
            for od in lp.ranked_options[:4] {
                key = od.plant_id + "/" + od.lot_id;
                if key in seen {
                    continue;
                }
                seen.append(key);
                opt = _option_for(order, line, od.plant_id, od.lot_id, od.slot_id, source, od.rationale, idx + 1, out.rejected);
                if opt is not None {
                    idx += 1;
                    out.options.append(opt);
                }
                if idx >= 3 {
                    break;
                }
            }
        }
        if idx == 0 {
            out.infeasible_lines.append(lid);
        }
    }
    return out;
}

def validate_assignments(shipments: list[Shipment], draft: AssignmentPlanDraft, source: str) -> ActionValidation {
    out = ActionValidation();
    ids = [jid(s) for s in shipments];
    used_drivers: list[str] = [];
    used_trucks: list[str] = [];
    rank = 0;
    for a in draft.assignments {
        if a.shipment_id not in ids {
            out.rejected.append(RejectedOption(line_id="", plant_id="", lot_id="", reasons=["Assignment for a shipment not in this run."], source=source));
            continue;
        }
        sh = get_shipment(a.shipment_id);
        if sh is None {
            continue;
        }
        lot = get_lot(sh.lot_id);
        m = mineral_by_code(lot.mineral_code) if lot is not None else None;
        reasons: list[str] = [];
        drivers = {d.driver_id: d for d in driver_candidates(sh)};
        trucks = {t.truck_id: t for t in truck_candidates(sh, m.allowed_bodies if m is not None else [])};
        loaders = {l.loader_id: l for l in loader_candidates(sh)};
        if a.driver_id not in drivers or not drivers[a.driver_id].eligible {
            reasons.append("Driver is not eligible: " + ("; ".join(drivers[a.driver_id].reasons) if a.driver_id in drivers else "unknown id"));
        }
        if a.truck_id not in trucks or not trucks[a.truck_id].eligible {
            reasons.append("Truck is not eligible: " + ("; ".join(trucks[a.truck_id].reasons) if a.truck_id in trucks else "unknown id"));
        }
        if a.loader_id and (a.loader_id not in loaders or not loaders[a.loader_id].eligible) {
            reasons.append("Loader is not eligible for that slot.");
        }
        if a.driver_id in used_drivers or a.truck_id in used_trucks {
            reasons.append("Driver or truck already used by another shipment in this plan.");
        }
        if reasons {
            out.rejected.append(RejectedOption(line_id=sh.line_id, plant_id=sh.plant_id, lot_id=sh.lot_id, reasons=reasons, source=source));
            continue;
        }
        used_drivers.append(a.driver_id);
        used_trucks.append(a.truck_id);
        rank += 1;
        d = drivers[a.driver_id];
        t = trucks[a.truck_id];
        out.actions.append(ActionOption(
            option_id="A" + str(rank), rank=rank, action="ASSIGN", shipment_id=a.shipment_id,
            driver_id=a.driver_id, truck_id=a.truck_id, loader_id=a.loader_id,
            summary=sh.ref + ": " + d.name + " with " + t.plate + (" + loader " + loaders[a.loader_id].name if a.loader_id in loaders else ""),
            rationale=a.rationale, metrics={"km_to_plant": d.km_to_plant, "truck_payload_t": t.payload_t}
        ));
    }
    return out;
}

def validate_recovery(sh: Shipment, draft: RecoveryDraft, source: str) -> ActionValidation {
    out = ActionValidation();
    line = get_line(sh.line_id);
    order = get_order(sh.order_id);
    lot = get_lot(sh.lot_id);
    m = mineral_by_code(lot.mineral_code) if lot is not None else None;
    bodies = m.allowed_bodies if m is not None else [];
    held = get_reservation(sh.reservation_id);
    credit = held.quantity_t if held is not None and held.status == ReservationStatus.HELD else 0.0;
    rank = 0;
    for od in draft.options[:4] {
        if od.action == RecoveryAction.REASSIGN_DRIVER {
            drivers = {d.driver_id: d for d in driver_candidates(sh)};
            trucks = {t.truck_id: t for t in truck_candidates(sh, bodies)};
            reasons: list[str] = [];
            if od.driver_id not in drivers or not drivers[od.driver_id].eligible or od.driver_id == sh.driver_id {
                reasons.append("Replacement driver is not eligible.");
            }
            if od.truck_id not in trucks or not trucks[od.truck_id].eligible {
                reasons.append("Replacement truck is not eligible.");
            }
            if reasons {
                out.rejected.append(RejectedOption(line_id=sh.line_id, plant_id=sh.plant_id, lot_id=sh.lot_id, reasons=reasons, source=source));
                continue;
            }
            rank += 1;
            out.actions.append(ActionOption(
                option_id="R" + str(rank), rank=rank, action=str(od.action), shipment_id=jid(sh),
                driver_id=od.driver_id, truck_id=od.truck_id,
                summary="Offer to " + drivers[od.driver_id].name + " with " + trucks[od.truck_id].plate,
                rationale=od.rationale, metrics={"km_to_plant": drivers[od.driver_id].km_to_plant}
            ));
            continue;
        }
        if line is None or order is None {
            continue;
        }
        opt = _option_for(order, line, od.plant_id, od.lot_id, od.slot_id, source, od.rationale, rank + 1, out.rejected, sh.lot_id, credit);
        if opt is None {
            continue;
        }
        rank += 1;
        out.actions.append(ActionOption(
            option_id="R" + str(rank), rank=rank, action=str(od.action), shipment_id=jid(sh),
            plant_id=opt.plant_id, lot_id=opt.lot_id, slot_id=opt.slot_id,
            summary=opt.plant_name + " · lot " + opt.lot_code,
            rationale=opt.rationale,
            metrics={"wait_minutes": opt.wait_minutes, "travel_minutes": opt.travel_minutes, "eta_ts": opt.eta_ts, "total_cost": opt.total_cost, "slot_start": opt.slot_start}
        ));
    }
    return out;
}
