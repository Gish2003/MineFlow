"""Deterministic option metrics: ETA, wait, cost.

These are the only numbers ever shown for a recommendation. Values proposed by
the LLM are discarded and recomputed here during validation.
"""

import from core.model { Order, OrderLine, Plant, StockLot, LoadingSlot, PlanOption }
import from core.config { settings }
import from core.geo { road_km, travel_minutes, haulage_cost }
import from core.util { r2 }
import from scheduling.slots { loading_minutes, LoadingEstimate }
import from inventory.availability { availability }
import from catalog.grades { check_lot_for_line }

obj Trip {
    has distance_km: float,
        travel_minutes: float,
        loading_minutes: float,
        depart_ts: float,
        eta_ts: float;
}

"""Simulated trip: truck presents at the slot, waits the plant readiness buffer,
loads, then drives the estimated road distance."""
def trip_for(order: Order, plant: Plant, slot_start: float, quantity_t: float) -> Trip {
    km = road_km(plant.lat, plant.lng, order.dest_lat, order.dest_lng);
    travel = travel_minutes(km);
    load = loading_minutes(plant, quantity_t);
    depart = slot_start + (plant.readiness_buffer_min + load) * 60.0;
    return Trip(distance_km=km, travel_minutes=travel, loading_minutes=load, depart_ts=depart, eta_ts=depart + travel * 60.0);
}

"""Latest slot start that can still meet the window end (used to bound searches)."""
def latest_slot_start(order: Order, plant: Plant, quantity_t: float) -> float {
    km = road_km(plant.lat, plant.lng, order.dest_lat, order.dest_lng);
    return order.window_end - (travel_minutes(km) + loading_minutes(plant, quantity_t) + plant.readiness_buffer_min) * 60.0;
}

"""Ideal earliest slot start so the truck arrives near the window start."""
def ideal_slot_start(order: Order, plant: Plant, quantity_t: float) -> float {
    km = road_km(plant.lat, plant.lng, order.dest_lat, order.dest_lng);
    return order.window_start - (travel_minutes(km) + loading_minutes(plant, quantity_t) + plant.readiness_buffer_min) * 60.0 - 1800.0;
}

def build_option(
    option_id: str,
    rank: int,
    order: Order,
    line: OrderLine,
    plant: Plant,
    lot: StockLot,
    est: LoadingEstimate,
    rationale: str = ""
) -> PlanOption {
    trip = trip_for(order, plant, est.slot_start, line.quantity_t);
    avail = availability(lot);
    grade = check_lot_for_line(lot, line);
    rate = settings().haulage_rate_per_tkm;
    material = r2(lot.price_per_t * line.quantity_t);
    haul = haulage_cost(line.quantity_t, trip.distance_km, rate);
    loading = r2(plant.loading_fee_per_t * line.quantity_t);
    return PlanOption(
        option_id=option_id,
        line_id=jid(line),
        rank=rank,
        plant_id=jid(plant),
        plant_name=plant.name,
        lot_id=jid(lot),
        lot_code=lot.code,
        slot_id=est.slot_id,
        slot_start=est.slot_start,
        quantity_t=line.quantity_t,
        grade_ok=grade.compatible,
        available_t=avail.available_t,
        lot_quality=avail.quality,
        wait_minutes=est.wait_minutes,
        distance_km=trip.distance_km,
        travel_minutes=trip.travel_minutes,
        eta_ts=trip.eta_ts,
        within_window=trip.eta_ts <= order.window_end,
        material_cost=material,
        haulage_cost=haul,
        loading_cost=loading,
        total_cost=r2(material + haul + loading),
        rationale=rationale
    );
}

"""Deterministic score used by the fallback planner and as a tie-breaker.
Lower is better: cost per tonne + time penalties + verification penalty."""
def option_score(opt: PlanOption) -> float {
    per_t = opt.total_cost / opt.quantity_t if opt.quantity_t > 0 else opt.total_cost;
    lateness = 0.0 if opt.within_window else 100000.0;
    unverified = 0.0 if opt.lot_quality == "VERIFIED" else 400.0;
    return round(per_t + opt.wait_minutes * 6.0 + opt.travel_minutes * 4.0 + unverified + lateness, 2);
}
