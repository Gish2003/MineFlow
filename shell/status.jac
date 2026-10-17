"""Status -> badge tone / human label mapping shared by every dashboard.

Pure data/logic, no JSX - safe to import from any client page without pulling
a server round-trip (plain helpers referenced from client code are bundled
client-side, see jac-cl-organization).
"""

glob DESTRUCTIVE_STATUSES: list[str] = [
    "CANCELLED", "REJECTED", "FAILED", "EXCEPTION", "DISPUTED", "OFFLINE",
    "UNAVAILABLE", "QUALITY_HOLD", "BLOCKED", "NO_FEASIBLE_OPTION", "INVALID",
    "DRIVER_REJECTED", "VEHICLE_ISSUE", "HANDOVER_LOCKED", "WITHDRAWN", "RELEASED"
];

glob SOLID_STATUSES: list[str] = [
    "COMPLETED", "DELIVERED", "PAID", "RESOLVED", "VERIFIED", "LIVE", "APPROVED",
    "SUCCEEDED", "RESERVED", "OPERATIONAL", "AVAILABLE", "DONE", "APPLIED"
];

glob SECONDARY_STATUSES: list[str] = [
    "IN_TRANSIT", "LOADING", "SCHEDULED", "PENDING", "WEAK", "UNDER_REVIEW",
    "OFFERED", "HELD", "PLANNING", "DISPATCHING", "IN_PROGRESS", "AWAITING_LOADING",
    "LOADED", "RECOVERY_PROPOSED", "IN_USE", "RESTRICTED", "COMMITTED", "UPDATE"
];

def status_variant(status: str) -> str {
    s = status.upper();
    if s in DESTRUCTIVE_STATUSES {
        return "destructive";
    }
    if s in SOLID_STATUSES {
        return "default";
    }
    if s in SECONDARY_STATUSES {
        return "secondary";
    }
    return "outline";
}

def status_label(status: str) -> str {
    if not status {
        return "";
    }
    words = status.replace("_", " ").split(" ");
    out: list[str] = [];
    for w in words {
        out.append(w[0].upper() + w[1:].lower() if len(w) > 1 else w.upper());
    }
    return " ".join(out);
}
