"""Organizations & Plants: the producer/buyer/logistics companies and the
mining plants they operate."""

import from "sonner" { toast }
import from ....admin.store { admin_directory, admin_create_org, admin_create_plant, OrgView, PlantRef }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.field { Field, FieldLabel, FieldGroup }
import from ....components.ui.input { Input }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ....components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }

def:pub OrgsPage() -> JsxPage {
    has orgs: list[OrgView] = [],
        plants: list[PlantRef] = [],
        loading: bool = True,
        error: str = "",
        saving: bool = False,

        org_code: str = "",
        org_name: str = "",
        org_type: str = "PRODUCER",
        org_region: str = "",

        plant_org: str = "",
        plant_code: str = "",
        plant_name: str = "",
        plant_lat: str = "",
        plant_lng: str = "",
        plant_region: str = "",
        plant_minerals: str = "",
        plant_bays: str = "2";

    poll_seq = usePoll(20000);

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

    async def submit_org {
        if len(org_code) < 2 or len(org_name) < 3 {
            toast.error("Enter a short code and a name.");
            return;
        }
        saving = True;
        try {
            result = await admin_create_org(org_code, org_name, org_type, org_region);
            if result.ok {
                toast.success(result.message);
                org_code = "";
                org_name = "";
                org_region = "";
                await load();
            } else {
                toast.error(result.message or "Could not create this organization.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    async def submit_plant {
        lat = float(plant_lat) if plant_lat else 0.0;
        lng = float(plant_lng) if plant_lng else 0.0;
        bays = int(plant_bays) if plant_bays else 2;
        minerals = [m.strip().upper() for m in plant_minerals.split(",") if m.strip()];
        if not plant_org or len(plant_code) < 2 or len(plant_name) < 3 {
            toast.error("Choose an organization and enter a code and name.");
            return;
        }
        saving = True;
        try {
            result = await admin_create_plant(plant_org, plant_code, plant_name, lat, lng, plant_region, minerals, bays);
            if result.ok {
                toast.success(result.message);
                plant_code = "";
                plant_name = "";
                plant_lat = "";
                plant_lng = "";
                plant_region = "";
                plant_minerals = "";
                await load();
            } else {
                toast.error(result.message or "Could not create this plant.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Organizations & Plants" description="Producers, buyers, logistics companies and the plants they operate." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <Card>
                <CardHeader>
                    <CardTitle>Organizations</CardTitle>
                    <CardDescription>{str(len(orgs))} total</CardDescription>
                </CardHeader>
                <CardContent className="p-0">
                    <Table>
                        <TableHeader><TableRow><TableHead>Code</TableHead><TableHead>Name</TableHead><TableHead>Type</TableHead><TableHead>Plants</TableHead></TableRow></TableHeader>
                        <TableBody>
                            {for o in orgs {
                                <TableRow key={o.id}>
                                    <TableCell className="font-medium">{o.code}</TableCell>
                                    <TableCell>{o.name}</TableCell>
                                    <TableCell><StatusChip status={o.org_type} /></TableCell>
                                    <TableCell className="text-muted-foreground">{", ".join(o.plants) or "-"}</TableCell>
                                </TableRow>
                            }}
                        </TableBody>
                    </Table>
                </CardContent>
                <CardFooter>
                    <Dialog>
                        <DialogTrigger asChild={True}><Button variant="outline" className="w-full">Add organization</Button></DialogTrigger>
                        <DialogContent>
                            <DialogHeader><DialogTitle>New organization</DialogTitle></DialogHeader>
                            <FieldGroup>
                                <Field><FieldLabel htmlFor="oc">Code</FieldLabel><Input id="oc" value={org_code} onChange={lambda (e: ChangeEvent) { org_code = e.target.value; }} /></Field>
                                <Field><FieldLabel htmlFor="on">Name</FieldLabel><Input id="on" value={org_name} onChange={lambda (e: ChangeEvent) { org_name = e.target.value; }} /></Field>
                                <Field>
                                    <FieldLabel htmlFor="ot">Type</FieldLabel>
                                    <Select value={org_type} onValueChange={lambda (v: str) { org_type = v; }}>
                                        <SelectTrigger id="ot"><SelectValue /></SelectTrigger>
                                        <SelectContent>
                                            <SelectItem value="PRODUCER">Producer</SelectItem>
                                            <SelectItem value="BUYER">Buyer</SelectItem>
                                            <SelectItem value="LOGISTICS">Logistics</SelectItem>
                                        </SelectContent>
                                    </Select>
                                </Field>
                                <Field><FieldLabel htmlFor="or">Region</FieldLabel><Input id="or" value={org_region} onChange={lambda (e: ChangeEvent) { org_region = e.target.value; }} /></Field>
                            </FieldGroup>
                            <DialogFooter><Button disabled={saving} onClick={submit_org}>Create</Button></DialogFooter>
                        </DialogContent>
                    </Dialog>
                </CardFooter>
            </Card>

            <Card>
                <CardHeader>
                    <CardTitle>Plants</CardTitle>
                    <CardDescription>{str(len(plants))} total</CardDescription>
                </CardHeader>
                <CardContent className="p-0">
                    <Table>
                        <TableHeader><TableRow><TableHead>Code</TableHead><TableHead>Name</TableHead><TableHead>Status</TableHead><TableHead>Minerals</TableHead></TableRow></TableHeader>
                        <TableBody>
                            {for p in plants {
                                <TableRow key={p.id}>
                                    <TableCell className="font-medium">{p.code}</TableCell>
                                    <TableCell>{p.name}</TableCell>
                                    <TableCell><StatusChip status={p.status} /></TableCell>
                                    <TableCell className="text-muted-foreground">{", ".join(p.minerals)}</TableCell>
                                </TableRow>
                            }}
                        </TableBody>
                    </Table>
                </CardContent>
                <CardFooter>
                    <Dialog>
                        <DialogTrigger asChild={True}><Button variant="outline" className="w-full">Add plant</Button></DialogTrigger>
                        <DialogContent>
                            <DialogHeader><DialogTitle>New plant</DialogTitle><DialogDescription>Coordinates must be inside Sri Lanka for this deployment.</DialogDescription></DialogHeader>
                            <FieldGroup>
                                <Field>
                                    <FieldLabel htmlFor="pgo">Organization</FieldLabel>
                                    <Select value={plant_org} onValueChange={lambda (v: str) { plant_org = v; }}>
                                        <SelectTrigger id="pgo"><SelectValue placeholder="Choose producer org" /></SelectTrigger>
                                        <SelectContent>
                                            {for o in orgs {
                                                <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                                            }}
                                        </SelectContent>
                                    </Select>
                                </Field>
                                <Field><FieldLabel htmlFor="pc">Code</FieldLabel><Input id="pc" value={plant_code} onChange={lambda (e: ChangeEvent) { plant_code = e.target.value; }} /></Field>
                                <Field><FieldLabel htmlFor="pn">Name</FieldLabel><Input id="pn" value={plant_name} onChange={lambda (e: ChangeEvent) { plant_name = e.target.value; }} /></Field>
                                <div className="grid grid-cols-2 gap-4">
                                    <Field><FieldLabel htmlFor="plt">Latitude</FieldLabel><Input id="plt" type="number" value={plant_lat} onChange={lambda (e: ChangeEvent) { plant_lat = e.target.value; }} /></Field>
                                    <Field><FieldLabel htmlFor="plg">Longitude</FieldLabel><Input id="plg" type="number" value={plant_lng} onChange={lambda (e: ChangeEvent) { plant_lng = e.target.value; }} /></Field>
                                </div>
                                <Field><FieldLabel htmlFor="pr">Region</FieldLabel><Input id="pr" value={plant_region} onChange={lambda (e: ChangeEvent) { plant_region = e.target.value; }} /></Field>
                                <Field><FieldLabel htmlFor="pm">Minerals (comma separated codes)</FieldLabel><Input id="pm" value={plant_minerals} onChange={lambda (e: ChangeEvent) { plant_minerals = e.target.value; }} placeholder="LIMESTONE, DOLOMITE" /></Field>
                                <Field><FieldLabel htmlFor="pb">Loading bays</FieldLabel><Input id="pb" type="number" value={plant_bays} onChange={lambda (e: ChangeEvent) { plant_bays = e.target.value; }} /></Field>
                            </FieldGroup>
                            <DialogFooter><Button disabled={saving} onClick={submit_plant}>Create</Button></DialogFooter>
                        </DialogContent>
                    </Dialog>
                </CardFooter>
            </Card>
        </div>
    </div>
}
