"""Quality / quantity / delivery claims.

A buyer's mismatch report creates a claim linked to its order, shipment, source
lot and plant. It is visible to dispatchers covering that plant and to the
plant's store managers; review and resolution follow the validated CLAIM_FLOW.
"""

import from core.model { Claim, HasClaim, Shipment, Order }
import from core.enums { ClaimStatus, ClaimType, ShipmentStatus, Role }
import from core.hub { get_hub, get_claim, get_order, get_shipment, get_lot, get_plant, get_account, all_claims }
import from core.access {
    AppError, Caller, current_caller, require_roles, can_view_claim, dispatcher_covers_plant,
    manages_plant, not_found, invalid, deny
}
import from core.state_machines { assert_claim, assert_shipment }
import from core.audit { audit, timeline, notify, notify_dispatchers, notify_plant_managers, notify_order_buyer }
import from core.views { ActionResult, ClaimView }
import from core.util { now, new_ref, clean_text }
import from evidence.store { evidence_views }
import from orders.rollup { refresh_order_status }
import from payments.ledger { on_completed }

obj ClaimListResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        claims: list[ClaimView] = [];
}

obj ClaimResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        data: ClaimView | None = None;
}

def claim_view(c: Caller, cl: Claim) -> ClaimView {
    o = get_order(cl.order_id);
    sh = get_shipment(cl.shipment_id);
    lot = get_lot(cl.lot_id);
    p = get_plant(cl.plant_id);
    author = get_account(cl.created_by);
    open_states = [ClaimStatus.OPEN, ClaimStatus.UNDER_REVIEW];
    return ClaimView(
        id=jid(cl), ref=cl.ref, order_id=cl.order_id, order_ref=o.ref if o is not None else "",
        shipment_id=cl.shipment_id, shipment_ref=sh.ref if sh is not None else "",
        claim_type=str(cl.claim_type), status=str(cl.status), description=cl.description,
        plant_name=p.name if p is not None else "", lot_code=lot.code if lot is not None else "",
        qty_expected_t=cl.qty_expected_t, qty_received_t=cl.qty_received_t, routed_to=cl.routed_to,
        resolution=cl.resolution, created_by_name=author.display_name if author is not None else "",
        created_at=cl.created_at, updated_at=cl.updated_at, evidence=evidence_views(cl),
        can_review=cl.status == ClaimStatus.OPEN and dispatcher_covers_plant(c, cl.plant_id),
        can_resolve=cl.status in open_states and (dispatcher_covers_plant(c, cl.plant_id) or manages_plant(c, cl.plant_id))
    );
}

"""Create a claim for a delivered shipment (validation already done by caller)."""
def open_claim(c: Caller, o: Order, sh: Shipment, claim_type: ClaimType, description: str, received_t: float) -> Claim {
    cl = Claim(
        ref=new_ref("CLM"), order_id=jid(o), shipment_id=jid(sh), claim_type=claim_type,
        description=description, plant_id=sh.plant_id, lot_id=sh.lot_id,
        qty_expected_t=sh.loaded_qty_t, qty_received_t=received_t, created_by=c.account_id,
        created_at=now(), updated_at=now()
    );
    get_hub() +>:HasClaim():+> cl;
    o +>:HasClaim():+> cl;
    msg = cl.ref + " (" + str(claim_type) + ") on " + sh.ref + ": " + description[:120];
    notify_dispatchers(sh.plant_id, "warning", "New claim " + cl.ref, msg, "/dispatch/claims");
    notify_plant_managers(sh.plant_id, "warning", "Claim against your plant: " + cl.ref, msg, "/plant/claims");
    timeline(jid(o), "CLAIM", "Claim " + cl.ref + " opened (" + str(claim_type).replace("_", " ").lower() + ")", description, jid(sh), c);
    audit(c, "CLAIM_OPENED", "Claim", jid(cl), msg, "", [sh.plant_id]);
    return cl;
}

