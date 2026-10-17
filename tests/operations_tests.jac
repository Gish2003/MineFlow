"""Store manager, exception recovery, claims and admin flows through HTTP."""

import time;
import base64;
import tempfile;
import from jaclang.testing.testing { JacTestClient }
import from support_helpers { Session }

def first(rows: list[dict[str, any]], key: str, value: any) -> dict[str, any] {
    found = [r for r in rows if r[key] == value];
    assert found, f"no row with {key}={value}";
    return found[0];
}

test "plant isolation, slot loss, recovery approval and spreadsheet import" {
    s = Session(client=JacTestClient.from_file("main.jac", base_path=tempfile.mkdtemp()));
    try {
        s.login_as("manager");
        mine = s.call("manager_plants");
        codes = [p["code"] for p in mine["plants"]];
        assert sorted(codes) == ["EPW", "MDQ", "PLP"], codes;

        s.login_as("manager2");
        nsp = first(s.call("manager_plants")["plants"], "code", "NSP");
        s.login_as("manager");
        foreign = s.call("plant_detail", {"plant_id": nsp["id"]});
        assert not foreign["ok"] and foreign["code"] == "ACCESS_DENIED", "manager cannot open another company's plant";
        hacked = s.call("set_plant_status", {"plant_id": nsp["id"], "status": "UNAVAILABLE", "note": "not mine to change"});
        assert not hacked["ok"];

        # --- equipment delay at Nattandiya removes the offered silica load's slot
        s.login_as("manager2");
        detail = s.call("plant_detail", {"plant_id": nsp["id"]});
        held = [r for r in detail["reservations"] if r["status"] == "HELD"][0];
        t0 = held["slot_start"];
        delay = s.call("add_delay", {"plant_id": nsp["id"], "kind": "EQUIPMENT", "severity": "HIGH", "start_ts": t0 - 60, "end_ts": t0 + 3600 + 60, "description": "Conveyor belt torn"});
        assert delay["ok"] and "1 load" in delay["message"], delay;

        # --- dispatcher sees the exception, runs recovery (labelled fallback), approves
        s.login_as("dispatcher");
        exs = s.call("exceptions_list", {"status_filter": "OPEN"});
        ex = [e for e in exs["exceptions"] if e["ex_type"] == "SLOT_LOST"][0];
        assert ex["shipment_status"] == "EXCEPTION";
        rec = s.call("run_recovery", {"exception_id": ex["id"]});
        assert rec["ok"], rec;
        run = rec["runs"][0];
        assert run["mode"] == "DETERMINISTIC_FALLBACK" and run["tool_calls"], run;
        assert run["actions"], f"another slot at Nattandiya should be feasible: {run}";
        bad = s.call("apply_recovery_option", {"exception_id": ex["id"], "run_id": run["id"], "option_id": "R99"});
        assert not bad["ok"];
        applied = s.call("apply_recovery_option", {"exception_id": ex["id"], "run_id": run["id"], "option_id": run["actions"][0]["option_id"], "reason": "Earliest slot after the repair"});
        assert applied["ok"], applied;
        after = s.call("exception_detail", {"exception_id": ex["id"]});
        assert after["data"]["status"] == "RESOLVED";
        assert after["data"]["shipment_status"] in ["AWAITING_DISPATCH", "SCHEDULED"], after["data"];

        # --- spreadsheet import: invalid rows never touch stock
        s.login_as("manager");
        plp = first(mine["plants"], "code", "PLP");
        csv_text = "lot_code,mineral_code,grade_code,stockpile,measured_t,price_per_t,assay:CaCO3,assay:MgO\n"
            + "PLP-CEM-N1,LIMESTONE,LS-CEM,North yard,1300,4200,91.8,2.2\n"
            + "PLP-NEW-01,LIMESTONE,LS-CEM,East yard,80,4100,90.9,2.4\n"
            + "PLP-BAD-01,ILMENITE,ILM52,Nowhere,10,1,52,0.1\n"
            + "PLP-HP-C1,LIMESTONE,LS-HP,Crusher bay,1,7400,96.2,1.1\n";
        prev = s.call("preview_import", {"plant_id": plp["id"], "filename": "stock.csv", "data_b64": base64.b64encode(csv_text.encode()).decode()});
        assert prev["ok"], prev;
        acts = {r["lot_code"]: r["action"] for r in prev["rows"]};
        assert acts["PLP-CEM-N1"] == "UPDATE" and acts["PLP-NEW-01"] == "NEW" and acts["PLP-BAD-01"] == "INVALID", acts;
        assert acts["PLP-HP-C1"] == "INVALID", "cannot drop measured below reserved / mismatched assay";
        com = s.call("commit_import", {"batch_id": prev["batch_id"]});
        assert com["ok"] and "Applied 2" in com["message"], com;
        again = s.call("commit_import", {"batch_id": prev["batch_id"]});
        assert not again["ok"], "an import batch commits once";
        lots = s.call("plant_detail", {"plant_id": plp["id"]})["lots"];
        assert first(lots, "lot_code", "PLP-CEM-N1")["measured_t"] == 1300.0;
        assert first(lots, "lot_code", "PLP-NEW-01")["quality"] == "PENDING";
        export = s.call("export_inventory", {"plant_id": plp["id"], "fmt": "csv"});
        assert export["ok"] and "PLP-NEW-01" in base64.b64decode(export["data_b64"]).decode();
        xlsx = s.call("export_inventory", {"plant_id": plp["id"], "fmt": "xlsx"});
        assert xlsx["ok"] and xlsx["filename"].endswith(".xlsx");
    } finally {
        s.client.close();
    }
}

