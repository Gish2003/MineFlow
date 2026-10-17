"""Available Offers and My Assignments: accept or reject a delivery offer,
then track every job you're carrying through to completion."""

import from "@jac/runtime" { useNavigate }
import from "sonner" { toast }
import from ....delivery.store { driver_home, respond_offer, OfferView, DriverJobView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_clock, fmt_t, fmt_km, fmt_minutes, fmt_money }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from ....components.ui.input { Input }

def:pub DriverHomePage() -> JsxPage {
    has offers: list[OfferView] = [],
        jobs: list[DriverJobView] = [],
        completed: list[DriverJobView] = [],
        loading: bool = True,
        error: str = "",
        acting: str = "",
        reject_reason: dict[str, str] = {};

    nav = useNavigate();
    poll_seq = usePoll(10000);

    async def load {
        try {
            result = await driver_home(poll_seq);
            if result.ok {
                offers = result.offers;
                jobs = result.jobs;
                completed = result.completed;
            } else {
                error = result.message or "Could not load your offers.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def do_respond(offer_id: str, accept: bool) {
        acting = offer_id;
        try {
            result = await respond_offer(offer_id, accept, "" if accept else (reject_reason[offer_id] or "Not available"));
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not respond to this offer.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = "";
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Offers & Assignments" description="Mineral deliveries offered to you, and the jobs you've accepted." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}

        {if not loading and not error {
            <Tabs defaultValue="offers">
                <TabsList className="w-full">
                    <TabsTrigger value="offers" className="flex-1">Offers ({str(len(offers))})</TabsTrigger>
                    <TabsTrigger value="jobs" className="flex-1">My Jobs ({str(len(jobs))})</TabsTrigger>
                    <TabsTrigger value="completed" className="flex-1">Completed</TabsTrigger>
                </TabsList>

                <TabsContent value="offers" className="flex flex-col gap-3 pt-4">
                    {if not offers {
                        <EmptyState title="No offers right now" />
                        skip;
                    }}
                    {for o in offers {
                        <Card key={o.id}>
                            <CardHeader>
                                <CardTitle>{o.mineral_name} {o.grade_code} · {fmt_t(o.quantity_t)}</CardTitle>
                                <CardDescription>Pickup at {o.plant_name} - deliver to {o.dest_name}, {o.dest_address}</CardDescription>
                            </CardHeader>
                            <CardContent className="grid grid-cols-2 gap-2 text-sm text-muted-foreground">
                                <span>Slot {fmt_clock(o.slot_start)} · window ends {fmt_clock(o.window_end)}</span>
                                <span>{fmt_km(o.distance_km)} · ~{fmt_minutes(o.travel_minutes)} drive</span>
                                <span>Truck {o.truck_plate} ({str(o.truck_payload_t)} t {o.truck_body})</span>
                                <span className="font-medium text-foreground">Pay: {fmt_money(o.pay_amount, o.currency)}</span>
                            </CardContent>
                            <CardFooter className="flex flex-wrap items-center gap-2">
                                <Button className="h-11" disabled={acting == o.id} onClick={lambda { do_respond(o.id, True); }}>Accept</Button>
                                <Input placeholder="Reason to decline" value={reject_reason[o.id] or ""} onChange={lambda (e: ChangeEvent) { reject_reason = {**reject_reason, o.id: e.target.value}; }} className="h-11 w-44" />
                                <Button variant="outline" className="h-11" disabled={acting == o.id} onClick={lambda { do_respond(o.id, False); }}>Decline</Button>
                            </CardFooter>
                        </Card>
                    }}
                </TabsContent>

                <TabsContent value="jobs" className="flex flex-col gap-3 pt-4">
                    {if not jobs {
                        <EmptyState title="No active jobs" description="Accept an offer to get started." />
                        skip;
                    }}
                    {for j in jobs {
                        <Card key={j.shipment_id} className="cursor-pointer" onClick={lambda { nav("/driver/jobs/" + j.shipment_id); }}>
                            <CardHeader>
                                <div className="flex items-center justify-between">
                                    <CardTitle>{j.ref}</CardTitle>
                                    <StatusChip status={j.status} />
                                </div>
                                <CardDescription>{j.plant_name} → {j.dest_name} · {fmt_t(j.quantity_t)} {j.mineral_name}</CardDescription>
                            </CardHeader>
                            <CardContent className="text-sm text-muted-foreground">{j.next_step}</CardContent>
                        </Card>
                    }}
                </TabsContent>

                <TabsContent value="completed" className="flex flex-col gap-3 pt-4">
                    {if not completed {
                        <EmptyState title="No completed deliveries yet" />
                        skip;
                    }}
                    {for j in completed {
                        <Card key={j.shipment_id}>
                            <CardHeader>
                                <div className="flex items-center justify-between">
                                    <CardTitle>{j.ref}</CardTitle>
                                    <StatusChip status={j.status} />
                                </div>
                                <CardDescription>{j.plant_name} → {j.dest_name} · {fmt_t(j.quantity_t)}</CardDescription>
                            </CardHeader>
                        </Card>
                    }}
                </TabsContent>
            </Tabs>
            skip;
        }}
    </div>
}
