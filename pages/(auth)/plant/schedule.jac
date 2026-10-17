"""Production / Restocking Schedule and Delays: expected replenishment and
any disruption that should be flagged to dispatch before it causes a missed
loading slot."""

import from "sonner" { toast }
import from ....inventory.store {
    manager_plants, plant_detail, add_production_plan, update_production_plan,
    add_delay, resolve_delay, notify_dispatch, PlantSummary, PlantDetail, GradeRef
}
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_date, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }
import from ....components.ui.field { Field, FieldLabel, FieldGroup }
import from ....components.ui.input { Input }
import from ....components.ui.textarea { Textarea }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ....components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogFooter }
import from ....components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }

def to_epoch(local_value: str) -> float {
    if not local_value {
        return 0.0;
    }
    d: any = new(Date, local_value);
    return float(d.getTime()) / 1000.0;
}

def:pub ScheduleAndDelaysPage() -> JsxPage {
    has plants: list[PlantSummary] = [],
        active_plant: str = "",
        detail: PlantDetail | None = None,
        loading: bool = True,
        error: str = "",
        saving: bool = False,

        plan_mineral: str = "",
        plan_grade: str = "",
        plan_qty: str = "",
        plan_when: str = "",
        plan_note: str = "",

        delay_kind: str = "PRODUCTION",
        delay_severity: str = "MEDIUM",
        delay_start: str = "",
        delay_end: str = "",
        delay_desc: str = "",

        notify_text: str = "";

    poll_seq = usePoll(15000);

    async def load_plants {
        try {
            result = await manager_plants(poll_seq);
            if result.ok {
                plants = result.plants;
                if result.plants and not active_plant {
                    active_plant = result.plants[0].id;
                }
            }
        } except Exception {
            error = "Could not reach the server.";
        }
    }

    async def load_detail {
        if not active_plant {
            loading = False;
            return;
        }
        try {
            result = await plant_detail(active_plant, poll_seq);
            if result.ok {
                detail = result;
            } else {
                error = result.message or "Could not load this plant.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [active_plant, poll_seq] entry {
        await load_plants();
        await load_detail();
    }

    async def submit_plan {
        qty = float(plan_qty) if plan_qty else 0.0;
        when = to_epoch(plan_when);
        if not plan_mineral or not plan_grade or qty <= 0.0 or when <= 0.0 {
            toast.error("Fill in mineral, grade, quantity and an expected date.");
            return;
        }
        saving = True;
        try {
            result = await add_production_plan(active_plant, plan_mineral, plan_grade, qty, when, plan_note);
            if result.ok {
                toast.success(result.message);
                plan_mineral = "";
                plan_grade = "";
                plan_qty = "";
                plan_when = "";
                plan_note = "";
                await load_detail();
            } else {
                toast.error(result.message or "Could not add this plan.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    async def set_plan_status(plan_id: str, status: str) {
        saving = True;
        try {
            result = await update_production_plan(plan_id, status, "");
            if result.ok {
                await load_detail();
            } else {
                toast.error(result.message or "Could not update this plan.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    async def submit_delay {
        start = to_epoch(delay_start);
        end = to_epoch(delay_end);
        if len(delay_desc) < 3 or start <= 0.0 or end <= start {
            toast.error("Fill in a description and a valid start/end.");
            return;
        }
        saving = True;
        try {
            result = await add_delay(active_plant, delay_kind, delay_severity, start, end, delay_desc);
            if result.ok {
                toast.success(result.message);
                delay_desc = "";
                delay_start = "";
                delay_end = "";
                await load_detail();
            } else {
                toast.error(result.message or "Could not add this delay.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    async def do_resolve_delay(delay_id: str) {
        saving = True;
        try {
            result = await resolve_delay(delay_id);
            if result.ok {
                await load_detail();
            } else {
                toast.error(result.message or "Could not resolve this delay.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    async def send_notify {
        if len(notify_text) < 3 {
            toast.error("Write a short note for dispatch.");
            return;
        }
        try {
            result = await notify_dispatch(active_plant, notify_text);
            if result.ok {
                toast.success(result.message);
                notify_text = "";
            } else {
                toast.error(result.message or "Could not send this note.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
    }

    grades = detail.grades if detail is not None else [];
    minerals_at_plant: list[str] = [];
    for g in grades {
        if g.mineral_code not in minerals_at_plant {
            minerals_at_plant.append(g.mineral_code);
        }
    }
    grades_for_mineral = [g for g in grades if g.mineral_code == plan_mineral];

    <div className="flex flex-col gap-6">
        <PageHeader title="Production & Delays" description="Expected replenishment, and anything that could disrupt a loading slot.">
            {if len(plants) > 1 {
                <Select value={active_plant} onValueChange={lambda (v: str) { active_plant = v; }}>
                    <SelectTrigger className="w-48"><SelectValue /></SelectTrigger>
                    <SelectContent>
                        {for p in plants {
                            <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
                        }}
                    </SelectContent>
                </Select>
                skip;
            }}
        </PageHeader>

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load_detail} />
            skip;
        }}

        <Card>
            <CardHeader>
                <CardTitle>Notify dispatch</CardTitle>
                <CardDescription>A free-form readiness or stock note for the dispatcher covering this plant.</CardDescription>
            </CardHeader>
            <CardFooter className="flex gap-2">
                <Input value={notify_text} onChange={lambda (e: ChangeEvent) { notify_text = e.target.value; }} placeholder="e.g. Crusher back online, bay 2 available from 14:00" className="flex-1" />
                <Button onClick={send_notify}>Send</Button>
            </CardFooter>
        </Card>

        {if detail is not None {
            d = detail;
            <Tabs defaultValue="plans">
                <TabsList>
                    <TabsTrigger value="plans">Production Schedule</TabsTrigger>
                    <TabsTrigger value="delays">Delays</TabsTrigger>
                </TabsList>

                <TabsContent value="plans" className="flex flex-col gap-4 pt-4">
                    <Card>
                        <CardHeader><CardTitle>Add expected replenishment</CardTitle></CardHeader>
                        <CardContent>
                            <FieldGroup>
                                <div className="grid grid-cols-2 gap-4">
                                    <Field>
                                        <FieldLabel htmlFor="pm">Mineral</FieldLabel>
                                        <Select value={plan_mineral} onValueChange={lambda (v: str) { plan_mineral = v; plan_grade = ""; }}>
                                            <SelectTrigger id="pm"><SelectValue placeholder="Mineral" /></SelectTrigger>
                                            <SelectContent>
                                                {for code in minerals_at_plant {
                                                    <SelectItem key={code} value={code}>{code}</SelectItem>
                                                }}
                                            </SelectContent>
                                        </Select>
                                    </Field>
                                    <Field>
                                        <FieldLabel htmlFor="pg">Grade</FieldLabel>
                                        <Select value={plan_grade} onValueChange={lambda (v: str) { plan_grade = v; }}>
                                            <SelectTrigger id="pg"><SelectValue placeholder="Grade" /></SelectTrigger>
                                            <SelectContent>
                                                {for g in grades_for_mineral {
                                                    <SelectItem key={g.grade_code} value={g.grade_code}>{g.name}</SelectItem>
                                                }}
                                            </SelectContent>
                                        </Select>
                                    </Field>
                                </div>
                                <div className="grid grid-cols-2 gap-4">
                                    <Field><FieldLabel htmlFor="pq">Expected quantity (t)</FieldLabel><Input id="pq" type="number" value={plan_qty} onChange={lambda (e: ChangeEvent) { plan_qty = e.target.value; }} /></Field>
                                    <Field><FieldLabel htmlFor="pw">Expected by</FieldLabel><Input id="pw" type="datetime-local" value={plan_when} onChange={lambda (e: ChangeEvent) { plan_when = e.target.value; }} /></Field>
                                </div>
                                <Field><FieldLabel htmlFor="pn">Note</FieldLabel><Input id="pn" value={plan_note} onChange={lambda (e: ChangeEvent) { plan_note = e.target.value; }} /></Field>
                                <Button disabled={saving} onClick={submit_plan}>Add plan</Button>
                            </FieldGroup>
                        </CardContent>
                    </Card>
                    {if not d.plans {
                        <EmptyState title="No replenishment planned" />
                        skip;
                    }}
                    {for x in d.plans {
                        <Card key={x.id}>
                            <CardContent className="flex items-center justify-between p-4">
                                <div className="flex flex-col">
                                    <span className="font-medium">{fmt_t(x.expected_t)} {x.mineral_code} {x.grade_code}</span>
                                    <span className="text-sm text-muted-foreground">Expected by {fmt_date(x.expected_at)}{x.note and (" · " + x.note) or ""}</span>
                                </div>
                                <div className="flex items-center gap-2">
                                    <StatusChip status={x.status} />
                                    {x.status == "PLANNED" and
                                        <div className="flex gap-1">
                                            <Button size="sm" variant="outline" onClick={lambda { set_plan_status(x.id, "DELAYED"); }}>Mark delayed</Button>
                                            <Button size="sm" variant="outline" onClick={lambda { set_plan_status(x.id, "DONE"); }}>Mark done</Button>
                                        </div>
                                    or None}
                                </div>
                            </CardContent>
                        </Card>
                    }}
                </TabsContent>

                <TabsContent value="delays" className="flex flex-col gap-4 pt-4">
                    <Card>
                        <CardHeader><CardTitle>Flag a delay</CardTitle></CardHeader>
                        <CardContent>
                            <FieldGroup>
                                <div className="grid grid-cols-2 gap-4">
                                    <Field>
                                        <FieldLabel htmlFor="dk">Kind</FieldLabel>
                                        <Select value={delay_kind} onValueChange={lambda (v: str) { delay_kind = v; }}>
                                            <SelectTrigger id="dk"><SelectValue /></SelectTrigger>
                                            <SelectContent>
                                                <SelectItem value="PRODUCTION">Production</SelectItem>
                                                <SelectItem value="STOCKING">Stocking</SelectItem>
                                                <SelectItem value="EQUIPMENT">Equipment</SelectItem>
                                                <SelectItem value="LOADING">Loading</SelectItem>
                                            </SelectContent>
                                        </Select>
                                    </Field>
                                    <Field>
                                        <FieldLabel htmlFor="dsev">Severity</FieldLabel>
                                        <Select value={delay_severity} onValueChange={lambda (v: str) { delay_severity = v; }}>
                                            <SelectTrigger id="dsev"><SelectValue /></SelectTrigger>
                                            <SelectContent>
                                                <SelectItem value="LOW">Low</SelectItem>
                                                <SelectItem value="MEDIUM">Medium</SelectItem>
                                                <SelectItem value="HIGH">High</SelectItem>
                                            </SelectContent>
                                        </Select>
                                    </Field>
                                </div>
                                <div className="grid grid-cols-2 gap-4">
                                    <Field><FieldLabel htmlFor="dst">Start</FieldLabel><Input id="dst" type="datetime-local" value={delay_start} onChange={lambda (e: ChangeEvent) { delay_start = e.target.value; }} /></Field>
                                    <Field><FieldLabel htmlFor="den">End</FieldLabel><Input id="den" type="datetime-local" value={delay_end} onChange={lambda (e: ChangeEvent) { delay_end = e.target.value; }} /></Field>
                                </div>
                                <Field><FieldLabel htmlFor="dd">Description</FieldLabel><Textarea id="dd" value={delay_desc} onChange={lambda (e: ChangeEvent) { delay_desc = e.target.value; }} /></Field>
                                <Button variant="destructive" disabled={saving} onClick={submit_delay}>Flag delay</Button>
                            </FieldGroup>
                        </CardContent>
                    </Card>
                    {if not d.delays {
                        <EmptyState title="No delays recorded" />
                        skip;
                    }}
                    {for dl in d.delays {
                        <Card key={dl.id}>
                            <CardContent className="flex items-center justify-between p-4">
                                <div className="flex flex-col">
                                    <span className="font-medium">{dl.kind} · {dl.severity}</span>
                                    <span className="text-sm text-muted-foreground">{fmt_date(dl.start_ts)} – {fmt_date(dl.end_ts)} · {dl.description}</span>
                                </div>
                                <div className="flex items-center gap-2">
                                    <Badge variant={dl.active and "destructive" or "outline"}>{dl.active and "Active" or "Resolved"}</Badge>
                                    {dl.active and <Button size="sm" variant="outline" onClick={lambda { do_resolve_delay(dl.id); }}>Resolve</Button> or None}
                                </div>
                            </CardContent>
                        </Card>
                    }}
                </TabsContent>
            </Tabs>
            skip;
        }}
    </div>
}
