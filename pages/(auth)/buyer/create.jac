"""Buyer: Create Order - one or more mineral loads, a delivery site and a
delivery window. Grade/quality specification follows from the chosen grade
(catalog minimums); quantity is capped at one truckload per line, matching
the server's validation in orders/store.jac."""

import from "@jac/runtime" { useNavigate }
import from "sonner" { toast }
import from ....orders.store { buyer_catalog, create_order, BuyerCatalog, MineralOption, SiteOption, OrderLineInput }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StateViews { LoadingRows, ErrorState }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.field { Field, FieldLabel, FieldGroup, FieldDescription }
import from ....components.ui.input { Input }
import from ....components.ui.textarea { Textarea }
import from ....components.ui.badge { Badge }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }
import from ....components.ui.separator { Separator }

def find_mineral(minerals: list[MineralOption], code: str) -> MineralOption | None {
    for m in minerals {
        if m.code == code {
            return m;
        }
    }
    return None;
}

def to_epoch(local_value: str) -> float {
    if not local_value {
        return 0.0;
    }
    d: any = new(Date, local_value);
    return float(d.getTime()) / 1000.0;
}

def:pub CreateOrderPage() -> JsxPage {
    has catalog: BuyerCatalog | None = None,
        loading: bool = True,
        error: str = "",
        site_id: str = "",
        window_start: str = "",
        window_end: str = "",
        notes: str = "",
        cur_mineral: str = "",
        cur_grade: str = "",
        cur_qty: str = "",
        lines: list[OrderLineInput] = [],
        submitting: bool = False;

    nav = useNavigate();

    async can with entry {
        try {
            result = await buyer_catalog();
            if result.ok {
                catalog = result;
                if result.sites {
                    site_id = result.sites[0].id;
                }
            } else {
                error = result.message or "Could not load the catalog.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    def add_line {
        cat = catalog;
        if cat is None {
            return;
        }
        if not cur_mineral or not cur_grade {
            toast.error("Choose a mineral and grade.");
            return;
        }
        qty = float(cur_qty) if cur_qty else 0.0;
        if qty <= 0 or qty > cat.max_load_t {
            toast.error(f"Quantity must be between 0 and {cat.max_load_t} t (one truckload per load).");
            return;
        }
        if len(lines) >= 6 {
            toast.error("A single order can hold at most six loads.");
            return;
        }
        lines = lines + [OrderLineInput(mineral_code=cur_mineral, grade_code=cur_grade, quantity_t=qty, spec_overrides=[])];
        cur_mineral = "";
        cur_grade = "";
        cur_qty = "";
    }

    def remove_line(idx: int) {
        lines = [l for (i, l) in enumerate(lines) if i != idx];
    }

    async def submit {
        if not site_id {
            toast.error("Choose a delivery site.");
            return;
        }
        if not lines {
            toast.error("Add at least one load.");
            return;
        }
        ws = to_epoch(window_start);
        we = to_epoch(window_end);
        if ws <= 0.0 or we <= 0.0 {
            toast.error("Choose a delivery window start and end.");
            return;
        }
        submitting = True;
        try {
            result = await create_order(site_id, ws, we, lines, notes);
            if result.ok {
                toast.success(result.message);
                nav("/buyer/orders/" + result.id);
            } else {
                toast.error(result.message or "Could not create the order.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        submitting = False;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Create Order" description="Add one or more loads, choose a delivery site and window." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} />
            skip;
        }}
        {if catalog is None {
            skip;
        }}

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-3">
            <Card className="lg:col-span-2">
                <CardHeader>
                    <CardTitle>Loads</CardTitle>
                    <CardDescription>Mineral, grade and quantity for each truckload.</CardDescription>
                </CardHeader>
                <CardContent className="flex flex-col gap-4">
                    {for (idx, l) in enumerate(lines) {
                        <div key={str(idx)} className="flex items-center justify-between rounded-lg border p-3">
                            <div className="flex flex-col">
                                <span className="text-sm font-medium">{l.quantity_t} t · {l.mineral_code}</span>
                                <span className="text-xs text-muted-foreground">Grade {l.grade_code}</span>
                            </div>
                            <Button variant="ghost" size="sm" onClick={lambda { remove_line(idx); }}>Remove</Button>
                        </div>
                    }}

                    {if catalog is not None {
                        <div className="rounded-lg border p-4">
                            <FieldGroup>
                                <Field>
                                    <FieldLabel htmlFor="mineral">Mineral</FieldLabel>
                                    <Select value={cur_mineral} onValueChange={lambda (v: str) { cur_mineral = v; cur_grade = ""; }}>
                                        <SelectTrigger id="mineral"><SelectValue placeholder="Choose a mineral" /></SelectTrigger>
                                        <SelectContent>
                                            {for m in (catalog.minerals if catalog is not None else []) {
                                                <SelectItem key={m.code} value={m.code}>{m.name} ({str(m.plant_count)} plants)</SelectItem>
                                            }}
                                        </SelectContent>
                                    </Select>
                                </Field>
                                {if cur_mineral {
                                    sel = find_mineral(catalog.minerals, cur_mineral) if catalog is not None else None;
                                    grade_list = sel.grades if sel is not None else [];
                                    <Field>
                                        <FieldLabel htmlFor="grade">Grade / quality spec</FieldLabel>
                                        <Select value={cur_grade} onValueChange={lambda (v: str) { cur_grade = v; }}>
                                            <SelectTrigger id="grade"><SelectValue placeholder="Choose a grade" /></SelectTrigger>
                                            <SelectContent>
                                                {for g in grade_list {
                                                    <SelectItem key={g.code} value={g.code}>{g.name}</SelectItem>
                                                }}
                                            </SelectContent>
                                        </Select>
                                        <FieldDescription>The minimum assay thresholds for this grade are enforced automatically when matching stock lots.</FieldDescription>
                                    </Field>
                                    skip;
                                }}
                                <Field>
                                    <FieldLabel htmlFor="qty">Quantity (t)</FieldLabel>
                                    <Input id="qty" type="number" min="1" max={str(catalog.max_load_t if catalog is not None else 40)} value={cur_qty} onChange={lambda (e: ChangeEvent) { cur_qty = e.target.value; }} />
                                    <FieldDescription>One truckload per line, up to {str(catalog.max_load_t if catalog is not None else 40.0)} t.</FieldDescription>
                                </Field>
                                <Button type="button" variant="outline" onClick={add_line}>Add this load</Button>
                            </FieldGroup>
                        </div>
                        skip;
                    }}
                </CardContent>
            </Card>

            <Card>
                <CardHeader>
                    <CardTitle>Delivery</CardTitle>
                    <CardDescription>Where and when.</CardDescription>
                </CardHeader>
                <CardContent className="flex flex-col gap-4">
                    <Field>
                        <FieldLabel htmlFor="site">Delivery site</FieldLabel>
                        <Select value={site_id} onValueChange={lambda (v: str) { site_id = v; }}>
                            <SelectTrigger id="site"><SelectValue placeholder="Choose a site" /></SelectTrigger>
                            <SelectContent>
                                {for s in (catalog.sites if catalog is not None else []) {
                                    <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>
                                }}
                            </SelectContent>
                        </Select>
                    </Field>
                    <Field>
                        <FieldLabel htmlFor="ws">Window start</FieldLabel>
                        <Input id="ws" type="datetime-local" value={window_start} onChange={lambda (e: ChangeEvent) { window_start = e.target.value; }} />
                    </Field>
                    <Field>
                        <FieldLabel htmlFor="we">Window end</FieldLabel>
                        <Input id="we" type="datetime-local" value={window_end} onChange={lambda (e: ChangeEvent) { window_end = e.target.value; }} />
                        <FieldDescription>At least an hour from now, and at least two hours long.</FieldDescription>
                    </Field>
                    <Field>
                        <FieldLabel htmlFor="notes">Notes (optional)</FieldLabel>
                        <Textarea id="notes" value={notes} onChange={lambda (e: ChangeEvent) { notes = e.target.value; }} />
                    </Field>
                </CardContent>
                <CardFooter>
                    <Button className="w-full" disabled={submitting} onClick={submit}>{submitting and "Creating…" or "Create order"}</Button>
                </CardFooter>
            </Card>
        </div>
    </div>
}
