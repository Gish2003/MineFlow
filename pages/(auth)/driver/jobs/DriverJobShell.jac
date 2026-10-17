"""Driver job flow (mobile-first): check in, confirm the load ticket, share
location during the journey, upload proof of delivery, and record handover.
Connectivity loss never silently fails or completes the delivery."""

import from "react" { useEffect }
import from "sonner" { toast }
import from .....delivery.store {
    driver_job, driver_check_in, confirm_ticket_and_depart, record_unloading,
    submit_handover_pin, driver_cancel, report_vehicle_issue, report_route_delay, DriverJobView
}
import from .....delivery.tracking { get_tracking, report_location, TrackingView }
import from .....messaging.store { shipment_messages, send_message, MessageView }
import from .....evidence.store { upload_evidence }
import from .....shell.PageHeader { PageHeader }
import from .....shell.StatusChip { StatusChip }
import from .....shell.StateViews { LoadingRows, ErrorState }
import from .....shell.format { fmt_clock, fmt_t, fmt_money, fmt_ago, fmt_datetime }
import from .....shell.TrackingMap { TrackingMap }
import from .....hooks.usePoll { usePoll }
import from .....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from .....components.ui.button { Button }
import from .....components.ui.badge { Badge }
import from .....components.ui.field { Field, FieldLabel, FieldGroup }
import from .....components.ui.input { Input }
import from .....components.ui.textarea { Textarea }
import from .....components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from .....components.ui.scroll_area { ScrollArea }

