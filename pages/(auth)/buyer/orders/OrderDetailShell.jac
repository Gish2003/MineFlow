"""Order Details: timeline, AI plant recommendations, shipments/tracking
summary, claims and the per-shipment message thread - everything a buyer
needs for one order on a single page."""

import from "@jac/runtime" { useNavigate }
import from "sonner" { toast }
import from .....orders.store {
    order_detail, request_recommendations, confirm_order_option, cancel_order,
    acknowledge_delivery, report_issue, OrderDetailView, OrderLineView, ShipmentView, LineSelection
}
import from .....planning.workflow { AgentRunView }
import from .....core.model { PlanOption }
import from .....messaging.store { shipment_messages, send_message, MessageView }
import from .....shell.PageHeader { PageHeader }
import from .....shell.StatusChip { StatusChip }
import from .....shell.StateViews { LoadingRows, ErrorState }
import from .....shell.format { fmt_date, fmt_datetime, fmt_t, fmt_km, fmt_money, fmt_minutes }
import from .....hooks.usePoll { usePoll }
import from .....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from .....components.ui.button { Button }
import from .....components.ui.badge { Badge }
import from .....components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from .....components.ui.separator { Separator }
import from .....components.ui.field { Field, FieldLabel }
import from .....components.ui.input { Input }
import from .....components.ui.textarea { Textarea }
import from .....components.ui.alert_dialog {
    AlertDialog, AlertDialogTrigger, AlertDialogContent, AlertDialogHeader, AlertDialogTitle,
    AlertDialogDescription, AlertDialogFooter, AlertDialogAction, AlertDialogCancel
}
import from .....components.ui.dialog {
    Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter
}
import from .....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from .....components.ui.scroll_area { ScrollArea }
import from .....components.ui.empty { Empty, EmptyHeader, EmptyMedia, EmptyTitle, EmptyDescription }
import from "@hugeicons/react" { HugeiconsIcon }
import from "@hugeicons/core-free-icons" { CheckmarkCircle02Icon, AlertCircleIcon, Mail01Icon }

def best_option_for(run: AgentRunView, line_id: str) -> str {
    best: PlanOption | None = None;
    for opt in run.options {
        if opt.line_id == line_id {
            if best is None or opt.rank < best.rank {
                best = opt;
            }
        }
    }
    return best.option_id if best is not None else "";
}

def options_for(run: AgentRunView, line_id: str) -> list[PlanOption] {
    rows = [o for o in run.options if o.line_id == line_id];
    return sorted(rows, key=by_rank);
}

def by_rank(o: PlanOption) -> int {
    return o.rank;
}

