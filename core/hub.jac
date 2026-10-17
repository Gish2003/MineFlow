"""Hub resolution and typed lookups on the shared operational graph."""

import from core.model {
    MineFlowHub, HubLink, HasOrg, HasAccount, HasMineral, HasGrade, OperatesPlant,
    HoldsLot, HasSlot, HasShift, OwnsTruck, HasSite, HasOrder, HasLine, HasShipment,
    HasReservation, HasOffer, HasException, HasLedgerEntry, HasAudit, HasClaim,
    Organization, Account, Mineral, GradeSpec, Plant, StockLot, LoadingSlot,
    LoaderShift, Truck, DeliverySite, Order, OrderLine, Shipment, Reservation,
    DriverOffer, ExceptionCase, LedgerEntry, AuditEvent, Claim, AgentRun, Evidence,
    EvidenceBlob, HasBlob
}

def get_hub -> MineFlowHub {
    found = [root.shared ->:HubLink:-> [?:MineFlowHub]];
    if found {
        return found[0];
    }
    hub = MineFlowHub();
    root.shared +>:HubLink():+> hub;
    return hub;
}

"""Type test that also accepts the same archetype loaded under the served app's
module name (the in-process test client rehydrates nodes that way)."""
def same_type(n: any, cls: type) -> bool {
    if n is None {
        return False;
    }
    return isinstance(n, cls) or type(n).__qualname__ == cls.__qualname__;
}

def fetch(node_id: str, cls: type) -> any {
    if not node_id or len(node_id) > 64 {
        return None;
    }
    try {
        n = jobj(node_id);
    } except Exception {
        return None;
    }
    return n if same_type(n, cls) else None;
}

def get_org(oid: str) -> Organization | None {
    n = fetch(oid, Organization);
    return None if n is None else n as Organization;
}

def get_account(aid: str) -> Account | None {
    n = fetch(aid, Account);
    return None if n is None else n as Account;
}

def get_plant(pid: str) -> Plant | None {
    n = fetch(pid, Plant);
    return None if n is None else n as Plant;
}

def get_lot(lid: str) -> StockLot | None {
    n = fetch(lid, StockLot);
    return None if n is None else n as StockLot;
}

def get_slot(sid: str) -> LoadingSlot | None {
    n = fetch(sid, LoadingSlot);
    return None if n is None else n as LoadingSlot;
}

def get_truck(tid: str) -> Truck | None {
    n = fetch(tid, Truck);
    return None if n is None else n as Truck;
}

def get_site(sid: str) -> DeliverySite | None {
    n = fetch(sid, DeliverySite);
    return None if n is None else n as DeliverySite;
}

def get_order(oid: str) -> Order | None {
    n = fetch(oid, Order);
    return None if n is None else n as Order;
}

def get_line(lid: str) -> OrderLine | None {
    n = fetch(lid, OrderLine);
    return None if n is None else n as OrderLine;
}

def get_shipment(sid: str) -> Shipment | None {
    n = fetch(sid, Shipment);
    return None if n is None else n as Shipment;
}

def get_reservation(rid: str) -> Reservation | None {
    n = fetch(rid, Reservation);
    return None if n is None else n as Reservation;
}

def get_offer(oid: str) -> DriverOffer | None {
    n = fetch(oid, DriverOffer);
    return None if n is None else n as DriverOffer;
}

def get_exception(eid: str) -> ExceptionCase | None {
    n = fetch(eid, ExceptionCase);
    return None if n is None else n as ExceptionCase;
}

def get_ledger_entry(eid: str) -> LedgerEntry | None {
    n = fetch(eid, LedgerEntry);
    return None if n is None else n as LedgerEntry;
}

def get_claim(cid: str) -> Claim | None {
    n = fetch(cid, Claim);
    return None if n is None else n as Claim;
}

def get_run(rid: str) -> AgentRun | None {
    n = fetch(rid, AgentRun);
    return None if n is None else n as AgentRun;
}

def get_evidence(eid: str) -> Evidence | None {
    n = fetch(eid, Evidence);
    return None if n is None else n as Evidence;
}

def blob_of(ev: Evidence) -> EvidenceBlob | None {
    blobs = [ev ->:HasBlob:-> [?:EvidenceBlob]];
    return blobs[0] if blobs else None;
}

# ----------------------------------------------------------- collections
def all_orgs -> list[Organization] {
    return [get_hub() ->:HasOrg:-> [?:Organization]];
}

