"""Server-side authorization for every MineFlow endpoint.

Identity comes from `jid(root)` - the caller's per-user root resolved from the
JWT by the runtime - and is mapped to an app `Account` holding role, organization
and scope. Every endpoint calls `require_roles(...)` (or `current_caller()`) first
and then a scope predicate for the specific record.

Contract: `AppError` may only be raised during validation, *before* any graph
mutation. Endpoints catch it and return a typed failure result, which commits
the (unchanged) transaction. Invariant failures discovered mid-mutation must
raise a different exception so the whole request transaction rolls back.
"""

import from core.enums { Role, OrderStatus, ShipmentStatus }
import from core.model { Account, Organization, Order, Shipment, Plant, Claim, ExceptionCase }
import from core.hub { account_by_root, get_org, get_order, get_account }

obj AppError(Exception) {
    has code: str,
        message: str = "";
}

def deny(message: str) -> AppError {
    return AppError(code="ACCESS_DENIED", message=message);
}

def not_found(what: str) -> AppError {
    return AppError(code="NOT_FOUND", message=what + " was not found or is not visible to you.");
}

def invalid(message: str) -> AppError {
    return AppError(code="VALIDATION", message=message);
}

def bad_state(message: str) -> AppError {
    return AppError(code="INVALID_STATE", message=message);
}

def conflict(message: str) -> AppError {
    return AppError(code="CONFLICT", message=message);
}

"""The authenticated caller resolved to an active MineFlow account."""
obj Caller {
    has account: Account,
        account_id: str,
        org: Organization | None = None;

    def role -> Role {
        return self.account.role;
    }

    def has_role(r: Role) -> bool {
        return self.account.role == r;
    }

    def org_name -> str {
        return self.org.name if self.org is not None else "";
    }
}

def current_caller -> Caller {
    acct = account_by_root(jid(root));
    if acct is None {
        raise AppError(
            code="NO_ACCOUNT",
            message="This sign-in is not linked to a MineFlow account. Use an invite code or a demo persona."
        );
    }
    if not acct.active {
        raise AppError(code="ACCOUNT_DISABLED", message="This account has been deactivated by an administrator.");
    }
    return Caller(account=acct, account_id=jid(acct), org=get_org(acct.org_id));
}

def require_roles(roles: list[Role]) -> Caller {
    c = current_caller();
    if c.account.role not in roles {
        raise deny("This action is not available to the " + str(c.account.role) + " role.");
    }
    return c;
}

def require_admin -> Caller {
    return require_roles([Role.ADMIN]);
}

# ------------------------------------------------------------ scope tests
def overlaps(a: list[str], b: list[str]) -> bool {
    for x in a {
        if x in b {
            return True;
        }
    }
    return False;
}

def dispatcher_covers_plant(c: Caller, plant_id: str) -> bool {
    return c.has_role(Role.DISPATCHER) and plant_id in c.account.dispatch_plant_ids;
}

def manages_plant(c: Caller, plant_id: str) -> bool {
    return c.has_role(Role.STORE_MANAGER) and plant_id in c.account.plant_ids;
}

def can_view_order(c: Caller, o: Order) -> bool {
    r = c.account.role;
    if r == Role.ADMIN {
        return True;
    }
    if r == Role.BUYER {
        return o.buyer_id == c.account_id;
    }
    if r == Role.DISPATCHER {
        return overlaps(o.plant_ids + o.candidate_plant_ids, c.account.dispatch_plant_ids);
    }
    if r == Role.STORE_MANAGER {
        return overlaps(o.plant_ids, c.account.plant_ids);
    }
    return False;
}

"""Loader eligibility: an unassigned job at one of the loader's plants."""
def loader_eligible(c: Caller, s: Shipment) -> bool {
    pre_loading = [ShipmentStatus.OFFERED, ShipmentStatus.SCHEDULED, ShipmentStatus.AWAITING_LOADING, ShipmentStatus.AWAITING_DISPATCH];
    return c.has_role(Role.LOADER) and s.loader_id == "" and s.plant_id in c.account.plant_ids and s.status in pre_loading;
}

def can_view_shipment(c: Caller, s: Shipment, offered_to_caller: bool = False) -> bool {
    r = c.account.role;
    if r == Role.ADMIN {
        return True;
    }
    if r == Role.BUYER {
        o = get_order(s.order_id);
        return o is not None and o.buyer_id == c.account_id;
    }
    if r == Role.DRIVER {
        return s.driver_id == c.account_id or offered_to_caller;
    }
    if r == Role.LOADER {
        return s.loader_id == c.account_id or loader_eligible(c, s);
    }
    if r == Role.DISPATCHER {
        return dispatcher_covers_plant(c, s.plant_id);
    }
    if r == Role.STORE_MANAGER {
        return manages_plant(c, s.plant_id);
    }
    return False;
}

def can_view_claim(c: Caller, cl: Claim) -> bool {
    r = c.account.role;
    if r == Role.ADMIN {
        return True;
    }
    if r == Role.BUYER {
        return cl.created_by == c.account_id;
    }
    if r == Role.DISPATCHER {
        return dispatcher_covers_plant(c, cl.plant_id);
    }
    if r == Role.STORE_MANAGER {
        return manages_plant(c, cl.plant_id);
    }
    return False;
}

def can_view_exception(c: Caller, ex: ExceptionCase) -> bool {
    r = c.account.role;
    if r == Role.ADMIN {
        return True;
    }
    if r == Role.DISPATCHER {
        return dispatcher_covers_plant(c, ex.plant_id);
    }
    if r == Role.STORE_MANAGER {
        return manages_plant(c, ex.plant_id);
    }
    return False;
}

def require_order_visible(c: Caller, order_id: str) -> Order {
    o = get_order(order_id);
    if o is None or not can_view_order(c, o) {
        raise not_found("Order");
    }
    return o;
}

def require_dispatch_scope(c: Caller, plant_id: str) {
    if not dispatcher_covers_plant(c, plant_id) {
        raise deny("This plant is outside your dispatch scope.");
    }
}

def require_plant_manager(c: Caller, plant_id: str) {
    if not manages_plant(c, plant_id) {
        raise deny("You are not a store manager for this plant.");
    }
}

def account_name(aid: str) -> str {
    a = get_account(aid);
    return a.display_name if a is not None else "";
}
