"""Reservations: every hold against this plant's stock, so measured minus
reserved minus quality-held always matches what can still be promised."""

import from ....inventory.store { manager_plants, plant_detail, PlantSummary, PlantDetail }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_date, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def:pub ReservationsPage() -> JsxPage {
    has plants: list[PlantSummary] = [],
        active_plant: str = "",
        detail: PlantDetail | None = None,
        loading: bool = True,
        error: str = "";

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
                error = result.message or "Could not load reservations.";
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

    <div className="flex flex-col gap-6">
        <PageHeader title="Reservations" description="Stock held against confirmed orders.">
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

        {if detail is not None {
            d = detail;
            <Card>
                <CardContent className="p-0">
                    {if not d.reservations {
                        <EmptyState title="No active reservations" />
                        skip;
                    }}
                    <Table>
                        <TableHeader>
                            <TableRow>
                                <TableHead>Lot</TableHead>
                                <TableHead>Order</TableHead>
                                <TableHead>Buyer</TableHead>
                                <TableHead className="text-right">Quantity</TableHead>
                                <TableHead>Status</TableHead>
                                <TableHead>Shipment</TableHead>
                                <TableHead>Slot</TableHead>
                            </TableRow>
                        </TableHeader>
                        <TableBody>
                            {for r in d.reservations {
                                <TableRow key={r.id}>
                                    <TableCell className="font-medium">{r.lot_code}</TableCell>
                                    <TableCell>{r.order_ref}</TableCell>
                                    <TableCell className="text-muted-foreground">{r.buyer_org}</TableCell>
                                    <TableCell className="text-right tabular-nums">{fmt_t(r.quantity_t)}</TableCell>
                                    <TableCell><StatusChip status={r.status} /></TableCell>
                                    <TableCell className="text-muted-foreground">{r.shipment_ref} · {r.shipment_status}</TableCell>
                                    <TableCell className="text-muted-foreground">{r.slot_start > 0 and fmt_date(r.slot_start) or "-"}</TableCell>
                                </TableRow>
                            }}
                        </TableBody>
                    </Table>
                </CardContent>
            </Card>
            skip;
        }}
    </div>
}
