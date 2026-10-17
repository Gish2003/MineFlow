"""Loading Schedule: upcoming loads at this plant, in slot order. Built from
the same reservation data as the Reservations page, grouped by day for a
quick read of what's coming up."""

import from ....inventory.store { manager_plants, plant_detail, PlantSummary, PlantDetail }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_date, fmt_clock, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardContent }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def:pub PlantLoadingSchedulePage() -> JsxPage {
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
                error = result.message or "Could not load the schedule.";
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

    upcoming = [r for r in (detail.reservations if detail is not None else []) if r.slot_start > 0.0];
    ordered = sorted(upcoming, key=by_slot);

    <div className="flex flex-col gap-6">
        <PageHeader title="Loading Schedule" description="Upcoming loads at this plant, by scheduled slot.">
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
        {if not loading and not error and len(ordered) == 0 {
            <EmptyState title="Nothing scheduled" />
            skip;
        }}

        <div className="flex flex-col gap-3">
            {for r in ordered {
                <Card key={r.id}>
                    <CardContent className="flex items-center justify-between p-4">
                        <div className="flex flex-col">
                            <span className="font-medium">{fmt_date(r.slot_start)} · {fmt_clock(r.slot_start)}</span>
                            <span className="text-sm text-muted-foreground">{r.lot_code} · {fmt_t(r.quantity_t)} · {r.order_ref} ({r.buyer_org})</span>
                        </div>
                        <StatusChip status={r.shipment_status or r.status} />
                    </CardContent>
                </Card>
            }}
        </div>
    </div>
}

def by_slot(r: any) -> float {
    return r.slot_start as float;
}
