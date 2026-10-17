"""In-app messages (per shipment thread) and notifications.

Messages are in-app only - no SMS or phone numbers are exposed. A thread is
readable by the buyer who owns the order, the assigned driver and dispatchers
covering the plant.
"""

import from core.model { Message, HasMessage, Shipment, Notification, HasNotification, Order }
import from core.enums { Role, ShipmentStatus }
import from core.hub { get_shipment, get_order, all_shipments, name_of_plant, fetch }
import from core.access { AppError, Caller, current_caller, dispatcher_covers_plant, not_found, invalid, bad_state }
import from core.audit { notify }
import from core.views { ActionResult, MessageView, NotificationView }
import from core.util { now, clean_text }

obj MessagesResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        shipment_ref: str = "",
        can_send: bool = False,
        messages: list[MessageView] = [];
}

obj ThreadSummary {
    has shipment_id: str,
        shipment_ref: str,
        order_ref: str,
        status: str,
        title: str,
        last_body: str,
        last_at: float,
        count: int;
}

obj ThreadsResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        threads: list[ThreadSummary] = [];
}

obj NotificationsResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        unread: int = 0,
        items: list[NotificationView] = [];
}

def can_read_thread(c: Caller, sh: Shipment) -> bool {
    if c.has_role(Role.BUYER) {
        o = get_order(sh.order_id);
        return o is not None and o.buyer_id == c.account_id;
    }
    if c.has_role(Role.DRIVER) {
        return sh.driver_id == c.account_id;
    }
    if c.has_role(Role.DISPATCHER) {
        return dispatcher_covers_plant(c, sh.plant_id);
    }
    return False;
}

def messages_of(sh: Shipment) -> list[Message] {
    return sorted([sh ->:HasMessage:-> [?:Message]], key=lambda (m: Message) { m.at; });
}

def:protect shipment_messages(shipment_id: str, poll: int = 0) -> MessagesResult {
    _ = poll;
    try {
        c = current_caller();
        sh = get_shipment(shipment_id);
        if sh is None or not can_read_thread(c, sh) {
            raise not_found("Conversation");
        }
        rows = [MessageView(id=jid(m), sender_name=m.sender_name, sender_role=m.sender_role, body=m.body, at=m.at, mine=m.sender_id == c.account_id) for m in messages_of(sh)];
        return MessagesResult(ok=True, shipment_ref=sh.ref, can_send=sh.status != ShipmentStatus.CANCELLED and sh.driver_id != "", messages=rows[-100:]);
    } except AppError as e {
        return MessagesResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect send_message(shipment_id: str, body: str) -> ActionResult {
    try {
        c = current_caller();
        sh = get_shipment(shipment_id);
        if sh is None or not can_read_thread(c, sh) {
            raise not_found("Conversation");
        }
        text = clean_text(body, 1000);
        if not text {
            raise invalid("Message is empty.");
        }
        if sh.status == ShipmentStatus.CANCELLED or not sh.driver_id {
            raise bad_state("Messaging opens once a driver is assigned.");
        }
        m = Message(shipment_id=shipment_id, order_id=sh.order_id, sender_id=c.account_id, sender_name=c.account.display_name, sender_role=str(c.account.role), body=text, at=now());
        sh +>:HasMessage():+> m;
        o = get_order(sh.order_id);
        recipients: list[str] = [];
        if o is not None and o.buyer_id != c.account_id {
            recipients.append(o.buyer_id);
        }
        if sh.driver_id and sh.driver_id != c.account_id {
            recipients.append(sh.driver_id);
        }
        for r in recipients {
            notify(r, "info", "Message on " + sh.ref + " from " + c.account.display_name, text[:140]);
        }
        return ActionResult(ok=True, id=jid(m), message="Sent.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect my_threads(poll: int = 0) -> ThreadsResult {
    _ = poll;
    try {
        c = current_caller();
        rows: list[ThreadSummary] = [];
        for sh in all_shipments() {
            if not sh.driver_id or not can_read_thread(c, sh) {
                continue;
            }
            msgs = messages_of(sh);
            if not msgs and str(sh.status) not in ["SCHEDULED", "AWAITING_LOADING", "LOADING", "LOADED", "IN_TRANSIT", "DELIVERED"] {
                continue;
            }
            o = get_order(sh.order_id);
            last = msgs[-1] if msgs else None;
            rows.append(ThreadSummary(
                shipment_id=jid(sh), shipment_ref=sh.ref, order_ref=o.ref if o is not None else "", status=str(sh.status),
                title=(o.site_name if o is not None else "") + " · " + name_of_plant(sh.plant_id),
                last_body=last.body if last is not None else "", last_at=last.at if last is not None else sh.updated_at, count=len(msgs)
            ));
        }
        return ThreadsResult(ok=True, threads=sorted(rows, key=lambda (t: ThreadSummary) { -t.last_at; }));
    } except AppError as e {
        return ThreadsResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect my_notifications(poll: int = 0) -> NotificationsResult {
    _ = poll;
    try {
        c = current_caller();
        items = sorted([c.account ->:HasNotification:-> [?:Notification]], key=lambda (n: Notification) { -n.at; });
        views = [NotificationView(id=jid(n), at=n.at, level=n.level, title=n.title, body=n.body, link=n.link, read=n.read) for n in items[:60]];
        return NotificationsResult(ok=True, unread=len([n for n in items if not n.read]), items=views);
    } except AppError as e {
        return NotificationsResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect mark_notifications_read(ids: list[str] = []) -> ActionResult {
    try {
        c = current_caller();
        for n in [c.account ->:HasNotification:-> [?:Notification]] {
            if not ids or jid(n) in ids {
                n.read = True;
            }
        }
        return ActionResult(ok=True, message="Marked as read.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
