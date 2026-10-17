"""Platform administrator (limited operational support role): users, role and
scope assignment, organizations/plants, invites, and demo configuration.
Every endpoint here requires the ADMIN role.
"""

import from core.model { DomainNode, MineFlowHub, Organization, HasOrg, Plant, OperatesPlant, Account }
import from core.enums { Role, OrgType, PlantStatus }
import from core.hub { get_hub, all_accounts, all_orgs, all_plants, get_account, get_org, get_plant, account_by_persona }
import from core.access { AppError, Caller, require_admin, not_found, invalid, conflict }
import from core.audit { audit }
import from core.views { ActionResult }
import from core.config { settings, agent_label }
import from core.util { now, clean_text, id_list }
import from scheduling.slots { ensure_slots }
import from seed.demo_data { ensure_demo_seed }
import from jaclang.server.identity.app_tokens { token_create }

obj AccountView {
    has id: str,
        display_name: str,
        email: str,
        role: str,
        org_id: str,
        org_name: str,
        active: bool,
        linked: bool,
        persona_key: str,
        plant_ids: list[str],
        dispatch_plant_ids: list[str];
}

obj OrgView {
    has id: str,
        code: str,
        name: str,
        org_type: str,
        region: str,
        plants: list[str] = [];
}

obj PlantRef {
    has id: str,
        code: str,
        name: str,
        org_id: str,
        status: str,
        minerals: list[str];
}

obj AdminDirectory {
    has ok: bool,
        code: str = "",
        message: str = "",
        accounts: list[AccountView] = [],
        orgs: list[OrgView] = [],
        plants: list[PlantRef] = [],
        demo_mode: bool = False,
        agent_label: str = "";
}

obj InviteResult {
    has ok: bool,
        code: str = "",
        message: str = "",
        invite_code: str = "";
}

def account_view(a: Account) -> AccountView {
    org = get_org(a.org_id);
    return AccountView(
        id=jid(a), display_name=a.display_name, email=a.email, role=str(a.role), org_id=a.org_id,
        org_name=org.name if org is not None else "", active=a.active, linked=a.root_id != "",
        persona_key=a.persona_key, plant_ids=a.plant_ids, dispatch_plant_ids=a.dispatch_plant_ids
    );
}

def:protect admin_directory(poll: int = 0) -> AdminDirectory {
    _ = poll;
    try {
        require_admin();
        plants = all_plants();
        orgs = [OrgView(id=jid(o), code=o.code, name=o.name, org_type=str(o.org_type), region=o.region, plants=[p.name for p in plants if p.org_id == jid(o)]) for o in all_orgs()];
        return AdminDirectory(
            ok=True, accounts=[account_view(a) for a in sorted(all_accounts(), key=lambda (x: Account) { (str(x.role), x.display_name); })],
            orgs=orgs, plants=[PlantRef(id=jid(p), code=p.code, name=p.name, org_id=p.org_id, status=str(p.status), minerals=p.minerals) for p in plants],
            demo_mode=settings().demo_mode, agent_label=agent_label()
        );
    } except AppError as e {
        return AdminDirectory(ok=False, code=e.code, message=e.message);
    }
}

def _scope_problems(role: Role, org: Organization | None, plant_ids: list[str], dispatch_plant_ids: list[str]) -> list[str] {
    problems: list[str] = [];
    if org is None {
        return ["Unknown organization."];
    }
    expected = {
        Role.BUYER: OrgType.BUYER, Role.STORE_MANAGER: OrgType.PRODUCER, Role.LOADER: OrgType.PRODUCER,
        Role.DISPATCHER: OrgType.LOGISTICS, Role.DRIVER: OrgType.LOGISTICS, Role.ADMIN: OrgType.PLATFORM
    }[role];
    if org.org_type != expected {
        problems.append(str(role) + " accounts belong to a " + str(expected) + " organization.");
    }
    for pid in plant_ids {
        p = get_plant(pid);
        if p is None or p.org_id != jid(org) {
            problems.append("Store managers and loaders can only be scoped to their own organization's plants.");
            break;
        }
    }
    if role in [Role.STORE_MANAGER, Role.LOADER] and not plant_ids {
        problems.append("Choose at least one plant.");
    }
    for pid in dispatch_plant_ids {
        if get_plant(pid) is None {
            problems.append("Unknown plant in dispatch scope.");
            break;
        }
    }
    if role == Role.DISPATCHER and not dispatch_plant_ids {
        problems.append("Choose the plants this dispatcher covers.");
    }
    return problems;
}

