"""Invites: single-use codes that let a new user join with a specific role,
organization and scope."""

import from "sonner" { toast }
import from ....admin.store { admin_directory, admin_create_invite, OrgView, PlantRef }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StateViews { LoadingRows, ErrorState }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.field { Field, FieldLabel, FieldGroup }
import from ....components.ui.input { Input }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ....components.ui.badge { Badge }

glob ROLES: list[str] = ["BUYER", "STORE_MANAGER", "DISPATCHER", "LOADER", "DRIVER"];

def:pub InvitesPage() -> JsxPage {
    has orgs: list[OrgView] = [],
        plants: list[PlantRef] = [],
        loading: bool = True,
        error: str = "",
        sending: bool = False,
        last_code: str = "",

        inv_email: str = "",
        inv_role: str = "DRIVER",
        inv_org: str = "",
        inv_plant_ids: list[str] = [],
        inv_dispatch_ids: list[str] = [],
        inv_license: str = "";

    poll_seq = usePoll(30000);

    async def load {
        try {
            result = await admin_directory(poll_seq);
            if result.ok {
                orgs = result.orgs;
                plants = result.plants;
            } else {
                error = result.message or "Could not load organizations.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    def toggle_plant(pid: str) {
        if pid in inv_plant_ids {
            inv_plant_ids = [x for x in inv_plant_ids if x != pid];
        } else {
            inv_plant_ids = inv_plant_ids + [pid];
        }
    }

    def toggle_dispatch(pid: str) {
        if pid in inv_dispatch_ids {
            inv_dispatch_ids = [x for x in inv_dispatch_ids if x != pid];
        } else {
            inv_dispatch_ids = inv_dispatch_ids + [pid];
        }
    }

    async def submit {
        if len(inv_email) < 3 or not inv_org {
            toast.error("Enter an email and choose an organization.");
            return;
        }
        sending = True;
        try {
            result = await admin_create_invite(inv_email, inv_role, inv_org, inv_plant_ids, inv_dispatch_ids, inv_license);
            if result.ok {
                last_code = result.invite_code;
                toast.success("Invite created - share this code once.");
                inv_email = "";
            } else {
                toast.error(result.message or "Could not create this invite.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        sending = False;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Invites" description="Issue a single-use code so a new user can join with the right role and scope." />

        {if loading {
            <LoadingRows count={3} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}

        <Card className="max-w-xl">
            <CardHeader>
                <CardTitle>New invite</CardTitle>
                <CardDescription>Expires in 7 days and can be redeemed once.</CardDescription>
            </CardHeader>
            <CardContent>
                <FieldGroup>
                    <Field><FieldLabel htmlFor="ie">Email</FieldLabel><Input id="ie" type="email" value={inv_email} onChange={lambda (e: ChangeEvent) { inv_email = e.target.value; }} /></Field>
                    <Field>
                        <FieldLabel htmlFor="ir">Role</FieldLabel>
                        <Select value={inv_role} onValueChange={lambda (v: str) { inv_role = v; inv_plant_ids = []; inv_dispatch_ids = []; }}>
                            <SelectTrigger id="ir"><SelectValue /></SelectTrigger>
                            <SelectContent>
                                {for r in ROLES {
                                    <SelectItem key={r} value={r}>{r}</SelectItem>
                                }}
                            </SelectContent>
                        </Select>
                    </Field>
                    <Field>
                        <FieldLabel htmlFor="io">Organization</FieldLabel>
                        <Select value={inv_org} onValueChange={lambda (v: str) { inv_org = v; }}>
                            <SelectTrigger id="io"><SelectValue placeholder="Choose an organization" /></SelectTrigger>
                            <SelectContent>
                                {for o in orgs {
                                    <SelectItem key={o.id} value={o.id}>{o.name} ({o.org_type})</SelectItem>
                                }}
                            </SelectContent>
                        </Select>
                    </Field>
                    {(inv_role == "STORE_MANAGER" or inv_role == "LOADER") and
                        <Field>
                            <FieldLabel>Plants</FieldLabel>
                            <div className="flex flex-wrap gap-2">
                                {for p in plants {
                                    <Button key={p.id} type="button" size="sm" variant={p.id in inv_plant_ids and "default" or "outline"} onClick={lambda { toggle_plant(p.id); }}>{p.code}</Button>
                                }}
                            </div>
                        </Field>
                    or None}
                    {inv_role == "DISPATCHER" and
                        <Field>
                            <FieldLabel>Dispatch scope</FieldLabel>
                            <div className="flex flex-wrap gap-2">
                                {for p in plants {
                                    <Button key={p.id} type="button" size="sm" variant={p.id in inv_dispatch_ids and "default" or "outline"} onClick={lambda { toggle_dispatch(p.id); }}>{p.code}</Button>
                                }}
                            </div>
                        </Field>
                    or None}
                    {inv_role == "DRIVER" and
                        <Field><FieldLabel htmlFor="il">License class</FieldLabel><Input id="il" value={inv_license} onChange={lambda (e: ChangeEvent) { inv_license = e.target.value; }} placeholder="HEAVY" /></Field>
                    or None}
                </FieldGroup>
            </CardContent>
            <CardFooter className="flex flex-col items-start gap-3">
                <Button disabled={sending} onClick={submit}>{sending and "Creating…" or "Create invite"}</Button>
                {last_code and
                    <div className="flex items-center gap-2">
                        <span className="text-sm text-muted-foreground">Code:</span>
                        <Badge variant="secondary" className="font-mono">{last_code}</Badge>
                    </div>
                or None}
            </CardFooter>
        </Card>
    </div>
}
