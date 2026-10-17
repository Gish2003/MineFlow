"""Impact analysis when supply changes (quality hold, stock drop, plant
unavailable, loading delay): walk Plant -> lots -> HELD reservations to find the
not-yet-loaded shipments that can no longer be served as planned, move them to
EXCEPTION and open linked exceptions for the recovery workflow.
"""

import from core.model { Plant, StockLot, Reservation, HoldsLot, HasReservation, Shipment }
import from core.enums { ReservationStatus, ShipmentStatus, ExceptionType, OfferStatus }
import from core.hub { get_shipment, get_slot, get_order, offers_of }
import from core.access { Caller }
import from core.state_machines { can_move, SHIPMENT_FLOW }
import from core.audit { notify, notify_order_buyer }
import from core.util { now }
import from orders.rollup { refresh_order_status }
import from dispatch.exceptions { raise_exception }

glob PRE_LOADING: list[str] = ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "AWAITING_LOADING"];

walker:priv ExceptionImpactScanner {
    has lot_ids: list[str] = [],
        all_lots: bool = False,
        window_start: float = 0.0,
        window_end: float = 0.0,
        affected: list[str] = [];

    can start with Plant entry {
        visit [here ->:HoldsLot:-> [?:StockLot]];
    }

    can on_lot with StockLot entry {
        if not self.all_lots and jid(here) not in self.lot_ids {
            skip;
        }
        visit [here ->:HasReservation:-> [?:Reservation]];
    }

    can on_reservation with Reservation entry {
        if here.status != ReservationStatus.HELD or not here.shipment_id or here.shipment_id in self.affected {
            skip;
        }
        sh = get_shipment(here.shipment_id);
        if sh is None or str(sh.status) not in PRE_LOADING {
            skip;
        }
        if self.window_end > 0 {
            slot = get_slot(sh.slot_id);
            if slot is None or slot.end_ts <= self.window_start or slot.start_ts >= self.window_end {
                skip;
            }
        }
        self.affected.append(here.shipment_id);
    }
}

def scan_plant(p: Plant, lot_ids: list[str], all_lots: bool, window_start: float = 0.0, window_end: float = 0.0) -> list[str] {
    w = p spawn ExceptionImpactScanner(lot_ids=lot_ids, all_lots=all_lots, window_start=window_start, window_end=window_end);
    return w.affected;
}

"""Move affected shipments to EXCEPTION and open linked exceptions."""
def flag_shipments(c: Caller, shipment_ids: list[str], ex_type: ExceptionType, severity: str, summary: str, detail: str) -> int {
    count = 0;
    for sid in shipment_ids {
        sh = get_shipment(sid);
        if sh is None or not can_move(SHIPMENT_FLOW, str(sh.status), "EXCEPTION") {
            continue;
        }
        for off in offers_of(sh) {
            if off.status == OfferStatus.OFFERED {
                off.status = OfferStatus.WITHDRAWN;
                notify(off.driver_id, "warning", "Offer withdrawn: " + sh.ref, summary);
            }
        }
        sh.status = ShipmentStatus.EXCEPTION;
        sh.exception_note = summary;
        sh.updated_at = now();
        raise_exception(ex_type, severity, sh.ref + ": " + summary, detail, sh, sh.plant_id, c.account_id);
        if sh.driver_id {
            notify(sh.driver_id, "warning", "Job on hold: " + sh.ref, summary);
        }
        if sh.loader_id {
            notify(sh.loader_id, "warning", "Loading on hold: " + sh.ref, summary);
        }
        o = get_order(sh.order_id);
        if o is not None {
            refresh_order_status(o);
            notify_order_buyer(o, "warning", "Your delivery " + sh.ref + " needs re-planning", summary + " Dispatch is working on an alternative.");
        }
        count += 1;
    }
    return count;
}
