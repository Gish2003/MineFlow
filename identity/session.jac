"""Session and account binding endpoints.

Authentication itself is Jac's built-in JWT auth (`/user/register`,
`/user/login`, client `jacLogin`). This module binds an authenticated Jac user
(its root) to a MineFlow `Account` in one of three ways:

* DEMO mode only: `claim_demo_persona` binds a seeded, publicly documented
  demo persona (clearly labelled demo functionality, not production auth);
* `redeem_invite`: an admin-issued, single-use invite code (atomic consume);
* `redeem_bootstrap_admin`: first administrator via an operator secret, only
  while no administrator exists.
"""

import hmac;
import from core.views { SessionView, SessionResult, PlatformStatus, DemoPersonaCard }
import from core.access { AppError, Caller, current_caller, conflict, invalid }
import from core.hub {
    get_hub, account_by_root, account_by_persona, get_org, get_plant, all_accounts,
    all_orgs
}
import from core.config { settings, agent_label, llm_available }
import from core.model { Account, HasAccount, Notification, HasNotification, Organization, HasOrg }
import from core.enums { Role, OrgType }
import from core.audit { audit }
import from core.util { now, clean_text }
import from seed.personas { PERSONAS, persona_by_key }
import from seed.demo_data { ensure_demo_seed, ORGS, ensure_reference_catalog }
import from jaclang.server.identity.app_tokens { token_consume }

glob INVITE_PURPOSE: str = "mineflow-invite";

def unread_count(acct: Account) -> int {
    return len([n for n in [acct ->:HasNotification:-> [?:Notification]] if not n.read]);
}

def session_view(c: Caller) -> SessionView {
    a = c.account;
    org = c.org;
    plant_names: list[str] = [];
    for pid in a.plant_ids {
        p = get_plant(pid);
        if p is not None {
            plant_names.append(p.name);
        }
    }
    dispatch_names: list[str] = [];
    for pid in a.dispatch_plant_ids {
        p = get_plant(pid);
        if p is not None {
            dispatch_names.append(p.name);
        }
    }
    cfg = settings();
    return SessionView(
        account_id=c.account_id,
        display_name=a.display_name,
        email=a.email,
        role=str(a.role),
        org_id=a.org_id,
        org_name=org.name if org is not None else "",
        org_type=str(org.org_type) if org is not None else "",
        plant_ids=a.plant_ids,
        plant_names=plant_names,
        dispatch_plant_ids=a.dispatch_plant_ids,
        dispatch_plant_names=dispatch_names,
        demo_mode=cfg.demo_mode,
        agent_label=agent_label(),
        currency=cfg.currency,
        unread_notifications=unread_count(a)
    );
}

def org_label(code: str) -> str {
    for row in ORGS {
        if row[0] == code {
            return row[1];
        }
    }
    return code;
}

def:pub platform_status -> PlatformStatus {
    cfg = settings();
    return PlatformStatus(
        demo_mode=cfg.demo_mode,
        agent_label=agent_label(),
        llm_enabled=llm_available(),
        currency=cfg.currency,
        demo_password=cfg.demo_password if cfg.demo_mode else ""
    );
}

def:pub demo_personas -> list[DemoPersonaCard] {
    if not settings().demo_mode {
        return [];
    }
    return [
        DemoPersonaCard(
            key=p.key,
            email=p.email,
            display_name=p.display_name,
            role=str(p.role),
            org_name=org_label(p.org_code),
            blurb=p.blurb,
            primary=p.primary
        )
        for p in PERSONAS
        if p.login
    ];
}

def:protect whoami -> SessionResult {
    try {
        return SessionResult(ok=True, data=session_view(current_caller()));
    } except AppError as e {
        return SessionResult(ok=False, code=e.code, message=e.message);
    }
}

