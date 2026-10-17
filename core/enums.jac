"""Domain vocabularies for MineFlow AI.

Each status family is a separate enum on purpose: delivery progress,
connectivity, claims and payments move independently and must never be
folded into one field.
"""

enum Role: str {
    BUYER = "BUYER",
    STORE_MANAGER = "STORE_MANAGER",
    DISPATCHER = "DISPATCHER",
    LOADER = "LOADER",
    DRIVER = "DRIVER",
    ADMIN = "ADMIN"
}

enum OrgType: str {
    BUYER = "BUYER",
    PRODUCER = "PRODUCER",
    LOGISTICS = "LOGISTICS",
    PLATFORM = "PLATFORM"
}

enum OrderStatus: str {
    DRAFT = "DRAFT",
    PLANNING = "PLANNING",
    OPTIONS_READY = "OPTIONS_READY",
    NO_FEASIBLE_OPTION = "NO_FEASIBLE_OPTION",
    RESERVED = "RESERVED",
    DISPATCHING = "DISPATCHING",
    IN_PROGRESS = "IN_PROGRESS",
    DELIVERED = "DELIVERED",
    COMPLETED = "COMPLETED",
    DISPUTED = "DISPUTED",
    EXCEPTION = "EXCEPTION",
    CANCELLED = "CANCELLED"
}

"""Delivery status of one truckload (shipment)."""
enum ShipmentStatus: str {
    AWAITING_DISPATCH = "AWAITING_DISPATCH",
    OFFERED = "OFFERED",
    SCHEDULED = "SCHEDULED",
    AWAITING_LOADING = "AWAITING_LOADING",
    LOADING = "LOADING",
    LOADED = "LOADED",
    IN_TRANSIT = "IN_TRANSIT",
    DELIVERED = "DELIVERED",
    COMPLETED = "COMPLETED",
    DISPUTED = "DISPUTED",
    EXCEPTION = "EXCEPTION",
    CANCELLED = "CANCELLED"
}

enum ConnectivityStatus: str {
    LIVE = "LIVE",
    WEAK = "WEAK",
    OFFLINE = "OFFLINE",
    NO_DATA = "NO_DATA"
}

enum ClaimStatus: str {
    OPEN = "OPEN",
    UNDER_REVIEW = "UNDER_REVIEW",
    RESOLVED = "RESOLVED",
    REJECTED = "REJECTED"
}

enum ClaimType: str {
    GRADE_QUALITY = "GRADE_QUALITY",
    QUANTITY = "QUANTITY",
    DELIVERY = "DELIVERY",
    OTHER = "OTHER"
}

enum PaymentStatus: str {
    PENDING = "PENDING",
    APPROVED = "APPROVED",
    PAID = "PAID",
    FAILED = "FAILED"
}

enum LedgerKind: str {
    LOADER_FEE = "LOADER_FEE",
    DRIVER_PAYOUT = "DRIVER_PAYOUT",
    BUYER_INVOICE = "BUYER_INVOICE"
}

enum ReservationStatus: str {
    HELD = "HELD",
    CONSUMED = "CONSUMED",
    RELEASED = "RELEASED"
}

enum SlotStatus: str {
    OPEN = "OPEN",
    HELD = "HELD",
    BLOCKED = "BLOCKED",
    DONE = "DONE"
}

enum LotQuality: str {
    VERIFIED = "VERIFIED",
    PENDING = "PENDING",
    QUALITY_HOLD = "QUALITY_HOLD"
}

enum PlantStatus: str {
    OPERATIONAL = "OPERATIONAL",
    RESTRICTED = "RESTRICTED",
    UNAVAILABLE = "UNAVAILABLE"
}

enum OfferStatus: str {
    OFFERED = "OFFERED",
    ACCEPTED = "ACCEPTED",
    REJECTED = "REJECTED",
    WITHDRAWN = "WITHDRAWN"
}

enum TruckStatus: str {
    AVAILABLE = "AVAILABLE",
    IN_USE = "IN_USE",
    MAINTENANCE = "MAINTENANCE"
}

enum ExceptionType: str {
    STOCK_SHORTAGE = "STOCK_SHORTAGE",
    SLOT_LOST = "SLOT_LOST",
    PLANT_UNAVAILABLE = "PLANT_UNAVAILABLE",
    PRODUCTION_DELAY = "PRODUCTION_DELAY",
    DRIVER_CANCELLED = "DRIVER_CANCELLED",
    DRIVER_REJECTED = "DRIVER_REJECTED",
    VEHICLE_ISSUE = "VEHICLE_ISSUE",
    LATE_LOADING = "LATE_LOADING",
    DELIVERY_FAILED = "DELIVERY_FAILED",
    ROUTE_DELAY = "ROUTE_DELAY",
    HANDOVER_LOCKED = "HANDOVER_LOCKED"
}

enum ExceptionStatus: str {
    OPEN = "OPEN",
    RECOVERY_PROPOSED = "RECOVERY_PROPOSED",
    RESOLVED = "RESOLVED",
    NO_FEASIBLE_OPTION = "NO_FEASIBLE_OPTION",
    DISMISSED = "DISMISSED"
}

enum DelayKind: str {
    PRODUCTION = "PRODUCTION",
    STOCKING = "STOCKING",
    EQUIPMENT = "EQUIPMENT",
    LOADING = "LOADING"
}

enum AgentMode: str {
    LLM = "LLM",
    DETERMINISTIC_FALLBACK = "DETERMINISTIC_FALLBACK"
}

enum AgentKind: str {
    SUPPLY_PLANNING = "SUPPLY_PLANNING",
    ASSIGNMENT_PLANNING = "ASSIGNMENT_PLANNING",
    EXCEPTION_RECOVERY = "EXCEPTION_RECOVERY"
}

enum AgentRunStatus: str {
    SUCCEEDED = "SUCCEEDED",
    NO_FEASIBLE_OPTION = "NO_FEASIBLE_OPTION",
    FAILED = "FAILED"
}

enum EvidenceKind: str {
    LOADING_PHOTO = "LOADING_PHOTO",
    LOAD_TICKET = "LOAD_TICKET",
    UNLOADING_PHOTO = "UNLOADING_PHOTO",
    DELIVERY_NOTE = "DELIVERY_NOTE",
    QUALITY_CERTIFICATE = "QUALITY_CERTIFICATE",
    CLAIM_EVIDENCE = "CLAIM_EVIDENCE"
}

enum AckMethod: str {
    NONE = "NONE",
    IN_APP = "IN_APP",
    HANDOVER_PIN = "HANDOVER_PIN"
}

enum PingSource: str {
    DEVICE = "DEVICE",
    SIMULATED = "SIMULATED"
}
