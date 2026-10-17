"""Order status rollup derived from its shipments' (validated) delivery states."""

import from core.model { Order }
import from core.enums { OrderStatus, ShipmentStatus }
import from core.hub { shipments_of_order }
import from core.util { now }

def refresh_order_status(o: Order) {
    statuses = [str(s.status) for s in shipments_of_order(o)];
    if not statuses {
        return;
    }
    live = [s for s in statuses if s != "CANCELLED"];
    target = o.status;
    if not live {
        target = OrderStatus.CANCELLED;
    } elif "EXCEPTION" in live {
        target = OrderStatus.EXCEPTION;
    } elif "DISPUTED" in live {
        target = OrderStatus.DISPUTED;
    } elif all(s == "COMPLETED" for s in live) {
        target = OrderStatus.COMPLETED;
    } elif all(s in ["DELIVERED", "COMPLETED"] for s in live) {
        target = OrderStatus.DELIVERED;
    } elif any(s in ["AWAITING_LOADING", "LOADING", "LOADED", "IN_TRANSIT", "DELIVERED", "COMPLETED"] for s in live) {
        target = OrderStatus.IN_PROGRESS;
    } elif any(s in ["OFFERED", "SCHEDULED"] for s in live) {
        target = OrderStatus.DISPATCHING;
    } else {
        target = OrderStatus.RESERVED;
    }
    if target != o.status {
        o.status = target;
        o.updated_at = now();
    }
}
