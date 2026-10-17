"""Planning/recovery orchestration and run history.

`PlanningWorkflow` walks Order -> OrderLines, then (at the Order exit) runs the
supply planning agent, validates its draft deterministically and persists an
`AgentRun` under the order. Assignment planning and exception recovery follow
the same shape. If the LLM call fails, the failed run is stored *as failed*
and a separate, labelled deterministic fallback run is produced.
"""

import from core.model {
    DomainNode, Order, OrderLine, HasLine, Shipment, ExceptionCase, AgentRun, HasRun, ToolCallLog,
    PlanOption, ActionOption, RejectedOption
}
import from core.enums { AgentKind, AgentMode, AgentRunStatus, ExceptionType }
import from core.config { settings, llm_available }
import from core.util { now, clip, fmt_time }
import from core.hub {
    get_plant, get_line, get_order, get_shipment, get_slot, mineral_by_code,
    grade_by_code, all_plants, name_of_plant
}
import from catalog.grades { describe_param }
import from planning.recorder { begin_run, end_run, RunRecorder }
import from planning.agent {
    run_supply_agent, run_assignment_agent, run_recovery_agent, make_model,
    OrderBrief, LineBrief, AssignmentBrief, ShipmentBrief, ExceptionBrief
}
import from planning.fallback { fallback_supply_plan, fallback_assignment_plan, fallback_recovery_plan }
import from planning.validate { validate_supply_plan, validate_assignments, validate_recovery, SupplyValidation, ActionValidation }

glob _model_override: any = None;

obj AgentRunView {
    has id: str,
        kind: str,
        mode: str,
        mode_label: str,
        model: str,
        status: str,
        started_at: float,
        ended_at: float,
        tool_calls: list[ToolCallLog] = [],
        transcript: list[dict[str, str]] = [],
        options: list[PlanOption] = [],
        actions: list[ActionOption] = [],
        rejected: list[RejectedOption] = [],
        explanation: str = "",
        what_changed: str = "",
        error: str = "",
        applied_option_id: str = "";
}

"""Tests inject a MockLLM here; production uses the configured provider."""
def set_model_override(m: any) {
    _model_override = m;
}

def agent_model -> any {
    if _model_override is not None {
        return _model_override;
    }
    if llm_available() {
        return make_model(settings().llm_model);
    }
    return None;
}

def model_name_of(m: any) -> str {
    name = getattr(m, "model_name", "");
    return str(name) if name else "llm";
}

def mode_label(r: AgentRun) -> str {
    if r.mode == AgentMode.LLM {
        return "LLM agent · " + r.model;
    }
    return "Deterministic fallback (no LLM)";
}

def run_view(r: AgentRun) -> AgentRunView {
    return AgentRunView(
        id=jid(r), kind=str(r.kind), mode=str(r.mode), mode_label=mode_label(r), model=r.model,
        status=str(r.status), started_at=r.started_at, ended_at=r.ended_at, tool_calls=r.tool_calls,
        transcript=r.transcript, options=r.options, actions=r.actions, rejected=r.rejected,
        explanation=r.explanation, what_changed=r.what_changed, error=r.error,
        applied_option_id=r.applied_option_id
    );
}

def _text(content: any) -> str {
    if isinstance(content, str) {
        return content;
    }
    if isinstance(content, list) {
        parts: list[str] = [];
        for b in content {
            if isinstance(b, dict) and "text" in b {
                parts.append(str(b["text"]));
            }
        }
        return " ".join(parts);
    }
    return "" if content is None else str(content);
}

"""Display-safe copy of the byLLM conversation: roles, text, tool names and arguments."""
def sanitize_transcript(history: list[dict[str, any]]) -> list[dict[str, str]] {
    out: list[dict[str, str]] = [];
    for m in history {
        role = str(m.get("role", ""));
        row: dict[str, str] = {"role": role, "content": clip(_text(m.get("content", "")), 1500), "tool": "", "args": ""};
        if role == "tool" {
            row["tool"] = str(m.get("name", ""));
        }
        calls = m.get("tool_calls") or [];
        names: list[str] = [];
        args: list[str] = [];
        for tc in calls {
            fn = getattr(tc, "function", None);
            if fn is None and isinstance(tc, dict) {
                fn = tc.get("function");
            }
            if fn is None {
                continue;
            }
            fname = getattr(fn, "name", None) if not isinstance(fn, dict) else fn.get("name");
            fargs = getattr(fn, "arguments", None) if not isinstance(fn, dict) else fn.get("arguments");
            names.append(str(fname));
            args.append(clip(str(fargs), 400));
        }
        if names {
            row["tool"] = ", ".join(names);
            row["args"] = " | ".join(args);
        }
        out.append(row);
    }
    return out[-80:];
}

