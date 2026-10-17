"""Agentic workflow tests with MockLLM (no network, no API key).

MockLLM replaces only the network call: byLLM still builds the real request,
executes the tools the scripted model asks for, and parses the final answer.
"""

import from jaclang.byllm.lib { MockLLM, MockToolCall, MockRawResponse, MockError }
import from core.model { Order, OrderLine, Plant, StockLot, Shipment }
import from core.enums { PlantStatus, ExceptionType, ShipmentStatus }
import from core.hub { get_hub, all_plants, lots_of, get_run, all_accounts, shipments_of_order, all_orders }
import from core.util { now }
import from seed.demo_data { ensure_demo_seed, _new_order, _new_line, SITES }
import from scheduling.slots { ensure_all_slots }
import from planning.workflow { PlanningWorkflow, set_model_override, execute_recovery, runs_of }
import from dispatch.exceptions { raise_exception }
import from core.hub { sites_of, all_orgs }

def tool_turn(name: str, args: dict[str, any]) -> MockRawResponse {
    return MockRawResponse(tool_calls=[MockToolCall(tool=name, args=args)]);
}

def finish_turn(output: dict[str, any]) -> MockRawResponse {
    return MockRawResponse(tool_calls=[MockToolCall(tool="finish_tool", args={"final_output": output}, call_id="call_finish")]);
}

def plant_by_code(code: str) -> Plant {
    return [p for p in all_plants() if p.code == code][0];
}

def lot_by_code(code: str) -> StockLot {
    for p in all_plants() {
        for l in lots_of(p) {
            if l.code == code {
                return l;
            }
        }
    }
    raise RuntimeError("lot " + code + " missing");
}

def new_limestone_order -> tuple[Order, OrderLine] {
    ensure_demo_seed();
    ensure_all_slots(3);
    buyer = [a for a in all_accounts() if a.persona_key == "buyer"][0];
    site = [s for o in all_orgs() for s in sites_of(o) if s.name == "Wattala Cement Mill"][0];
    t = now();
    o = _new_order(get_hub(), buyer, site, t + 3 * 3600, t + 30 * 3600, t, "agent test");
    line = _new_line(o, 1, "LIMESTONE", "LS-CEM", 25.0);
    return (o, line);
}

test "llm agent tools execute for real and its output is validated" {
    (o, line) = new_limestone_order();
    lid = jid(line);
    plp = plant_by_code("PLP");
    good_lot = lot_by_code("PLP-CEM-N1");
    wrong_plant_lot = lot_by_code("MDQ-AG-01");
    mock = MockLLM(outputs=[
        tool_turn("list_candidate_plants", {"line_id": lid}),
        tool_turn("evaluate_plant_feasibility", {"plant_id": jid(plp), "line_id": lid}),
        tool_turn("check_grade_compatibility", {"lot_id": jid(good_lot), "line_id": "not-a-line-of-this-run"}),
        finish_turn({
            "lines": [{
                "line_id": lid,
                "ranked_options": [
                    {"plant_id": jid(plp), "lot_id": jid(good_lot), "slot_id": "made-up-slot", "rationale": "Verified lot, closest plant."},
                    {"plant_id": jid(plp), "lot_id": jid(wrong_plant_lot), "slot_id": "", "rationale": "Hallucinated pairing."}
                ],
                "note": ""
            }],
            "summary": "Puttalam is the only limestone plant."
        })
    ]);
    set_model_override(mock);
    try {
        w = o spawn PlanningWorkflow(requested_by="test");
    } finally {
        set_model_override(None);
    }
    run = get_run(w.run_id);
    assert run is not None;
    assert str(run.mode) == "LLM", f"mode {run.mode}";
    tools = [c.tool for c in run.tool_calls];
    assert tools[:2] == ["list_candidate_plants", "evaluate_plant_feasibility"], f"tools actually executed in order: {tools}";
    scoped = [c for c in run.tool_calls if c.tool == "check_grade_compatibility"][0];
    assert not scoped.ok, "tools refuse ids outside the run";
    assert len(run.options) == 1, f"only the valid option survives: {run.options}";
    assert run.options[0].lot_id == jid(good_lot);
    assert "validator replaced" in run.options[0].rationale, "an unusable proposed slot is replaced and disclosed";
    assert any("does not belong" in " ".join(r.reasons) for r in run.rejected), f"wrong-plant lot rejected: {run.rejected}";
    assert any(t["role"] == "tool" for t in run.transcript), "conversation transcript recorded";
    assert str(run.status) == "SUCCEEDED";
}

test "llm failure is recorded and the fallback is labelled" {
    (o, line) = new_limestone_order();
    _ = line;
    mock = MockLLM(outputs=[MockError(error=RuntimeError("provider unavailable"))]);
    set_model_override(mock);
    try {
        w = o spawn PlanningWorkflow(requested_by="test");
    } finally {
        set_model_override(None);
    }
    run = get_run(w.run_id);
    assert run is not None;
    assert str(run.mode) == "DETERMINISTIC_FALLBACK" and "LLM run failed" in run.explanation, run.explanation;
    statuses = [(str(r.mode), str(r.status)) for r in runs_of(o)];
    assert ("LLM", "FAILED") in statuses, f"failed LLM run is kept, not hidden: {statuses}";
    assert run.options, "fallback still produced validated options";
}

test "recovery reports truthfully when no alternative exists" {
    ensure_demo_seed();
    ensure_all_slots(3);
    target: Shipment | None = None;
    for o in all_orders() {
        for sh in shipments_of_order(o) {
            if sh.status == ShipmentStatus.AWAITING_DISPATCH {
                target = sh;
            }
        }
    }
    assert target is not None, "seed has a reserved dolomite load";
    mdq = plant_by_code("MDQ");
    mdq.status = PlantStatus.UNAVAILABLE;
    mdq.status_note = "Crusher failure (test)";
    ex = raise_exception(ExceptionType.PLANT_UNAVAILABLE, "HIGH", "Matale unavailable", "test", target, target.plant_id, "test");
    mock = MockLLM(outputs=[
        tool_turn("get_exception_context", {"exception_id": jid(ex)}),
        tool_turn("list_candidate_plants", {"line_id": target.line_id}),
        tool_turn("evaluate_plant_feasibility", {"plant_id": jid(plant_by_code("PLP")), "line_id": target.line_id}),
        finish_turn({"what_changed": "Matale is down.", "options": [], "recommendation": "", "no_feasible_reason": "Only Matale holds DOL-IND stock."})
    ]);
    set_model_override(mock);
    try {
        run = execute_recovery(ex, target, "test");
    } finally {
        set_model_override(None);
    }
    assert str(run.status) == "NO_FEASIBLE_OPTION", run.status;
    assert not run.actions;
    assert "DOL-IND" in run.explanation;
    assert [c.tool for c in run.tool_calls] == ["get_exception_context", "list_candidate_plants", "evaluate_plant_feasibility"];
    feas = run.tool_calls[2];
    assert "false" in feas.result_json.lower(), "PLP cannot supply industrial dolomite";
}