"""DEMO ONLY: bind the caller's sign-in to a seeded persona account."""
def:protect claim_demo_persona(persona_key: str) -> SessionResult {
    try {
        if not settings().demo_mode {
            raise AppError(code="DEMO_DISABLED", message="Demo personas are disabled on this deployment.");
        }
        pdef = persona_by_key(persona_key);
        if pdef is None or not pdef.login {
            raise AppError(code="NOT_FOUND", message="Unknown demo persona.");
        }
        rid = jid(root);
        ensure_demo_seed();
        existing = account_by_root(rid);
        if existing is not None and existing.persona_key != persona_key {
            raise conflict("This sign-in is already linked to another MineFlow account.");
        }
        acct = account_by_persona(persona_key);
        if acct is None {
            raise AppError(code="NOT_FOUND", message="Demo persona account is missing; ask an admin to reset the demo.");
        }
        if acct.root_id and acct.root_id != rid {
            raise AppError(code="PERSONA_CLAIMED", message="This demo persona is linked to a different sign-in. An admin can reset the demo scenario.");
        }
        first_time = acct.root_id == "";
        acct.root_id = rid;
        c = Caller(account=acct, account_id=jid(acct), org=get_org(acct.org_id));
        if first_time {
            audit(c, "DEMO_PERSONA_CLAIMED", "Account", jid(acct), "Demo persona '" + persona_key + "' bound to a sign-in");
        }
        return SessionResult(ok=True, data=session_view(c));
    } except AppError as e {
        return SessionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect redeem_invite(code: str, display_name: str) -> SessionResult {
    try {
        rid = jid(root);
        if account_by_root(rid) is not None {
            raise conflict("This sign-in already has a MineFlow account.");
        }
        name = clean_text(display_name, 80);
        if len(name) < 2 {
            raise invalid("Enter your full name.");
        }
        token = code.strip();
        if not token {
            raise invalid("Enter the invite code you received.");
        }
        got = token_consume(INVITE_PURPOSE, token);
        if got is None {
            raise AppError(code="INVALID_INVITE", message="The invite code is invalid, expired or already used.");
        }
        payload: dict[str, any] = got["payload"];
        acct = Account(
            email=str(payload.get("email", "")),
            display_name=name,
            role=Role(str(payload["role"])),
            org_id=str(payload["org_id"]),
            root_id=rid,
            plant_ids=[str(x) for x in payload.get("plant_ids", [])],
            dispatch_plant_ids=[str(x) for x in payload.get("dispatch_plant_ids", [])],
            license_class=str(payload.get("license_class", "")),
            created_at=now()
        );
        get_hub() +>:HasAccount():+> acct;
        c = Caller(account=acct, account_id=jid(acct), org=get_org(acct.org_id));
        audit(c, "INVITE_REDEEMED", "Account", jid(acct), name + " joined as " + str(acct.role));
        return SessionResult(ok=True, data=session_view(c));
    } except AppError as e {
        return SessionResult(ok=False, code=e.code, message=e.message);
    }
}

def platform_org -> Organization {
    for o in all_orgs() {
        if o.org_type == OrgType.PLATFORM {
            return o;
        }
    }
    o = Organization(code="PLAT", name="MineFlow Platform", org_type=OrgType.PLATFORM, region="Island-wide");
    get_hub() +>:HasOrg():+> o;
    return o;
}

def:protect redeem_bootstrap_admin(code: str, display_name: str) -> SessionResult {
    try {
        expected = settings().bootstrap_admin_code;
        if not expected {
            raise AppError(code="DISABLED", message="Bootstrap admin is not configured (MINEFLOW_BOOTSTRAP_ADMIN_CODE).");
        }
        if not hmac.compare_digest(code.strip(), expected) {
            raise AppError(code="ACCESS_DENIED", message="Bootstrap code is incorrect.");
        }
        for a in all_accounts() {
            if a.role == Role.ADMIN and a.active and a.root_id {
                raise conflict("An administrator already exists; ask them for an invite.");
            }
        }
        rid = jid(root);
        if account_by_root(rid) is not None {
            raise conflict("This sign-in already has a MineFlow account.");
        }
        name = clean_text(display_name, 80);
        if len(name) < 2 {
            raise invalid("Enter your full name.");
        }
        ensure_reference_catalog();
        org = platform_org();
        acct = Account(email="", display_name=name, role=Role.ADMIN, org_id=jid(org), root_id=rid, created_at=now());
        get_hub() +>:HasAccount():+> acct;
        c = Caller(account=acct, account_id=jid(acct), org=org);
        audit(c, "BOOTSTRAP_ADMIN", "Account", jid(acct), "First administrator created");
        return SessionResult(ok=True, data=session_view(c));
    } except AppError as e {
        return SessionResult(ok=False, code=e.code, message=e.message);
    }
}
