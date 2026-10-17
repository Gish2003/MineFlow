"""Exceptions: plant/slot/vehicle/driver problems. The Exception Recovery
Agent (or labelled deterministic fallback) gathers fresh evidence and
proposes validated alternatives; nothing changes until a dispatcher approves
one, or the agent truthfully reports no feasible option."""

import from "sonner" { toast }
import from ....dispatch.exceptions { exceptions_list, exception_detail, run_recovery, apply_recovery_option, close_exception, ExceptionView }
import from ....planning.workflow { AgentRunView }
import from ....core.model { ActionOption }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }
import from ....components.ui.field { Field, FieldLabel }
import from ....components.ui.input { Input }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def:pub ExceptionsPage() -> JsxPage {
    has status_filter: str = "OPEN",
        exceptions: list[ExceptionView] = [],
        selected: str = "",
        detail: ExceptionView | None = None,
        runs: list[AgentRunView] = [],
        loading_list: bool = True,
        loading_detail: bool = False,
        error: str = "",
        running: bool = False,
        applying: bool = False,
        reason: str = "",
        close_reason: str = "";

    poll_seq = usePoll(15000);

    async def load_list {
        loading_list = True;
        try {
            result = await exceptions_list(status_filter, poll_seq);
            if result.ok {
                exceptions = result.exceptions;
            } else {
                error = result.message or "Could not load exceptions.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading_list = False;
    }

    async can with [status_filter, poll_seq] entry {
        await load_list();
    }

    async def open_detail(exception_id: str) {
        selected = exception_id;
        loading_detail = True;
        reason = "";
        try {
            result = await exception_detail(exception_id, poll_seq);
            if result.ok {
                detail = result.data;
                runs = result.runs;
            } else {
                toast.error(result.message or "Could not load this exception.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        loading_detail = False;
    }

    async def do_run_recovery {
        if not selected {
            return;
        }
        running = True;
        try {
            result = await run_recovery(selected);
            if result.ok {
                detail = result.data;
                runs = result.runs;
                toast.success("Recovery evaluated.");
            } else {
                toast.error(result.message or "Could not run recovery.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        running = False;
    }

    async def do_apply(run_id: str, option_id: str) {
        if not selected {
            return;
        }
        applying = True;
        try {
            result = await apply_recovery_option(selected, run_id, option_id, reason);
            if result.ok {
                toast.success(result.message);
                await open_detail(selected);
                await load_list();
            } else {
                toast.error(result.message or "Could not apply this option.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        applying = False;
    }

    async def do_close(outcome: str) {
        if not selected or len(close_reason) < 3 {
            toast.error("Give a short reason.");
            return;
        }
        applying = True;
        try {
            result = await close_exception(selected, outcome, close_reason);
            if result.ok {
                toast.success(result.message);
                close_reason = "";
                selected = "";
                detail = None;
                await load_list();
            } else {
                toast.error(result.message or "Could not close this exception.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        applying = False;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Exceptions" description="Operational problems and the recovery agent's proposed alternatives.">
            <Select value={status_filter} onValueChange={lambda (v: str) { status_filter = v; }}>
                <SelectTrigger className="w-44"><SelectValue /></SelectTrigger>
                <SelectContent>
                    <SelectItem value="OPEN">Open</SelectItem>
                    <SelectItem value="RESOLVED">Resolved</SelectItem>
                    <SelectItem value="">All</SelectItem>
                </SelectContent>
            </Select>
        </PageHeader>

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
                    {if not loading_list and len(exceptions) == 0 {
                        <EmptyState title="No exceptions" />
                        skip;
                    }}
                    {for ex in exceptions {
                        <button
                            key={ex.id}
                            onClick={lambda { open_detail(ex.id); }}
                            className={"flex flex-col gap-1 rounded-lg border p-3 text-left text-sm hover:bg-muted " + ("border-primary bg-primary/5" if selected == ex.id else "")}
                        >
                            <div className="flex items-center justify-between">
                                <span className="font-medium">{ex.ref}</span>
                                <StatusChip status={ex.status} />
                            </div>
                            <span className="text-muted-foreground">{ex.ex_type} · {ex.plant_name}</span>
                            <span className="text-xs text-muted-foreground">{ex.summary}</span>
                        </button>
                    }}
                </CardContent>
            </Card>

            <Card>
                {if not selected {
                    <CardContent className="pt-12 pb-12"><EmptyState title="Choose an exception" /></CardContent>
                    skip;
                }}
                {if selected and loading_detail {
                    <CardContent><LoadingRows count={4} /></CardContent>
                    skip;
                }}
                {if selected and not loading_detail and detail is not None {
                    ex = detail;
                    <CardHeader>
                        <div className="flex items-center justify-between">
                            <CardTitle>{ex.ref} · {ex.ex_type}</CardTitle>
                            <StatusChip status={ex.status} />
                        </div>
                        <CardDescription>{ex.summary}</CardDescription>
                    </CardHeader>
                    <CardContent className="flex flex-col gap-4">
                        <p className="text-sm text-muted-foreground">{ex.detail}</p>
                        <div className="flex items-center gap-4 text-xs text-muted-foreground">
                            <span>Order {ex.order_ref}</span>
                            <span>Shipment {ex.shipment_ref} ({ex.shipment_status})</span>
                            <span>Raised {fmt_datetime(ex.created_at)}</span>
                        </div>

                        {if not runs {
                            <p className="text-sm text-muted-foreground">No recovery run yet.</p>
                            skip;
                        }}
                        {for run in runs[:1] {
                            <div key={run.id} className="flex flex-col gap-3 rounded-lg border p-3">
                                <div className="flex items-center justify-between">
                                    <Badge variant="secondary">{run.mode_label}</Badge>
                                    <StatusChip status={run.status} />
                                </div>
                                {run.what_changed and <p className="text-sm font-medium">{run.what_changed}</p> or None}
                                <p className="text-sm text-muted-foreground">{run.explanation}</p>
                                {if not run.actions {
                                    <p className="text-sm text-destructive">No feasible alternative was found.</p>
                                    skip;
                                }}
                                {for opt in run.actions {
                                    <div key={opt.option_id} className="flex items-center justify-between rounded-lg border p-2 text-sm">
                                        <div className="flex flex-col">
                                            <span className="font-medium">{opt.action.replace("_", " ")}</span>
                                            <span className="text-muted-foreground">{opt.summary}</span>
                                            {opt.rationale and <span className="text-xs text-muted-foreground">{opt.rationale}</span> or None}
                                        </div>
                                        <Button size="sm" disabled={applying or ex.status == "RESOLVED"} onClick={lambda { do_apply(run.id, opt.option_id); }}>Apply</Button>
                                    </div>
                                }}
                            </div>
                        }}

                        {ex.status != "RESOLVED" and
                            <Field>
                                <FieldLabel htmlFor="rr">Reason (shown in the audit trail when applying an option)</FieldLabel>
                                <Input id="rr" value={reason} onChange={lambda (e: ChangeEvent) { reason = e.target.value; }} />
                            </Field>
                        or None}
                    </CardContent>
                    <CardFooter className="flex flex-wrap gap-2">
                        {ex.status != "RESOLVED" and <Button variant="outline" disabled={running} onClick={do_run_recovery}>{running and "Evaluating…" or "Run recovery agent"}</Button> or None}
                        {ex.status != "RESOLVED" and
                            <div className="flex items-center gap-2">
                                <Input placeholder="Closing reason" value={close_reason} onChange={lambda (e: ChangeEvent) { close_reason = e.target.value; }} className="w-48" />
                                <Button variant="outline" disabled={applying} onClick={lambda { do_close("DISMISSED"); }}>Dismiss</Button>
                            </div>
                        or None}
                    </CardFooter>
                    skip;
                }}
            </Card>
        </div>
    </div>
}
