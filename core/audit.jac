"""Audit trail, order timeline and in-app notifications.

These are graph writes inside the caller's request transaction, so they commit
or roll back together with the change they describe.
"""

import from core.enums { Role }
import from core.model {
    AuditEvent, HasAudit, TimelineEvent, HasEvent, Notification, HasNotification,
    Order, Account
}
import from core.hub { get_hub, get_order, get_account, all_accounts }
import from core.access { Caller }
import from core.util { now, clip }

def audit(
    c: Caller | None,
    action: str,
    entity_type: str,
    entity_id: str,
    summary: str,
    reason: str = "",
    plant_ids: list[str] = []
) {
    ev = AuditEvent(
        at=now(),
        actor_id=c.account_id if c is not None else "system",
        actor_name=c.account.display_name if c is not None else "MineFlow system",
        actor_role=str(c.account.role) if c is not None else "SYSTEM",
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        summary=clip(summary, 400),
        reason=clip(reason, 600),
        plant_ids=plant_ids
    );
    get_hub() +>:HasAudit():+> ev;
}

def timeline(
    order_id: str,
    kind: str,
    title: str,
    detail: str = "",
    shipment_id: str = "",
    c: Caller | None = None
) {
    o = get_order(order_id);
    if o is None {
        return;
    }
    ev = TimelineEvent(
        order_id=order_id,
        at=now(),
        kind=kind,
        title=clip(title, 160),
        detail=clip(detail, 600),
        shipment_id=shipment_id,
        actor_name=c.account.display_name if c is not None else "MineFlow",
        actor_role=str(c.account.role) if c is not None else "SYSTEM"
    );
    o +>:HasEvent():+> ev;
}

def notify(account_id: str, level: str, title: str, body: str = "", link: str = "") {
    acct = get_account(account_id);
    if acct is None {
        return;
    }
    n = Notification(
        account_id=account_id,
        at=now(),
        level=level,
        title=clip(title, 160),
        body=clip(body, 500),
        link=link
    );
    acct +>:HasNotification():+> n;
}

"""Notify every dispatcher whose scope covers the plant."""
def notify_dispatchers(plant_id: str, level: str, title: str, body: str = "", link: str = "") {
    for a in all_accounts() {
        if a.role == Role.DISPATCHER and a.active and plant_id in a.dispatch_plant_ids {
            notify(jid(a), level, title, body, link);
        }
    }
}

"""Notify every store manager of the plant."""
def notify_plant_managers(plant_id: str, level: str, title: str, body: str = "", link: str = "") {
    for a in all_accounts() {
        if a.role == Role.STORE_MANAGER and a.active and plant_id in a.plant_ids {
            notify(jid(a), level, title, body, link);
        }
    }
}

def notify_order_buyer(o: Order, level: str, title: str, body: str = "") {
    notify(o.buyer_id, level, title, body, "/buyer/orders/" + jid(o));
}
