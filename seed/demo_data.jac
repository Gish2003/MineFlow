"""Seeded, clearly-labelled DEMO dataset (fictional companies, simulated data).

`ensure_demo_seed()` is idempotent. It builds the catalog, plants, stock lots,
fleet, delivery sites and accounts, plus a handful of orders in different
workflow states so every persona has something to act on immediately:

  S1  limestone   IN_TRANSIT, last ping 7 min ago (shows last-known/offline)
  S2  dolomite    DELIVERED with proof photo, waiting for buyer acknowledgement
  S3  phosphate   COMPLETED with an OPEN quantity claim
  S4  dolomite    RESERVED, awaiting dispatcher approval/assignment
  S5  limestone   SCHEDULED (driver accepted, loader assigned)
  S6  silica      OFFERED to a driver, awaiting accept/reject
"""

import base64;
import struct;
import zlib;
import from core.model {
    DomainNode, MineFlowHub, Organization, HasOrg, Account, HasAccount, Mineral, HasMineral,
    GradeSpec, HasGrade, SpecParam, Plant, OperatesPlant, StockLot, HoldsLot,
    LoadingSlot, HasSlot, Truck, OwnsTruck, DeliverySite, HasSite, Order, HasOrder,
    OrderLine, HasLine, Shipment, DriverOffer, HasOffer, LocationPing, HasPing,
    Evidence, HasEvidence, EvidenceBlob, HasBlob, TimelineEvent, HasEvent, Claim,
    HasClaim, LedgerEntry, HasLedgerEntry, DelayNotice, HasDelay, ProductionPlan,
    HasProductionPlan, QualityRecord, HasQualityRecord
}
import from core.enums {
    Role, OrgType, OrderStatus, ShipmentStatus, LotQuality, TruckStatus,
    OfferStatus, PingSource, EvidenceKind, AckMethod, ClaimType, ClaimStatus,
    LedgerKind, PaymentStatus, DelayKind, SlotStatus
}
import from core.hub { get_hub, get_plant, mineral_by_code, grade_by_code }
import from core.util { now, new_ref, sha256_hex }
import from core.config { settings }
import from core.geo { route_points }
import from catalog.grades { resolve_spec }
import from scheduling.slots { ensure_slots, plant_slots, slot_problems, day_start, HOUR, DAY }
import from reservations.reserve { reserve_line, consume_for_loading }
import from seed.personas { PERSONAS, PersonaDef }

obj GradeDef {
    has code: str,
        name: str,
        description: str,
        params: list[SpecParam];
}

obj MineralDef {
    has code: str,
        name: str,
        description: str,
        bodies: list[str],
        grades: list[GradeDef];
}

obj PlantDef {
    has code: str,
        name: str,
        org_code: str,
        lat: float,
        lng: float,
        region: str,
        minerals: list[str],
        bays: int = 2,
        rate_tph: float = 120.0,
        buffer_min: int = 15,
        fee_per_t: float = 150.0;
}

obj LotDef {
    has plant_code: str,
        code: str,
        mineral: str,
        grade: str,
        stockpile: str,
        measured_t: float,
        quality: LotQuality,
        assay: dict[str, float],
        price: float;
}

obj TruckDef {
    has plate: str,
        payload_t: float,
        body: str,
        status: TruckStatus = TruckStatus.AVAILABLE;
}

obj SiteDef {
    has org_code: str,
        name: str,
        address: str,
        lat: float,
        lng: float,
        contact: str;
}

glob ORGS: list[list[str]] = [
    ["PLAT", "MineFlow Platform", "PLATFORM", "Island-wide"],
    ["SRM", "Serendib Minerals PLC", "PRODUCER", "Central / North Western"],
    ["CSL", "Coastline Sands & Silica Ltd", "PRODUCER", "Eastern / North Western"],
    ["MHN", "MineFlow Haulage Network", "LOGISTICS", "Island-wide"],
    ["KCW", "Kelani Cement Works", "BUYER", "Western"],
    ["UAF", "Uva Agro Fertilizers", "BUYER", "Uva / North Western"]
];

