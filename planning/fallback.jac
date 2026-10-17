"""Deterministic fallback planners (used when no LLM is configured or the LLM
call fails). They call the *same* traced tools in a fixed order and rank by a
fixed score; runs produced here are stored and labelled DETERMINISTIC_FALLBACK,
never presented as an LLM agent run.
"""

import from core.model { OrderLine, Shipment, PlanOption }
import from planning.tools {
    list_candidate_plants, evaluate_plant_feasibility, list_eligible_drivers,
    list_eligible_trucks, list_eligible_loaders, get_exception_context
}
import from planning.metrics { option_score }
import from planning.agent {
    SupplyPlanDraft, LinePlanDraft, OptionDraft, AssignmentPlanDraft, AssignmentDraft,
    RecoveryDraft, RecoveryOptionDraft, RecoveryAction
}

def fallback_supply_plan(lines: list[OrderLine]) -> SupplyPlanDraft {
    plan = SupplyPlanDraft(summary="Deterministic fallback: every candidate plant was checked with the feasibility tools and feasible options were ranked by cost per tonne plus wait/travel penalties (no LLM involved).");
    for line in lines {
        lid = jid(line);
        feasible: list[PlanOption] = [];
        reasons: list[str] = [];
        for c in list_candidate_plants(lid) {
            rep = evaluate_plant_feasibility(c.plant_id, lid);
            if rep.feasible and rep.option is not None {
                feasible.append(rep.option);
            } else {
                reasons.append(c.name + ": " + "; ".join(rep.reasons[:2]));
            }
        }
        ranked = sorted(feasible, key=lambda (o: PlanOption) { option_score(o); });
        drafts = [
            OptionDraft(plant_id=o.plant_id, lot_id=o.lot_id, slot_id=o.slot_id, rationale=f"Score {option_score(o)}: total {o.total_cost:,.0f}, wait ~{o.wait_minutes:.0f} min, travel ~{o.travel_minutes:.0f} min, lot {o.lot_quality.lower()}.")
            for o in ranked[:3]
        ];
        note = "" if drafts else "No feasible plant. " + " | ".join(reasons[:4]);
        plan.lines.append(LinePlanDraft(line_id=lid, ranked_options=drafts, note=note));
    }
    return plan;
}

def fallback_assignment_plan(shipments: list[Shipment]) -> AssignmentPlanDraft {
    plan = AssignmentPlanDraft(summary="Deterministic fallback: first eligible driver by distance, smallest eligible truck that fits the load, first loader on shift (no LLM involved).");
    used_drivers: list[str] = [];
    used_trucks: list[str] = [];
    for sh in shipments {
        sid = jid(sh);
        driver = "";
        truck = "";
        loader = "";
        for d in list_eligible_drivers(sid) {
            if d.eligible and d.driver_id not in used_drivers {
                driver = d.driver_id;
                break;
            }
        }
        for t in list_eligible_trucks(sid) {
            if t.eligible and t.truck_id not in used_trucks {
                truck = t.truck_id;
                break;
            }
        }
        for l in list_eligible_loaders(sid) {
            if l.eligible {
                loader = l.loader_id;
                break;
            }
        }
        if driver {
            used_drivers.append(driver);
        }
        if truck {
            used_trucks.append(truck);
        }
        plan.assignments.append(AssignmentDraft(shipment_id=sid, driver_id=driver, truck_id=truck, loader_id=loader, rationale="Eligibility-first deterministic selection."));
    }
    return plan;
}

def fallback_recovery_plan(exception_id: str, line: OrderLine | None, needs_driver: bool) -> RecoveryDraft {
    ctx = get_exception_context(exception_id);
    draft = RecoveryDraft(what_changed=ctx.ex_type + ": " + ctx.summary, recommendation="Deterministic fallback ranking (no LLM involved).");
    if needs_driver and ctx.shipment_id {
        drivers = [d for d in list_eligible_drivers(ctx.shipment_id) if d.eligible and d.driver_id != ctx.driver_id];
        trucks = [t for t in list_eligible_trucks(ctx.shipment_id) if t.eligible];
        if drivers and trucks {
            draft.options.append(RecoveryOptionDraft(action=RecoveryAction.REASSIGN_DRIVER, driver_id=drivers[0].driver_id, truck_id=trucks[0].truck_id, rationale="Nearest eligible driver with a suitable truck."));
        } else {
            draft.no_feasible_reason = "No eligible replacement driver and truck are currently available.";
        }
        return draft;
    }
    if line is None {
        draft.no_feasible_reason = "The exception is not linked to a shipment that can be re-planned.";
        return draft;
    }
    lid = jid(line);
    feasible: list[PlanOption] = [];
    for c in list_candidate_plants(lid) {
        rep = evaluate_plant_feasibility(c.plant_id, lid);
        if rep.feasible and rep.option is not None {
            feasible.append(rep.option);
        }
    }
    ranked = sorted(feasible, key=lambda (o: PlanOption) { option_score(o); });
    for o in ranked[:3] {
        action = RecoveryAction.SWITCH_SLOT if o.plant_id == ctx.current_plant_id and o.lot_id == ctx.current_lot_id else (RecoveryAction.SWITCH_LOT if o.plant_id == ctx.current_plant_id else RecoveryAction.SWITCH_PLANT);
        draft.options.append(RecoveryOptionDraft(action=action, plant_id=o.plant_id, lot_id=o.lot_id, slot_id=o.slot_id, rationale=f"Feasible: {o.plant_name}, wait ~{o.wait_minutes:.0f} min, arrives before window end, total {o.total_cost:,.0f}."));
    }
    if not draft.options {
        draft.no_feasible_reason = "No plant can currently supply this line inside the delivery window.";
    }
    return draft;
}
