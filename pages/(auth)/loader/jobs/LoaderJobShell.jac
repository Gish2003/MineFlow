"""Loader job flow (mobile-first): claim, check in, verify material/truck/
order before loading is authorized, record quantity and ticket, attach
evidence, and track the service fee."""

import from "@jac/runtime" { useNavigate }
import from "sonner" { toast }
import from .....loading.store {
    loader_job, claim_loading_job, loader_check_in, verify_and_start_loading,
    finish_loading, loader_update, LoaderJobView
}
import from .....evidence.store { upload_evidence }
import from .....shell.PageHeader { PageHeader }
import from .....shell.StatusChip { StatusChip }
import from .....shell.StateViews { LoadingRows, ErrorState }
import from .....shell.format { fmt_clock, fmt_t, fmt_money }
import from .....hooks.usePoll { usePoll }
import from .....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from .....components.ui.button { Button }
import from .....components.ui.badge { Badge }
import from .....components.ui.field { Field, FieldLabel, FieldGroup }
import from .....components.ui.input { Input }
import from .....components.ui.separator { Separator }

def:pub LoaderJobShell(shipmentId: str) -> JsxElement {
    has job: LoaderJobView | None = None,
        loading: bool = True,
        error: str = "",
        acting: bool = False,
        v_lot: str = "",
        v_truck: str = "",
        v_order: str = "",
        f_qty: str = "",
        f_ticket: str = "",
        delay_minutes: str = "15",
        uploading: bool = False;

    nav = useNavigate();
    poll_seq = usePoll(10000);

    async def load {
        try {
            result = await loader_job(shipmentId, poll_seq);
            if result.ok {
                job = result.data;
            } else {
                error = result.message or "Could not load this job.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def do_claim {
        acting = True;
        try {
            result = await claim_loading_job(shipmentId);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not claim this job.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_check_in {
        acting = True;
        try {
            result = await loader_check_in(shipmentId);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not check in.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_verify {
        if not v_lot or not v_truck or not v_order {
            toast.error("Enter the lot code, truck plate and order reference.");
            return;
        }
        acting = True;
        try {
            result = await verify_and_start_loading(shipmentId, v_lot, v_truck, v_order);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Verification failed - double check the lot, truck and order.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_finish {
        qty = float(f_qty) if f_qty else 0.0;
        if qty <= 0.0 or not f_ticket {
            toast.error("Enter the loaded quantity and a ticket number.");
            return;
        }
        acting = True;
        try {
            result = await finish_loading(shipmentId, qty, f_ticket);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not finish loading.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_update(kind: str) {
        acting = True;
        try {
            mins = int(delay_minutes) if delay_minutes else 15;
            result = await loader_update(shipmentId, kind, "", mins if kind == "DELAY" else 0);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not send this update.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    def read_as_base64(file: any, cb: Callable[[str, str, str], None]) {
        reader: any = new(FileReader);  # jac:ignore[E1053]
        reader.onload = lambda (ev: any) {
            result: str = reader.result as str;
            parts = result.split(",");
            b64 = parts[1] if len(parts) > 1 else "";
            cb(b64, file.name as str, file.type as str);
        };
        reader.readAsDataURL(file);
    }

    async def on_upload(b64: str, filename: str, mime: str) {
        uploading = True;
        try {
            result = await upload_evidence("Shipment", shipmentId, "LOAD_TICKET", filename, mime, b64, "");
            if result.ok {
                toast.success("Evidence attached.");
                await load();
            } else {
                toast.error(result.message or "Could not upload.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        uploading = False;
    }

    def handle_file(e: ChangeEvent) {
        target: any = e.target;
        files: any = target.files;
        if not files or int(files.length) == 0 {
            return;
        }
        read_as_base64(files[0], on_upload);
    }

    if loading {
        return <div className="flex flex-col gap-4"><LoadingRows count={4} /></div>;
    }
    if error {
        return <ErrorState message={error} onRetry={load} />;
    }
    j = job;
    if j is None {
        return <ErrorState message="Job not found." />;
    }

    <div className="flex flex-col gap-4 pb-24">
        <PageHeader title={j.ref} description={j.plant_name + " · " + j.mineral_name + " " + j.grade_code}>
            <StatusChip status={j.status} />
        </PageHeader>

        <Card>
            <CardContent className="grid grid-cols-2 gap-3 p-4 text-sm">
                <div><span className="text-muted-foreground">Quantity</span><p className="font-medium">{fmt_t(j.quantity_t)}</p></div>
                <div><span className="text-muted-foreground">Bay</span><p className="font-medium">{str(j.bay)}</p></div>
                <div><span className="text-muted-foreground">Present by</span><p className="font-medium">{fmt_clock(j.present_by)}</p></div>
                <div><span className="text-muted-foreground">Truck</span><p className="font-medium">{j.truck_plate or "-"} ({str(j.truck_payload_t)} t)</p></div>
                <div><span className="text-muted-foreground">Driver</span><p className="font-medium">{j.driver_name or "-"}{j.driver_checked_in and " (checked in)" or ""}</p></div>
                <div><span className="text-muted-foreground">Lot</span><p className="font-medium">{j.lot_code} · {j.stockpile}</p></div>
            </CardContent>
        </Card>

        {not j.assigned_to_me and
            <Card>
                <CardContent className="p-4"><Button className="h-12 w-full" disabled={acting} onClick={do_claim}>Claim this job</Button></CardContent>
            </Card>
        or None}

        {j.assigned_to_me and not j.loader_checked_in and
            <Card>
                <CardHeader><CardTitle>Check in</CardTitle><CardDescription>Manual check-in (no geofence) - confirms you are at the bay.</CardDescription></CardHeader>
                <CardContent><Button className="h-12 w-full" disabled={acting} onClick={do_check_in}>Check in at bay {str(j.bay)}</Button></CardContent>
            </Card>
        or None}

        {j.assigned_to_me and j.loader_checked_in and not j.verified and
            <Card>
                <CardHeader><CardTitle>Verify before loading</CardTitle><CardDescription>Confirm the lot, truck plate and order match the reservation.</CardDescription></CardHeader>
                <CardContent>
                    <FieldGroup>
                        <Field><FieldLabel htmlFor="vl">Lot code</FieldLabel><Input id="vl" className="h-12" value={v_lot} onChange={lambda (e: ChangeEvent) { v_lot = e.target.value; }} /></Field>
                        <Field><FieldLabel htmlFor="vt">Truck plate</FieldLabel><Input id="vt" className="h-12" value={v_truck} onChange={lambda (e: ChangeEvent) { v_truck = e.target.value; }} /></Field>
                        <Field><FieldLabel htmlFor="vo">Order reference</FieldLabel><Input id="vo" className="h-12" value={v_order} onChange={lambda (e: ChangeEvent) { v_order = e.target.value; }} /></Field>
                        <Button className="h-12 w-full" disabled={acting} onClick={do_verify}>Verify and start loading</Button>
                    </FieldGroup>
                </CardContent>
            </Card>
        or None}

        {j.assigned_to_me and j.verified and j.loading_ended_at <= 0.0 and
            <Card>
                <CardHeader><CardTitle>Finish loading</CardTitle><CardDescription>Record the loaded quantity and ticket number.</CardDescription></CardHeader>
                <CardContent>
                    <FieldGroup>
                        <Field><FieldLabel htmlFor="fq">Loaded quantity (t)</FieldLabel><Input id="fq" type="number" className="h-12" value={f_qty} onChange={lambda (e: ChangeEvent) { f_qty = e.target.value; }} /></Field>
                        <Field><FieldLabel htmlFor="ft">Load ticket number</FieldLabel><Input id="ft" className="h-12" value={f_ticket} onChange={lambda (e: ChangeEvent) { f_ticket = e.target.value; }} /></Field>
                        <Field>
                            <FieldLabel htmlFor="fev">Attach a photo of the ticket (optional)</FieldLabel>
                            <input id="fev" type="file" accept="image/*" onChange={handle_file} className="text-sm" />
                        </Field>
                        <Button className="h-12 w-full" disabled={acting} onClick={do_finish}>Finish loading</Button>
                    </FieldGroup>
                </CardContent>
            </Card>
        or None}

        {j.assigned_to_me and j.loading_ended_at > 0.0 and
            <Card>
                <CardHeader><CardTitle>Loaded</CardTitle></CardHeader>
                <CardContent className="flex flex-col gap-1 text-sm">
                    <p>{fmt_t(j.loaded_qty_t)} loaded, ticket {j.load_ticket_no}.</p>
                    <p className="text-muted-foreground">Fee: <Badge variant="outline">{j.fee_status}</Badge> {j.fee_amount > 0 and fmt_money(j.fee_amount, "LKR") or ""}</p>
                </CardContent>
            </Card>
        or None}

        {j.assigned_to_me and j.loading_ended_at <= 0.0 and
            <Card>
                <CardHeader><CardTitle>Quick updates</CardTitle></CardHeader>
                <CardContent className="flex flex-wrap gap-2">
                    <Button variant="outline" size="sm" disabled={acting} onClick={lambda { do_update("ARRIVED"); }}>Arrived</Button>
                    <Button variant="outline" size="sm" disabled={acting} onClick={lambda { do_update("QUEUE"); }}>In queue</Button>
                    <Button variant="outline" size="sm" disabled={acting} onClick={lambda { do_update("READY"); }}>Bay ready</Button>
                    <div className="flex items-center gap-1">
                        <Input type="number" value={delay_minutes} onChange={lambda (e: ChangeEvent) { delay_minutes = e.target.value; }} className="h-9 w-16" />
                        <Button variant="outline" size="sm" disabled={acting} onClick={lambda { do_update("DELAY"); }}>Report delay (min)</Button>
                    </div>
                </CardContent>
            </Card>
        or None}
    </div>
}