def _new_run(kind: AgentKind, mode: AgentMode, subject_type: str, subject_id: str, model: str, started_at: float, rec: RunRecorder, transcript: list[dict[str, any]], requested_by: str) -> AgentRun {
    return AgentRun(
        kind=kind, mode=mode, status=AgentRunStatus.SUCCEEDED, subject_type=subject_type,
        subject_id=subject_id, model=model, started_at=started_at, ended_at=now(),
        tool_calls=list(rec.calls), transcript=sanitize_transcript(transcript), requested_by=requested_by
    );
}

# ------------------------------------------------------------ supply planning
def order_brief(order: Order, lines: list[OrderLine]) -> OrderBrief {
    briefs: list[LineBrief] = [];
    for l in lines {
        m = mineral_by_code(l.mineral_code);
        g = grade_by_code(l.mineral_code, l.grade_code);
        spec = ", ".join([p.label + " " + describe_param(p) for p in l.spec]);
        briefs.append(LineBrief(
            line_id=jid(l), mineral_code=l.mineral_code, mineral_name=m.name if m is not None else l.mineral_code,
            grade_code=l.grade_code, grade_name=g.name if g is not None else l.grade_code,
            quantity_t=l.quantity_t, spec=spec
        ));
    }
    return OrderBrief(
        order_ref=order.ref, destination=order.site_name + " (" + order.site_address + ")",
        window_start=fmt_time(order.window_start), window_end=fmt_time(order.window_end),
        lines=briefs, buyer_notes=clip(order.notes, 300)
    );
}

def candidate_plants_for(lines: list[OrderLine]) -> list[str] {
    minerals = [l.mineral_code for l in lines];
    return [jid(p) for p in all_plants() if any(m in p.minerals for m in minerals)];
}

def _store_supply_run(order: Order, mode: AgentMode, model: str, started_at: float, rec: RunRecorder, transcript: list[dict[str, any]], explanation: str, outcome: SupplyValidation, requested_by: str) -> AgentRun {
    run = _new_run(AgentKind.SUPPLY_PLANNING, mode, "Order", jid(order), model, started_at, rec, transcript, requested_by);
    run.options = outcome.options;
    run.rejected = outcome.rejected;
    run.explanation = clip(explanation, 2000);
    run.status = AgentRunStatus.NO_FEASIBLE_OPTION if outcome.infeasible_lines else AgentRunStatus.SUCCEEDED;
    order +>:HasRun():+> run;
    return run;
}

def _store_failed_run(subject: DomainNode, kind: AgentKind, subject_type: str, subject_id: str, model: str, started_at: float, rec: RunRecorder, transcript: list[dict[str, any]], error: str, requested_by: str) {
    run = _new_run(kind, AgentMode.LLM, subject_type, subject_id, model, started_at, rec, transcript, requested_by);
    run.status = AgentRunStatus.FAILED;
    run.error = clip(error, 1000);
    run.explanation = "The LLM agent run failed; no recommendation from this run was used.";
    subject +>:HasRun():+> run;
}