glob CATALOG: list[MineralDef] = [
    MineralDef(code="LIMESTONE", name="Limestone", description="Crushed limestone for cement and lime.", bodies=["TIPPER", "TARP_TIPPER"], grades=[
        GradeDef(code="LS-CEM", name="Cement-grade limestone", description="CaCO3 >= 90 %, MgO <= 3 %", params=[SpecParam(key="CaCO3", label="CaCO3", min_value=90.0), SpecParam(key="MgO", label="MgO", max_value=3.0)]),
        GradeDef(code="LS-HP", name="High-purity limestone", description="CaCO3 >= 95 %, SiO2 <= 1.5 %", params=[SpecParam(key="CaCO3", label="CaCO3", min_value=95.0), SpecParam(key="SiO2", label="SiO2", max_value=1.5)])
    ]),
    MineralDef(code="DOLOMITE", name="Dolomite", description="Agricultural and industrial dolomite.", bodies=["TIPPER", "TARP_TIPPER", "COVERED_TIPPER"], grades=[
        GradeDef(code="DOL-AG", name="Agricultural dolomite", description="MgO >= 18 %, CaO >= 28 %", params=[SpecParam(key="MgO", label="MgO", min_value=18.0), SpecParam(key="CaO", label="CaO", min_value=28.0)]),
        GradeDef(code="DOL-IND", name="Industrial dolomite", description="MgO >= 20 %, SiO2 <= 2 %", params=[SpecParam(key="MgO", label="MgO", min_value=20.0), SpecParam(key="SiO2", label="SiO2", max_value=2.0)])
    ]),
    MineralDef(code="ROCK_PHOSPHATE", name="Rock phosphate", description="Apatite rock phosphate for fertilizer blending.", bodies=["COVERED_TIPPER", "TARP_TIPPER"], grades=[
        GradeDef(code="RP28", name="Rock phosphate 28", description="P2O5 >= 28 %, moisture <= 3 %", params=[SpecParam(key="P2O5", label="P2O5", min_value=28.0), SpecParam(key="MOISTURE", label="Moisture", max_value=3.0)]),
        GradeDef(code="RP32", name="Rock phosphate 32 (premium)", description="P2O5 >= 32 %, moisture <= 2.5 %", params=[SpecParam(key="P2O5", label="P2O5", min_value=32.0), SpecParam(key="MOISTURE", label="Moisture", max_value=2.5)])
    ]),
    MineralDef(code="ILMENITE", name="Ilmenite (mineral sands)", description="Heavy mineral sand concentrate.", bodies=["COVERED_TIPPER"], grades=[
        GradeDef(code="ILM52", name="Ilmenite 52", description="TiO2 >= 52 %, Cr2O3 <= 0.1 %", params=[SpecParam(key="TiO2", label="TiO2", min_value=52.0), SpecParam(key="Cr2O3", label="Cr2O3", max_value=0.1)]),
        GradeDef(code="ILM54", name="Ilmenite 54", description="TiO2 >= 54 %, Cr2O3 <= 0.08 %", params=[SpecParam(key="TiO2", label="TiO2", min_value=54.0), SpecParam(key="Cr2O3", label="Cr2O3", max_value=0.08)])
    ]),
    MineralDef(code="SILICA_SAND", name="Silica sand", description="Washed silica sand for glass and foundry.", bodies=["COVERED_TIPPER"], grades=[
        GradeDef(code="SS-GL", name="Glass-grade silica", description="SiO2 >= 99.5 %, Fe2O3 <= 0.03 %", params=[SpecParam(key="SiO2", label="SiO2", min_value=99.5), SpecParam(key="Fe2O3", label="Fe2O3", max_value=0.03)]),
        GradeDef(code="SS-FD", name="Foundry silica", description="SiO2 >= 98 %, Fe2O3 <= 0.1 %", params=[SpecParam(key="SiO2", label="SiO2", min_value=98.0), SpecParam(key="Fe2O3", label="Fe2O3", max_value=0.1)])
    ])
];

glob PLANTS: list[PlantDef] = [
    PlantDef(code="EPW", name="Eppawala Rock Phosphate Works", org_code="SRM", lat=8.1430, lng=80.4040, region="North Central", minerals=["ROCK_PHOSPHATE"], bays=2, rate_tph=110.0, buffer_min=20, fee_per_t=160.0),
    PlantDef(code="MDQ", name="Matale Dolomite Quarry", org_code="SRM", lat=7.4675, lng=80.6234, region="Central", minerals=["DOLOMITE"], bays=2, rate_tph=120.0, buffer_min=15, fee_per_t=140.0),
    PlantDef(code="PLP", name="Puttalam Limestone Plant", org_code="SRM", lat=8.0362, lng=79.8283, region="North Western", minerals=["LIMESTONE", "DOLOMITE"], bays=3, rate_tph=150.0, buffer_min=10, fee_per_t=130.0),
    PlantDef(code="PMS", name="Pulmoddai Mineral Sands", org_code="CSL", lat=8.9330, lng=81.0090, region="Eastern", minerals=["ILMENITE"], bays=2, rate_tph=90.0, buffer_min=25, fee_per_t=180.0),
    PlantDef(code="NSP", name="Nattandiya Silica Plant", org_code="CSL", lat=7.4086, lng=79.8687, region="North Western", minerals=["SILICA_SAND"], bays=2, rate_tph=100.0, buffer_min=15, fee_per_t=150.0)
];

