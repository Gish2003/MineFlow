"""Atomic stock + loading-slot reservation.

`reservation_problems` re-validates everything against live state; only when the
whole order passes does `reserve_line` mutate. Both run inside one endpoint
request, i.e. one SERIALIZABLE transaction: two buyers racing for the last
tonnes or the same slot cannot both commit - the loser is replayed, re-reads
the reduced availability and is refused.
"""

import from core.model {
    Order, OrderLine, StockLot, LoadingSlot, Plant, Reservation, Shipment,
    HasReservation, HasShipment
}
import from core.enums { ReservationStatus, SlotStatus, PlantStatus, ShipmentStatus }
import from core.hub { get_hub, get_plant, get_slot, get_lot, get_reservation }
import from core.util { now, new_ref, new_pin }
import from catalog.grades { check_lot_for_line }
import from inventory.availability { availability }
import from scheduling.slots { slot_problems, held_in_hour }
import from planning.metrics { trip_for }

def reservation_problems(
    order: Order,
    line: OrderLine,
    lot: StockLot | None,
    slot: LoadingSlot | None,
    claimed_t: dict[str, float],
    used_slots: list[str]
) -> list[str] {
    problems: list[str] = [];
    if lot is None {
        return ["Stock lot no longer exists."];
    }
    if slot is None {
        return ["Loading slot no longer exists."];
    }
    if lot.plant_id != slot.plant_id {
        problems.append("Slot and lot belong to different plants.");
    }
    plant = get_plant(lot.plant_id);
    if plant is None {
        return problems + ["Plant no longer exists."];
    }
    if plant.status == PlantStatus.UNAVAILABLE {
        problems.append(plant.name + " is currently unavailable.");
    }
    grade = check_lot_for_line(lot, line);
    if not grade.compatible {
        problems = problems + grade.reasons;
    }
    lid = jid(lot);
    already = claimed_t.get(lid, 0.0);
    avail = availability(lot).available_t - already;
    if avail + 1e-9 < line.quantity_t {
        problems.append(f"Only {round(max(avail, 0.0), 2)} t available in lot {lot.code}; {line.quantity_t} t requested.");
    }
    sid = jid(slot);
    if sid in used_slots {
        problems.append("The same loading slot cannot serve two loads.");
    }
    problems = problems + slot_problems(plant, slot);
    trip = trip_for(order, plant, slot.start_ts, line.quantity_t);
    if trip.eta_ts > order.window_end {
        problems.append("Estimated arrival is after the delivery window closes.");
    }
    return problems;
}

"""Create the HELD reservation, hold the slot and create the shipment.
Call only after `reservation_problems` returned no problems for every line."""
def reserve_line(order: Order, line: OrderLine, lot: StockLot, slot: LoadingSlot) -> Shipment {
    if slot.status != SlotStatus.OPEN {
        raise RuntimeError("Slot changed state during reservation; aborting transaction.");
    }
    plant = get_plant(lot.plant_id);
    if plant is None {
        raise RuntimeError("Plant vanished during reservation; aborting transaction.");
    }
    res = Reservation(
        lot_id=jid(lot),
        line_id=jid(line),
        order_id=jid(order),
        plant_id=lot.plant_id,
        quantity_t=line.quantity_t,
        created_at=now()
    );
    lot +>:HasReservation():+> res;
    line +>:HasReservation():+> res;
    trip = trip_for(order, plant, slot.start_ts, line.quantity_t);
    sh = Shipment(
        ref=new_ref("SHP"),
        order_id=jid(order),
        line_id=jid(line),
        plant_id=lot.plant_id,
        lot_id=jid(lot),
        slot_id=jid(slot),
        reservation_id=jid(res),
        quantity_t=line.quantity_t,
        handover_pin=new_pin(),
        distance_km=trip.distance_km,
        eta_minutes=trip.travel_minutes,
        updated_at=now()
    );
    line +>:HasShipment():+> sh;
    get_hub() +>:HasShipment():+> sh;
    res.shipment_id = jid(sh);
    slot.status = SlotStatus.HELD;
    slot.shipment_id = jid(sh);
    if lot.plant_id not in order.plant_ids {
        order.plant_ids = order.plant_ids + [lot.plant_id];
    }
    return sh;
}

def release_reservation(res: Reservation, reason: str) {
    if res.status != ReservationStatus.HELD {
        return;
    }
    res.status = ReservationStatus.RELEASED;
    res.released_reason = reason;
}

def free_slot_of(sh: Shipment) {
    slot = get_slot(sh.slot_id);
    if slot is not None and slot.shipment_id == jid(sh) and slot.status == SlotStatus.HELD {
        slot.status = SlotStatus.OPEN;
        slot.shipment_id = "";
    }
}

"""Loading finished: reservation consumed, physical stock drawn down, slot done."""
def consume_for_loading(sh: Shipment, loaded_t: float) {
    res = get_reservation(sh.reservation_id);
    if res is not None and res.status == ReservationStatus.HELD {
        res.status = ReservationStatus.CONSUMED;
    }
    lot = get_lot(sh.lot_id);
    if lot is not None {
        lot.measured_t = round(max(0.0, lot.measured_t - loaded_t), 3);
        lot.updated_at = now();
    }
    slot = get_slot(sh.slot_id);
    if slot is not None and slot.shipment_id == jid(sh) {
        slot.status = SlotStatus.DONE;
    }
}

"""Move a shipment to a new lot/slot (recovery). Validates before mutating."""
def rereserve_problems(order: Order, line: OrderLine, sh: Shipment, lot: StockLot | None, slot: LoadingSlot | None) -> list[str] {
    claimed: dict[str, float] = {};
    old = get_reservation(sh.reservation_id);
    if lot is not None and old is not None and old.status == ReservationStatus.HELD and old.lot_id == jid(lot) {
        claimed[jid(lot)] = -old.quantity_t;
    }
    problems = reservation_problems(order, line, lot, slot, claimed, []);
    if slot is not None and slot.shipment_id == jid(sh) {
        problems = [p for p in problems if not p.startswith("Slot is ")];
    }
    return problems;
}

def rereserve(order: Order, line: OrderLine, sh: Shipment, lot: StockLot, slot: LoadingSlot, reason: str) {
    old = get_reservation(sh.reservation_id);
    if old is not None {
        release_reservation(old, reason);
    }
    if sh.slot_id != jid(slot) {
        free_slot_of(sh);
    }
    res = Reservation(
        lot_id=jid(lot),
        line_id=jid(line),
        order_id=jid(order),
        plant_id=lot.plant_id,
        quantity_t=line.quantity_t,
        shipment_id=jid(sh),
        created_at=now()
    );
    lot +>:HasReservation():+> res;
    line +>:HasReservation():+> res;
    slot.status = SlotStatus.HELD;
    slot.shipment_id = jid(sh);
    plant = get_plant(lot.plant_id);
    sh.reservation_id = jid(res);
    sh.lot_id = jid(lot);
    sh.slot_id = jid(slot);
    sh.plant_id = lot.plant_id;
    if plant is not None {
        trip = trip_for(order, plant, slot.start_ts, line.quantity_t);
        sh.distance_km = trip.distance_km;
        sh.eta_minutes = trip.travel_minutes;
    }
    sh.updated_at = now();
    if lot.plant_id not in order.plant_ids {
        order.plant_ids = order.plant_ids + [lot.plant_id];
    }
}
