"""Shared test helpers: a JacTestClient session that signs in as demo personas."""

import base64;
import from jaclang.testing.testing { JacTestClient }
import from seed.demo_data { placeholder_png }

glob PASSWORD: str = "password123";

obj Session {
    has client: JacTestClient,
        users: list[str] = [];

    def login_as(persona: str) {
        user = "wf-" + persona;
        if user not in self.users {
            self.client.register_user(user, PASSWORD);
            self.users.append(user);
            claimed = self.call("claim_demo_persona", {"persona_key": persona});
            assert claimed["ok"], f"claim {persona}: {claimed}";
        } else {
            self.client.login(user, PASSWORD);
        }
    }

    def call(name: str, body: dict[str, any] = {}) -> dict[str, any] {
        resp = self.client.post("/function/" + name, json=body);
        assert resp.ok, f"{name} HTTP {resp.status_code}: {resp.text[:600]}";
        return resp.data["result"];
    }
}

def tiny_png_b64 -> str {
    return base64.b64encode(placeholder_png(24, 16, 120, 140, 130)).decode("ascii");
}

