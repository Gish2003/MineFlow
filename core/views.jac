"""View models shared by client and server.

Endpoints only ever return these role-shaped objects (never raw nodes), and
failures come back as `ok=False` with a stable `code` the UI can act on.
"""

obj ActionResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        id: str = "";
}

obj PlatformStatus {
    has demo_mode: bool,
        agent_label: str,
        llm_enabled: bool,
        currency: str,
        demo_password: str = "",
        version: str = "0.1.0";
}

obj DemoPersonaCard {
    has key: str,
        email: str,
        display_name: str,
        role: str,
        org_name: str,
        blurb: str,
        primary: bool = True;
}

obj SessionView {
    has account_id: str,
        display_name: str,
        email: str,
        role: str,
        org_id: str,
        org_name: str,
        org_type: str,
        plant_ids: list[str] = [],
        plant_names: list[str] = [],
        dispatch_plant_ids: list[str] = [],
        dispatch_plant_names: list[str] = [],
        demo_mode: bool = False,
        agent_label: str = "",
        currency: str = "LKR",
        unread_notifications: int = 0;
}

obj SessionResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: SessionView | None = None;
}

obj NotificationView {
    has id: str,
        at: float,
        level: str,
        title: str,
        body: str,
        link: str,
        read: bool;
}

obj TimelineEntryView {
    has at: float,
        kind: str,
        title: str,
        detail: str,
        actor_name: str,
        actor_role: str,
        shipment_id: str = "";
}

obj EvidenceView {
    has id: str,
        kind: str,
        filename: str,
        mime: str,
        size_bytes: int,
        uploaded_by_name: str,
        uploaded_role: str,
        note: str,
        created_at: float;
}

obj EvidenceFile {
    has ok: bool,
        code: str = "",
        message: str = "",
        filename: str = "",
        mime: str = "",
        data_b64: str = "";
}

obj MessageView {
    has id: str,
        sender_name: str,
        sender_role: str,
        body: str,
        at: float,
        mine: bool;
}

obj ClaimView {
    has id: str,
        ref: str,
        order_id: str,
        order_ref: str,
        shipment_id: str,
        shipment_ref: str,
        claim_type: str,
        status: str,
        description: str,
        plant_name: str,
        lot_code: str,
        qty_expected_t: float,
        qty_received_t: float,
        routed_to: str,
        resolution: str,
        created_by_name: str,
        created_at: float,
        updated_at: float,
        evidence: list[EvidenceView] = [],
        can_review: bool = False,
        can_resolve: bool = False;
}

obj FileDownload {
    has ok: bool,
        code: str = "",
        message: str = "",
        filename: str = "",
        mime: str = "",
        data_b64: str = "";
}

def ok_result(id: str = "", message: str = "") -> ActionResult {
    return ActionResult(ok=True, id=id, message=message);
}

def fail_result(code: str, message: str) -> ActionResult {
    return ActionResult(ok=False, code=code, message=message);
}