def all_accounts -> list[Account] {
    return [get_hub() ->:HasAccount:-> [?:Account]];
}

def account_by_root(rid: str) -> Account | None {
    found = [get_hub() ->:HasAccount:-> [?:Account, root_id == rid]];
    return found[0] if found else None;
}

def account_by_persona(key: str) -> Account | None {
    found = [get_hub() ->:HasAccount:-> [?:Account, persona_key == key]];
    return found[0] if found else None;
}

def accounts_with_role(role_value: str) -> list[Account] {
    return [a for a in all_accounts() if a.role == role_value and a.active];
}

def all_minerals -> list[Mineral] {
    return [get_hub() ->:HasMineral:-> [?:Mineral]];
}

def mineral_by_code(code: str) -> Mineral | None {
    found = [get_hub() ->:HasMineral:-> [?:Mineral, code == code]];
    return found[0] if found else None;
}

def grades_of(m: Mineral) -> list[GradeSpec] {
    return [m ->:HasGrade:-> [?:GradeSpec]];
}

def grade_by_code(mineral_code: str, grade_code: str) -> GradeSpec | None {
    m = mineral_by_code(mineral_code);
    if m is None {
        return None;
    }
    found = [m ->:HasGrade:-> [?:GradeSpec, code == grade_code]];
    return found[0] if found else None;
}

def all_plants -> list[Plant] {
    plants: list[Plant] = [];
    for org in all_orgs() {
        plants = plants + [org ->:OperatesPlant:-> [?:Plant]];
    }
    return plants;
}

def lots_of(p: Plant) -> list[StockLot] {
    return [p ->:HoldsLot:-> [?:StockLot]];
}

def slots_of(p: Plant) -> list[LoadingSlot] {
    return [p ->:HasSlot:-> [?:LoadingSlot]];
}

def shifts_of(p: Plant) -> list[LoaderShift] {
    return [p ->:HasShift:-> [?:LoaderShift]];
}

def all_trucks -> list[Truck] {
    trucks: list[Truck] = [];
    for org in all_orgs() {
        trucks = trucks + [org ->:OwnsTruck:-> [?:Truck]];
    }
    return trucks;
}

def sites_of(org: Organization) -> list[DeliverySite] {
    return [org ->:HasSite:-> [?:DeliverySite]];
}

def all_orders -> list[Order] {
    return [get_hub() ->:HasOrder:-> [?:Order]];
}

def lines_of(o: Order) -> list[OrderLine] {
    return sorted([o ->:HasLine:-> [?:OrderLine]], key=lambda (l: OrderLine) { l.line_no; });
}

def shipments_of_line(l: OrderLine) -> list[Shipment] {
    return [l ->:HasShipment:-> [?:Shipment]];
}

def shipments_of_order(o: Order) -> list[Shipment] {
    out: list[Shipment] = [];
    for l in lines_of(o) {
        out = out + shipments_of_line(l);
    }
    return out;
}

def all_shipments -> list[Shipment] {
    return [get_hub() ->:HasShipment:-> [?:Shipment]];
}

def reservations_of_lot(lot: StockLot) -> list[Reservation] {
    return [lot ->:HasReservation:-> [?:Reservation]];
}

def reservations_of_line(l: OrderLine) -> list[Reservation] {
    return [l ->:HasReservation:-> [?:Reservation]];
}

def offers_of(s: Shipment) -> list[DriverOffer] {
    return [s ->:HasOffer:-> [?:DriverOffer]];
}

def all_exceptions -> list[ExceptionCase] {
    return [get_hub() ->:HasException:-> [?:ExceptionCase]];
}

def all_ledger -> list[LedgerEntry] {
    return [get_hub() ->:HasLedgerEntry:-> [?:LedgerEntry]];
}

def all_audit -> list[AuditEvent] {
    return [get_hub() ->:HasAudit:-> [?:AuditEvent]];
}

def all_claims -> list[Claim] {
    return [get_hub() ->:HasClaim:-> [?:Claim]];
}

def order_of_shipment(s: Shipment) -> Order | None {
    return get_order(s.order_id);
}

def name_of_account(aid: str) -> str {
    a = get_account(aid);
    return a.display_name if a is not None else "";
}

def name_of_plant(pid: str) -> str {
    p = get_plant(pid);
    return p.name if p is not None else "";
}
