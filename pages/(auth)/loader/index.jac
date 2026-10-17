"""My Loading Jobs: jobs assigned to me, unclaimed eligible jobs at my
plant(s), and recently completed jobs."""

import from "@jac/runtime" { useNavigate }
import from ....loading.store { loader_home, LoaderJobView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_clock, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ....components.ui.tabs { Tabs, TabsList, TabsTrigger, TabsContent }
import from ....components.ui.badge { Badge }

def:pub LoaderHomePage() -> JsxPage {
    has jobs: list[LoaderJobView] = [],
        eligible: list[LoaderJobView] = [],
        done: list[LoaderJobView] = [],
        loading: bool = True,
        error: str = "";

    nav = useNavigate();
    poll_seq = usePoll(10000);

    async def load {
        try {
            result = await loader_home(poll_seq);
            if result.ok {
                jobs = result.jobs;
                eligible = result.eligible;
                done = result.done;
            } else {
                error = result.message or "Could not load your jobs.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="My Loading Jobs" description="Check in, verify, load and record evidence - all from here." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}

        {if not loading and not error {
            <Tabs defaultValue="mine">
                <TabsList className="w-full">
                    <TabsTrigger value="mine" className="flex-1">My jobs ({str(len(jobs))})</TabsTrigger>
                    <TabsTrigger value="eligible" className="flex-1">Available ({str(len(eligible))})</TabsTrigger>
                    <TabsTrigger value="done" className="flex-1">Done</TabsTrigger>
                </TabsList>
                <TabsContent value="mine" className="flex flex-col gap-3 pt-4">
                    {if not jobs {
                        <EmptyState title="No active jobs" description="Claim an available job to get started." />
                        skip;
                    }}
                    {for j in jobs {
                        <Card key={j.shipment_id} className="cursor-pointer" onClick={lambda { nav("/loader/jobs/" + j.shipment_id); }}>
                            <CardHeader>
                                <div className="flex items-center justify-between">
                                    <CardTitle>{j.ref}</CardTitle>
                                    <StatusChip status={j.status} />
                                </div>
                                <CardDescription>{j.mineral_name} {j.grade_code} · {fmt_t(j.quantity_t)} · bay {str(j.bay)} · present by {fmt_clock(j.present_by)}</CardDescription>
                            </CardHeader>
                            <CardContent className="text-sm text-muted-foreground">{j.next_step}</CardContent>
                        </Card>
                    }}
                </TabsContent>
                <TabsContent value="eligible" className="flex flex-col gap-3 pt-4">
                    {if not eligible {
                        <EmptyState title="Nothing available right now" />
                        skip;
                    }}
                    {for j in eligible {
                        <Card key={j.shipment_id} className="cursor-pointer" onClick={lambda { nav("/loader/jobs/" + j.shipment_id); }}>
                            <CardHeader>
                                <div className="flex items-center justify-between">
                                    <CardTitle>{j.ref}</CardTitle>
                                    <Badge variant="outline">Unclaimed</Badge>
                                </div>
                                <CardDescription>{j.mineral_name} {j.grade_code} · {fmt_t(j.quantity_t)} · bay {str(j.bay)} · present by {fmt_clock(j.present_by)}</CardDescription>
                            </CardHeader>
                        </Card>
                    }}
                </TabsContent>
                <TabsContent value="done" className="flex flex-col gap-3 pt-4">
                    {if not done {
                        <EmptyState title="Nothing completed yet" />
                        skip;
                    }}
                    {for j in done {
                        <Card key={j.shipment_id}>
                            <CardHeader>
                                <div className="flex items-center justify-between">
                                    <CardTitle>{j.ref}</CardTitle>
                                    <StatusChip status={j.status} />
                                </div>
                                <CardDescription>{fmt_t(j.loaded_qty_t)} loaded · ticket {j.load_ticket_no} · fee {j.fee_status}</CardDescription>
                            </CardHeader>
                        </Card>
                    }}
                </TabsContent>
            </Tabs>
            skip;
        }}
    </div>
}
