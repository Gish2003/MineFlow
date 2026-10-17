"""The MineFlow operational graph.

Every domain archetype extends `DomainNode` / `DomainEdge`, which open the
runtime-level access check (`__jac_access__`). That is deliberate: the graph is
app-owned, shared by all roles, and *all* authorization is enforced explicitly in
`core.access` at the top of every endpoint. No endpoint ever returns raw nodes;
callers receive role-shaped view objects (`core.views`).
"""

import from core.enums {
    Role, OrgType, OrderStatus, ShipmentStatus, ClaimStatus, ClaimType,
    PaymentStatus, LedgerKind, ReservationStatus, SlotStatus, LotQuality,
    PlantStatus, OfferStatus, TruckStatus, ExceptionType, ExceptionStatus,
    DelayKind, AgentMode, AgentKind, AgentRunStatus, EvidenceKind, AckMethod,
    PingSource
}

node DomainNode {
    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

edge DomainEdge: any --> any {
    def __jac_access__ -> AccessLevel {
        return AccessLevel.WRITE;
    }
}

# ---------------------------------------------------------------- structure
edge HubLink(DomainEdge) {}
edge HasOrg(DomainEdge) {}
edge HasAccount(DomainEdge) {}
edge HasMineral(DomainEdge) {}
edge HasGrade(DomainEdge) {}
edge OperatesPlant(DomainEdge) {}
edge HoldsLot(DomainEdge) {}
edge HasSlot(DomainEdge) {}
edge HasShift(DomainEdge) {}
edge HasQualityRecord(DomainEdge) {}
edge HasProductionPlan(DomainEdge) {}
edge HasDelay(DomainEdge) {}
edge HasImportBatch(DomainEdge) {}
edge OwnsTruck(DomainEdge) {}
edge HasSite(DomainEdge) {}
edge HasOrder(DomainEdge) {}
edge HasLine(DomainEdge) {}
edge HasReservation(DomainEdge) {}
edge HasShipment(DomainEdge) {}
edge HasOffer(DomainEdge) {}
edge HasPing(DomainEdge) {}
edge HasEvidence(DomainEdge) {}
edge HasBlob(DomainEdge) {}
edge HasEvent(DomainEdge) {}
edge HasClaim(DomainEdge) {}
edge HasMessage(DomainEdge) {}
edge HasRun(DomainEdge) {}
edge HasException(DomainEdge) {}
edge HasNotification(DomainEdge) {}
edge HasLedgerEntry(DomainEdge) {}
edge HasAudit(DomainEdge) {}

"""One quality parameter of a grade specification (e.g. P2O5 >= 28 %)."""
obj SpecParam {
    has key: str,
        label: str,
        min_value: float | None = None,
        max_value: float | None = None,
        unit: str = "%";
}

"""Root of the app-owned operational graph (hangs off root.shared)."""
node MineFlowHub(DomainNode) {
    has key: str = "mineflow",
        seeded_at: float = 0.0,
        scenario: str = "";
}

node Organization(DomainNode) {
    has code: str,
        name: str,
        org_type: OrgType,
        region: str = "";
}

"""An application account. `root_id` binds it to an authenticated Jac user."""
node Account(DomainNode) {
    has email: str,
        display_name: str,
        role: Role,
        org_id: str,
        root_id: str = "",
        persona_key: str = "",
        active: bool = True,
        plant_ids: list[str] = [],
        dispatch_plant_ids: list[str] = [],
        license_class: str = "",
        home_lat: float = 0.0,
        home_lng: float = 0.0,
        created_at: float = 0.0;
}

node Mineral(DomainNode) {
    has code: str,
        name: str,
        description: str = "",
        allowed_bodies: list[str] = [];
}

node GradeSpec(DomainNode) {
    has code: str,
        mineral_code: str,
        name: str,
        params: list[SpecParam] = [],
        description: str = "";
}

node Plant(DomainNode) {
    has code: str,
        name: str,
        org_id: str,
        lat: float,
        lng: float,
        region: str = "",
        status: PlantStatus = PlantStatus.OPERATIONAL,
        status_note: str = "",
        minerals: list[str] = [],
        bays: int = 2,
        open_hour: int = 6,
        close_hour: int = 20,
        loader_rate_tph: float = 120.0,
        setup_minutes: int = 15,
        readiness_buffer_min: int = 15,
        loading_fee_per_t: float = 150.0;
}

node StockLot(DomainNode) {
    has code: str,
        plant_id: str,
        mineral_code: str,
        grade_code: str,
        stockpile: str,
        measured_t: float,
        quality: LotQuality = LotQuality.PENDING,
        assay: dict[str, float] = {},
        price_per_t: float = 0.0,
        updated_at: float = 0.0,
        notes: str = "";
}

node QualityRecord(DomainNode) {
    has lot_id: str,
        lab: str,
        tested_at: float,
        results: dict[str, float] = {},
        verdict: LotQuality = LotQuality.PENDING,
        certificate_no: str = "",
        recorded_by: str = "",
        notes: str = "";
}

node Reservation(DomainNode) {
    has lot_id: str,
        line_id: str,
        order_id: str,
        plant_id: str,
        quantity_t: float,
        status: ReservationStatus = ReservationStatus.HELD,
        shipment_id: str = "",
        created_at: float = 0.0,
        released_reason: str = "";
}

node LoadingSlot(DomainNode) {
    has plant_id: str,
        bay: int,
        start_ts: float,
        end_ts: float,
        status: SlotStatus = SlotStatus.OPEN,
        shipment_id: str = "",
        blocked_reason: str = "";
}

node LoaderShift(DomainNode) {
    has plant_id: str,
        loader_id: str,
        start_ts: float,
        end_ts: float;
}

node ProductionPlan(DomainNode) {
    has plant_id: str,
        mineral_code: str,
        grade_code: str,
        expected_t: float,
        expected_at: float,
        status: str = "PLANNED",
        note: str = "";
}

node DelayNotice(DomainNode) {
    has plant_id: str,
        kind: DelayKind,
        severity: str,
        start_ts: float,
        end_ts: float,
        description: str,
        active: bool = True,
        created_by: str = "",
        created_at: float = 0.0;
}

node ImportBatch(DomainNode) {
    has plant_id: str,
        filename: str,
        sha256: str,
        uploaded_by: str,
        at: float,
        total_rows: int = 0,
        applied: int = 0,
        skipped: int = 0,
        errors: list[str] = [],
        status: str = "PREVIEWED";
}

node Truck(DomainNode) {
    has plate: str,
        org_id: str,
        payload_t: float,
        body_type: str,
        status: TruckStatus = TruckStatus.AVAILABLE,
        note: str = "";
}

node DeliverySite(DomainNode) {
    has org_id: str,
        name: str,
        address: str,
        lat: float,
        lng: float,
        contact_name: str = "";
}

node Order(DomainNode) {
    has ref: str,
        buyer_id: str,
        buyer_org_id: str,
        site_name: str,
        site_address: str,
        dest_lat: float,
        dest_lng: float,
        window_start: float,
        window_end: float,
        status: OrderStatus = OrderStatus.DRAFT,
        site_contact: str = "",
        notes: str = "",
        plant_ids: list[str] = [],
        candidate_plant_ids: list[str] = [],
        selected_run_id: str = "",
        created_at: float = 0.0,
        updated_at: float = 0.0;
}

node OrderLine(DomainNode) {
    has order_id: str,
        line_no: int,
        mineral_code: str,
        grade_code: str,
        quantity_t: float,
        spec: list[SpecParam] = [];
}

node Shipment(DomainNode) {
    has ref: str,
        order_id: str,
        line_id: str,
        plant_id: str,
        lot_id: str,
        slot_id: str,
        reservation_id: str,
        quantity_t: float,
        status: ShipmentStatus = ShipmentStatus.AWAITING_DISPATCH,
        truck_id: str = "",
        driver_id: str = "",
        loader_id: str = "",
        driver_checked_in_at: float = 0.0,
        loader_checked_in_at: float = 0.0,
        verified_at: float = 0.0,
        loading_started_at: float = 0.0,
        loading_ended_at: float = 0.0,
        loaded_qty_t: float = 0.0,
        load_ticket_no: str = "",
        ticket_confirmed_at: float = 0.0,
        departed_at: float = 0.0,
        arrived_at: float = 0.0,
        unloaded_at: float = 0.0,
        handover_note: str = "",
        handover_recorded_at: float = 0.0,
        handover_pin: str = "",
        pin_attempts: int = 0,
        ack_method: AckMethod = AckMethod.NONE,
        acknowledged_at: float = 0.0,
        received_qty_t: float = 0.0,
        completed_at: float = 0.0,
        eta_minutes: float = 0.0,
        distance_km: float = 0.0,
        exception_note: str = "",
        updated_at: float = 0.0;
}

node DriverOffer(DomainNode) {
    has shipment_id: str,
        driver_id: str,
        truck_id: str,
        status: OfferStatus = OfferStatus.OFFERED,
        pay_amount: float = 0.0,
        note: str = "",
        created_at: float = 0.0,
        responded_at: float = 0.0;
}

node LocationPing(DomainNode) {
    has shipment_id: str,
        lat: float,
        lng: float,
        accuracy_m: float,
        source: PingSource,
        at: float;
}

node Evidence(DomainNode) {
    has kind: EvidenceKind,
        owner_type: str,
        owner_id: str,
        filename: str,
        mime: str,
        size_bytes: int,
        sha256: str,
        uploaded_by: str,
        uploaded_by_name: str = "",
        uploaded_role: str = "",
        note: str = "",
        created_at: float = 0.0;
}

"""File bytes live apart from metadata so listings never load them."""
node EvidenceBlob(DomainNode) {
    has data_b64: str;
}

node TimelineEvent(DomainNode) {
    has order_id: str,
        at: float,
        kind: str,
        title: str,
        detail: str = "",
        shipment_id: str = "",
        actor_name: str = "",
        actor_role: str = "";
}

node Claim(DomainNode) {
    has ref: str,
        order_id: str,
        shipment_id: str,
        claim_type: ClaimType,
        description: str,
        status: ClaimStatus = ClaimStatus.OPEN,
        plant_id: str = "",
        lot_id: str = "",
        qty_expected_t: float = 0.0,
        qty_received_t: float = 0.0,
        routed_to: str = "",
        resolution: str = "",
        created_by: str = "",
        created_at: float = 0.0,
        updated_at: float = 0.0;
}

node Message(DomainNode) {
    has shipment_id: str,
        order_id: str,
        sender_id: str,
        sender_name: str,
        sender_role: str,
        body: str,
        at: float;
}

node Notification(DomainNode) {
    has account_id: str,
        at: float,
        level: str,
        title: str,
        body: str = "",
        link: str = "",
        read: bool = False;
}

node ExceptionCase(DomainNode) {
    has ref: str,
        ex_type: ExceptionType,
        severity: str,
        summary: str,
        status: ExceptionStatus = ExceptionStatus.OPEN,
        order_id: str = "",
        shipment_id: str = "",
        plant_id: str = "",
        detail: str = "",
        created_by: str = "",
        created_at: float = 0.0,
        resolved_at: float = 0.0,
        resolution: str = "",
        last_run_id: str = "";
}

"""One real tool invocation made during an agent run."""
obj ToolCallLog {
    has seq: int,
        tool: str,
        args_json: str,
        result_json: str,
        ok: bool,
        duration_ms: float,
        error: str = "";
}

"""One ranked, deterministically validated option produced by a planning run."""
obj PlanOption {
    has option_id: str,
        line_id: str,
        rank: int,
        plant_id: str,
        plant_name: str,
        lot_id: str,
        lot_code: str,
        slot_id: str,
        slot_start: float,
        quantity_t: float,
        grade_ok: bool,
        available_t: float,
        lot_quality: str,
        wait_minutes: float,
        distance_km: float,
        travel_minutes: float,
        eta_ts: float,
        within_window: bool,
        material_cost: float,
        haulage_cost: float,
        loading_cost: float,
        total_cost: float,
        rationale: str = "",
        score: float = 0.0;
}

obj RejectedOption {
    has line_id: str,
        plant_id: str,
        lot_id: str,
        reasons: list[str] = [],
        source: str = "LLM";
}

"""A validated assignment or recovery action (driver/truck/loader/plant switch)."""
obj ActionOption {
    has option_id: str,
        rank: int,
        action: str,
        shipment_id: str = "",
        plant_id: str = "",
        lot_id: str = "",
        slot_id: str = "",
        driver_id: str = "",
        truck_id: str = "",
        loader_id: str = "",
        summary: str = "",
        rationale: str = "",
        metrics: dict[str, float] = {};
}

node AgentRun(DomainNode) {
    has kind: AgentKind,
        mode: AgentMode,
        status: AgentRunStatus,
        subject_type: str,
        subject_id: str,
        model: str = "",
        started_at: float = 0.0,
        ended_at: float = 0.0,
        input_summary: str = "",
        tool_calls: list[ToolCallLog] = [],
        transcript: list[dict[str, str]] = [],
        options: list[PlanOption] = [],
        actions: list[ActionOption] = [],
        rejected: list[RejectedOption] = [],
        explanation: str = "",
        what_changed: str = "",
        error: str = "",
        requested_by: str = "",
        applied_option_id: str = "";
}

node LedgerEntry(DomainNode) {
    has kind: LedgerKind,
        shipment_id: str,
        order_id: str,
        payee_id: str,
        payee_name: str,
        amount: float,
        currency: str,
        status: PaymentStatus = PaymentStatus.PENDING,
        note: str = "",
        history: list[str] = [],
        created_at: float = 0.0,
        updated_at: float = 0.0;
}

node AuditEvent(DomainNode) {
    has at: float,
        actor_id: str,
        actor_name: str,
        actor_role: str,
        action: str,
        entity_type: str,
        entity_id: str,
        summary: str,
        reason: str = "",
        plant_ids: list[str] = [];
}