def:protect admin_update_account(account_id: str, role: str, org_id: str, plant_ids: list[str], dispatch_plant_ids: list[str], active: bool) -> ActionResult {
    try {
        c = require_admin();
        plant_ids = id_list(plant_ids);
        dispatch_plant_ids = id_list(dispatch_plant_ids);
        a = get_account(account_id);
        if a is None {
            raise not_found("Account");
        }
        try {
            r = Role(role);
        } except ValueError {
            raise invalid("Unknown role.");
        }
        if account_id == c.account_id and (r != Role.ADMIN or not active) {
            raise conflict("You cannot remove your own administrator access.");
        }
        problems = _scope_problems(r, get_org(org_id), plant_ids, dispatch_plant_ids);
        if problems {
            raise invalid(" ".join(problems));
        }
        before = str(a.role) + " active=" + str(a.active);
        a.role = r;
        a.org_id = org_id;
        a.plant_ids = plant_ids if r in [Role.STORE_MANAGER, Role.LOADER] else [];
        a.dispatch_plant_ids = dispatch_plant_ids if r == Role.DISPATCHER else [];
        a.active = active;
        audit(c, "ACCOUNT_UPDATED", "Account", account_id, a.display_name + ": " + before + " -> " + role + " active=" + str(active));
        return ActionResult(ok=True, id=account_id, message="Account updated.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Single-use invite (platform token store; shown once, consumed atomically)."""
def:protect admin_create_invite(email: str, role: str, org_id: str, plant_ids: list[str] = [], dispatch_plant_ids: list[str] = [], license_class: str = "") -> InviteResult {
    try {
        c = require_admin();
        plant_ids = id_list(plant_ids);
        dispatch_plant_ids = id_list(dispatch_plant_ids);
        try {
            r = Role(role);
        } except ValueError {
            raise invalid("Unknown role.");
        }
        problems = _scope_problems(r, get_org(org_id), plant_ids, dispatch_plant_ids);
        if problems {
            raise invalid(" ".join(problems));
        }
        tok = token_create(
            "mineflow-invite", subject=c.account_id, ttl_seconds=7 * 86400,
            payload={"email": clean_text(email, 120), "role": role, "org_id": org_id, "plant_ids": plant_ids, "dispatch_plant_ids": dispatch_plant_ids, "license_class": license_class}
        );
        audit(c, "INVITE_CREATED", "Invite", "", role + " invite for " + clean_text(email, 120));
        return InviteResult(ok=True, invite_code=str(tok), message="Share this code once; it expires in 7 days.");
    } except AppError as e {
        return InviteResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect admin_create_org(code: str, name: str, org_type: str, region: str = "") -> ActionResult {
    try {
        c = require_admin();
        cd = clean_text(code, 8).upper();
        if len(cd) < 2 or len(clean_text(name, 80)) < 3 {
            raise invalid("Enter a short code and a name.");
        }
        try {
            ot = OrgType(org_type);
        } except ValueError {
            raise invalid("Unknown organization type.");
        }
        if any(o.code == cd for o in all_orgs()) {
            raise conflict("Organization code already used.");
        }
        o = Organization(code=cd, name=clean_text(name, 80), org_type=ot, region=clean_text(region, 60));
        get_hub() +>:HasOrg():+> o;
        audit(c, "ORG_CREATED", "Organization", jid(o), o.name + " (" + org_type + ")");
        return ActionResult(ok=True, id=jid(o), message="Organization created.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect admin_create_plant(org_id: str, code: str, name: str, lat: float, lng: float, region: str, minerals: list[str], bays: int = 2) -> ActionResult {
    try {
        c = require_admin();
        minerals = id_list(minerals);
        org = get_org(org_id);
        if org is None or org.org_type != OrgType.PRODUCER {
            raise invalid("Plants belong to a producer organization.");
        }
        cd = clean_text(code, 8).upper();
        if any(p.code == cd for p in all_plants()) {
            raise conflict("Plant code already used.");
        }
        if not (5.5 <= lat and lat <= 10.2 and 79.3 <= lng and lng <= 82.2) {
            raise invalid("Coordinates must be inside Sri Lanka for this deployment.");
        }
        if not minerals or bays < 1 or bays > 8 {
            raise invalid("Choose at least one mineral and 1-8 loading bays.");
        }
        p = Plant(code=cd, name=clean_text(name, 80), org_id=org_id, lat=lat, lng=lng, region=clean_text(region, 60), minerals=minerals, bays=bays);
        org +>:OperatesPlant():+> p;
        ensure_slots(p, 3);
        audit(c, "PLANT_CREATED", "Plant", jid(p), p.name, "", [jid(p)]);
        return ActionResult(ok=True, id=jid(p), message="Plant created with a 3-day slot grid.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

"""Collects every node reachable from the hub (for a demo reset)."""
walker:priv GraphCollector {
    has seen: dict[str, bool] = {},
        nodes: list[DomainNode] = [];

    can collect with DomainNode entry {
        key = jid(here);
        if key in self.seen {
            skip;
        }
        self.seen[key] = True;
        self.nodes.append(here);
        visit [here -->];
    }
}

"""DEMO ONLY: wipe the operational graph and re-seed the scenario."""
def:protect admin_reset_demo(confirm_text: str) -> ActionResult {
    try {
        c = require_admin();
        if not settings().demo_mode {
            raise AppError(code="DEMO_DISABLED", message="Demo reset is only available in demo mode.");
        }
        if confirm_text != "RESET DEMO" {
            raise invalid("Type RESET DEMO to confirm.");
        }
        persona = c.account.persona_key;
        rid = c.account.root_id;
        hub = get_hub();
        w = hub spawn GraphCollector();
        count = len(w.nodes);
        for n in w.nodes {
            del n;
        }
        ensure_demo_seed();
        if persona {
            me = account_by_persona(persona);
            if me is not None {
                me.root_id = rid;
            }
        }
        audit(None, "DEMO_RESET", "Hub", "", "Demo scenario reset by " + c.account.display_name + " (" + str(count) + " nodes removed)");
        return ActionResult(ok=True, message="Demo scenario reset (" + str(count) + " records replaced). Other demo users re-link on their next sign-in.");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}
