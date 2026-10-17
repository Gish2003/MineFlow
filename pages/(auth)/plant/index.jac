"""Plant Inventory: KPIs and status for each plant the store manager is
authorized to manage."""

import from "@jac/runtime" { useNavigate }
import from "sonner" { toast }
import from ....inventory.store { manager_plants, set_plant_status, PlantSummary }
import from ....shell.PageHeader { PageHeader }
import from ....shell.KpiCard { KpiCard }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }
import from ....components.ui.input { Input }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def:pub PlantInventoryPage() -> JsxPage {
    has plants: list[PlantSummary] = [],
        loading: bool = True,
        error: str = "",
        notes: dict[str, str] = {},
        acting: str = "";

    nav = useNavigate();
    poll_seq = usePoll(15000);

    async def load {
        try {
            result = await manager_plants(poll_seq);
            if result.ok {
                plants = result.plants;
            } else {
                error = result.message or "Could not load your plants.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def change_status(plant_id: str, status: str) {
        acting = plant_id;
        try {
            result = await set_plant_status(plant_id, status, notes[plant_id] or "");
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not update the plant.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = "";
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Plant Inventory" description="Stock, reservations and readiness for your plant(s)." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(plants) == 0 {
            <EmptyState title="No plants assigned" description="Ask an administrator to scope your account to a plant." />
            skip;
        }}

        <div className="flex flex-col gap-6">
            {for p in plants {
                <Card key={p.id}>
                    <CardHeader>
                        <div className="flex items-center justify-between">
                            <CardTitle>{p.name} ({p.code})</CardTitle>
                            <StatusChip status={p.status} />
                        </div>
                        <CardDescription>{p.region} · minerals: {", ".join(p.minerals)}</CardDescription>
                    </CardHeader>
                    <CardContent>
                        <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
                            <KpiCard label="Available stock" value={str(p.available_t) + " t"} hint={str(p.lots) + " lots"} />
                            <KpiCard label="Reserved" value={str(p.reserved_t) + " t"} />
                            <KpiCard label="Quality held" value={str(p.held_t) + " t"} tone={"destructive" if p.held_t > 0 else "default"} />
                            <KpiCard label="Upcoming loads" value={str(p.upcoming_loads)} hint={(str(p.open_claims) + " open claims") if p.open_claims > 0 else ""} tone={"destructive" if p.open_claims > 0 else "default"} />
                        </div>
                        {p.pending_lots > 0 and <p className="mt-3 text-sm text-muted-foreground">{str(p.pending_lots)} lot(s) pending quality verification.</p> or None}
                        {p.active_delays > 0 and <p className="mt-1 text-sm text-destructive">{str(p.active_delays)} active delay(s) affecting this plant.</p> or None}
                        {p.status_note and <p className="mt-1 text-sm text-muted-foreground">Status note: {p.status_note}</p> or None}
                    </CardContent>
                    <CardFooter className="flex flex-wrap items-center gap-2">
                        <Select value={p.status} onValueChange={lambda (v: str) { change_status(p.id, v); }}>
                            <SelectTrigger className="w-44" disabled={acting == p.id}><SelectValue /></SelectTrigger>
                            <SelectContent>
                                <SelectItem value="OPERATIONAL">Operational</SelectItem>
                                <SelectItem value="RESTRICTED">Restricted</SelectItem>
                                <SelectItem value="UNAVAILABLE">Unavailable</SelectItem>
                            </SelectContent>
                        </Select>
                        <Input placeholder="Status note (optional)" value={notes[p.id] or ""} onChange={lambda (e: ChangeEvent) { notes = {**notes, p.id: e.target.value}; }} className="w-56" />
                        <Button variant="outline" size="sm" onClick={lambda { nav("/plant/lots"); }}>View stock lots</Button>
                    </CardFooter>
                </Card>
            }}
        </div>
    </div>
}
