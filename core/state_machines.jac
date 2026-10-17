"""Explicit, validated state transitions.

Every status change in the app goes through one of the `assert_*` checks below
*before* mutating anything; an illegal move raises `AppError(INVALID_STATE)`.
"""

import from core.enums {
    ShipmentStatus, OrderStatus, ClaimStatus, PaymentStatus, ExceptionStatus,
    ReservationStatus
}
import from core.access { AppError, bad_state }

glob SHIPMENT_FLOW: dict[str, list[str]] = {
    "AWAITING_DISPATCH": ["OFFERED", "EXCEPTION", "CANCELLED"],
    "OFFERED": ["SCHEDULED", "AWAITING_DISPATCH", "EXCEPTION", "CANCELLED"],
    "SCHEDULED": ["AWAITING_LOADING", "AWAITING_DISPATCH", "EXCEPTION", "CANCELLED"],
    "AWAITING_LOADING": ["LOADING", "EXCEPTION"],
    "LOADING": ["LOADED", "EXCEPTION"],
    "LOADED": ["IN_TRANSIT", "EXCEPTION"],
    "IN_TRANSIT": ["DELIVERED", "EXCEPTION"],
    "DELIVERED": ["COMPLETED", "DISPUTED"],
    "DISPUTED": ["COMPLETED"],
    "EXCEPTION": ["AWAITING_DISPATCH", "SCHEDULED", "AWAITING_LOADING", "IN_TRANSIT", "CANCELLED"],
    "COMPLETED": [],
    "CANCELLED": []
};

glob ORDER_FLOW: dict[str, list[str]] = {
    "DRAFT": ["PLANNING", "CANCELLED"],
    "PLANNING": ["OPTIONS_READY", "NO_FEASIBLE_OPTION", "CANCELLED"],
    "OPTIONS_READY": ["RESERVED", "PLANNING", "NO_FEASIBLE_OPTION", "CANCELLED"],
    "NO_FEASIBLE_OPTION": ["PLANNING", "CANCELLED"],
    "RESERVED": ["DISPATCHING", "IN_PROGRESS", "EXCEPTION", "CANCELLED"],
    "DISPATCHING": ["IN_PROGRESS", "RESERVED", "EXCEPTION", "CANCELLED"],
    "IN_PROGRESS": ["DELIVERED", "COMPLETED", "DISPUTED", "EXCEPTION"],
    "DELIVERED": ["COMPLETED", "DISPUTED", "IN_PROGRESS"],
    "DISPUTED": ["COMPLETED", "IN_PROGRESS", "DELIVERED"],
    "EXCEPTION": ["RESERVED", "DISPATCHING", "IN_PROGRESS", "CANCELLED"],
    "COMPLETED": [],
    "CANCELLED": []
};

glob CLAIM_FLOW: dict[str, list[str]] = {
    "OPEN": ["UNDER_REVIEW", "REJECTED"],
    "UNDER_REVIEW": ["RESOLVED", "REJECTED"],
    "RESOLVED": [],
    "REJECTED": []
};

glob PAYMENT_FLOW: dict[str, list[str]] = {
    "PENDING": ["APPROVED", "FAILED"],
    "APPROVED": ["PAID", "FAILED"],
    "FAILED": ["APPROVED"],
    "PAID": []
};

glob EXCEPTION_FLOW: dict[str, list[str]] = {
    "OPEN": ["RECOVERY_PROPOSED", "NO_FEASIBLE_OPTION", "RESOLVED", "DISMISSED"],
    "RECOVERY_PROPOSED": ["RESOLVED", "OPEN", "NO_FEASIBLE_OPTION", "DISMISSED"],
    "NO_FEASIBLE_OPTION": ["RECOVERY_PROPOSED", "RESOLVED", "OPEN", "DISMISSED"],
    "RESOLVED": [],
    "DISMISSED": []
};

def _allowed(table: dict[str, list[str]], src: str, dst: str) -> bool {
    return dst in table.get(src, []);
}

def can_move(table: dict[str, list[str]], src: str, dst: str) -> bool {
    return _allowed(table, src, dst);
}

def _check(table: dict[str, list[str]], what: str, src: str, dst: str) {
    if not _allowed(table, src, dst) {
        raise bad_state(what + " cannot move from " + src + " to " + dst + ".");
    }
}

def assert_shipment(current: ShipmentStatus, target: ShipmentStatus) {
    _check(SHIPMENT_FLOW, "Shipment", str(current), str(target));
}

def assert_order(current: OrderStatus, target: OrderStatus) {
    _check(ORDER_FLOW, "Order", str(current), str(target));
}

def assert_claim(current: ClaimStatus, target: ClaimStatus) {
    _check(CLAIM_FLOW, "Claim", str(current), str(target));
}

def assert_payment(current: PaymentStatus, target: PaymentStatus) {
    _check(PAYMENT_FLOW, "Payment", str(current), str(target));
}

def assert_exception(current: ExceptionStatus, target: ExceptionStatus) {
    _check(EXCEPTION_FLOW, "Exception", str(current), str(target));
}

glob ACTIVE_SHIPMENT: list[str] = [
    "AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "AWAITING_LOADING", "LOADING",
    "LOADED", "IN_TRANSIT", "EXCEPTION"
];

glob PRE_LOADING: list[str] = ["AWAITING_DISPATCH", "OFFERED", "SCHEDULED", "AWAITING_LOADING"];

def is_active_shipment(status: ShipmentStatus) -> bool {
    return str(status) in ACTIVE_SHIPMENT;
}
