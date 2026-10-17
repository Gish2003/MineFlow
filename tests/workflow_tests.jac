"""End-to-end delivery workflow through the HTTP endpoints, with authorization
and failure-path checks at each step (JacTestClient, isolated store per test)."""

import time;
import base64;
import tempfile;
import from jaclang.testing.testing { JacTestClient }
import from support_helpers { Session, tiny_png_b64 }

test "buyer to completion with authorization at every step" {
    s = Session(client=JacTestClient.from_file("main.jac", base_path=tempfile.mkdtemp()));
    try {
        # --- buyer creates an order and gets recommendations
        s.login_as("buyer");
        cat = s.call("buyer_catalog");
        assert cat["ok"];
        site = [x for x in cat["sites"] if x["name"] == "Wattala Cement Mill"][0];
        t = time.time();
        made = s.call("create_order", {
            "site_id": site["id"], "window_start": t + 3 * 3600, "window_end": t + 30 * 3600,
            "lines": [{"mineral_code": "LIMESTONE", "grade_code": "LS-CEM", "quantity_t": 25.0}], "notes": "workflow test"
        });
        assert made["ok"], made;
        order_id = made["id"];

        bad = s.call("create_order", {"site_id": site["id"], "window_start": t + 3 * 3600, "window_end": t + 30 * 3600, "lines": [{"mineral_code": "LIMESTONE", "grade_code": "LS-CEM", "quantity_t": 400.0}]});
        assert not bad["ok"] and bad["code"] == "VALIDATION", "oversized load must be rejected";

        plan = s.call("request_recommendations", {"order_id": order_id});
        assert plan["ok"] and plan["order_status"] == "OPTIONS_READY", plan;
        run = plan["run"];
        assert run["mode"] == "DETERMINISTIC_FALLBACK", "no LLM key in tests: fallback must be labelled";
        assert len(run["tool_calls"]) >= 2, "real tool invocations must be logged";
        assert {c["tool"] for c in run["tool_calls"]} >= {"list_candidate_plants", "evaluate_plant_feasibility"};
        opt = run["options"][0];
        assert opt["within_window"] and opt["grade_ok"];

        # --- another buyer cannot see this order
        s.login_as("buyer2");
        peek = s.call("order_detail", {"order_id": order_id});
        assert not peek["ok"] and peek["code"] == "NOT_FOUND", "buyer isolation";
        steal = s.call("confirm_order_option", {"order_id": order_id, "run_id": run["id"], "selections": [{"line_id": opt["line_id"], "option_id": opt["option_id"]}]});
        assert not steal["ok"], "other buyer cannot confirm";

        # --- owner confirms: atomic reservation
        s.login_as("buyer");
        conf = s.call("confirm_order_option", {"order_id": order_id, "run_id": run["id"], "selections": [{"line_id": opt["line_id"], "option_id": opt["option_id"]}]});
        assert conf["ok"], conf;
        detail = s.call("order_detail", {"order_id": order_id})["data"];
        assert detail["summary"]["status"] == "RESERVED";
        ship = detail["shipments"][0];
        sid = ship["id"];
        assert ship["status"] == "AWAITING_DISPATCH";

        # --- out-of-scope dispatcher sees nothing
        s.login_as("dispatcher2");
        q2 = s.call("dispatch_queue", {"view": "ACTIVE"});
        assert order_id not in [r["order_id"] for r in q2["rows"]], "dispatcher scope";
        opts2 = s.call("assignment_options", {"shipment_id": sid});
        assert not opts2["ok"] and opts2["code"] == "NOT_FOUND";

        # --- dispatcher assigns (override needs a reason)
        s.login_as("dispatcher");
        q = s.call("dispatch_queue", {"view": "ACTIVE"});
        assert order_id in [r["order_id"] for r in q["rows"]];
        opts = s.call("assignment_options", {"shipment_id": sid});
        assert opts["ok"], opts;
        nuwan = [d for d in opts["drivers"] if d["name"] == "Nuwan Herath"][0];
        assert nuwan["eligible"], nuwan;
        busy = [d for d in opts["drivers"] if d["name"] == "Mahesh Gunawardena"][0];
        assert not busy["eligible"], "a driver with an active job is not eligible";
        truck = [x for x in opts["trucks"] if x["eligible"]][0];
        bad_truck = [x for x in opts["trucks"] if x["status"] == "MAINTENANCE"][0];
        rejected = s.call("approve_dispatch", {"shipment_id": sid, "driver_id": nuwan["driver_id"], "truck_id": bad_truck["truck_id"], "loader_id": ""});
        assert not rejected["ok"], "truck in maintenance must be refused";
        needs_reason = nuwan["driver_id"] != opts["recommended_driver_id"] or truck["truck_id"] != opts["recommended_truck_id"] or opts["recommended_loader_id"] != "";
        if needs_reason {
            no_reason = s.call("approve_dispatch", {"shipment_id": sid, "driver_id": nuwan["driver_id"], "truck_id": truck["truck_id"], "loader_id": ""});
            assert not no_reason["ok"] and no_reason["code"] == "OVERRIDE_REASON_REQUIRED", no_reason;
        }
        ok_dispatch = s.call("approve_dispatch", {"shipment_id": sid, "driver_id": nuwan["driver_id"], "truck_id": truck["truck_id"], "loader_id": "", "override_reason": "Loader will self-assign at the bay (test)"});
        assert ok_dispatch["ok"], ok_dispatch;

        # --- driver accepts; another driver cannot see the job
        s.login_as("driver2");
        other_home = s.call("driver_home");
        assert sid not in [o["shipment_id"] for o in other_home["offers"]], "offer visible only to its driver";
        s.login_as("driver4");
        home = s.call("driver_home");
        offer = [o for o in home["offers"] if o["shipment_id"] == sid][0];
        acc = s.call("respond_offer", {"offer_id": offer["id"], "accept": True});
        assert acc["ok"], acc;

        # --- loader claims, checks in; truck checks in
        s.login_as("loader");
        lh = s.call("loader_home");
        assert sid in [j["shipment_id"] for j in lh["eligible"]], lh;
        assert s.call("claim_loading_job", {"shipment_id": sid})["ok"];
        assert s.call("loader_check_in", {"shipment_id": sid})["ok"];
        early = s.call("verify_and_start_loading", {"shipment_id": sid, "lot_code": "x", "truck_plate": "y", "order_ref": "z"});
        assert not early["ok"], "truck has not checked in yet";
        s.login_as("driver4");
        assert s.call("driver_check_in", {"shipment_id": sid})["ok"];
        job = s.call("driver_job", {"shipment_id": sid})["data"];

        # --- loader verifies material + truck + order before loading
        s.login_as("loader");
        lj = s.call("loader_job", {"shipment_id": sid})["data"];
        wrong = s.call("verify_and_start_loading", {"shipment_id": sid, "lot_code": lj["lot_code"], "truck_plate": "XX 0000", "order_ref": lj["order_ref"]});
        assert not wrong["ok"] and wrong["code"] == "VERIFICATION_FAILED";
        go = s.call("verify_and_start_loading", {"shipment_id": sid, "lot_code": lj["lot_code"], "truck_plate": lj["truck_plate"], "order_ref": lj["order_ref"]});
        assert go["ok"], go;
        too_much = s.call("finish_loading", {"shipment_id": sid, "loaded_qty_t": 30.0, "ticket_no": "T-1"});
        assert not too_much["ok"], "quantity outside tolerance";
        done = s.call("finish_loading", {"shipment_id": sid, "loaded_qty_t": 25.1, "ticket_no": "PLP-T-90001"});
        assert done["ok"], done;

        # --- driver confirms ticket, departs, shares location
        s.login_as("driver4");
        bad_ticket = s.call("confirm_ticket_and_depart", {"shipment_id": sid, "ticket_no": "nope"});
        assert not bad_ticket["ok"];
        assert s.call("confirm_ticket_and_depart", {"shipment_id": sid, "ticket_no": "plp-t-90001"})["ok"];
        ping = s.call("report_location", {"shipment_id": sid, "lat": 7.6, "lng": 79.85, "accuracy_m": 20.0, "source": "SIMULATED", "nonce": 1});
        assert ping["ok"], ping;

        # --- buyer sees live tracking; loader cannot track
        s.login_as("buyer");
        tr = s.call("get_tracking", {"shipment_id": sid, "poll_seq": 1});
        assert tr["ok"] and tr["data"]["connectivity"] == "LIVE" and tr["data"]["last_source"] == "SIMULATED", tr;
        s.login_as("loader");
        assert not s.call("get_tracking", {"shipment_id": sid, "poll_seq": 2})["ok"];

        # --- proof of delivery: photo required, photo alone does not complete
        s.login_as("driver4");
        early_unload = s.call("record_unloading", {"shipment_id": sid, "note": "bay 1"});
        assert not early_unload["ok"] and early_unload["code"] == "EVIDENCE_REQUIRED";
        up = s.call("upload_evidence", {"owner_type": "SHIPMENT", "owner_id": sid, "kind": "UNLOADING_PHOTO", "filename": "unload.png", "mime": "image/png", "data_b64": tiny_png_b64()});
        assert up["ok"], up;
        mid = s.call("driver_job", {"shipment_id": sid})["data"];
        assert mid["status"] == "IN_TRANSIT", "uploading a photo must not change delivery status";
        assert s.call("record_unloading", {"shipment_id": sid, "note": "Unloaded at bay 1"})["ok"];
        wrong_pin = s.call("submit_handover_pin", {"shipment_id": sid, "pin": "000000"});
        assert not wrong_pin["ok"] and wrong_pin["code"] == "WRONG_PIN";

        # --- buyer's PIN (visible only to the buyer) completes the handover
        s.login_as("buyer");
        d2 = s.call("order_detail", {"order_id": order_id})["data"];
        pin = d2["shipments"][0]["handover_pin"];
        assert len(pin) == 6 and d2["shipments"][0]["status"] == "DELIVERED";
        s.login_as("driver4");
        assert s.call("driver_job", {"shipment_id": sid})["data"]["status"] == "DELIVERED";
        fin = s.call("submit_handover_pin", {"shipment_id": sid, "pin": pin, "received_qty_t": 25.1});
        assert fin["ok"], fin;
        pay = s.call("ledger_entries");
        assert any(e["kind"] == "DRIVER_PAYOUT" and e["status"] == "PENDING" for e in pay["entries"]), pay;

        s.login_as("buyer");
        final = s.call("order_detail", {"order_id": order_id})["data"];
        assert final["summary"]["status"] == "COMPLETED", final["summary"];
        assert final["shipments"][0]["ack_method"] == "HANDOVER_PIN";
        assert final["shipments"][0]["handover_pin"] == "", "PIN is hidden once completed";
    } finally {
        s.client.close();
    }
}

