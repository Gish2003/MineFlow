"""Stock availability: measured (physical) stock minus HELD reservations, with
quality-held lots contributing nothing. This is the single definition used by the
store manager screens, the planning tools and the reservation guard.
"""

import from core.model { Plant, StockLot, Reservation, HoldsLot, HasReservation }
import from core.enums { ReservationStatus, LotQuality }
import from core.hub { reservations_of_lot, lots_of, get_plant }

obj LotAvailability {
    has lot_id: str,
        lot_code: str,
        plant_id: str,
        mineral_code: str,
        grade_code: str,
        stockpile: str,
        quality: str,
        measured_t: float,
        reserved_t: float,
        quality_held_t: float,
        available_t: float,
        price_per_t: float,
        assay: dict[str, float] = {},
        updated_at: float = 0.0;
}

def reserved_on(lot: StockLot) -> float {
    total = 0.0;
    for r in reservations_of_lot(lot) {
        if r.status == ReservationStatus.HELD {
            total += r.quantity_t;
        }
    }
    return round(total, 3);
}

def availability(lot: StockLot) -> LotAvailability {
    reserved = reserved_on(lot);
    held = lot.measured_t if lot.quality == LotQuality.QUALITY_HOLD else 0.0;
    available = 0.0 if held > 0 else max(0.0, lot.measured_t - reserved);
    return LotAvailability(
        lot_id=jid(lot),
        lot_code=lot.code,
        plant_id=lot.plant_id,
        mineral_code=lot.mineral_code,
        grade_code=lot.grade_code,
        stockpile=lot.stockpile,
        quality=str(lot.quality),
        measured_t=round(lot.measured_t, 3),
        reserved_t=reserved,
        quality_held_t=round(held, 3),
        available_t=round(available, 3),
        price_per_t=lot.price_per_t,
        assay=lot.assay,
        updated_at=lot.updated_at
    );
}

"""Walks plant -> lots -> HELD reservations and reports one availability row
per lot (optionally filtered to a mineral)."""
walker:priv InventoryRollup {
    has mineral_code: str = "",
        rows: list[LotAvailability] = [],
        reports: list[list[LotAvailability]] = [];

    can start with Plant entry {
        visit [here ->:HoldsLot:-> [?:StockLot]];
    }

    can tally with StockLot entry {
        if self.mineral_code and here.mineral_code != self.mineral_code {
            skip;
        }
        self.rows.append(availability(here));
    }

    can finish with Plant exit {
        report self.rows;
    }
}

def plant_inventory(p: Plant, mineral_code: str = "") -> list[LotAvailability] {
    w = p spawn InventoryRollup(mineral_code=mineral_code);
    return w.rows;
}
