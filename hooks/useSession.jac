"""Fetches the signed-in MineFlow account once per mount. Reused by every role
layout (identical fetch+state shape), so it lives in hooks/ rather than being
duplicated six times - see jac-cl-organization."""

import from ..identity.session { whoami, SessionView }

def:pub useSession() -> dict[str, any] {
    has session: SessionView | None = None,
        loading: bool = True,
        error: str = "";

    async can with entry {
        try {
            result = await whoami();
            if result.ok {
                session = result.data;
            } else {
                error = result.message or "Could not load your account.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    return {"session": session, "loading": loading, "error": error};
}
