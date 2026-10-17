"""Deterministic geography and cost estimates.

Routes are SIMULATED: straight-line great-circle distance times a road factor,
at an average truck speed. Every figure derived here is labelled an estimate.
"""

import math;

glob ROAD_FACTOR: float = 1.35,
     AVG_SPEED_KMH: float = 45.0;

def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float {
    r = 6371.0;
    p1 = math.radians(lat1);
    p2 = math.radians(lat2);
    dp = math.radians(lat2 - lat1);
    dl = math.radians(lng2 - lng1);
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2;
    return 2 * r * math.asin(math.sqrt(a));
}

def road_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float {
    return round(haversine_km(lat1, lng1, lat2, lng2) * ROAD_FACTOR, 1);
}

def travel_minutes(km: float) -> float {
    return round(km / AVG_SPEED_KMH * 60.0, 1);
}

def interpolate(lat1: float, lng1: float, lat2: float, lng2: float, frac: float) -> list[float] {
    f = max(0.0, min(1.0, frac));
    return [lat1 + (lat2 - lat1) * f, lng1 + (lng2 - lng1) * f];
}

"""Points along a gently curved simulated route (for drawing and simulation)."""
def route_points(lat1: float, lng1: float, lat2: float, lng2: float, steps: int = 32) -> list[list[float]] {
    pts: list[list[float]] = [];
    bend = 0.08;
    for i in range(steps + 1) {
        f = i / steps;
        base = interpolate(lat1, lng1, lat2, lng2, f);
        offset = math.sin(f * math.pi) * bend;
        pts.append([round(base[0] + offset * (lng2 - lng1) * 0.15, 6), round(base[1] - offset * (lat2 - lat1) * 0.15, 6)]);
    }
    return pts;
}

"""Fraction of the route closest to a reported point (for progress display)."""
def progress_fraction(route: list[list[float]], lat: float, lng: float) -> float {
    if len(route) < 2 {
        return 0.0;
    }
    best_i = 0;
    best_d = 1e18;
    for (i, p) in enumerate(route) {
        d = (p[0] - lat) ** 2 + (p[1] - lng) ** 2;
        if d < best_d {
            best_d = d;
            best_i = i;
        }
    }
    return round(best_i / (len(route) - 1), 3);
}

def haulage_cost(quantity_t: float, km: float, rate_per_tkm: float) -> float {
    return round(quantity_t * km * rate_per_tkm, 2);
}
