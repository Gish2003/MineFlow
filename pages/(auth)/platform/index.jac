"""Directory: every account, its role, organization and scope. Admin-only."""

import from "sonner" { toast }
import from ....admin.store { admin_directory, admin_update_account, AccountView, OrgView, PlantRef }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StateViews { LoadingRows, ErrorState }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.badge { Badge }
import from ....components.ui.switch { Switch }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ....components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogFooter }
import from ....components.ui.button { Button }
import from ....components.ui.field { Field, FieldLabel, FieldGroup }

glob ROLES: list[str] = ["BUYER", "STORE_MANAGER", "DISPATCHER", "LOADER", "DRIVER", "ADMIN"];

def:pub DirectoryPage() -> JsxPage {
    has accounts: list[AccountView] = [],
        orgs: list[OrgView] = [],
        plants: list[PlantRef] = [],
        loading: bool = True,
        error: str = "",
        editing: str = "",
        e_role: str = "",
        e_org: str = "",
        e_plant_ids: list[str] = [],
        e_dispatch_ids: list[str] = [],
        e_active: bool = True,
        saving: bool = False;

    poll_seq = usePoll(20000);

    async def load {
        try {
            result = await admin_directory(poll_seq);
            if result.ok {
                accounts = result.accounts;
                orgs = result.orgs;
                plants = result.plants;
            } else {
                error = result.message or "Could not load the directory.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    def open_edit(a: AccountView) {
        editing = a.id;
        e_role = a.role;
        e_org = a.org_id;
        e_plant_ids = a.plant_ids;
        e_dispatch_ids = a.dispatch_plant_ids;
        e_active = a.active;
    }

    def toggle_plant(pid: str) {
        if pid in e_plant_ids {
            e_plant_ids = [x for x in e_plant_ids if x != pid];
        } else {
            e_plant_ids = e_plant_ids + [pid];
        }
    }

    def toggle_dispatch(pid: str) {
        if pid in e_dispatch_ids {
            e_dispatch_ids = [x for x in e_dispatch_ids if x != pid];
        } else {
            e_dispatch_ids = e_dispatch_ids + [pid];
        }
    }

    async def save_account {
        saving = True;
        try {
            result = await admin_update_account(editing, e_role, e_org, e_plant_ids, e_dispatch_ids, e_active);
            if result.ok {
                toast.success(result.message);
                editing = "";
                await load();
            } else {
                toast.error(result.message or "Could not update this account.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Directory" description="Users, roles, organizations and scope." />

        {if loading {
            <LoadingRows count={5} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}

        <Card>
            <CardContent className="p-0">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>Name</TableHead>
                            <TableHead>Role</TableHead>
                            <TableHead>Organization</TableHead>
                            <TableHead>Scope</TableHead>
                            <TableHead>Active</TableHead>
                            <TableHead></TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {for a in accounts {
                            <TableRow key={a.id}>
                                <TableCell className="font-medium">{a.display_name}<span className="block text-xs text-muted-foreground">{a.email or "(demo persona)"}</span></TableCell>
                                <TableCell><Badge variant="outline">{a.role}</Badge></TableCell>
                                <TableCell className="text-muted-foreground">{a.org_name}</TableCell>
                                <TableCell className="text-xs text-muted-foreground">{", ".join(a.plant_ids + a.dispatch_plant_ids) or "-"}</TableCell>
                                <TableCell>{a.active and <Badge>Active</Badge> or <Badge variant="destructive">Inactive</Badge>}</TableCell>
                                <TableCell>
                                    <Dialog>
                                        <DialogTrigger asChild={True}><Button size="sm" variant="ghost" onClick={lambda { open_edit(a); }}>Edit</Button></DialogTrigger>
                                        <DialogContent>
                                            <DialogHeader><DialogTitle>Edit {a.display_name}</DialogTitle></DialogHeader>
                                            <FieldGroup>
                                                <Field>
                                                    <FieldLabel htmlFor="er">Role</FieldLabel>
                                                    <Select value={e_role} onValueChange={lambda (v: str) { e_role = v; }}>
                                                        <SelectTrigger id="er"><SelectValue /></SelectTrigger>
                                                        <SelectContent>
                                                            {for r in ROLES {
                                                                <SelectItem key={r} value={r}>{r}</SelectItem>
                                                            }}
                                                        </SelectContent>
                                                    </Select>
                                                </Field>
                                                <Field>
                                                    <FieldLabel htmlFor="eo">Organization</FieldLabel>
                                                    <Select value={e_org} onValueChange={lambda (v: str) { e_org = v; }}>
                                                        <SelectTrigger id="eo"><SelectValue /></SelectTrigger>
                                                        <SelectContent>
                                                            {for o in orgs {
                                                                <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                                                            }}
                                                        </SelectContent>
                                                    </Select>
                                                </Field>
                                                {(e_role == "STORE_MANAGER" or e_role == "LOADER") and
                                                    <Field>
                                                        <FieldLabel>Plants</FieldLabel>
                                                        <div className="flex flex-wrap gap-2">
                                                            {for p in plants {
                                                                <Button key={p.id} type="button" size="sm" variant={p.id in e_plant_ids and "default" or "outline"} onClick={lambda { toggle_plant(p.id); }}>{p.code}</Button>
                                                            }}
                                                        </div>
                                                    </Field>
                                                or None}
                                                {e_role == "DISPATCHER" and
                                                    <Field>
                                                        <FieldLabel>Dispatch scope (plants covered)</FieldLabel>
                                                        <div className="flex flex-wrap gap-2">
                                                            {for p in plants {
                                                                <Button key={p.id} type="button" size="sm" variant={p.id in e_dispatch_ids and "default" or "outline"} onClick={lambda { toggle_dispatch(p.id); }}>{p.code}</Button>
                                                            }}
                                                        </div>
                                                    </Field>
                                                or None}
                                                <Field>
                                                    <FieldLabel htmlFor="ea">Active</FieldLabel>
                                                    <Switch id="ea" checked={e_active} onCheckedChange={lambda (v: bool) { e_active = v; }} />
                                                </Field>
                                            </FieldGroup>
                                            <DialogFooter><Button disabled={saving} onClick={save_account}>Save</Button></DialogFooter>
                                        </DialogContent>
                                    </Dialog>
                                </TableCell>
                            </TableRow>
                        }}
                    </TableBody>
                </Table>
            </CardContent>
        </Card>
    </div>
}