def execute_supply_planning(order: Order, lines: list[OrderLine], requested_by: str) -> AgentRun {
    model = agent_model();
    started_at = now();
    rec = begin_run(jid(order), [jid(l) for l in lines]);
    order.candidate_plant_ids = candidate_plants_for(lines);
    try {
        if model is not None {
            transcript: list[dict[str, any]] = [];
            try {
                draft = run_supply_agent(model, order_brief(order, lines), transcript);
                outcome = validate_supply_plan(order, lines, draft, "LLM");
                return _store_supply_run(order, AgentMode.LLM, model_name_of(model), started_at, rec, transcript, draft.summary, outcome, requested_by);
            } except Exception as e {
                _store_failed_run(order, AgentKind.SUPPLY_PLANNING, "Order", jid(order), model_name_of(model), started_at, rec, transcript, str(e), requested_by);
                rec = begin_run(jid(order), [jid(l) for l in lines]);
                started_at = now();
                draft = fallback_supply_plan(lines);
                outcome = validate_supply_plan(order, lines, draft, "FALLBACK");
                return _store_supply_run(order, AgentMode.DETERMINISTIC_FALLBACK, "", started_at, rec, [], "LLM run failed (" + clip(str(e), 160) + "), so the deterministic fallback was used. " + draft.summary, outcome, requested_by);
            }
        }
        draft = fallback_supply_plan(lines);
        outcome = validate_supply_plan(order, lines, draft, "FALLBACK");
        return _store_supply_run(order, AgentMode.DETERMINISTIC_FALLBACK, "", started_at, rec, [], draft.summary, outcome, requested_by);
    } finally {
        end_run();
    }
}

"""Walks Order -> lines, then plans at the Order exit."""
walker:priv PlanningWorkflow {
    has requested_by: str,
        lines: list[OrderLine] = [],
        run_id: str = "";

    can start with Order entry {
        visit [here ->:HasLine:-> [?:OrderLine]];
    }

    can gather with OrderLine entry {
        self.lines.append(here);
    }

    can plan with Order exit {
        ordered = sorted(self.lines, key=lambda (l: OrderLine) { l.line_no; });
        run = execute_supply_planning(here, ordered, self.requested_by);
        self.run_id = jid(run);
    }
}

# --------------------------------------------------------- assignment planning
def assignment_brief(order: Order, shipments: list[Shipment]) -> AssignmentBrief {
    briefs: list[ShipmentBrief] = [];
    for sh in shipments {
        line = get_line(sh.line_id);
        slot = get_slot(sh.slot_id);
        briefs.append(ShipmentBrief(
            shipment_id=jid(sh), ref=sh.ref, plant_name=name_of_plant(sh.plant_id),
            mineral_code=line.mineral_code if line is not None else "", grade_code=line.grade_code if line is not None else "",
            quantity_t=sh.quantity_t, slot_start=fmt_time(slot.start_ts) if slot is not None else "",
            destination=order.site_name, window=fmt_time(order.window_start) + " to " + fmt_time(order.window_end)
        ));
    }
    return AssignmentBrief(order_ref=order.ref, shipments=briefs);
}

def _store_action_run(subject: DomainNode, kind: AgentKind, mode: AgentMode, subject_type: str, subject_id: str, model: str, started_at: float, rec: RunRecorder, transcript: list[dict[str, any]], explanation: str, what_changed: str, outcome: ActionValidation, requested_by: str) -> AgentRun {
    run = _new_run(kind, mode, subject_type, subject_id, model, started_at, rec, transcript, requested_by);
    run.actions = outcome.actions;
    run.rejected = outcome.rejected;
    run.explanation = clip(explanation, 2000);
    run.what_changed = clip(what_changed, 1000);
    run.status = AgentRunStatus.SUCCEEDED if outcome.actions else AgentRunStatus.NO_FEASIBLE_OPTION;
    subject +>:HasRun():+> run;
    return run;
}

