"""Dispatch Board: pick a load awaiting assignment, review the agent's
candidates (drivers, trucks, loaders) with eligibility reasons, and approve
or override with a recorded reason - per AGENTS.md section 4."""

import from "@jac/runtime" { useLocation, useNavigate }
import from "sonner" { toast }
import from ....dispatch.store { dispatch_queue, assignment_options, plan_assignments, approve_dispatch, withdraw_offer, QueueRow, QueueShipment, AssignmentOptions }
import from ....planning.tools { DriverCandidate, TruckCandidate, LoaderCandidate }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_t, fmt_km }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }
import from ....components.ui.field { Field, FieldLabel }
import from ....components.ui.input { Input }
import from ....components.ui.separator { Separator }

obj PendingRow {
    has order_id: str,
        sh: QueueShipment;
}

def:pub DispatchBoardPage() -> JsxPage {
    has pending: list[PendingRow] = [],
        selected: str = "",
        selected_order_id: str = "",
        options: AssignmentOptions | None = None,
        loading_list: bool = True,
        loading_options: bool = False,
        error: str = "",
        picked_driver: str = "",
        picked_truck: str = "",
        picked_loader: str = "",
        override_reason: str = "",
        planning: bool = False,
        approving: bool = False,
        withdraw_reason: str = "";

    loc = useLocation();
    nav = useNavigate();
    poll_seq = usePoll(15000);

    async def load_list {
        loading_list = True;
        try {
            result = await dispatch_queue("ACTIVE", poll_seq);
            if result.ok {
                rows: list[PendingRow] = [];
                for row in result.rows {
                    for sh in row.shipments {
                        if sh.status == "AWAITING_DISPATCH" or sh.status == "EXCEPTION" or sh.status == "OFFERED" {
                            rows.append(PendingRow(order_id=row.order_id, sh=sh));
                        }
                    }
                }
                pending = rows;
            } else {
                error = result.message or "Could not load the board.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading_list = False;
    }

    async def select(shipment_id: str, order_id: str) {
        selected = shipment_id;
        selected_order_id = order_id;
        picked_driver = "";
        picked_truck = "";
        picked_loader = "";
        override_reason = "";
        loading_options = True;
        try {
            result = await assignment_options(shipment_id, poll_seq);
            if result.ok {
                options = result;
                picked_driver = result.recommended_driver_id;
                picked_truck = result.recommended_truck_id;
                picked_loader = result.recommended_loader_id;
            } else {
                toast.error(result.message or "Could not load candidates.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        loading_options = False;
    }

    async can with entry {
        await load_list();
        params: any = new(URLSearchParams, loc.search);  # jac:ignore[E1053]
        pre: str | None = params.get("shipment");
        if pre {
            for row in pending {
                if row.sh.id == pre {
                    await select(row.sh.id, row.order_id);
                }
            }
        }
    }

    async def run_plan {
        if not selected_order_id {
            return;
        }
        planning = True;
        try {
            result = await plan_assignments(selected_order_id);
            if result.ok {
                toast.success("Recommendation ready.");
                await select(selected, selected_order_id);
            } else {
                toast.error(result.message or "Could not run the planning agent.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        planning = False;
    }

    async def do_approve {
        if not selected or not picked_driver or not picked_truck {
            toast.error("Choose a driver and a truck.");
            return;
        }
        approving = True;
        try {
            result = await approve_dispatch(selected, picked_driver, picked_truck, picked_loader, override_reason);
            if result.ok {
                toast.success(result.message);
                selected = "";
                options = None;
                await load_list();
            } elif result.code == "OVERRIDE_REASON_REQUIRED" {
                toast.error("This differs from the recommendation - add a reason below and try again.");
            } else {
                toast.error(result.message or "Could not approve this dispatch.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        approving = False;
    }

    async def do_withdraw {
        if not selected or len(withdraw_reason) < 3 {
            toast.error("Give a reason for withdrawing the offer.");
            return;
        }
        approving = True;
        try {
            result = await withdraw_offer(selected, withdraw_reason);
            if result.ok {
                toast.success(result.message);
                withdraw_reason = "";
                selected = "";
                options = None;
                await load_list();
            } else {
                toast.error(result.message or "Could not withdraw the offer.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        approving = False;
    }

    opts = options;
    overridden = opts is not None and (picked_driver != opts.recommended_driver_id or picked_truck != opts.recommended_truck_id or (picked_loader != opts.recommended_loader_id and opts.recommended_loader_id != ""));

    <div className="flex flex-col gap-6">
        <PageHeader title="Dispatch Board" description="Assign a truck, driver and loader to each load waiting for dispatch." />

        {if error {
            <ErrorState message={error} onRetry={load_list} />
            skip;
        }}

        <div className="grid grid-cols-1 gap-4 lg:grid-cols-[380px_1fr]">
            <Card className="p-0">
                <CardContent className="flex flex-col gap-2 p-3">
                    {if loading_list {
                        <LoadingRows count={4} />
                        skip;
                    }}
                    {if not loading_list and len(pending) == 0 {
                        <EmptyState title="Nothing waiting" description="Every load has been dispatched." />
                        skip;
                    }}
                    {for row in pending {
                        <button
                            key={row.sh.id}
                            onClick={lambda { select(row.sh.id, row.order_id); }}
                            className={"flex flex-col gap-1 rounded-lg border p-3 text-left text-sm hover:bg-muted " + ("border-primary bg-primary/5" if selected == row.sh.id else "")}
                        >
                            <div className="flex items-center justify-between">
                                <span className="font-medium">{row.sh.ref}</span>
                                <StatusChip status={row.sh.status} />
                            </div>
                            <span className="text-muted-foreground">{row.sh.plant_name} · {fmt_t(row.sh.quantity_t)} {row.sh.grade_code}</span>
                        </button>
                    }}
                </CardContent>
            </Card>

            <Card>
                {if not selected {
                    <CardContent className="pt-12 pb-12"><EmptyState title="Choose a load" description="Pick a load on the left to review candidates." /></CardContent>
                    skip;
                }}
                {if selected and loading_options {
                    <CardContent><LoadingRows count={4} /></CardContent>
                    skip;
                }}
                {if selected and not loading_options and opts is not None and opts.shipment is not None {
                    shipment = opts.shipment;
                    <CardHeader>
                        <div className="flex items-center justify-between">
                            <CardTitle>{shipment.ref} · {shipment.plant_name}</CardTitle>
                            <StatusChip status={shipment.status} />
                        </div>
                        <CardDescription>{fmt_t(shipment.quantity_t)} {shipment.grade_code} · slot requires presence soon</CardDescription>
                    </CardHeader>
                    <CardContent className="flex flex-col gap-6">
                        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
                            <div className="flex flex-col gap-2">
                                <FieldLabel>Driver</FieldLabel>
                                {for d in opts.drivers {
                                    <button
                                        key={d.driver_id}
                                        disabled={not d.eligible}
                                        onClick={lambda { picked_driver = d.driver_id; }}
                                        className={"flex flex-col gap-0.5 rounded-lg border p-2 text-left text-xs disabled:opacity-40 " + ("border-primary bg-primary/5" if picked_driver == d.driver_id else "")}
                                    >
                                        <span className="font-medium">{d.name}{d.driver_id == opts.recommended_driver_id and " · recommended" or ""}</span>
                                        <span className="text-muted-foreground">{fmt_km(d.km_to_plant)} · {str(d.active_jobs)} active jobs</span>
                                        {not d.eligible and <span className="text-destructive">{"; ".join(d.reasons)}</span> or None}
                                    </button>
                                }}
                            </div>
                            <div className="flex flex-col gap-2">
                                <FieldLabel>Truck</FieldLabel>
                                {for t in opts.trucks {
                                    <button
                                        key={t.truck_id}
                                        disabled={not t.eligible}
                                        onClick={lambda { picked_truck = t.truck_id; }}
                                        className={"flex flex-col gap-0.5 rounded-lg border p-2 text-left text-xs disabled:opacity-40 " + ("border-primary bg-primary/5" if picked_truck == t.truck_id else "")}
                                    >
                                        <span className="font-medium">{t.plate}{t.truck_id == opts.recommended_truck_id and " · recommended" or ""}</span>
                                        <span className="text-muted-foreground">{str(t.payload_t)} t · {t.body_type}</span>
                                        {not t.eligible and <span className="text-destructive">{"; ".join(t.reasons)}</span> or None}
                                    </button>
                                }}
                            </div>
                            <div className="flex flex-col gap-2">
                                <FieldLabel>Loader</FieldLabel>
                                {for l in opts.loaders {
                                    <button
                                        key={l.loader_id}
                                        disabled={not l.eligible}
                                        onClick={lambda { picked_loader = l.loader_id; }}
                                        className={"flex flex-col gap-0.5 rounded-lg border p-2 text-left text-xs disabled:opacity-40 " + ("border-primary bg-primary/5" if picked_loader == l.loader_id else "")}
                                    >
                                        <span className="font-medium">{l.name}{l.loader_id == opts.recommended_loader_id and " · recommended" or ""}</span>
                                        <span className="text-muted-foreground">{str(l.assigned_jobs_same_hour)} jobs this hour</span>
                                        {not l.eligible and <span className="text-destructive">{"; ".join(l.reasons)}</span> or None}
                                    </button>
                                }}
                            </div>
                        </div>

                        {overridden and
                            <Field>
                                <FieldLabel htmlFor="ov">Override reason (required - your choice differs from the recommendation)</FieldLabel>
                                <Input id="ov" value={override_reason} onChange={lambda (e: ChangeEvent) { override_reason = e.target.value; }} />
                            </Field>
                        or None}

                        {opts.agent_runs and
                            <div className="rounded-lg border p-3 text-xs text-muted-foreground">
                                <Badge variant="secondary" className="mb-1">{opts.agent_runs[0].mode_label}</Badge>
                                <p>{opts.agent_runs[0].explanation}</p>
                            </div>
                        or None}
                    </CardContent>
                    <CardFooter className="flex flex-wrap gap-2">
                        <Button variant="outline" disabled={planning} onClick={run_plan}>{planning and "Thinking…" or "Re-run AI agent"}</Button>
                        <Button disabled={approving} onClick={do_approve}>{approving and "Approving…" or "Approve and offer"}</Button>
                        {shipment.status == "OFFERED" and
                            <div className="flex items-center gap-2">
                                <Input placeholder="Withdrawal reason" value={withdraw_reason} onChange={lambda (e: ChangeEvent) { withdraw_reason = e.target.value; }} className="w-56" />
                                <Button variant="outline" disabled={approving} onClick={do_withdraw}>Withdraw offer</Button>
                            </div>
                        or None}
                    </CardFooter>
                    skip;
                }}
            </Card>
        </div>
    </div>
}
