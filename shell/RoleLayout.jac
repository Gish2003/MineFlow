"""Guards a role's route group: loads the session once, bounces anonymous or
wrong-role visitors, and wraps the matched child route in RoleShell. This is
a UX convenience only - every real authorization check happens server-side
in core/access.jac on each endpoint, per AGENTS.md section 3."""

import from "@jac/runtime" { Navigate }
import from .RoleShell { RoleShell }
import from ..hooks.useSession { useSession }
import from ..identity.session { SessionView }

glob ROLE_HOME: dict[str, str] = {
    "BUYER": "/buyer", "STORE_MANAGER": "/plant", "DISPATCHER": "/dispatch",
    "LOADER": "/loader", "DRIVER": "/driver", "ADMIN": "/platform"
};

def:pub RoleLayout(role: str, children: any = None) -> JsxElement {
    data = useSession();
    loading = data["loading"] as bool;
    session: SessionView | None = data["session"] as SessionView | None;

    if loading {
        return <div className="flex min-h-svh items-center justify-center">
            <p className="text-sm text-muted-foreground">Loading your workspace…</p>
        </div>;
    }
    if session is None {
        return <Navigate to="/login" replace={True} />;
    }
    actual_role = session.role as str;
    if actual_role != role {
        return <Navigate to={ROLE_HOME[actual_role] or "/login"} replace={True} />;
    }
    <RoleShell
        role={role}
        display_name={session.display_name as str}
        org_name={session.org_name as str}
        demo_mode={session.demo_mode as bool}
        agent_label={session.agent_label as str}
    >
        {children}
    </RoleShell>
}