glob LOTS: list[LotDef] = [
    LotDef(plant_code="EPW", code="EPW-RP28-A1", mineral="ROCK_PHOSPHATE", grade="RP28", stockpile="Stockpile A1", measured_t=420.0, quality=LotQuality.VERIFIED, assay={"P2O5": 29.4, "MOISTURE": 2.1}, price=18500.0),
    LotDef(plant_code="EPW", code="EPW-RP28-A2", mineral="ROCK_PHOSPHATE", grade="RP28", stockpile="Stockpile A2", measured_t=65.0, quality=LotQuality.PENDING, assay={"P2O5": 28.6, "MOISTURE": 2.8}, price=18200.0),
    LotDef(plant_code="EPW", code="EPW-RP32-P1", mineral="ROCK_PHOSPHATE", grade="RP32", stockpile="Premium bay P1", measured_t=140.0, quality=LotQuality.VERIFIED, assay={"P2O5": 32.8, "MOISTURE": 1.9}, price=24800.0),
    LotDef(plant_code="MDQ", code="MDQ-AG-01", mineral="DOLOMITE", grade="DOL-AG", stockpile="Pit 2 stock", measured_t=610.0, quality=LotQuality.VERIFIED, assay={"MgO": 19.5, "CaO": 30.1}, price=6200.0),
    LotDef(plant_code="MDQ", code="MDQ-IND-01", mineral="DOLOMITE", grade="DOL-IND", stockpile="Washed bay 1", measured_t=95.0, quality=LotQuality.QUALITY_HOLD, assay={"MgO": 20.4, "SiO2": 2.6}, price=8900.0),
    LotDef(plant_code="MDQ", code="MDQ-IND-02", mineral="DOLOMITE", grade="DOL-IND", stockpile="Washed bay 2", measured_t=180.0, quality=LotQuality.VERIFIED, assay={"MgO": 21.1, "SiO2": 1.4}, price=9100.0),
    LotDef(plant_code="PLP", code="PLP-CEM-N1", mineral="LIMESTONE", grade="LS-CEM", stockpile="North yard", measured_t=1250.0, quality=LotQuality.VERIFIED, assay={"CaCO3": 91.8, "MgO": 2.2}, price=4200.0),
    LotDef(plant_code="PLP", code="PLP-CEM-S1", mineral="LIMESTONE", grade="LS-CEM", stockpile="South yard", measured_t=300.0, quality=LotQuality.PENDING, assay={"CaCO3": 90.4, "MgO": 2.9}, price=4050.0),
    LotDef(plant_code="PLP", code="PLP-HP-C1", mineral="LIMESTONE", grade="LS-HP", stockpile="Crusher bay", measured_t=160.0, quality=LotQuality.VERIFIED, assay={"CaCO3": 96.2, "SiO2": 1.1}, price=7400.0),
    LotDef(plant_code="PLP", code="PLP-DOL-W1", mineral="DOLOMITE", grade="DOL-AG", stockpile="West yard", measured_t=220.0, quality=LotQuality.VERIFIED, assay={"MgO": 18.6, "CaO": 29.2}, price=6600.0),
    LotDef(plant_code="PMS", code="PMS-ILM52-D1", mineral="ILMENITE", grade="ILM52", stockpile="Dryer stock", measured_t=380.0, quality=LotQuality.VERIFIED, assay={"TiO2": 52.9, "Cr2O3": 0.08}, price=31500.0),
    LotDef(plant_code="PMS", code="PMS-ILM54-M1", mineral="ILMENITE", grade="ILM54", stockpile="Magnetic fraction", measured_t=120.0, quality=LotQuality.VERIFIED, assay={"TiO2": 54.6, "Cr2O3": 0.06}, price=36500.0),
    LotDef(plant_code="NSP", code="NSP-GL-S1", mineral="SILICA_SAND", grade="SS-GL", stockpile="Silo 1", measured_t=240.0, quality=LotQuality.VERIFIED, assay={"SiO2": 99.62, "Fe2O3": 0.025}, price=12800.0),
    LotDef(plant_code="NSP", code="NSP-FD-Y1", mineral="SILICA_SAND", grade="SS-FD", stockpile="Open yard", measured_t=520.0, quality=LotQuality.VERIFIED, assay={"SiO2": 98.4, "Fe2O3": 0.07}, price=7800.0)
];

glob TRUCKS: list[TruckDef] = [
    TruckDef(plate="WP LB-4521", payload_t=30.0, body="COVERED_TIPPER"),
    TruckDef(plate="WP LC-7788", payload_t=35.0, body="TARP_TIPPER"),
    TruckDef(plate="NW LD-2210", payload_t=40.0, body="TIPPER"),
    TruckDef(plate="CP LE-9034", payload_t=30.0, body="COVERED_TIPPER"),
    TruckDef(plate="NC LF-1187", payload_t=25.0, body="TARP_TIPPER"),
    TruckDef(plate="EP LG-5560", payload_t=40.0, body="COVERED_TIPPER", status=TruckStatus.MAINTENANCE)
];

