"""Public sign-in page. The seeded "sign in as ..." list is clearly labelled
DEMO ONLY (per AGENTS.md section 3) - it is not production authentication.
Real provisioning goes through an admin-issued invite code, or a one-time
bootstrap admin code when no administrator exists yet."""

import from "@jac/runtime" { jacLogin, jacSignup, SignupResult, useNavigate }
import from "sonner" { toast }
import from ..identity.session {
    platform_status, demo_personas, claim_demo_persona, redeem_invite, redeem_bootstrap_admin,
    DemoPersonaCard, PlatformStatus
}
import from ..components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ..components.ui.button { Button }
import from ..components.ui.badge { Badge }
import from ..components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from ..components.ui.field { Field, FieldLabel, FieldGroup }
import from ..components.ui.input { Input }
import from ..components.ui.separator { Separator }
import from ..components.ui.alert { Alert, AlertDescription }
import from ..shell.StateViews { LoadingRows }
import from "@hugeicons/react" { HugeiconsIcon }
import from "@hugeicons/core-free-icons" { TruckDeliveryIcon }

glob ROLE_HOME: dict[str, str] = {
    "BUYER": "/buyer", "STORE_MANAGER": "/plant", "DISPATCHER": "/dispatch",
    "LOADER": "/loader", "DRIVER": "/driver", "ADMIN": "/platform"
};