def:pub OrderDetailShell(orderId: str) -> JsxElement {
    has data: OrderDetailView | None = None,
        loading: bool = True,
        error: str = "",
        requesting_plan: bool = False,
        selections: dict[str, str] = {},
        confirming: bool = False,
        cancel_reason: str = "",
        ack_shipment: str = "",
        ack_qty: str = "",
        ack_note: str = "",
        issue_shipment: str = "",
        issue_type: str = "QUANTITY",
        issue_desc: str = "",
        issue_qty: str = "",
        thread_shipment: str = "",
        thread_messages: list[MessageView] = [],
        msg_text: str = "",
        acting: bool = False;

    nav = useNavigate();
    poll_seq = usePoll(15000);

    async def load {
        try {
            result = await order_detail(orderId, poll_seq);
            if result.ok {
                data = result.data;
                d = data;
                if d is not None and not selections {
                    runs = d.runs;
                    if runs {
                        run = runs[0];
                        next_sel: dict[str, str] = {};
                        for line in d.lines {
                            opt_id = best_option_for(run, line.id);
                            if opt_id {
                                next_sel[line.id] = opt_id;
                            }
                        }
                        selections = next_sel;
                    }
                }
            } else {
                error = result.message or "Could not load this order.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def request_plan {
        requesting_plan = True;
        try {
            result = await request_recommendations(orderId);
            if result.ok {
                selections = {};
                toast.success("Recommendations ready.");
                await load();
            } else {
                toast.error(result.message or "Could not get recommendations.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        requesting_plan = False;
    }

    async def confirm_plan {
        d = data;
        if d is None or not d.runs {
            return;
        }
        run = d.runs[0];
        picks: list[LineSelection] = [];
        for line in d.lines {
            opt_id = selections[line.id] or "";
            if not opt_id {
                toast.error("Choose an option for every load first.");
                return;
            }
            picks.append(LineSelection(line_id=line.id, option_id=opt_id));
        }
        confirming = True;
        try {
            result = await confirm_order_option(orderId, run.id, picks);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not confirm this order.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        confirming = False;
    }

    async def do_cancel {
        if len(cancel_reason) < 3 {
            toast.error("Give a short reason for cancelling.");
            return;
        }
        acting = True;
        try {
            result = await cancel_order(orderId, cancel_reason);
            if result.ok {
                toast.success(result.message);
                cancel_reason = "";
                await load();
            } else {
                toast.error(result.message or "Could not cancel this order.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_ack {
        qty = float(ack_qty) if ack_qty else 0.0;
        if qty <= 0.0 {
            toast.error("Enter the quantity you received.");
            return;
        }
        acting = True;
        try {
            result = await acknowledge_delivery(ack_shipment, qty, ack_note);
            if result.ok {
                toast.success(result.message);
                ack_shipment = "";
                ack_qty = "";
                ack_note = "";
                await load();
            } else {
                toast.error(result.message or "Could not acknowledge this delivery.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def do_report_issue {
        if len(issue_desc) < 10 {
            toast.error("Describe the issue in at least a sentence.");
            return;
        }
        qty = float(issue_qty) if issue_qty else 0.0;
        acting = True;
        try {
            result = await report_issue(issue_shipment, issue_type, issue_desc, qty);
            if result.ok {
                toast.success(result.message);
                issue_shipment = "";
                issue_desc = "";
                issue_qty = "";
                await load();
            } else {
                toast.error(result.message or "Could not open a claim.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = False;
    }

    async def open_thread(shipment_id: str) {
        thread_shipment = shipment_id;
        try {
            result = await shipment_messages(shipment_id, poll_seq);
            if result.ok {
                thread_messages = result.messages;
            }
        } except Exception {
            thread_messages = [];
        }
    }

    async def send_msg {
        if not thread_shipment or not msg_text.strip() {
            return;
        }
        try {
            await send_message(thread_shipment, msg_text);
            msg_text = "";
            await open_thread(thread_shipment);
        } except Exception {
            toast.error("Could not send the message.");
        }
    }

    if loading {
        return <div className="flex flex-col gap-4"><LoadingRows count={6} /></div>;
    }
    if error {
        return <ErrorState message={error} onRetry={load} />;
    }
    d = data;
    if d is None {
        return <ErrorState message="Order not found." />;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title={d.summary.ref} description={d.summary.site_name + " · " + fmt_date(d.summary.window_start) + " – " + fmt_date(d.summary.window_end)}>
            <StatusChip status={d.summary.status} />
            {d.can_request_plan and <Button variant="outline" disabled={requesting_plan} onClick={request_plan}>{requesting_plan and "Thinking…" or "Get recommendations"}</Button> or None}
            {d.can_cancel and
                <AlertDialog>
                    <AlertDialogTrigger asChild={True}><Button variant="outline">Cancel order</Button></AlertDialogTrigger>
                    <AlertDialogContent>
                        <AlertDialogHeader>
                            <AlertDialogTitle>Cancel this order?</AlertDialogTitle>
                            <AlertDialogDescription>Any held stock and loading slots will be released.</AlertDialogDescription>
                        </AlertDialogHeader>
                        <Field><FieldLabel htmlFor="cr">Reason</FieldLabel><Input id="cr" value={cancel_reason} onChange={lambda (e: ChangeEvent) { cancel_reason = e.target.value; }} /></Field>
                        <AlertDialogFooter>
                            <AlertDialogCancel>Back</AlertDialogCancel>
                            <AlertDialogAction onClick={do_cancel}>Cancel order</AlertDialogAction>
                        </AlertDialogFooter>
                    </AlertDialogContent>
                </AlertDialog>
            or None}
        </PageHeader>

        <Tabs defaultValue="overview">
            <TabsList>
                <TabsTrigger value="overview">Overview</TabsTrigger>
                {d.summary.status == "OPTIONS_READY" and <TabsTrigger value="recommendations">Plant Recommendations</TabsTrigger> or None}
                <TabsTrigger value="shipments">Active Deliveries</TabsTrigger>
                <TabsTrigger value="claims">Claims {len(d.claims) > 0 and ("(" + str(len(d.claims)) + ")") or ""}</TabsTrigger>
                <TabsTrigger value="messages">Messages</TabsTrigger>
            </TabsList>

            <TabsContent value="overview" className="flex flex-col gap-6 pt-4">
                <Card>
                    <CardHeader><CardTitle>Loads</CardTitle></CardHeader>
                    <CardContent className="flex flex-col gap-2">
                        {for line in d.lines {
                            <div key={line.id} className="flex items-center justify-between rounded-lg border p-3 text-sm">
                                <span>{fmt_t(line.quantity_t)} · {line.mineral_name}</span>
                                <Badge variant="outline">{line.grade_name}</Badge>
                            </div>
                        }}
                    </CardContent>
                </Card>
                <Card>
                    <CardHeader><CardTitle>Timeline</CardTitle></CardHeader>
                    <CardContent>
                        <div className="flex flex-col gap-4">
                            {for ev in d.timeline {
                                <div key={str(ev.at)} className="flex gap-3 text-sm">
                                    <HugeiconsIcon icon={CheckmarkCircle02Icon} strokeWidth={2} className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
                                    <div className="flex flex-col">
                                        <span className="font-medium">{ev.title}</span>
                                        {ev.detail and <span className="text-muted-foreground">{ev.detail}</span> or None}
                                        <span className="text-xs text-muted-foreground">{fmt_datetime(ev.at)}{ev.actor_name and (" · " + ev.actor_name) or ""}</span>
                                    </div>
                                </div>
                            }}
                        </div>
                    </CardContent>
                </Card>
            </TabsContent>

            <TabsContent value="recommendations" className="flex flex-col gap-6 pt-4">
                {if not d.runs {
                    <Empty>
                        <EmptyHeader>
                            <EmptyMedia variant="icon"><HugeiconsIcon icon={AlertCircleIcon} strokeWidth={2} /></EmptyMedia>
                            <EmptyTitle>No recommendations yet</EmptyTitle>
                        </EmptyHeader>
                    </Empty>
                    skip;
                }}
                {if d.runs {
                    run = d.runs[0];
                    <Card>
                        <CardHeader>
                            <div className="flex items-center justify-between">
                                <CardTitle>{run.mode_label}</CardTitle>
                                <Badge variant="secondary">{str(len(run.tool_calls))} tool calls</Badge>
                            </div>
                            <CardDescription>{run.explanation}</CardDescription>
                        </CardHeader>
                        <CardContent className="flex flex-col gap-6">
                            {for line in d.lines {
                                opts = options_for(run, line.id);
                                <div key={line.id} className="flex flex-col gap-2">
                                    <p className="text-sm font-medium">{fmt_t(line.quantity_t)} {line.mineral_name} ({line.grade_name})</p>
                                    {if not opts {
                                        <p className="text-sm text-muted-foreground">No feasible plant found for this load.</p>
                                        skip;
                                    }}
                                    {for opt in opts {
                                        <button
                                            key={opt.option_id}
                                            onClick={lambda { selections = {**selections, line.id: opt.option_id}; }}
                                            className={"flex flex-col gap-1 rounded-lg border p-3 text-left text-sm transition-colors hover:bg-muted " + ("border-primary bg-primary/5" if (selections[line.id] or "") == opt.option_id else "")}
                                        >
                                            <div className="flex items-center justify-between">
                                                <span className="font-medium">{opt.plant_name} · lot {opt.lot_code}</span>
                                                <Badge variant="outline">{fmt_money(opt.total_cost, "LKR")}</Badge>
                                            </div>
                                            <span className="text-muted-foreground">
                                                {fmt_km(opt.distance_km)} away · wait {fmt_minutes(opt.wait_minutes)} · ETA {fmt_datetime(opt.eta_ts)}
                                            </span>
                                            {opt.rationale and <span className="text-xs text-muted-foreground">{opt.rationale}</span> or None}
                                        </button>
                                    }}
                                </div>
                            }}
                        </CardContent>
                        <CardFooter>
                            <Button disabled={confirming} onClick={confirm_plan}>{confirming and "Reserving…" or "Confirm and reserve"}</Button>
                        </CardFooter>
                    </Card>
                    skip;
                }}
            </TabsContent>

            <TabsContent value="shipments" className="flex flex-col gap-4 pt-4">
                {if not d.shipments {
                    <Empty><EmptyHeader><EmptyTitle>No deliveries yet</EmptyTitle></EmptyHeader></Empty>
                    skip;
                }}
                {for sh in d.shipments {
                    <Card key={sh.id}>
                        <CardHeader>
                            <div className="flex items-center justify-between">
                                <CardTitle>{sh.ref} · {sh.plant_name}</CardTitle>
                                <StatusChip status={sh.status} />
                            </div>
                            <CardDescription>{fmt_t(sh.quantity_t)} · lot {sh.lot_code} · truck {sh.truck_plate or "unassigned"} · driver {sh.driver_name or "unassigned"}</CardDescription>
                        </CardHeader>
                        <CardContent className="flex flex-col gap-2 text-sm">
                            {sh.can_track and <p className="text-muted-foreground">Connectivity: <StatusChip status={sh.connectivity} /> {sh.last_ping_at > 0 and ("· last update " + fmt_datetime(sh.last_ping_at)) or ""}</p> or None}
                            {sh.eta_ts > 0 and <p className="text-muted-foreground">Estimated arrival {fmt_datetime(sh.eta_ts)} (simulated)</p> or None}
                            {sh.handover_pin and <p>Handover PIN for the driver: <Badge variant="secondary" className="font-mono">{sh.handover_pin}</Badge></p> or None}
                            {sh.load_ticket_no and <p className="text-muted-foreground">Load ticket {sh.load_ticket_no} · loaded {fmt_t(sh.loaded_qty_t)}</p> or None}
                        </CardContent>
                        <CardFooter className="flex gap-2">
                            {sh.can_message and <Button variant="outline" size="sm" onClick={lambda { open_thread(sh.id); }}><HugeiconsIcon icon={Mail01Icon} strokeWidth={2} className="size-4" /> Message driver</Button> or None}
                            {sh.can_acknowledge and
                                <Dialog>
                                    <DialogTrigger asChild={True}><Button size="sm" onClick={lambda { ack_shipment = sh.id; }}>Acknowledge delivery</Button></DialogTrigger>
                                    <DialogContent>
                                        <DialogHeader>
                                            <DialogTitle>Acknowledge {sh.ref}</DialogTitle>
                                            <DialogDescription>Confirm the quantity you actually received.</DialogDescription>
                                        </DialogHeader>
                                        <Field><FieldLabel htmlFor="aq">Received quantity (t)</FieldLabel><Input id="aq" type="number" value={ack_qty} onChange={lambda (e: ChangeEvent) { ack_qty = e.target.value; }} /></Field>
                                        <Field><FieldLabel htmlFor="an">Note (optional)</FieldLabel><Textarea id="an" value={ack_note} onChange={lambda (e: ChangeEvent) { ack_note = e.target.value; }} /></Field>
                                        <DialogFooter><Button disabled={acting} onClick={do_ack}>Confirm receipt</Button></DialogFooter>
                                    </DialogContent>
                                </Dialog>
                            or None}
                            {sh.can_report_issue and
                                <Dialog>
                                    <DialogTrigger asChild={True}><Button variant="outline" size="sm" onClick={lambda { issue_shipment = sh.id; }}>Report an issue</Button></DialogTrigger>
                                    <DialogContent>
                                        <DialogHeader>
                                            <DialogTitle>Report an issue - {sh.ref}</DialogTitle>
                                            <DialogDescription>This opens a claim for the dispatcher and plant manager to review.</DialogDescription>
                                        </DialogHeader>
                                        <Field>
                                            <FieldLabel htmlFor="it">Issue type</FieldLabel>
                                            <Select value={issue_type} onValueChange={lambda (v: str) { issue_type = v; }}>
                                                <SelectTrigger id="it"><SelectValue /></SelectTrigger>
                                                <SelectContent>
                                                    <SelectItem value="QUANTITY">Quantity mismatch</SelectItem>
                                                    <SelectItem value="GRADE_QUALITY">Grade / quality</SelectItem>
                                                    <SelectItem value="DELIVERY">Delivery / handling</SelectItem>
                                                    <SelectItem value="OTHER">Other</SelectItem>
                                                </SelectContent>
                                            </Select>
                                        </Field>
                                        {issue_type == "QUANTITY" and <Field><FieldLabel htmlFor="iq">Quantity received (t)</FieldLabel><Input id="iq" type="number" value={issue_qty} onChange={lambda (e: ChangeEvent) { issue_qty = e.target.value; }} /></Field> or None}
                                        <Field><FieldLabel htmlFor="id">Description</FieldLabel><Textarea id="id" value={issue_desc} onChange={lambda (e: ChangeEvent) { issue_desc = e.target.value; }} /></Field>
                                        <DialogFooter><Button disabled={acting} onClick={do_report_issue}>Submit claim</Button></DialogFooter>
                                    </DialogContent>
                                </Dialog>
                            or None}
                        </CardFooter>
                    </Card>
                }}
            </TabsContent>

            <TabsContent value="claims" className="flex flex-col gap-4 pt-4">
                {if not d.claims {
                    <Empty><EmptyHeader><EmptyTitle>No claims on this order</EmptyTitle></EmptyHeader></Empty>
                    skip;
                }}
                {for cl in d.claims {
                    <Card key={cl.id}>
                        <CardHeader>
                            <div className="flex items-center justify-between">
                                <CardTitle>{cl.ref} · {cl.claim_type}</CardTitle>
                                <StatusChip status={cl.status} />
                            </div>
                            <CardDescription>{cl.description}</CardDescription>
                        </CardHeader>
                        <CardContent className="text-sm text-muted-foreground">
                            <p>Routed to: {cl.routed_to or "not yet routed"}</p>
                            {cl.resolution and <p>Resolution: {cl.resolution}</p> or None}
                        </CardContent>
                    </Card>
                }}
            </TabsContent>

            <TabsContent value="messages" className="flex flex-col gap-4 pt-4">
                {if not thread_shipment {
                    <Empty>
                        <EmptyHeader>
                            <EmptyTitle>Pick a delivery to message its driver</EmptyTitle>
                            <EmptyDescription>Open "Message driver" from the Active Deliveries tab.</EmptyDescription>
                        </EmptyHeader>
                    </Empty>
                    skip;
                }}
                {if thread_shipment {
                    <Card>
                        <CardContent className="flex flex-col gap-3 p-4">
                            <ScrollArea className="h-80">
                                <div className="flex flex-col gap-2 pr-2">
                                    {for m in thread_messages {
                                        <div key={m.id} className={"max-w-[80%] rounded-lg p-2 text-sm " + ("self-end bg-primary text-primary-foreground" if m.mine else "self-start bg-muted")}>
                                            <p className="text-xs opacity-70">{m.sender_name}</p>
                                            <p>{m.body}</p>
                                        </div>
                                    }}
                                </div>
                            </ScrollArea>
                            <div className="flex gap-2">
                                <Input value={msg_text} onChange={lambda (e: ChangeEvent) { msg_text = e.target.value; }} placeholder="Message the driver…" />
                                <Button onClick={send_msg}>Send</Button>
                            </div>
                        </CardContent>
                    </Card>
                    skip;
                }}
            </TabsContent>
        </Tabs>
    </div>
}