glob SITES: list[SiteDef] = [
    SiteDef(org_code="KCW", name="Wattala Cement Mill", address="Hekitta Road, Wattala", lat=6.9890, lng=79.8920, contact="Gate office - shift supervisor"),
    SiteDef(org_code="KCW", name="Galle Port Bulk Terminal", address="Harbour Road, Galle", lat=6.0300, lng=80.2160, contact="Terminal receiving clerk"),
    SiteDef(org_code="UAF", name="Badulla Blending Plant", address="Passara Road, Badulla", lat=6.9895, lng=81.0550, contact="Stores officer"),
    SiteDef(org_code="UAF", name="Kurunegala Distribution Depot", address="Puttalam Road, Kurunegala", lat=7.4863, lng=80.3647, contact="Depot manager")
];

# ------------------------------------------------------------ placeholders
def _png_chunk(tag: bytes, data: bytes) -> bytes {
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff);
}

"""A small generated PNG used as a clearly-labelled placeholder 'photo'."""
def placeholder_png(w: int, h: int, r: int, g: int, b: int) -> bytes {
    raw = bytearray();
    for y in range(h) {
        raw.append(0);
        for x in range(w) {
            border = x < 4 or y < 4 or x >= w - 4 or y >= h - 4;
            stripe = ((x + y) // 12) % 2 == 0;
            shade = 0.55 if border else (0.92 if stripe else 0.78);
            raw.extend(bytes([int(r * shade), int(g * shade), int(b * shade)]));
        }
    }
    header = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0);
    return bytes([137, 80, 78, 71, 13, 10, 26, 10]) + _png_chunk(b"IHDR", header) + _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + _png_chunk(b"IEND", b"");
}

# ------------------------------------------------------------ builders
def _attach_evidence(owner: DomainNode, kind: EvidenceKind, owner_type: str, owner_id: str, filename: str, data: bytes, who: Account, at: float, note: str) -> Evidence {
    ev = Evidence(
        kind=kind,
        owner_type=owner_type,
        owner_id=owner_id,
        filename=filename,
        mime="image/png",
        size_bytes=len(data),
        sha256=sha256_hex(data),
        uploaded_by=jid(who),
        uploaded_by_name=who.display_name,
        uploaded_role=str(who.role),
        note=note,
        created_at=at
    );
    owner +>:HasEvidence():+> ev;
    ev +>:HasBlob():+> EvidenceBlob(data_b64=base64.b64encode(data).decode("ascii"));
    return ev;
}

def _event(o: Order, at: float, kind: str, title: str, detail: str = "", shipment_id: str = "", actor: str = "MineFlow (seed)", role: str = "SYSTEM") {
    o +>:HasEvent():+> TimelineEvent(order_id=jid(o), at=at, kind=kind, title=title, detail=detail, shipment_id=shipment_id, actor_name=actor, actor_role=role);
}

def _ledger(hub: MineFlowHub, kind: LedgerKind, sh: Shipment, o: Order, payee_id: str, payee_name: str, amount: float, status: PaymentStatus, at: float, note: str) {
    hub +>:HasLedgerEntry():+> LedgerEntry(
        kind=kind,
        shipment_id=jid(sh),
        order_id=jid(o),
        payee_id=payee_id,
        payee_name=payee_name,
        amount=round(amount, 2),
        currency=settings().currency,
        status=status,
        note=note,
        history=["PENDING (seed)"] if status == PaymentStatus.PENDING else ["PENDING (seed)", str(status) + " (seed)"],
        created_at=at,
        updated_at=at
    );
}

def _new_order(hub: MineFlowHub, buyer: Account, site: DeliverySite, start: float, end: float, created: float, notes: str) -> Order {
    o = Order(
        ref=new_ref("ORD"),
        buyer_id=jid(buyer),
        buyer_org_id=buyer.org_id,
        site_name=site.name,
        site_address=site.address,
        dest_lat=site.lat,
        dest_lng=site.lng,
        site_contact=site.contact_name,
        window_start=start,
        window_end=end,
        notes=notes,
        created_at=created,
        updated_at=created
    );
    hub +>:HasOrder():+> o;
    return o;
}

def _new_line(o: Order, n: int, mineral: str, grade_code: str, qty: float) -> OrderLine {
    g = grade_by_code(mineral, grade_code);
    spec = resolve_spec(g, []) if g is not None else [];
    line = OrderLine(order_id=jid(o), line_no=n, mineral_code=mineral, grade_code=grade_code, quantity_t=qty, spec=spec);
    o +>:HasLine():+> line;
    return line;
}

"""A slot dedicated to a seeded historical load (outside the live slot grid)."""
def _past_slot(p: Plant, start: float) -> LoadingSlot {
    s = LoadingSlot(plant_id=jid(p), bay=9, start_ts=start, end_ts=start + HOUR);
    p +>:HasSlot():+> s;
    return s;
}

def _future_slot(p: Plant, after: float) -> LoadingSlot | None {
    for s in plant_slots(p, after, after + 3 * DAY) {
        if s.start_ts >= after and not slot_problems(p, s) {
            return s;
        }
    }
    return None;
}