def execute_assignment_planning(order: Order, shipments: list[Shipment], requested_by: str) -> AgentRun {
    model = agent_model();
    started_at = now();
    rec = begin_run(jid(order), [s.line_id for s in shipments], [jid(s) for s in shipments]);
    try {
        if model is not None {
            transcript: list[dict[str, any]] = [];
            try {
                draft = run_assignment_agent(model, assignment_brief(order, shipments), transcript);
                outcome = validate_assignments(shipments, draft, "LLM");
                return _store_action_run(order, AgentKind.ASSIGNMENT_PLANNING, AgentMode.LLM, "Order", jid(order), model_name_of(model), started_at, rec, transcript, draft.summary, "", outcome, requested_by);
            } except Exception as e {
                _store_failed_run(order, AgentKind.ASSIGNMENT_PLANNING, "Order", jid(order), model_name_of(model), started_at, rec, transcript, str(e), requested_by);
                rec = begin_run(jid(order), [s.line_id for s in shipments], [jid(s) for s in shipments]);
                started_at = now();
                draft = fallback_assignment_plan(shipments);
                outcome = validate_assignments(shipments, draft, "FALLBACK");
                return _store_action_run(order, AgentKind.ASSIGNMENT_PLANNING, AgentMode.DETERMINISTIC_FALLBACK, "Order", jid(order), "", started_at, rec, [], "LLM run failed (" + clip(str(e), 160) + "), so the deterministic fallback was used. " + draft.summary, "", outcome, requested_by);
            }
        }
        draft = fallback_assignment_plan(shipments);
        outcome = validate_assignments(shipments, draft, "FALLBACK");
        return _store_action_run(order, AgentKind.ASSIGNMENT_PLANNING, AgentMode.DETERMINISTIC_FALLBACK, "Order", jid(order), "", started_at, rec, [], draft.summary, "", outcome, requested_by);
    } finally {
        end_run();
    }
}

# ------------------------------------------------------------ exception recovery
glob DRIVER_EXCEPTIONS: list[str] = ["DRIVER_CANCELLED", "DRIVER_REJECTED", "VEHICLE_ISSUE"];

def execute_recovery(ex: ExceptionCase, sh: Shipment, requested_by: str) -> AgentRun {
    model = agent_model();
    started_at = now();
    line = get_line(sh.line_id);
    needs_driver = str(ex.ex_type) in DRIVER_EXCEPTIONS;
    rec = begin_run(sh.order_id, [sh.line_id], [jid(sh)]);
    brief = ExceptionBrief(exception_id=jid(ex), ex_type=str(ex.ex_type), summary=ex.summary, shipment_id=jid(sh), line_id=sh.line_id);
    try {
        if model is not None {
            transcript: list[dict[str, any]] = [];
            try {
                draft = run_recovery_agent(model, brief, transcript);
                outcome = validate_recovery(sh, draft, "LLM");
                explanation = draft.recommendation if outcome.actions else (draft.no_feasible_reason or "No feasible alternative passed validation.");
                return _store_action_run(ex, AgentKind.EXCEPTION_RECOVERY, AgentMode.LLM, "ExceptionCase", jid(ex), model_name_of(model), started_at, rec, transcript, explanation, draft.what_changed, outcome, requested_by);
            } except Exception as e {
                _store_failed_run(ex, AgentKind.EXCEPTION_RECOVERY, "ExceptionCase", jid(ex), model_name_of(model), started_at, rec, transcript, str(e), requested_by);
                rec = begin_run(sh.order_id, [sh.line_id], [jid(sh)]);
                started_at = now();
                draft = fallback_recovery_plan(jid(ex), line, needs_driver);
                outcome = validate_recovery(sh, draft, "FALLBACK");
                explanation = "LLM run failed (" + clip(str(e), 160) + "), so the deterministic fallback was used. " + (draft.recommendation if outcome.actions else draft.no_feasible_reason);
                return _store_action_run(ex, AgentKind.EXCEPTION_RECOVERY, AgentMode.DETERMINISTIC_FALLBACK, "ExceptionCase", jid(ex), "", started_at, rec, [], explanation, draft.what_changed, outcome, requested_by);
            }
        }
        draft = fallback_recovery_plan(jid(ex), line, needs_driver);
        outcome = validate_recovery(sh, draft, "FALLBACK");
        explanation = draft.recommendation if outcome.actions else (draft.no_feasible_reason or "No feasible alternative passed validation.");
        return _store_action_run(ex, AgentKind.EXCEPTION_RECOVERY, AgentMode.DETERMINISTIC_FALLBACK, "ExceptionCase", jid(ex), "", started_at, rec, [], explanation, draft.what_changed, outcome, requested_by);
    } finally {
        end_run();
    }
}

def runs_of(subject: DomainNode) -> list[AgentRun] {
    return sorted([subject ->:HasRun:-> [?:AgentRun]], key=lambda (r: AgentRun) { -r.started_at; });
}