def:pub DriverJobShell(shipmentId: str) -> JsxElement {
    has job: DriverJobView | None = None,
        tracking: TrackingView | None = None,
        loading: bool = True,
        error: str = "",
        acting: bool = False,

        ticket_no: str = "",
        sharing: bool = False,
        share_mode: str = "SIMULATED",
        sim_progress: float = 0.0,
        ping_seq: int = 0,

        unload_note: str = "",
        pin_value: str = "",
        pin_qty: str = "",

        issue_note: str = "",
        delay_minutes: str = "15",
        delay_note: str = "",
        cancel_reason: str = "",

        messages: list[MessageView] = [],
        msg_text: str = "";

    poll_seq = usePoll(8000);

    async def load {
        try {
            result = await driver_job(shipmentId, poll_seq);
            if result.ok {
                job = result.data;
            } else {
                error = result.message or "Could not load this job.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        try {
            tr = await get_tracking(shipmentId, poll_seq);
            if tr.ok {
                tracking = tr.data;
            }
        } except Exception {
            _ = None;
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def load_messages {
        try {
            result = await shipment_messages(shipmentId, poll_seq);
            if result.ok {
                messages = result.messages;
            }
        } except Exception {
            _ = None;
        }
    }

    async can with [poll_seq] entry {
        await load_messages();
    }

    async def send_msg {
        if not msg_text.strip() {
            return;
        }
        try {
            await send_message(shipmentId, msg_text);
            msg_text = "";
            await load_messages();
        } except Exception {
            toast.error("Could not send the message.");
        }
    }

    async def do_check_in {
        acting = True;
        try {
            result = await driver_check_in(shipmentId);
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

    async def do_depart {
        if not ticket_no {
            toast.error("Enter the load ticket number.");
            return;
        }
        acting = True;
        try {
            result = await confirm_ticket_and_depart(shipmentId, ticket_no);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Ticket does not match - check with the loader.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    def point_on_route(route: list[list[float]], fraction: float) -> list[float] {
        if len(route) == 0 {
            return [0.0, 0.0];
        }
        if len(route) == 1 {
            return route[0];
        }
        idx = int(fraction * float(len(route) - 1));
        if idx >= len(route) - 1 {
            return route[-1];
        }
        return route[idx];
    }

    async def send_ping(lat: float, lng: float, source: str) {
        ping_seq = ping_seq + 1;
        try {
            await report_location(shipmentId, lat, lng, 30.0, source, ping_seq);
            tr = await get_tracking(shipmentId, ping_seq);
            if tr.ok {
                tracking = tr.data;
            }
        } except Exception {
            _ = None;
        }
    }

    async def tick_simulated {
        tr = tracking;
        if tr is None or not tr.route {
            return;
        }
        sim_progress = sim_progress + 0.04;
        if sim_progress > 1.0 {
            sim_progress = 1.0;
        }
        pt = point_on_route(tr.route, sim_progress);
        await send_ping(pt[0], pt[1], "SIMULATED");
    }

    def device_success(lat: float, lng: float) {
        send_ping(lat, lng, "DEVICE");
    }

    async def tick_device {
        try {
            geo: any = navigator.geolocation;
            geo.getCurrentPosition(lambda (pos: any) {
                coords: any = pos.coords;
                device_success(float(coords.latitude), float(coords.longitude));
            }, lambda (err: any) {
                toast.error("Device GPS unavailable; switch to simulated route.");
            });
        } except Exception {
            toast.error("Device GPS unavailable; switch to simulated route.");
        }
    }

    async def tick {
        if share_mode == "DEVICE" {
            await tick_device();
        } else {
            await tick_simulated();
        }
    }

    useEffect(lambda {
        if not sharing {
            return lambda { };
        }
        id = setInterval(lambda { tick(); }, 4000);
        return lambda { clearInterval(id); };
    }, [sharing, share_mode]);

    async def do_record_unloading {
        acting = True;
        try {
            result = await record_unloading(shipmentId, unload_note);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Upload an unloading photo first.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_submit_pin {
        qty = float(pin_qty) if pin_qty else 0.0;
        if not pin_value {
            toast.error("Enter the 6-digit handover PIN.");
            return;
        }
        acting = True;
        try {
            result = await submit_handover_pin(shipmentId, pin_value, qty);
            if result.ok {
                toast.success(result.message);
                pin_value = "";
                await load();
            } else {
                toast.error(result.message or "Incorrect PIN.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_issue {
        if len(issue_note) < 3 {
            toast.error("Describe the vehicle issue.");
            return;
        }
        acting = True;
        try {
            result = await report_vehicle_issue(shipmentId, issue_note);
            if result.ok {
                toast.success(result.message);
                issue_note = "";
                await load();
            } else {
                toast.error(result.message or "Could not report this issue.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_delay {
        mins = int(delay_minutes) if delay_minutes else 15;
        acting = True;
        try {
            result = await report_route_delay(shipmentId, mins, delay_note);
            if result.ok {
                toast.success(result.message);
                delay_note = "";
                await load();
            } else {
                toast.error(result.message or "Could not report this delay.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_cancel {
        if len(cancel_reason) < 3 {
            toast.error("Give a reason for cancelling.");
            return;
        }
        acting = True;
        try {
            result = await driver_cancel(shipmentId, cancel_reason);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not cancel this job.");
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
        try {
            result = await upload_evidence("Shipment", shipmentId, "UNLOADING_PHOTO", filename, mime, b64, "");
            if result.ok {
                toast.success("Photo attached.");
                await load();
            } else {
                toast.error(result.message or "Could not upload.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
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
    tr = tracking;

    <div className="flex flex-col gap-4 pb-24">
        <PageHeader title={j.ref} description={j.plant_name + " → " + j.dest_name}>
            <StatusChip status={j.status} />
        </PageHeader>

        <Tabs defaultValue="job">
            <TabsList className="w-full">
                <TabsTrigger value="job" className="flex-1">Job</TabsTrigger>
                <TabsTrigger value="journey" className="flex-1">Map & ETA</TabsTrigger>
                <TabsTrigger value="messages" className="flex-1">Messages</TabsTrigger>
            </TabsList>

            <TabsContent value="job" className="flex flex-col gap-4 pt-4">
                <Card>
                    <CardContent className="grid grid-cols-2 gap-3 p-4 text-sm">
                        <div><span className="text-muted-foreground">Mineral</span><p className="font-medium">{j.mineral_name} {j.grade_code}</p></div>
                        <div><span className="text-muted-foreground">Quantity</span><p className="font-medium">{fmt_t(j.quantity_t)}</p></div>
                        <div><span className="text-muted-foreground">Window</span><p className="font-medium">{fmt_clock(j.window_start)}–{fmt_clock(j.window_end)}</p></div>
                        <div><span className="text-muted-foreground">Pay</span><p className="font-medium">{fmt_money(j.pay_amount, "LKR")}</p></div>
                        <div><span className="text-muted-foreground">Destination</span><p className="font-medium">{j.dest_address}{j.site_contact and (" · " + j.site_contact) or ""}</p></div>
                        <div><span className="text-muted-foreground">Loader</span><p className="font-medium">{j.loader_name or "-"}{j.loader_checked_in and " (at bay)" or ""}</p></div>
                    </CardContent>
                </Card>

                {not j.driver_checked_in and
                    <Card>
                        <CardHeader><CardTitle>Check in at the plant</CardTitle><CardDescription>Manual check-in (no geofence).</CardDescription></CardHeader>
                        <CardContent><Button className="h-12 w-full" disabled={acting} onClick={do_check_in}>Check in</Button></CardContent>
                    </Card>
                or None}

                {j.driver_checked_in and j.loaded_qty_t > 0.0 and not j.ticket_confirmed and
                    <Card>
                        <CardHeader><CardTitle>Confirm load ticket</CardTitle><CardDescription>Loaded {fmt_t(j.loaded_qty_t)} · ticket {j.load_ticket_no}</CardDescription></CardHeader>
                        <CardContent>
                            <FieldGroup>
                                <Field><FieldLabel htmlFor="tk">Ticket number</FieldLabel><Input id="tk" className="h-12" value={ticket_no} onChange={lambda (e: ChangeEvent) { ticket_no = e.target.value; }} /></Field>
                                <Button className="h-12 w-full" disabled={acting} onClick={do_depart}>Confirm and depart</Button>
                            </FieldGroup>
                        </CardContent>
                    </Card>
                or None}

                {j.departed_at > 0.0 and j.unloading_photos == 0 and
                    <Card>
                        <CardHeader><CardTitle>Proof of delivery</CardTitle><CardDescription>Upload at least one unloading photo.</CardDescription></CardHeader>
                        <CardContent>
                            <input type="file" accept="image/*" onChange={handle_file} className="text-sm" />
                        </CardContent>
                    </Card>
                or None}

                {j.departed_at > 0.0 and j.unloading_photos > 0 and not j.handover_recorded and
                    <Card>
                        <CardHeader><CardTitle>Record handover</CardTitle><CardDescription>{str(j.unloading_photos)} photo(s) attached.</CardDescription></CardHeader>
                        <CardContent>
                            <FieldGroup>
                                <Field><FieldLabel htmlFor="un">Note (optional)</FieldLabel><Textarea id="un" value={unload_note} onChange={lambda (e: ChangeEvent) { unload_note = e.target.value; }} /></Field>
                                <Button className="h-12 w-full" disabled={acting} onClick={do_record_unloading}>Record handover</Button>
                            </FieldGroup>
                        </CardContent>
                    </Card>
                or None}

                {j.handover_recorded and j.status != "COMPLETED" and
                    <Card>
                        <CardHeader><CardTitle>Buyer handover PIN</CardTitle><CardDescription>Ask the buyer for their 6-digit PIN ({str(j.pin_attempts_left)} attempts left).</CardDescription></CardHeader>
                        <CardContent>
                            <FieldGroup>
                                <Field><FieldLabel htmlFor="pv">PIN</FieldLabel><Input id="pv" className="h-12 font-mono" maxLength={6} value={pin_value} onChange={lambda (e: ChangeEvent) { pin_value = e.target.value; }} /></Field>
                                <Field><FieldLabel htmlFor="pq">Received quantity (t, optional override)</FieldLabel><Input id="pq" type="number" className="h-12" value={pin_qty} onChange={lambda (e: ChangeEvent) { pin_qty = e.target.value; }} /></Field>
                                <Button className="h-12 w-full" disabled={acting} onClick={do_submit_pin}>Submit PIN</Button>
                            </FieldGroup>
                        </CardContent>
                    </Card>
                or None}

                {j.status == "COMPLETED" and
                    <Card><CardContent className="p-4 text-sm text-muted-foreground">Delivery completed. Payout status will update shortly.</CardContent></Card>
                or None}

                {j.status != "COMPLETED" and j.status != "CANCELLED" and
                    <Card>
                        <CardHeader><CardTitle>Report a problem</CardTitle></CardHeader>
                        <CardContent className="flex flex-col gap-3">
                            <div className="flex gap-2">
                                <Input placeholder="Vehicle issue" value={issue_note} onChange={lambda (e: ChangeEvent) { issue_note = e.target.value; }} />
                                <Button variant="outline" disabled={acting} onClick={do_issue}>Report</Button>
                            </div>
                            {j.departed_at > 0.0 and
                                <div className="flex gap-2">
                                    <Input type="number" className="w-20" value={delay_minutes} onChange={lambda (e: ChangeEvent) { delay_minutes = e.target.value; }} />
                                    <Input placeholder="Route delay reason" value={delay_note} onChange={lambda (e: ChangeEvent) { delay_note = e.target.value; }} />
                                    <Button variant="outline" disabled={acting} onClick={do_delay}>Report delay</Button>
                                </div>
                            or None}
                            <div className="flex gap-2">
                                <Input placeholder="Cancellation reason" value={cancel_reason} onChange={lambda (e: ChangeEvent) { cancel_reason = e.target.value; }} />
                                <Button variant="destructive" disabled={acting} onClick={do_cancel}>Cancel job</Button>
                            </div>
                        </CardContent>
                    </Card>
                or None}
            </TabsContent>

            <TabsContent value="journey" className="flex flex-col gap-4 pt-4">
                {if tr is not None {
                    <Card>
                        <CardContent className="flex flex-col gap-3 p-4">
                            <TrackingMap
                                plantLat={tr.plant_lat} plantLng={tr.plant_lng} destLat={tr.dest_lat} destLng={tr.dest_lng}
                                route={tr.route} trail={tr.trail} lastLat={tr.last_lat} lastLng={tr.last_lng}
                                hasFix={tr.age_seconds >= 0.0} simulated={share_mode == "SIMULATED"}
                            />
                            <p className="text-xs text-muted-foreground">{tr.note}</p>
                            <div className="flex items-center justify-between text-sm">
                                <StatusChip status={tr.connectivity} />
                                <span className="text-muted-foreground">{tr.age_seconds >= 0.0 and ("last update " + fmt_ago(tr.last_at)) or "no location yet"}</span>
                            </div>
                        </CardContent>
                    </Card>
                    skip;
                }}
                <Card>
                    <CardHeader><CardTitle>Share location</CardTitle><CardDescription>Only while loaded or in transit.</CardDescription></CardHeader>
                    <CardContent className="flex flex-wrap items-center gap-2">
                        <Button variant={share_mode == "SIMULATED" and "default" or "outline"} size="sm" onClick={lambda { share_mode = "SIMULATED"; }}>Simulated route</Button>
                        <Button variant={share_mode == "DEVICE" and "default" or "outline"} size="sm" onClick={lambda { share_mode = "DEVICE"; }}>Device GPS</Button>
                        <Button variant={sharing and "destructive" or "default"} size="sm" disabled={j.status != "LOADED" and j.status != "IN_TRANSIT"} onClick={lambda { sharing = not sharing; }}>
                            {sharing and "Pause sharing (simulate signal loss)" or "Start sharing"}
                        </Button>
                    </CardContent>
                </Card>
            </TabsContent>

            <TabsContent value="messages" className="pt-4">
                <Card>
                    <CardContent className="flex flex-col gap-3 p-4">
                        <ScrollArea className="h-72">
                            <div className="flex flex-col gap-2 pr-2">
                                {for m in messages {
                                    <div key={m.id} className={"max-w-[80%] rounded-lg p-2 text-sm " + ("self-end bg-primary text-primary-foreground" if m.mine else "self-start bg-muted")}>
                                        <p className="text-xs opacity-70">{m.sender_name}</p>
                                        <p>{m.body}</p>
                                    </div>
                                }}
                            </div>
                        </ScrollArea>
                        <div className="flex gap-2">
                            <Input value={msg_text} onChange={lambda (e: ChangeEvent) { msg_text = e.target.value; }} placeholder="Message the buyer…" />
                            <Button onClick={send_msg}>Send</Button>
                        </div>
                    </CardContent>
                </Card>
            </TabsContent>
        </Tabs>
    </div>
}
