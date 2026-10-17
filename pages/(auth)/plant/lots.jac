"""Stock Lots & Quality: create/edit lots, record inspections, report stock
losses. Available stock = measured - reservations - quality-held, computed
server-side; this page only displays and edits the inputs."""

import from "sonner" { toast }
import from ....inventory.store {
    manager_plants, plant_detail, upsert_lot, add_quality_record, report_stock_loss,
    PlantSummary, PlantDetail, GradeRef, QualityRecordView
}
import from ....inventory.availability { LotAvailability }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }
import from ....components.ui.field { Field, FieldLabel, FieldGroup }
import from ....components.ui.input { Input }
import from ....components.ui.textarea { Textarea }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ....components.ui.dialog { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter }
import from ....components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }

def grade_of(grades: list[GradeRef], mineral_code: str, grade_code: str) -> GradeRef | None {
    for g in grades {
        if g.mineral_code == mineral_code and g.grade_code == grade_code {
            return g;
        }
    }
    return None;
}

def to_num_dict(raw: dict[str, str]) -> dict[str, float] {
    out: dict[str, float] = {};
    for (k, v) in raw.items() {
        try {
            out[k] = float(v) if v else 0.0;
        } except ValueError {
            out[k] = 0.0;
        }
    }
    return out;
}

def:pub StockLotsPage() -> JsxPage {
    has plants: list[PlantSummary] = [],
        active_plant: str = "",
        detail: PlantDetail | None = None,
        loading: bool = True,
        error: str = "",
        saving: bool = False,

        lot_open: bool = False,
        editing_id: str = "",
        lot_mineral: str = "",
        lot_grade: str = "",
        lot_code: str = "",
        lot_stockpile: str = "",
        lot_measured: str = "",
        lot_price: str = "",
        lot_assay: dict[str, str] = {},
        lot_notes: str = "",

        q_lot_id: str = "",
        q_lab: str = "",
        q_results: dict[str, str] = {},
        q_verdict: str = "PENDING",
        q_cert: str = "",
        q_notes: str = "",

        loss_lot_id: str = "",
        loss_measured: str = "",
        loss_reason: str = "";

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

    def open_new_lot {
        editing_id = "";
        lot_mineral = "";
        lot_grade = "";
        lot_code = "";
        lot_stockpile = "";
        lot_measured = "";
        lot_price = "";
        lot_assay = {};
        lot_notes = "";
        lot_open = True;
    }

    def open_edit_lot(lot: LotAvailability) {
        editing_id = lot.lot_id;
        lot_mineral = lot.mineral_code;
        lot_grade = lot.grade_code;
        lot_code = lot.lot_code;
        lot_stockpile = lot.stockpile;
        lot_measured = str(lot.measured_t);
        lot_price = str(lot.price_per_t);
        raw: dict[str, str] = {};
        for (k, v) in lot.assay.items() {
            raw[k] = str(v);
        }
        lot_assay = raw;
        lot_notes = "";
        lot_open = True;
    }

    async def submit_lot {
        if not active_plant or not lot_mineral or not lot_grade or not lot_code {
            toast.error("Fill in the mineral, grade and lot code.");
            return;
        }
        measured = float(lot_measured) if lot_measured else 0.0;
        price = float(lot_price) if lot_price else 0.0;
        saving = True;
        try {
            result = await upsert_lot(active_plant, editing_id, lot_code, lot_mineral, lot_grade, lot_stockpile, measured, price, to_num_dict(lot_assay), lot_notes);
            if result.ok {
                toast.success(result.message);
                lot_open = False;
                await load_detail();
            } else {
                toast.error(result.message or "Could not save this lot.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    def open_quality(lot: LotAvailability) {
        q_lot_id = lot.lot_id;
        q_lab = "";
        raw: dict[str, str] = {};
        for k in lot.assay.keys() {
            raw[k] = "";
        }
        q_results = raw;
        q_verdict = "VERIFIED";
        q_cert = "";
        q_notes = "";
    }

    async def submit_quality {
        if not q_lot_id or len(q_lab) < 2 {
            toast.error("Enter the laboratory or inspector.");
            return;
        }
        saving = True;
        try {
            result = await add_quality_record(q_lot_id, q_lab, to_num_dict(q_results), q_verdict, q_cert, q_notes);
            if result.ok {
                toast.success(result.message);
                q_lot_id = "";
                await load_detail();
            } else {
                toast.error(result.message or "Could not save this inspection.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    def open_loss(lot: LotAvailability) {
        loss_lot_id = lot.lot_id;
        loss_measured = str(lot.measured_t);
        loss_reason = "";
    }

    async def submit_loss {
        if not loss_lot_id or len(loss_reason) < 5 {
            toast.error("Explain the stock loss in a short sentence.");
            return;
        }
        newm = float(loss_measured) if loss_measured else 0.0;
        saving = True;
        try {
            result = await report_stock_loss(loss_lot_id, newm, loss_reason);
            if result.ok {
                toast.success(result.message);
                loss_lot_id = "";
                await load_detail();
            } else {
                toast.error(result.message or "Could not report this loss.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        saving = False;
    }

    grades = detail.grades if detail is not None else [];
    cur_grade = grade_of(grades, lot_mineral, lot_grade);
    assay_keys = cur_grade.param_keys if cur_grade is not None else [];
    minerals_at_plant: list[str] = [];
    for g in grades {
        if g.mineral_code not in minerals_at_plant {
            minerals_at_plant.append(g.mineral_code);
        }
    }
    grades_for_mineral = [g for g in grades if g.mineral_code == lot_mineral];

    <div className="flex flex-col gap-6">
        <PageHeader title="Stock Lots & Quality" description="Measured stock, assays and inspection records.">
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
            <Dialog open={lot_open} onOpenChange={lambda (v: bool) { lot_open = v; }}>
                <DialogTrigger asChild={True}><Button onClick={open_new_lot}>Add lot</Button></DialogTrigger>
                <DialogContent>
                    <DialogHeader>
                        <DialogTitle>{editing_id and "Edit lot" or "Add lot"}</DialogTitle>
                        <DialogDescription>New lots start PENDING until a quality record verifies them.</DialogDescription>
                    </DialogHeader>
                    <FieldGroup>
                        <Field>
                            <FieldLabel htmlFor="lm">Mineral</FieldLabel>
                            <Select value={lot_mineral} onValueChange={lambda (v: str) { lot_mineral = v; lot_grade = ""; }}>
                                <SelectTrigger id="lm" disabled={editing_id != ""}><SelectValue placeholder="Choose a mineral" /></SelectTrigger>
                                <SelectContent>
                                    {for code in minerals_at_plant {
                                        <SelectItem key={code} value={code}>{code}</SelectItem>
                                    }}
                                </SelectContent>
                            </Select>
                        </Field>
                        <Field>
                            <FieldLabel htmlFor="lg">Grade</FieldLabel>
                            <Select value={lot_grade} onValueChange={lambda (v: str) { lot_grade = v; }}>
                                <SelectTrigger id="lg" disabled={editing_id != ""}><SelectValue placeholder="Choose a grade" /></SelectTrigger>
                                <SelectContent>
                                    {for g in grades_for_mineral {
                                        <SelectItem key={g.grade_code} value={g.grade_code}>{g.name}</SelectItem>
                                    }}
                                </SelectContent>
                            </Select>
                        </Field>
                        <Field><FieldLabel htmlFor="lc">Lot code</FieldLabel><Input id="lc" value={lot_code} onChange={lambda (e: ChangeEvent) { lot_code = e.target.value; }} /></Field>
                        <Field><FieldLabel htmlFor="ls">Stockpile / location</FieldLabel><Input id="ls" value={lot_stockpile} onChange={lambda (e: ChangeEvent) { lot_stockpile = e.target.value; }} /></Field>
                        <div className="grid grid-cols-2 gap-4">
                            <Field><FieldLabel htmlFor="lmt">Measured (t)</FieldLabel><Input id="lmt" type="number" value={lot_measured} onChange={lambda (e: ChangeEvent) { lot_measured = e.target.value; }} /></Field>
                            <Field><FieldLabel htmlFor="lp">Price / t</FieldLabel><Input id="lp" type="number" value={lot_price} onChange={lambda (e: ChangeEvent) { lot_price = e.target.value; }} /></Field>
                        </div>
                        {for k in assay_keys {
                            <Field key={k}>
                                <FieldLabel htmlFor={"assay-" + k}>Assay: {k} (%)</FieldLabel>
                                <Input id={"assay-" + k} type="number" value={lot_assay[k] or ""} onChange={lambda (e: ChangeEvent) { lot_assay = {**lot_assay, k: e.target.value}; }} />
                            </Field>
                        }}
                        <Field><FieldLabel htmlFor="ln">Notes</FieldLabel><Textarea id="ln" value={lot_notes} onChange={lambda (e: ChangeEvent) { lot_notes = e.target.value; }} /></Field>
                    </FieldGroup>
                    <DialogFooter><Button disabled={saving} onClick={submit_lot}>{saving and "Saving…" or "Save lot"}</Button></DialogFooter>
                </DialogContent>
            </Dialog>
        </PageHeader>

        {if loading {
            <LoadingRows count={5} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load_detail} />
            skip;
        }}

        {if detail is not None {
            d = detail;
            <Tabs defaultValue="lots">
                <TabsList>
                    <TabsTrigger value="lots">Stock Lots</TabsTrigger>
                    <TabsTrigger value="quality">Quality Records</TabsTrigger>
                </TabsList>
                <TabsContent value="lots" className="pt-4">
                    {if not d.lots {
                        <EmptyState title="No lots yet" actionLabel="Add lot" onAction={open_new_lot} />
                        skip;
                    }}
                    <Card>
                        <CardContent className="p-0">
                            <Table>
                                <TableHeader>
                                    <TableRow>
                                        <TableHead>Lot</TableHead>
                                        <TableHead>Grade</TableHead>
                                        <TableHead>Stockpile</TableHead>
                                        <TableHead>Quality</TableHead>
                                        <TableHead className="text-right">Measured</TableHead>
                                        <TableHead className="text-right">Available</TableHead>
                                        <TableHead></TableHead>
                                    </TableRow>
                                </TableHeader>
                                <TableBody>
                                    {for lot in d.lots {
                                        <TableRow key={lot.lot_id}>
                                            <TableCell className="font-medium">{lot.lot_code}</TableCell>
                                            <TableCell className="text-muted-foreground">{lot.mineral_code} · {lot.grade_code}</TableCell>
                                            <TableCell className="text-muted-foreground">{lot.stockpile}</TableCell>
                                            <TableCell><StatusChip status={lot.quality} /></TableCell>
                                            <TableCell className="text-right tabular-nums">{lot.measured_t} t</TableCell>
                                            <TableCell className="text-right tabular-nums">{lot.available_t} t</TableCell>
                                            <TableCell className="flex items-center justify-end gap-1">
                                                <Button variant="ghost" size="sm" onClick={lambda { open_edit_lot(lot); }}>Edit</Button>
                                                <Dialog>
                                                    <DialogTrigger asChild={True}><Button variant="ghost" size="sm" onClick={lambda { open_quality(lot); }}>Quality</Button></DialogTrigger>
                                                    <DialogContent>
                                                        <DialogHeader><DialogTitle>Record inspection - {lot.lot_code}</DialogTitle></DialogHeader>
                                                        <FieldGroup>
                                                            <Field><FieldLabel htmlFor="qlab">Laboratory / inspector</FieldLabel><Input id="qlab" value={q_lab} onChange={lambda (e: ChangeEvent) { q_lab = e.target.value; }} /></Field>
                                                            {for k in lot.assay.keys() {
                                                                <Field key={k}>
                                                                    <FieldLabel htmlFor={"q-" + k}>{k} (%)</FieldLabel>
                                                                    <Input id={"q-" + k} type="number" value={q_results[k] or ""} onChange={lambda (e: ChangeEvent) { q_results = {**q_results, k: e.target.value}; }} />
                                                                </Field>
                                                            }}
                                                            <Field>
                                                                <FieldLabel htmlFor="qv">Verdict</FieldLabel>
                                                                <Select value={q_verdict} onValueChange={lambda (v: str) { q_verdict = v; }}>
                                                                    <SelectTrigger id="qv"><SelectValue /></SelectTrigger>
                                                                    <SelectContent>
                                                                        <SelectItem value="VERIFIED">Verified</SelectItem>
                                                                        <SelectItem value="PENDING">Pending</SelectItem>
                                                                        <SelectItem value="QUALITY_HOLD">Quality hold</SelectItem>
                                                                    </SelectContent>
                                                                </Select>
                                                            </Field>
                                                            <Field><FieldLabel htmlFor="qc">Certificate no. (optional)</FieldLabel><Input id="qc" value={q_cert} onChange={lambda (e: ChangeEvent) { q_cert = e.target.value; }} /></Field>
                                                            <Field><FieldLabel htmlFor="qn">Notes</FieldLabel><Textarea id="qn" value={q_notes} onChange={lambda (e: ChangeEvent) { q_notes = e.target.value; }} /></Field>
                                                        </FieldGroup>
                                                        <DialogFooter><Button disabled={saving} onClick={submit_quality}>{saving and "Saving…" or "Save inspection"}</Button></DialogFooter>
                                                    </DialogContent>
                                                </Dialog>
                                                <Dialog>
                                                    <DialogTrigger asChild={True}><Button variant="ghost" size="sm" onClick={lambda { open_loss(lot); }}>Report loss</Button></DialogTrigger>
                                                    <DialogContent>
                                                        <DialogHeader><DialogTitle>Report stock loss - {lot.lot_code}</DialogTitle></DialogHeader>
                                                        <FieldGroup>
                                                            <Field><FieldLabel htmlFor="lossm">New measured quantity (t)</FieldLabel><Input id="lossm" type="number" value={loss_measured} onChange={lambda (e: ChangeEvent) { loss_measured = e.target.value; }} /></Field>
                                                            <Field><FieldLabel htmlFor="lossr">Reason</FieldLabel><Textarea id="lossr" value={loss_reason} onChange={lambda (e: ChangeEvent) { loss_reason = e.target.value; }} /></Field>
                                                        </FieldGroup>
                                                        <DialogFooter><Button variant="destructive" disabled={saving} onClick={submit_loss}>{saving and "Saving…" or "Report loss"}</Button></DialogFooter>
                                                    </DialogContent>
                                                </Dialog>
                                            </TableCell>
                                        </TableRow>
                                    }}
                                </TableBody>
                            </Table>
                        </CardContent>
                    </Card>
                </TabsContent>
                <TabsContent value="quality" className="pt-4">
                    {if not d.quality {
                        <EmptyState title="No inspections recorded yet" />
                        skip;
                    }}
                    <div className="flex flex-col gap-3">
                        {for q in d.quality {
                            <Card key={q.id}>
                                <CardHeader>
                                    <div className="flex items-center justify-between">
                                        <CardTitle>{q.lot_code} · {q.lab}</CardTitle>
                                        <StatusChip status={q.verdict} />
                                    </div>
                                    <CardDescription>{fmt_datetime(q.tested_at)} · recorded by {q.recorded_by_name}</CardDescription>
                                </CardHeader>
                                <CardContent className="flex flex-wrap gap-2 text-sm text-muted-foreground">
                                    {for (k, v) in q.results.items() {
                                        <Badge key={k} variant="outline">{k}: {str(v)}%</Badge>
                                    }}
                                    {q.certificate_no and <span>Certificate {q.certificate_no}</span> or None}
                                </CardContent>
                            </Card>
                        }}
                    </div>
                </TabsContent>
            </Tabs>
            skip;
        }}
    </div>
}
