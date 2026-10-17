"""Kernel tests: demo persona binding, seeding, session resolution."""

import tempfile;
import from jaclang.testing.testing { JacTestClient }

glob APP: str = "main.jac";

def client_for_test -> JacTestClient {
    return JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
}

def call(client: JacTestClient, name: str, body: dict[str, any] = {}) -> dict[str, any] {
    resp = client.post("/function/" + name, json=body);
    assert resp.ok, f"{name} failed HTTP {resp.status_code}: {resp.text[:400]}";
    return resp.data["result"];
}

test "demo persona claim seeds data and binds the session" {
    client = client_for_test();
    try {
        client.register_user("kernel-buyer", "password123");
        before = call(client, "whoami");
        assert before["ok"] == False and before["code"] == "NO_ACCOUNT", f"unbound sign-in must have no account: {before}";

        claimed = call(client, "claim_demo_persona", {"persona_key": "buyer"});
        assert claimed["ok"], f"claim failed: {claimed}";
        assert claimed["data"]["role"] == "BUYER";
        assert claimed["data"]["org_name"] == "Kelani Cement Works";

        me = call(client, "whoami");
        assert me["ok"] and me["data"]["display_name"] == "Nadeesha Perera";

        again = call(client, "claim_demo_persona", {"persona_key": "buyer"});
        assert again["ok"], "re-claiming the same persona is idempotent";

        other = call(client, "claim_demo_persona", {"persona_key": "dispatcher"});
        assert not other["ok"] and other["code"] == "CONFLICT", f"one sign-in cannot hold two personas: {other}";

        client.register_user("kernel-intruder", "password123");
        stolen = call(client, "claim_demo_persona", {"persona_key": "buyer"});
        assert not stolen["ok"] and stolen["code"] == "PERSONA_CLAIMED", f"persona bound elsewhere must be refused: {stolen}";
    } finally {
        client.close();
    }
}

test "public endpoints expose no secrets beyond demo labels" {
    client = client_for_test();
    try {
        status = call(client, "platform_status");
        assert status["demo_mode"] == True;
        assert "fallback" in status["agent_label"].lower() or "agent" in status["agent_label"].lower();
        personas = call(client, "demo_personas");
        keys = [p["key"] for p in personas];
        assert "buyer" in keys and "admin" in keys and "staff-loader-mdq" not in keys, f"non-login staff must not be listed: {keys}";
    } finally {
        client.close();
    }
}
