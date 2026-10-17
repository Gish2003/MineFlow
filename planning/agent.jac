"""LLM agents (byLLM tool calling) for supply planning, assignment planning and
exception recovery.

The model decides which plants, lots, slots, drivers and trucks to investigate
by calling the read-only tools in `planning.tools`, inspects their results and
returns a typed draft holding ids + rationale only. Every number shown to users
is recomputed deterministically in `planning.validate`; nothing an agent returns
is applied without validation and, for dispatch changes, dispatcher approval.
"""

import from jaclang.byllm.lib { Model }
import from jaclang.byllm.types { IterationAction, IterationContext }
import from planning.tools {
    list_candidate_plants, get_plant_inventory, check_grade_compatibility,
    estimate_loading_wait, estimate_delivery_eta, evaluate_plant_feasibility,
    compare_dispatch_options, list_eligible_drivers, list_eligible_trucks,
    list_eligible_loaders, find_open_slots, get_exception_context
}

obj LineBrief {
    has line_id: str,
        mineral_code: str,
        mineral_name: str,
        grade_code: str,
        grade_name: str,
        quantity_t: float,
        spec: str;
}
sem LineBrief.spec = "Grade specification the delivered lot must meet, parameter by parameter.";

obj OrderBrief {
    has order_ref: str,
        destination: str,
        window_start: str,
        window_end: str,
        lines: list[LineBrief],
        buyer_notes: str = "";
}
sem OrderBrief = "A buyer's mineral order: one truckload per line, delivered to one site inside a delivery window.";

obj OptionDraft {
    has plant_id: str,
        lot_id: str,
        slot_id: str,
        rationale: str;
}
sem OptionDraft.plant_id = "Plant id exactly as returned by a tool.";
sem OptionDraft.lot_id = "Stock lot id exactly as returned by get_plant_inventory or evaluate_plant_feasibility.";
sem OptionDraft.slot_id = "Loading slot id exactly as returned by estimate_loading_wait, find_open_slots or evaluate_plant_feasibility.";
sem OptionDraft.rationale = "One or two sentences citing the tool evidence (grade fit, available tonnes, wait, ETA vs window, cost) and the trade-off versus other options.";

obj LinePlanDraft {
    has line_id: str,
        ranked_options: list[OptionDraft] = [],
        note: str = "";
}
sem LinePlanDraft.ranked_options = "Up to 3 feasible options, best first. Empty when no feasible option exists.";
sem LinePlanDraft.note = "If no option is feasible, say why based on tool results.";

obj SupplyPlanDraft {
    has lines: list[LinePlanDraft] = [],
        summary: str = "";
}
sem SupplyPlanDraft.summary = "Short explanation for the buyer and dispatcher of how the options were chosen.";

obj ShipmentBrief {
    has shipment_id: str,
        ref: str,
        plant_name: str,
        mineral_code: str,
        grade_code: str,
        quantity_t: float,
        slot_start: str,
        destination: str,
        window: str;
}

obj AssignmentBrief {
    has order_ref: str,
        shipments: list[ShipmentBrief];
}

obj AssignmentDraft {
    has shipment_id: str,
        driver_id: str,
        truck_id: str,
        loader_id: str,
        rationale: str;
}
sem AssignmentDraft.rationale = "Why this driver/truck/loader combination: eligibility, payload and body suitability, shift coverage, distance as a secondary factor.";

obj AssignmentPlanDraft {
    has assignments: list[AssignmentDraft] = [],
        summary: str = "";
}

enum RecoveryAction: str {
    SWITCH_PLANT = "SWITCH_PLANT",
    SWITCH_SLOT = "SWITCH_SLOT",
    SWITCH_LOT = "SWITCH_LOT",
    REASSIGN_DRIVER = "REASSIGN_DRIVER"
}
sem RecoveryAction.SWITCH_PLANT = "Supply the shipment from another plant (new lot and slot there).";
sem RecoveryAction.SWITCH_SLOT = "Keep plant and lot, move to another loading slot.";
sem RecoveryAction.SWITCH_LOT = "Keep plant, use a different compatible lot (and a valid slot).";
sem RecoveryAction.REASSIGN_DRIVER = "Keep supply, offer the shipment to another eligible driver and truck.";

obj ExceptionBrief {
    has exception_id: str,
        ex_type: str,
        summary: str,
        shipment_id: str,
        line_id: str;
}

obj RecoveryOptionDraft {
    has action: RecoveryAction,
        rationale: str,
        plant_id: str = "",
        lot_id: str = "",
        slot_id: str = "",
        driver_id: str = "",
        truck_id: str = "";
}
sem RecoveryOptionDraft.rationale = "Why this alternative is preferred, citing tool evidence.";