def _accept_offer(sh: Shipment, driver: Account, truck: Truck, pay: float, at: float) {
    offer = DriverOffer(shipment_id=jid(sh), driver_id=jid(driver), truck_id=jid(truck), status=OfferStatus.ACCEPTED, pay_amount=pay, created_at=at - 1800, responded_at=at);
    sh +>:HasOffer():+> offer;
    sh.driver_id = jid(driver);
    sh.truck_id = jid(truck);
}

def driver_pay(km: float) -> float {
    cfg = settings();
    return round(cfg.driver_base_pay + km * cfg.driver_rate_per_km, 2);
}

# ------------------------------------------------------------ entry point
"""Mineral and grade reference catalog (not demo data; created when missing)."""
def ensure_reference_catalog {
    hub = get_hub();
    for md in CATALOG {
        if mineral_by_code(md.code) is not None {
            continue;
        }
        m = Mineral(code=md.code, name=md.name, description=md.description, allowed_bodies=md.bodies);
        hub +>:HasMineral():+> m;
        for gd in md.grades {
            m +>:HasGrade():+> GradeSpec(code=gd.code, mineral_code=md.code, name=gd.name, params=gd.params, description=gd.description);
        }
    }
}

def ensure_demo_seed -> bool {
    hub = get_hub();
    if hub.seeded_at > 0 {
        return False;
    }
    seed_all(hub);
    hub.seeded_at = now();
    hub.scenario = "sri-lanka-demo-v1";
    return True;
}

def seed_all(hub: MineFlowHub) {
    t = now();
    orgs: dict[str, Organization] = {};
    for row in ORGS {
        o = Organization(code=row[0], name=row[1], org_type=OrgType(row[2]), region=row[3]);
        hub +>:HasOrg():+> o;
        orgs[row[0]] = o;
    }
    ensure_reference_catalog();
    plants: dict[str, Plant] = {};
    for pd in PLANTS {
        p = Plant(code=pd.code, name=pd.name, org_id=jid(orgs[pd.org_code]), lat=pd.lat, lng=pd.lng, region=pd.region, minerals=pd.minerals, bays=pd.bays, loader_rate_tph=pd.rate_tph, readiness_buffer_min=pd.buffer_min, loading_fee_per_t=pd.fee_per_t);
        orgs[pd.org_code] +>:OperatesPlant():+> p;
        plants[pd.code] = p;
    }
    lots: dict[str, StockLot] = {};
    for ld in LOTS {
        p = plants[ld.plant_code];
        lot = StockLot(code=ld.code, plant_id=jid(p), mineral_code=ld.mineral, grade_code=ld.grade, stockpile=ld.stockpile, measured_t=ld.measured_t, quality=ld.quality, assay=ld.assay, price_per_t=ld.price, updated_at=t);
        p +>:HoldsLot():+> lot;
        lots[ld.code] = lot;
        if ld.quality != LotQuality.PENDING {
            lot +>:HasQualityRecord():+> QualityRecord(
                lot_id=jid(lot), lab="Serendib Central Lab (seeded)", tested_at=t - 5 * DAY,
                results=ld.assay, verdict=ld.quality, certificate_no="QC-" + ld.code,
                notes="Seeded inspection record"
            );
        }
    }
    trucks: dict[str, Truck] = {};
    for td in TRUCKS {
        tr = Truck(plate=td.plate, org_id=jid(orgs["MHN"]), payload_t=td.payload_t, body_type=td.body, status=td.status, note="Under brake service" if td.status == TruckStatus.MAINTENANCE else "");
        orgs["MHN"] +>:OwnsTruck():+> tr;
        trucks[td.plate] = tr;
    }
    sites: dict[str, DeliverySite] = {};
    for sd in SITES {
        s = DeliverySite(org_id=jid(orgs[sd.org_code]), name=sd.name, address=sd.address, lat=sd.lat, lng=sd.lng, contact_name=sd.contact);
        orgs[sd.org_code] +>:HasSite():+> s;
        sites[sd.name] = s;
    }
    people: dict[str, Account] = {};
    for pdef in PERSONAS {
        acct = Account(
            email=pdef.email,
            display_name=pdef.display_name,
            role=pdef.role,
            org_id=jid(orgs[pdef.org_code]),
            persona_key=pdef.key,
            plant_ids=[jid(plants[c]) for c in pdef.plant_codes],
            dispatch_plant_ids=[jid(plants[c]) for c in pdef.dispatch_plant_codes],
            license_class=pdef.license_class,
            home_lat=pdef.home_lat,
            home_lng=pdef.home_lng,
            shift_start_hour=pdef.shift_start_hour,
            shift_end_hour=pdef.shift_end_hour,
            created_at=t
        );
        hub +>:HasAccount():+> acct;
        people[pdef.key] = acct;
    }
    for p in plants.values() {
        ensure_slots(p, 3);
    }
    plants["MDQ"] +>:HasDelay():+> DelayNotice(
        plant_id=jid(plants["MDQ"]), kind=DelayKind.EQUIPMENT, severity="MEDIUM",
        start_ts=day_start(t) + DAY + 13 * HOUR, end_ts=day_start(t) + DAY + 16 * HOUR,
        description="Front-end loader scheduled maintenance (seeded)", created_by=jid(people["manager"]), created_at=t
    );
    plants["EPW"] +>:HasProductionPlan():+> ProductionPlan(
        plant_id=jid(plants["EPW"]), mineral_code="ROCK_PHOSPHATE", grade_code="RP32",
        expected_t=200.0, expected_at=day_start(t) + 4 * DAY + 10 * HOUR, note="Premium screening run (seeded)"
    );
    _seed_orders(hub, people, plants, lots, trucks, sites, t);
}