def plan_order(s: Session, persona: str, loads: int, t: float) -> dict[str, any] {
    s.login_as(persona);
    site = s.call("buyer_catalog")["sites"][0];
    lines = [{"mineral_code": "ROCK_PHOSPHATE", "grade_code": "RP32", "quantity_t": 38.0} for _ in range(loads)];
    made = s.call("create_order", {"site_id": site["id"], "window_start": t + 3 * 3600, "window_end": t + 60 * 3600, "lines": lines});
    assert made["ok"], made;
    plan = s.call("request_recommendations", {"order_id": made["id"]});
    assert plan["ok"] and plan["order_status"] == "OPTIONS_READY", plan;
    sel: list[dict[str, str]] = [];
    for o in plan["run"]["options"] {
        if o["line_id"] not in [x["line_id"] for x in sel] {
            sel.append({"line_id": o["line_id"], "option_id": o["option_id"]});
        }
    }
    return {"order_id": made["id"], "run_id": plan["run"]["id"], "selections": sel};
}

test "the last tonnes cannot be reserved twice" {
    s = Session(client=JacTestClient.from_file("main.jac", base_path=tempfile.mkdtemp()));
    try {
        t = time.time();
        a = plan_order(s, "buyer", 3, t);
        b = plan_order(s, "buyer2", 2, t);
        s.login_as("buyer");
        first = s.call("confirm_order_option", a);
        assert first["ok"], f"first buyer reserves 114 of 140 t: {first}";
        s.login_as("buyer2");
        second = s.call("confirm_order_option", b);
        assert not second["ok"] and second["code"] == "CONFLICT", f"only 26 t left - must not over-reserve: {second}";
        detail = s.call("order_detail", {"order_id": b["order_id"]})["data"];
        assert detail["summary"]["status"] == "OPTIONS_READY" and not detail["shipments"], "nothing partially reserved";
    } finally {
        s.client.close();
    }
}