obj RecoveryDraft {
    has what_changed: str,
        options: list[RecoveryOptionDraft] = [],
        recommendation: str = "",
        no_feasible_reason: str = "";
}
sem RecoveryDraft.what_changed = "What changed operationally and why the current plan no longer works.";
sem RecoveryDraft.options = "Up to 3 feasible alternatives, best first. Empty if none is feasible.";
sem RecoveryDraft.no_feasible_reason = "When no alternative is feasible, explain why from the tool results.";

glob PLANNER_PROMPT: str = (
    "You are MineFlow's Dispatch Planning Agent for industrial mineral deliveries. "
    + "For EVERY line in the brief: call list_candidate_plants, then investigate plants with tools "
    + "(get_plant_inventory, check_grade_compatibility, estimate_loading_wait, estimate_delivery_eta, "
    + "evaluate_plant_feasibility, compare_dispatch_options). Never invent ids or numbers - use only ids returned by tools. "
    + "Grade integrity is strict: one lot per load, same grade code, every spec parameter met, no blends, no quality-hold lots. "
    + "Prefer verified lots, arrival inside the window, lower total cost and shorter wait; explain trade-offs. "
    + "Return up to 3 ranked feasible options per line, or an empty list with a reason when nothing is feasible."
);

glob ASSIGNMENT_PROMPT: str = (
    "You are MineFlow's Dispatch Planning Agent proposing driver, truck and loader assignments for reserved shipments. "
    + "For each shipment call list_eligible_drivers, list_eligible_trucks and list_eligible_loaders and choose only eligible ones. "
    + "Never assign one driver or truck to two shipments. Distance is a secondary factor; eligibility, payload, body type and shift coverage come first. "
    + "Use only ids returned by tools. Leave a field empty if nothing eligible exists and say so in the rationale."
);

glob RECOVERY_PROMPT: str = (
    "You are MineFlow's Exception Recovery Agent. Start with get_exception_context. Then gather UPDATED evidence with the tools "
    + "and re-evaluate feasible alternatives (another slot, another compatible lot, another plant, or another driver/truck). "
    + "Explain what changed and why your preferred alternative is better. Use only ids returned by tools. "
    + "If nothing is feasible, return no options and explain why. A dispatcher must approve any change."
);

def make_model(model_name: str) -> Model {
    return Model(model_name=model_name);
}

def budget_guard(ctx: IterationContext) -> IterationAction {
    if ctx.iteration > 18 {
        return IterationAction.ABORT_WITH_SUMMARY;
    }
    return IterationAction.CONTINUE;
}

def run_supply_agent(model: any, brief: OrderBrief, transcript: list[dict[str, any]]) -> SupplyPlanDraft {
    llm = model;
    def plan_supply(brief: OrderBrief) -> SupplyPlanDraft by llm(
        tools=[
            list_candidate_plants, get_plant_inventory, check_grade_compatibility,
            estimate_loading_wait, estimate_delivery_eta, evaluate_plant_feasibility,
            compare_dispatch_options
        ],
        conversation=transcript,
        system_prompt=PLANNER_PROMPT,
        max_react_iterations=16,
        on_iteration=budget_guard
    );
    return plan_supply(brief);
}

def run_assignment_agent(model: any, brief: AssignmentBrief, transcript: list[dict[str, any]]) -> AssignmentPlanDraft {
    llm = model;
    def plan_assignments(brief: AssignmentBrief) -> AssignmentPlanDraft by llm(
        tools=[list_eligible_drivers, list_eligible_trucks, list_eligible_loaders],
        conversation=transcript,
        system_prompt=ASSIGNMENT_PROMPT,
        max_react_iterations=12,
        on_iteration=budget_guard
    );
    return plan_assignments(brief);
}

def run_recovery_agent(model: any, brief: ExceptionBrief, transcript: list[dict[str, any]]) -> RecoveryDraft {
    llm = model;
    def plan_recovery(brief: ExceptionBrief) -> RecoveryDraft by llm(
        tools=[
            get_exception_context, list_candidate_plants, get_plant_inventory,
            check_grade_compatibility, find_open_slots, estimate_loading_wait,
            estimate_delivery_eta, evaluate_plant_feasibility, compare_dispatch_options,
            list_eligible_drivers, list_eligible_trucks
        ],
        conversation=transcript,
        system_prompt=RECOVERY_PROMPT,
        max_react_iterations=18,
        on_iteration=budget_guard
    );
    return plan_recovery(brief);
}