def _seed_orders(
    hub: MineFlowHub,
    people: dict[str, Account],
    plants: dict[str, Plant],
    lots: dict[str, StockLot],
    trucks: dict[str, Truck],
    sites: dict[str, DeliverySite],
    t: float
) {
    nadeesha = people["buyer"];
    ruwan = people["buyer2"];
    mahesh = people["driver"];
    pradeep = people["driver2"];
    lahiru = people["driver3"];
    sunil = people["loader"];
    chaminda = people["loader2"];
    roshan = people["staff-loader-mdq"];
    dinesh = people["staff-loader-nsp"];

    # S1 - limestone in transit from Puttalam, pings stopped 7 minutes ago
    site = sites["Wattala Cement Mill"];
    o1 = _new_order(hub, nadeesha, site, t + 1 * HOUR, t + 5 * HOUR, t - 6 * HOUR, "Seeded: in-transit load");
    l1 = _new_line(o1, 1, "LIMESTONE", "LS-CEM", 30.0);
    p = plants["PLP"];
    s1 = reserve_line(o1, l1, lots["PLP-CEM-N1"], _past_slot(p, t - 2.5 * HOUR));
    _accept_offer(s1, mahesh, trucks["NW LD-2210"], driver_pay(s1.distance_km), t - 4 * HOUR);
    s1.loader_id = jid(sunil);
    s1.driver_checked_in_at = t - 2.6 * HOUR;
    s1.loader_checked_in_at = t - 2.6 * HOUR;
    s1.verified_at = t - 2.5 * HOUR;
    s1.loading_started_at = t - 2.45 * HOUR;
    s1.loading_ended_at = t - 2.2 * HOUR;
    s1.loaded_qty_t = 30.2;
    s1.load_ticket_no = "PLP-T-20431";
    s1.ticket_confirmed_at = t - 2.15 * HOUR;
    s1.departed_at = t - 2.1 * HOUR;
    consume_for_loading(s1, 30.2);
    s1.status = ShipmentStatus.IN_TRANSIT;
    trucks["NW LD-2210"].status = TruckStatus.IN_USE;
    route = route_points(p.lat, p.lng, site.lat, site.lng, 40);
    for i in range(0, 26) {
        pt = route[i];
        s1 +>:HasPing():+> LocationPing(shipment_id=jid(s1), lat=pt[0], lng=pt[1], accuracy_m=25.0, source=PingSource.SIMULATED, at=t - 2.1 * HOUR + i * 420.0 - 7 * 60);
    }
    o1.status = OrderStatus.IN_PROGRESS;
    _event(o1, t - 6 * HOUR, "ORDER", "Order placed", "30 t cement-grade limestone");
    _event(o1, t - 5.8 * HOUR, "RESERVED", "Stock and slot reserved at Puttalam Limestone Plant");
    _event(o1, t - 4 * HOUR, "ASSIGNED", "Driver Mahesh Gunawardena accepted (NW LD-2210)", "", jid(s1));
    _event(o1, t - 2.2 * HOUR, "LOADED", "Loaded 30.2 t - ticket PLP-T-20431", "", jid(s1));
    _event(o1, t - 2.1 * HOUR, "DEPARTED", "Truck departed for Wattala", "", jid(s1));
    _ledger(hub, LedgerKind.LOADER_FEE, s1, o1, jid(sunil), sunil.display_name, 30.2 * p.loading_fee_per_t, PaymentStatus.PENDING, t - 2.2 * HOUR, "Loading service fee");

    # S2 - dolomite delivered to Galle, waiting for buyer acknowledgement
    site = sites["Galle Port Bulk Terminal"];
    p = plants["MDQ"];
    o2 = _new_order(hub, nadeesha, site, t - 3 * HOUR, t + 1 * HOUR, t - 20 * HOUR, "Seeded: delivered, awaiting acknowledgement");
    l2 = _new_line(o2, 1, "DOLOMITE", "DOL-AG", 25.0);
    s2 = reserve_line(o2, l2, lots["MDQ-AG-01"], _past_slot(p, t - 7 * HOUR));
    _accept_offer(s2, pradeep, trucks["WP LC-7788"], driver_pay(s2.distance_km), t - 12 * HOUR);
    s2.loader_id = jid(roshan);
    s2.driver_checked_in_at = t - 7.1 * HOUR;
    s2.loader_checked_in_at = t - 7.1 * HOUR;
    s2.verified_at = t - 7 * HOUR;
    s2.loading_started_at = t - 6.95 * HOUR;
    s2.loading_ended_at = t - 6.7 * HOUR;
    s2.loaded_qty_t = 25.0;
    s2.load_ticket_no = "MDQ-T-88310";
    s2.ticket_confirmed_at = t - 6.65 * HOUR;
    s2.departed_at = t - 6.6 * HOUR;
    s2.arrived_at = t - 0.9 * HOUR;
    s2.unloaded_at = t - 0.7 * HOUR;
    s2.handover_note = "Unloaded at bay 3; delivery note signed by receiving clerk (seeded).";
    s2.handover_recorded_at = t - 0.65 * HOUR;
    consume_for_loading(s2, 25.0);
    s2.status = ShipmentStatus.DELIVERED;
    _attach_evidence(s2, EvidenceKind.UNLOADING_PHOTO, "SHIPMENT", jid(s2), "unloading-bay3-placeholder.png", placeholder_png(160, 110, 150, 140, 120), pradeep, t - 0.7 * HOUR, "Seeded placeholder image - not a real photo");
    o2.status = OrderStatus.DELIVERED;
    _event(o2, t - 20 * HOUR, "ORDER", "Order placed", "25 t agricultural dolomite");
    _event(o2, t - 6.7 * HOUR, "LOADED", "Loaded 25.0 t - ticket MDQ-T-88310", "", jid(s2));
    _event(o2, t - 0.65 * HOUR, "DELIVERED", "Unloaded at Galle Port Bulk Terminal - awaiting your acknowledgement", "", jid(s2));
    _ledger(hub, LedgerKind.LOADER_FEE, s2, o2, jid(roshan), roshan.display_name, 25.0 * p.loading_fee_per_t, PaymentStatus.APPROVED, t - 6.7 * HOUR, "Loading service fee");

    # S3 - phosphate completed yesterday with an open quantity claim
    site = sites["Badulla Blending Plant"];
    p = plants["EPW"];
    o3 = _new_order(hub, ruwan, site, t - 28 * HOUR, t - 20 * HOUR, t - 50 * HOUR, "Seeded: completed with claim");
    l3 = _new_line(o3, 1, "ROCK_PHOSPHATE", "RP28", 20.0);
    s3 = reserve_line(o3, l3, lots["EPW-RP28-A1"], _past_slot(p, t - 30 * HOUR));
    _accept_offer(s3, pradeep, trucks["WP LB-4521"], driver_pay(s3.distance_km), t - 40 * HOUR);
    s3.loader_id = jid(chaminda);
    s3.verified_at = t - 30 * HOUR;
    s3.loading_started_at = t - 29.9 * HOUR;
    s3.loading_ended_at = t - 29.7 * HOUR;
    s3.loaded_qty_t = 20.0;
    s3.load_ticket_no = "EPW-T-55102";
    s3.ticket_confirmed_at = t - 29.6 * HOUR;
    s3.departed_at = t - 29.5 * HOUR;
    s3.unloaded_at = t - 23 * HOUR;
    s3.handover_note = "Unloaded at stores (seeded).";
    s3.handover_recorded_at = t - 23 * HOUR;
    s3.ack_method = AckMethod.IN_APP;
    s3.acknowledged_at = t - 22.5 * HOUR;
    s3.received_qty_t = 18.9;
    s3.completed_at = t - 22.5 * HOUR;
    consume_for_loading(s3, 20.0);
    s3.status = ShipmentStatus.COMPLETED;
    _attach_evidence(s3, EvidenceKind.UNLOADING_PHOTO, "SHIPMENT", jid(s3), "badulla-unload-placeholder.png", placeholder_png(160, 110, 120, 130, 150), pradeep, t - 23 * HOUR, "Seeded placeholder image - not a real photo");
    o3.status = OrderStatus.DISPUTED;
    claim = Claim(
        ref=new_ref("CLM"), order_id=jid(o3), shipment_id=jid(s3), claim_type=ClaimType.QUANTITY,
        description="Weighbridge at Badulla recorded 18.9 t against a 20.0 t load ticket (seeded).",
        plant_id=jid(p), lot_id=s3.lot_id, qty_expected_t=20.0, qty_received_t=18.9,
        created_by=jid(ruwan), created_at=t - 22 * HOUR, updated_at=t - 22 * HOUR
    );
    hub +>:HasClaim():+> claim;
    o3 +>:HasClaim():+> claim;
    _event(o3, t - 50 * HOUR, "ORDER", "Order placed", "20 t rock phosphate RP28");
    _event(o3, t - 22.5 * HOUR, "ACKNOWLEDGED", "Receipt acknowledged in-app: 18.9 t received", "", jid(s3), ruwan.display_name, "BUYER");
    _event(o3, t - 22 * HOUR, "CLAIM", "Quantity claim opened", claim.description, jid(s3), ruwan.display_name, "BUYER");
    _ledger(hub, LedgerKind.LOADER_FEE, s3, o3, jid(chaminda), chaminda.display_name, 20.0 * p.loading_fee_per_t, PaymentStatus.PAID, t - 29.7 * HOUR, "Loading service fee");
    _ledger(hub, LedgerKind.DRIVER_PAYOUT, s3, o3, jid(pradeep), pradeep.display_name, driver_pay(s3.distance_km), PaymentStatus.APPROVED, t - 22.5 * HOUR, "Trip payout");
    _ledger(hub, LedgerKind.BUYER_INVOICE, s3, o3, ruwan.org_id, "Uva Agro Fertilizers", 20.0 * 18500.0, PaymentStatus.PENDING, t - 22.5 * HOUR, "Material + haulage invoice (held: open claim)");

    # S4 - dolomite reserved, waiting for dispatcher approval
    site = sites["Kurunegala Distribution Depot"];
    p = plants["MDQ"];
    tomorrow9 = day_start(t) + DAY + 9 * HOUR;
    o4 = _new_order(hub, ruwan, site, tomorrow9 + 2 * HOUR, tomorrow9 + 8 * HOUR, t - 2 * HOUR, "Seeded: reserved, awaiting dispatch");
    l4 = _new_line(o4, 1, "DOLOMITE", "DOL-IND", 30.0);
    slot4 = _future_slot(p, tomorrow9);
    if slot4 is not None {
        s4 = reserve_line(o4, l4, lots["MDQ-IND-02"], slot4);
        o4.status = OrderStatus.RESERVED;
        _event(o4, t - 2 * HOUR, "ORDER", "Order placed", "30 t industrial dolomite");
        _event(o4, t - 1.9 * HOUR, "RESERVED", "30 t reserved in lot MDQ-IND-02 with a loading slot at Matale", "", jid(s4));
    }

    # S5 - high-purity limestone scheduled at Puttalam (driver accepted, loader assigned)
    site = sites["Wattala Cement Mill"];
    p = plants["PLP"];
    slot5 = _future_slot(p, t + 1.5 * HOUR);
    if slot5 is not None {
        o5 = _new_order(hub, nadeesha, site, slot5.start_ts + 3 * HOUR, slot5.start_ts + 9 * HOUR, t - 26 * HOUR, "Seeded: scheduled load");
        l5 = _new_line(o5, 1, "LIMESTONE", "LS-HP", 20.0);
        s5 = reserve_line(o5, l5, lots["PLP-HP-C1"], slot5);
        _accept_offer(s5, lahiru, trucks["NC LF-1187"], driver_pay(s5.distance_km), t - 3 * HOUR);
        s5.loader_id = jid(sunil);
        s5.status = ShipmentStatus.SCHEDULED;
        o5.status = OrderStatus.DISPATCHING;
        _event(o5, t - 26 * HOUR, "ORDER", "Order placed", "20 t high-purity limestone");
        _event(o5, t - 3 * HOUR, "ASSIGNED", "Driver Lahiru Wijesinghe accepted (NC LF-1187); loader Sunil Rathnayake assigned", "", jid(s5));
    }

    # S6 - silica sand offered to Pradeep, waiting for a response
    p = plants["NSP"];
    slot6 = _future_slot(p, t + 3 * HOUR);
    if slot6 is not None {
        o6 = _new_order(hub, nadeesha, site, slot6.start_ts + 2 * HOUR, slot6.start_ts + 10 * HOUR, t - 5 * HOUR, "Seeded: offer pending");
        l6 = _new_line(o6, 1, "SILICA_SAND", "SS-GL", 15.0);
        s6 = reserve_line(o6, l6, lots["NSP-GL-S1"], slot6);
        offer = DriverOffer(shipment_id=jid(s6), driver_id=jid(pradeep), truck_id=jid(trucks["CP LE-9034"]), pay_amount=driver_pay(s6.distance_km), created_at=t - 0.5 * HOUR, note="Covered tipper required for glass-grade silica");
        s6 +>:HasOffer():+> offer;
        s6.loader_id = jid(dinesh);
        s6.status = ShipmentStatus.OFFERED;
        o6.status = OrderStatus.DISPATCHING;
        _event(o6, t - 5 * HOUR, "ORDER", "Order placed", "15 t glass-grade silica sand");
        _event(o6, t - 0.5 * HOUR, "OFFERED", "Delivery offered to driver Pradeep Senanayake", "", jid(s6));
    }
}
