"""Truck location sharing and tracking.

Connectivity is derived only from the age of the last confirmed ping
(LIVE / WEAK / OFFLINE / NO_DATA). It never changes delivery status: losing
signal does not fail or complete a delivery. Pings carry their source
(DEVICE GPS or SIMULATED route) and the UI labels them accordingly.
"""

import from core.model { Shipment, LocationPing, HasPing, Order }
import from core.enums { ShipmentStatus, ConnectivityStatus, PingSource, Role }
import from core.hub { get_shipment, get_order, get_plant, get_account, get_truck }
import from core.access { AppError, current_caller, require_roles, can_view_shipment, not_found, invalid, bad_state }
import from core.views { ActionResult }
import from core.config { settings }
import from core.geo { route_points, progress_fraction }
import from core.util { now }

obj TrackingView {
    has shipment_id: str,
        ref: str,
        status: str,
        connectivity: str,
        server_time: float,
        live_threshold_s: int,
        weak_threshold_s: int,
        last_lat: float = 0.0,
        last_lng: float = 0.0,
        last_at: float = 0.0,
        last_source: str = "",
        age_seconds: float = -1.0,
        plant_name: str = "",
        plant_lat: float = 0.0,
        plant_lng: float = 0.0,
        dest_name: str = "",
        dest_lat: float = 0.0,
        dest_lng: float = 0.0,
        route: list[list[float]] = [],
        trail: list[list[float]] = [],
        progress: float = 0.0,
        eta_ts: float = 0.0,
        distance_km: float = 0.0,
        driver_name: str = "",
        truck_plate: str = "",
        note: str = "Route and ETA are simulated estimates (straight-line x road factor). Positions marked SIMULATED come from the demo route simulator, not GPS.";
}

obj TrackingResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: TrackingView | None = None;
}

def last_ping(sh: Shipment) -> LocationPing | None {
    rows = [sh ->:HasPing:-> [?:LocationPing, -at]][:1];
    return rows[0] if rows else None;
}

def recent_pings(sh: Shipment, limit: int = 80) -> list[LocationPing] {
    rows = [sh ->:HasPing:-> [?:LocationPing, -at]][:limit];
    return list(reversed(rows));
}

def connectivity_of(sh: Shipment) -> ConnectivityStatus {
    last = last_ping(sh);
    if last is None {
        return ConnectivityStatus.NO_DATA;
    }
    cfg = settings();
    age = now() - last.at;
    if age <= cfg.live_seconds {
        return ConnectivityStatus.LIVE;
    }
    if age <= cfg.weak_seconds {
        return ConnectivityStatus.WEAK;
    }
    return ConnectivityStatus.OFFLINE;
}

def tracking_view(sh: Shipment) -> TrackingView {
    cfg = settings();
    o = get_order(sh.order_id);
    p = get_plant(sh.plant_id);
    driver = get_account(sh.driver_id);
    truck = get_truck(sh.truck_id);
    v = TrackingView(
        shipment_id=jid(sh), ref=sh.ref, status=str(sh.status), connectivity=str(connectivity_of(sh)),
        server_time=now(), live_threshold_s=cfg.live_seconds, weak_threshold_s=cfg.weak_seconds,
        distance_km=sh.distance_km, driver_name=driver.display_name if driver is not None else "",
        truck_plate=truck.plate if truck is not None else ""
    );
    if p is not None and o is not None {
        v.plant_name = p.name;
        v.plant_lat = p.lat;
        v.plant_lng = p.lng;
        v.dest_name = o.site_name;
        v.dest_lat = o.dest_lat;
        v.dest_lng = o.dest_lng;
        v.route = route_points(p.lat, p.lng, o.dest_lat, o.dest_lng, 40);
    }
    pings = recent_pings(sh);
    v.trail = [[pg.lat, pg.lng] for pg in pings];
    last = pings[-1] if pings else None;
    if last is not None {
        v.last_lat = last.lat;
        v.last_lng = last.lng;
        v.last_at = last.at;
        v.last_source = str(last.source);
        v.age_seconds = round(now() - last.at, 1);
        v.progress = progress_fraction(v.route, last.lat, last.lng) if v.route else 0.0;
        if sh.status == ShipmentStatus.IN_TRANSIT {
            remaining = max(0.0, 1.0 - v.progress) * sh.eta_minutes;
            v.eta_ts = last.at + remaining * 60.0;
        }
    } elif sh.status == ShipmentStatus.IN_TRANSIT and sh.departed_at > 0 {
        v.eta_ts = sh.departed_at + sh.eta_minutes * 60.0;
    }
    if sh.status in [ShipmentStatus.DELIVERED, ShipmentStatus.COMPLETED, ShipmentStatus.DISPUTED] {
        v.progress = 1.0;
    }
    return v;
}

def:protect get_tracking(shipment_id: str, poll_seq: int = 0) -> TrackingResult {
    _ = poll_seq;
    try {
        c = current_caller();
        sh = get_shipment(shipment_id);
        if sh is None or not can_view_shipment(c, sh) or c.has_role(Role.LOADER) {
            raise not_found("Shipment");
        }
        return TrackingResult(ok=True, data=tracking_view(sh));
    } except AppError as e {
        return TrackingResult(ok=False, code=e.code, message=e.message);
    }
}

"""Assigned driver shares a position while the load is on the truck."""
def:protect report_location(shipment_id: str, lat: float, lng: float, accuracy_m: float = 30.0, source: str = "DEVICE", nonce: int = 0) -> ActionResult {
    _ = nonce;
    try {
        c = require_roles([Role.DRIVER]);
        sh = get_shipment(shipment_id);
        if sh is None or sh.driver_id != c.account_id {
            raise not_found("Shipment");
        }
        if sh.status not in [ShipmentStatus.LOADED, ShipmentStatus.IN_TRANSIT] {
            raise bad_state("Location is only shared while the load is on the truck.");
        }
        if not (-90.0 <= lat and lat <= 90.0 and -180.0 <= lng and lng <= 180.0) or accuracy_m < 0 or accuracy_m > 10000 {
            raise invalid("Invalid coordinates.");
        }
        if source not in ["DEVICE", "SIMULATED"] {
            raise invalid("Unknown location source.");
        }
        last = last_ping(sh);
        t = now();
        if last is not None and t - last.at < 2.5 {
            return ActionResult(ok=True, id=jid(sh), message="throttled");
        }
        sh +>:HasPing():+> LocationPing(shipment_id=jid(sh), lat=round(lat, 6), lng=round(lng, 6), accuracy_m=round(accuracy_m, 1), source=PingSource(source), at=t);
        return ActionResult(ok=True, id=jid(sh), message="recorded");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