def:protect claims_list(status_filter: str = "", poll: int = 0) -> ClaimListResult {
    _ = poll;
    try {
        c = require_roles([Role.BUYER, Role.DISPATCHER, Role.STORE_MANAGER, Role.ADMIN]);
        rows: list[ClaimView] = [];
        for cl in sorted(all_claims(), key=lambda (x: Claim) { -x.updated_at; }) {
            if status_filter and str(cl.status) != status_filter {
                continue;
            }
            if can_view_claim(c, cl) {
                rows.append(claim_view(c, cl));
            }
        }
        return ClaimListResult(ok=True, claims=rows);
    } except AppError as e {
        return ClaimListResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect claim_detail(claim_id: str) -> ClaimResult {
    try {
        c = current_caller();
        cl = get_claim(claim_id);
        if cl is None or not can_view_claim(c, cl) {
            raise not_found("Claim");
        }
        return ClaimResult(ok=True, data=claim_view(c, cl));
    } except AppError as e {
        return ClaimResult(ok=False, code=e.code, message=e.message);
    }
}

"""Dispatcher takes the claim under review and routes it to the responsible party."""
def:protect review_claim(claim_id: str, routed_to: str, note: str = "") -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER]);
        cl = get_claim(claim_id);
        if cl is None or not can_view_claim(c, cl) {
            raise not_found("Claim");
        }
        if routed_to not in ["PLANT_MANAGER", "DISPATCH", "DRIVER", "LOADER"] {
            raise invalid("Route the claim to PLANT_MANAGER, DISPATCH, DRIVER or LOADER.");
        }
        assert_claim(cl.status, ClaimStatus.UNDER_REVIEW);
        cl.status = ClaimStatus.UNDER_REVIEW;
        cl.routed_to = routed_to;
        cl.updated_at = now();
        if routed_to == "PLANT_MANAGER" {
            notify_plant_managers(cl.plant_id, "warning", "Claim " + cl.ref + " routed to you", clean_text(note, 300) or cl.description[:200], "/plant/claims");
        }
        if routed_to == "DRIVER" or routed_to == "LOADER" {
            sh = get_shipment(cl.shipment_id);
            if sh is not None {
                target = sh.driver_id if routed_to == "DRIVER" else sh.loader_id;
                notify(target, "warning", "Claim " + cl.ref + " needs your input", clean_text(note, 300) or cl.description[:200]);
            }
        }
        o = get_order(cl.order_id);
        if o is not None {
            notify_order_buyer(o, "info", "Claim " + cl.ref + " under review", "Routed to " + routed_to.replace("_", " ").lower() + ".");
            timeline(cl.order_id, "CLAIM", "Claim " + cl.ref + " under review", "Routed to " + routed_to.replace("_", " ").lower(), cl.shipment_id, c);
        }
        audit(c, "CLAIM_REVIEW", "Claim", claim_id, "Routed to " + routed_to, note, [cl.plant_id]);
        return ActionResult(ok=True, id=claim_id, message="Claim under review.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Dispatcher (scope) or the plant's store manager closes the claim."""
def:protect resolve_claim(claim_id: str, outcome: str, resolution: str) -> ActionResult {
    try {
        c = require_roles([Role.DISPATCHER, Role.STORE_MANAGER]);
        cl = get_claim(claim_id);
        if cl is None or not can_view_claim(c, cl) {
            raise not_found("Claim");
        }
        if outcome not in ["RESOLVED", "REJECTED"] {
            raise invalid("Outcome must be RESOLVED or REJECTED.");
        }
        text = clean_text(resolution, 1000);
        if len(text) < 5 {
            raise invalid("Describe the resolution (what was decided and why).");
        }
        dst = ClaimStatus(outcome);
        if cl.status == ClaimStatus.OPEN and dst == ClaimStatus.RESOLVED {
            raise AppError(code="INVALID_STATE", message="Take the claim under review before resolving it.");
        }
        assert_claim(cl.status, dst);
        sh = get_shipment(cl.shipment_id);
        cl.status = dst;
        cl.resolution = text;
        cl.updated_at = now();
        if sh is not None and sh.status == ShipmentStatus.DISPUTED {
            others_open = [x for x in all_claims() if x.shipment_id == cl.shipment_id and jid(x) != claim_id and x.status in [ClaimStatus.OPEN, ClaimStatus.UNDER_REVIEW]];
            if not others_open {
                sh.status = ShipmentStatus.COMPLETED;
                sh.completed_at = now();
                on_completed(sh);
            }
        }
        o = get_order(cl.order_id);
        if o is not None {
            refresh_order_status(o);
            notify_order_buyer(o, "info", "Claim " + cl.ref + " " + outcome.lower(), text[:200]);
            timeline(cl.order_id, "CLAIM", "Claim " + cl.ref + " " + outcome.lower(), text, cl.shipment_id, c);
        }
        audit(c, "CLAIM_" + outcome, "Claim", claim_id, text, "", [cl.plant_id]);
        return ActionResult(ok=True, id=claim_id, message="Claim " + outcome.lower() + ".");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