def:pub LoginPage() -> JsxPage {
    has status: PlatformStatus | None = None,
        personas: list[DemoPersonaCard] = [],
        loading: bool = True,
        busy_key: str = "",
        invite_email: str = "",
        invite_password: str = "",
        invite_name: str = "",
        invite_code: str = "",
        invite_busy: bool = False,
        admin_email: str = "",
        admin_password: str = "",
        admin_name: str = "",
        admin_code: str = "",
        admin_busy: bool = False,
        done: bool = False;

    nav = useNavigate();

    async can with entry {
        try {
            status = await platform_status();
            personas = await demo_personas();
        } except Exception {
            status = None;
        }
        loading = False;
    }

    def go_home(role: str) {
        done = True;
        nav(ROLE_HOME[role] or "/login");
    }

    async def sign_in_as(p: DemoPersonaCard) {
        cfg = status;
        if cfg is None {
            return;
        }
        busy_key = p.key;
        try {
            pwd = cfg.demo_password;
            ok: bool = False;
            ok = await jacLogin(p.email, pwd);
            if not ok {
                signup_result: SignupResult | None = None;
                signup_result = await jacSignup(p.email, pwd);
                _ = signup_result;
                ok = await jacLogin(p.email, pwd);
            }
            if not ok {
                toast.error("Could not sign in as " + p.display_name + ".");
                busy_key = "";
                return;
            }
            claimed = await claim_demo_persona(p.key);
            cdata = claimed.data;
            if claimed.ok and cdata is not None {
                toast.success("Signed in as " + cdata.display_name);
                go_home(cdata.role);
            } else {
                toast.error(claimed.message or "This demo persona is unavailable.");
            }
        } except Exception {
            toast.error("Sign-in failed. Please try again.");
        }
        busy_key = "";
    }

    async def submit_invite {
        if len(invite_email) < 3 or len(invite_password) < 8 or len(invite_name) < 2 or len(invite_code) < 3 {
            toast.error("Fill in your email, a password of 8+ characters, your name and the invite code.");
            return;
        }
        invite_busy = True;
        try {
            signup_result: SignupResult | None = None;
            signup_result = await jacSignup(invite_email, invite_password);
            if not signup_result.success {
                toast.error(signup_result.error or "Could not create an account with that email.");
                invite_busy = False;
                return;
            }
            login_ok: bool = False;
            login_ok = await jacLogin(invite_email, invite_password);
            if not login_ok {
                toast.error("Account created, but sign-in failed. Try signing in again.");
                invite_busy = False;
                return;
            }
            joined = await redeem_invite(invite_code, invite_name);
            jdata = joined.data;
            if joined.ok and jdata is not None {
                toast.success("Welcome, " + jdata.display_name);
                go_home(jdata.role);
            } else {
                toast.error(joined.message or "That invite code is invalid, expired or already used.");
            }
        } except Exception {
            toast.error("Could not redeem the invite. Please try again.");
        }
        invite_busy = False;
    }

    async def submit_admin {
        if len(admin_email) < 3 or len(admin_password) < 8 or len(admin_name) < 2 or len(admin_code) < 3 {
            toast.error("Fill in your email, a password of 8+ characters, your name and the admin code.");
            return;
        }
        admin_busy = True;
        try {
            signup_result: SignupResult | None = None;
            signup_result = await jacSignup(admin_email, admin_password);
            if not signup_result.success {
                toast.error(signup_result.error or "Could not create an account with that email.");
                admin_busy = False;
                return;
            }
            login_ok: bool = False;
            login_ok = await jacLogin(admin_email, admin_password);
            if not login_ok {
                toast.error("Account created, but sign-in failed. Try signing in again.");
                admin_busy = False;
                return;
            }
            created = await redeem_bootstrap_admin(admin_code, admin_name);
            if created.ok {
                toast.success("Administrator account created.");
                go_home("ADMIN");
            } else {
                toast.error(created.message or "That bootstrap code did not work.");
            }
        } except Exception {
            toast.error("Could not create the administrator account.");
        }
        admin_busy = False;
    }

    if done {
        return <p className="p-8 text-sm text-muted-foreground">Signing you in…</p>;
    }

    agent_note: str = "";
    if status is not None {
        agent_note = "AI dispatch planning: live agent." if status.llm_enabled else "AI dispatch planning: deterministic fallback (no LLM key configured).";
    }

    <div className="flex min-h-svh flex-col items-center justify-center gap-8 pt-12 pb-12 pl-4 pr-4">
        <div className="flex items-center gap-2">
            <div className="flex size-9 items-center justify-center rounded-lg bg-primary text-primary-foreground">
                <HugeiconsIcon icon={TruckDeliveryIcon} strokeWidth={2} className="size-5" />
            </div>
            <span className="text-xl font-bold tracking-tight">MineFlow AI</span>
        </div>

        {if loading {
            <div className="w-full max-w-lg"><LoadingRows count={4} /></div>
            skip;
        }}

        <Card className="w-full max-w-lg">
            <CardHeader>
                <CardTitle>Sign in</CardTitle>
                <CardDescription>Mineral ordering, dispatch and delivery.</CardDescription>
            </CardHeader>
            <CardContent>
                <Tabs defaultValue="demo">
                    <TabsList className="w-full">
                        <TabsTrigger value="demo" className="flex-1">Demo sign-in</TabsTrigger>
                        <TabsTrigger value="invite" className="flex-1">Invite code</TabsTrigger>
                        <TabsTrigger value="admin" className="flex-1">Bootstrap admin</TabsTrigger>
                    </TabsList>

                    <TabsContent value="demo" className="pt-4">
                        {if not personas {
                            <Alert><AlertDescription>Demo sign-in is disabled on this deployment. Use an invite code instead.</AlertDescription></Alert>
                            skip;
                        }}
                        <div className="mb-3 flex items-center gap-2">
                            <Badge variant="outline">DEMO</Badge>
                            <p className="text-xs text-muted-foreground">Seeded accounts for demonstration only - not production authentication.</p>
                        </div>
                        <div className="flex flex-col gap-2">
                            {for p in personas {
                                <button
                                    key={p.key}
                                    disabled={busy_key != ""}
                                    onClick={lambda { sign_in_as(p); }}
                                    className="flex items-center justify-between rounded-xl border p-3 text-left text-sm transition-colors hover:bg-muted disabled:opacity-60"
                                >
                                    <div className="flex flex-col">
                                        <span className="font-medium">{p.display_name}</span>
                                        <span className="text-xs text-muted-foreground">{p.org_name} · {p.blurb}</span>
                                    </div>
                                    <Badge variant="secondary">{busy_key == p.key and "Signing in…" or p.role}</Badge>
                                </button>
                            }}
                        </div>
                    </TabsContent>

                    <TabsContent value="invite" className="pt-4">
                        <FieldGroup>
                            <Field>
                                <FieldLabel htmlFor="invite-email">Email</FieldLabel>
                                <Input id="invite-email" type="email" value={invite_email} onChange={lambda (e: ChangeEvent) { invite_email = e.target.value; }} />
                            </Field>
                            <Field>
                                <FieldLabel htmlFor="invite-password">Choose a password</FieldLabel>
                                <Input id="invite-password" type="password" value={invite_password} onChange={lambda (e: ChangeEvent) { invite_password = e.target.value; }} />
                            </Field>
                            <Field>
                                <FieldLabel htmlFor="invite-name">Full name</FieldLabel>
                                <Input id="invite-name" value={invite_name} onChange={lambda (e: ChangeEvent) { invite_name = e.target.value; }} />
                            </Field>
                            <Field>
                                <FieldLabel htmlFor="invite-code">Invite code</FieldLabel>
                                <Input id="invite-code" value={invite_code} onChange={lambda (e: ChangeEvent) { invite_code = e.target.value; }} />
                            </Field>
                            <Button className="w-full" disabled={invite_busy} onClick={submit_invite}>{invite_busy and "Joining…" or "Join MineFlow"}</Button>
                        </FieldGroup>
                    </TabsContent>

                    <TabsContent value="admin" className="pt-4">
                        <p className="mb-3 text-xs text-muted-foreground">Only works while no administrator account exists yet.</p>
                        <FieldGroup>
                            <Field>
                                <FieldLabel htmlFor="admin-email">Email</FieldLabel>
                                <Input id="admin-email" type="email" value={admin_email} onChange={lambda (e: ChangeEvent) { admin_email = e.target.value; }} />
                            </Field>
                            <Field>
                                <FieldLabel htmlFor="admin-password">Choose a password</FieldLabel>
                                <Input id="admin-password" type="password" value={admin_password} onChange={lambda (e: ChangeEvent) { admin_password = e.target.value; }} />
                            </Field>
                            <Field>
                                <FieldLabel htmlFor="admin-name">Full name</FieldLabel>
                                <Input id="admin-name" value={admin_name} onChange={lambda (e: ChangeEvent) { admin_name = e.target.value; }} />
                            </Field>
                            <Field>
                                <FieldLabel htmlFor="admin-code">Bootstrap admin code</FieldLabel>
                                <Input id="admin-code" value={admin_code} onChange={lambda (e: ChangeEvent) { admin_code = e.target.value; }} />
                            </Field>
                            <Button className="w-full" variant="outline" disabled={admin_busy} onClick={submit_admin}>{admin_busy and "Creating…" or "Create administrator"}</Button>
                        </FieldGroup>
                    </TabsContent>
                </Tabs>
            </CardContent>
            <CardFooter>
                <p className="w-full text-center text-xs text-muted-foreground">{agent_note}</p>
            </CardFooter>
        </Card>
    </div>
}
