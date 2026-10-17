"""Settlement ledger: loader service fees, driver payouts and buyer invoices.

SIMULATED payments - no money moves. Entries are created by workflow events,
and every status change goes through the validated PAYMENT_FLOW
(PENDING -> APPROVED -> PAID, with FAILED -> APPROVED retries).
"""

import from core.model { LedgerEntry, HasLedgerEntry, Shipment, Order }
import from core.enums { LedgerKind, PaymentStatus, Role }
import from core.hub { get_hub, all_ledger, get_ledger_entry, get_plant, get_order, get_account, get_org, get_lot, get_shipment }
import from core.access { AppError, require_roles, Caller, dispatcher_covers_plant, current_caller, not_found, invalid }
import from core.state_machines { assert_payment }
import from core.audit { audit, notify }
import from core.views { ActionResult }
import from core.config { settings }
import from core.util { now, fmt_time, clip }
import from core.geo { haulage_cost }

obj LedgerView {
    has id: str,
        kind: str,
        shipment_id: str,
        shipment_ref: str,
        order_ref: str,
        payee_name: str,
        amount: float,
        currency: str,
        status: str,
        note: str,
        history: list[str],
        created_at: float,
        updated_at: float;
}

obj LedgerListResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        entries: list[LedgerView] = [],
        totals: dict[str, float] = {};
}

def driver_pay(km: float) -> float {
    cfg = settings();
    return round(cfg.driver_base_pay + km * cfg.driver_rate_per_km, 2);
}

def entry_for(sh: Shipment, kind: LedgerKind) -> LedgerEntry | None {
    sid = jid(sh);
    for e in all_ledger() {
        if e.shipment_id == sid and e.kind == kind {
            return e;
        }
    }
    return None;
}

def add_entry(kind: LedgerKind, sh: Shipment, payee_id: str, payee_name: str, amount: float, note: str) -> LedgerEntry {
    existing = entry_for(sh, kind);
    if existing is not None {
        return existing;
    }
    t = now();
    e = LedgerEntry(
        kind=kind, shipment_id=jid(sh), order_id=sh.order_id, payee_id=payee_id, payee_name=payee_name,
        amount=round(amount, 2), currency=settings().currency, note=note,
        history=[fmt_time(t) + " PENDING - created"], created_at=t, updated_at=t
    );
    get_hub() +>:HasLedgerEntry():+> e;
    return e;
}

def on_loading_finished(sh: Shipment) {
    p = get_plant(sh.plant_id);
    loader = get_account(sh.loader_id);
    if p is None or loader is None {
        return;
    }
    add_entry(LedgerKind.LOADER_FEE, sh, jid(loader), loader.display_name, sh.loaded_qty_t * p.loading_fee_per_t, "Loading service fee (" + str(round(sh.loaded_qty_t, 2)) + " t)");
    notify(jid(loader), "info", "Loading fee recorded", "Pending approval for " + sh.ref);
}

def on_completed(sh: Shipment) {
    driver = get_account(sh.driver_id);
    if driver is not None {
        add_entry(LedgerKind.DRIVER_PAYOUT, sh, jid(driver), driver.display_name, driver_pay(sh.distance_km), "Trip payout (" + str(sh.distance_km) + " km est.)");
        notify(jid(driver), "success", "Delivery completed", "Payout pending approval for " + sh.ref);
    }
    o = get_order(sh.order_id);
    lot = get_lot(sh.lot_id);
    if o is not None and lot is not None {
        org = get_org(o.buyer_org_id);
        material = lot.price_per_t * sh.received_qty_t if sh.received_qty_t > 0 else lot.price_per_t * sh.loaded_qty_t;
        haul = haulage_cost(sh.loaded_qty_t, sh.distance_km, settings().haulage_rate_per_tkm);
        add_entry(LedgerKind.BUYER_INVOICE, sh, o.buyer_org_id, org.name if org is not None else "Buyer", material + haul, "Material + haulage");
    }
}

def ledger_view(e: LedgerEntry) -> LedgerView {
    sh = get_shipment(e.shipment_id);
    o = get_order(e.order_id);
    return LedgerView(
        id=jid(e), kind=str(e.kind), shipment_id=e.shipment_id, shipment_ref=sh.ref if sh is not None else "",
        order_ref=o.ref if o is not None else "", payee_name=e.payee_name, amount=e.amount, currency=e.currency,
        status=str(e.status), note=e.note, history=e.history, created_at=e.created_at, updated_at=e.updated_at
    );
}

def _entry_plant(e: LedgerEntry) -> str {
    sh = get_shipment(e.shipment_id);
    return sh.plant_id if sh is not None else "";
}

def _totals(rows: list[LedgerView]) -> dict[str, float] {
    out: dict[str, float] = {"PENDING": 0.0, "APPROVED": 0.0, "PAID": 0.0, "FAILED": 0.0};
    for r in rows {
        out[r.status] = round(out.get(r.status, 0.0) + r.amount, 2);
    }
    return out;
}

"""Driver/loader: own entries. Dispatcher: entries for plants in scope. Admin: all."""
def:protect ledger_entries(kind_filter: str = "", poll: int = 0) -> LedgerListResult {
    _ = poll;
    try {
        c = current_caller();
        rows: list[LedgerView] = [];
        for e in sorted(all_ledger(), key=lambda (x: LedgerEntry) { -x.updated_at; }) {
            if kind_filter and str(e.kind) != kind_filter {
                continue;
            }
            visible = False;
            if c.has_role(Role.ADMIN) {
                visible = True;
            } elif c.has_role(Role.DISPATCHER) {
                visible = dispatcher_covers_plant(c, _entry_plant(e));
            } elif c.has_role(Role.DRIVER) or c.has_role(Role.LOADER) {
                visible = e.payee_id == c.account_id;
            } elif c.has_role(Role.BUYER) {
                visible = e.kind == LedgerKind.BUYER_INVOICE and e.payee_id == c.account.org_id;
            }
            if visible {
                rows.append(ledger_view(e));
            }
        }
        return LedgerListResult(ok=True, entries=rows, totals=_totals(rows));
    } except AppError as e {
        return LedgerListResult(ok=False, code=e.code, message=e.message);
    }
}

"""Dispatcher (in scope) or admin moves a payment through the validated flow."""
def:protect set_payment_status(entry_id: str, target: str, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER, Role.ADMIN]);
        e = get_ledger_entry(entry_id);
        if e is None {
            raise not_found("Ledger entry");
        }
        if c.has_role(Role.DISPATCHER) and not dispatcher_covers_plant(c, _entry_plant(e)) {
            raise not_found("Ledger entry");
        }
        if target not in ["APPROVED", "PAID", "FAILED"] {
            raise invalid("Unknown payment status.");
        }
        dst = PaymentStatus(target);
        assert_payment(e.status, dst);
        e.status = dst;
        e.updated_at = now();
        e.history = e.history + [fmt_time(e.updated_at) + " " + target + " by " + c.account.display_name + (" - " + clip(note, 120) if note else "") + " (simulated)"];
        audit(c, "PAYMENT_" + target, "LedgerEntry", entry_id, str(e.kind) + " " + e.payee_name + " " + str(e.amount), note, [_entry_plant(e)]);
        if e.kind != LedgerKind.BUYER_INVOICE {
            notify(e.payee_id, "info", "Payment " + target.lower(), e.note + " - " + str(e.amount) + " " + e.currency + " (simulated)");
        }
        return ActionResult(ok=True, id=entry_id, message="Payment marked " + target.lower() + " (simulated).");
    } except AppError as err {
        return ActionResult(ok=False, code=err.code, message=err.message);
    }
}
