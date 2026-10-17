"""Protected root: redirect straight to the signed-in account's dashboard."""

import from "@jac/runtime" { Navigate }
import from ...hooks.useSession { useSession }
import from ...identity.session { SessionView }

glob ROLE_HOME: dict[str, str] = {
    "BUYER": "/buyer", "STORE_MANAGER": "/plant", "DISPATCHER": "/dispatch",
    "LOADER": "/loader", "DRIVER": "/driver", "ADMIN": "/platform"
};

def:pub RoleRedirect() -> JsxPage {
    data = useSession();
    loading = data["loading"] as bool;
    session: SessionView | None = data["session"] as SessionView | None;
    error = data["error"] as str;

    if loading {
        return <p className="p-8 text-sm text-muted-foreground">Loading your account…</p>;
    }
    if session is not None {
        role = session.role as str;
        return <Navigate to={ROLE_HOME[role] or "/login"} replace={True} />;
    }
    _ = error;
    return <Navigate to="/login" replace={True} />;
}