test "claims reach the right plant manager and admin is admin-only" {
    s = Session(client=JacTestClient.from_file("main.jac", base_path=tempfile.mkdtemp()));
    try {
        s.login_as("manager");
        mine = s.call("claims_list");
        assert mine["claims"], "seeded Eppawala claim visible to its plant manager";
        claim = mine["claims"][0];
        s.login_as("manager2");
        assert not s.call("claims_list")["claims"], "other plants' managers do not see it";
        early = s.call("resolve_claim", {"claim_id": claim["id"], "outcome": "RESOLVED", "resolution": "credit note"});
        assert not early["ok"];

        s.login_as("dispatcher");
        routed = s.call("review_claim", {"claim_id": claim["id"], "routed_to": "PLANT_MANAGER", "note": "Check weighbridge calibration"});
        assert routed["ok"], routed;
        s.login_as("manager");
        done = s.call("resolve_claim", {"claim_id": claim["id"], "outcome": "RESOLVED", "resolution": "Weighbridge drift confirmed; 1.1 t credit note issued."});
        assert done["ok"], done;
        s.login_as("buyer2");
        mine_b = s.call("claims_list");
        assert first(mine_b["claims"], "id", claim["id"])["status"] == "RESOLVED";

        denied = s.call("admin_directory");
        assert not denied["ok"] and denied["code"] == "ACCESS_DENIED";
        s.login_as("admin");
        d = s.call("admin_directory");
        assert d["ok"] and len(d["accounts"]) > 10;
        mhn = first(d["orgs"], "code", "MHN");
        inv = s.call("admin_create_invite", {"email": "new.driver@example.com", "role": "DRIVER", "org_id": mhn["id"], "license_class": "HEAVY"});
        assert inv["ok"] and inv["invite_code"], inv;
        wrong = s.call("admin_create_invite", {"email": "x@example.com", "role": "STORE_MANAGER", "org_id": mhn["id"], "plant_ids": []});
        assert not wrong["ok"], "role/org mismatch rejected";
        s.client.register_user("invited-driver", "password123");
        joined = s.call("redeem_invite", {"code": inv["invite_code"], "display_name": "Kamal New"});
        assert joined["ok"] and joined["data"]["role"] == "DRIVER", joined;
        s.client.register_user("invited-driver-2", "password123");
        reuse = s.call("redeem_invite", {"code": inv["invite_code"], "display_name": "Someone Else"});
        assert not reuse["ok"] and reuse["code"] == "INVALID_INVITE", "invite codes are single-use";
    } finally {
        s.client.close();
    }
}
