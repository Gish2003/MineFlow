"""Order Queue: every order within the dispatcher's plant scope, with flags
for late loading, offline trucks and open exceptions."""

import from "@jac/runtime" { useNavigate }
import from ....dispatch.store { dispatch_queue, QueueRow }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_date, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.badge { Badge }
import from ....components.ui.button { Button }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def:pub OrderQueuePage() -> JsxPage {
    has rows: list[QueueRow] = [],
        counts: dict[str, int] = {},
        view: str = "ACTIVE",
        loading: bool = True,
        error: str = "";

    nav = useNavigate();
    poll_seq = usePoll(15000);

    async def load {
        loading = True;
        try {
            result = await dispatch_queue(view, poll_seq);
            if result.ok {
                rows = result.rows;
                counts = result.counts;
            } else {
                error = result.message or "Could not load the order queue.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [view, poll_seq] entry {
        await load();
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Order Queue" description="Orders and their shipments, scoped to the plants you dispatch for.">
            <Select value={view} onValueChange={lambda (v: str) { view = v; }}>
                <SelectTrigger className="w-40"><SelectValue /></SelectTrigger>
                <SelectContent>
                    <SelectItem value="ACTIVE">Active</SelectItem>
                    <SelectItem value="DONE">Done</SelectItem>
                    <SelectItem value="ALL">All</SelectItem>
                </SelectContent>
            </Select>
        </PageHeader>

        {if loading {
            <LoadingRows count={5} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(rows) == 0 {
            <EmptyState title="Queue is empty" description="Nothing matches this filter right now." />
            skip;
        }}

        <div className="flex flex-col gap-4">
            {for row in rows {
                <Card key={row.order_id}>
                    <CardContent className="flex flex-col gap-3 p-4">
                        <div className="flex items-center justify-between">
                            <div className="flex flex-col">
                                <span className="font-medium">{row.ref} · {row.site_name}</span>
                                <span className="text-xs text-muted-foreground">{row.buyer_org} · {fmt_t(row.total_t)} · window {fmt_date(row.window_start)} – {fmt_date(row.window_end)}</span>
                            </div>
                            <div className="flex items-center gap-2">
                                {for f in row.flags {
                                    <Badge key={f} variant="destructive">{f}</Badge>
                                }}
                                <StatusChip status={row.status} />
                            </div>
                        </div>
                        <div className="flex flex-col gap-1">
                            {for sh in row.shipments {
                                <div key={sh.id} className="flex items-center justify-between rounded-lg border p-2 text-sm">
                                    <span>{sh.ref} · {sh.plant_name} · {fmt_t(sh.quantity_t)} {sh.grade_code}</span>
                                    <div className="flex items-center gap-2">
                                        {sh.late and <Badge variant="destructive">Late</Badge> or None}
                                        <span className="text-muted-foreground">{sh.driver_name or "unassigned"}</span>
                                        <StatusChip status={sh.status} />
                                        {(sh.status == "AWAITING_DISPATCH" or sh.status == "EXCEPTION") and
                                            <Button size="sm" variant="outline" onClick={lambda { nav("/dispatch/board?shipment=" + sh.id); }}>Assign</Button>
                                        or None}
                                    </div>
                                </div>
                            }}
                        </div>
                        {row.next_action and <p className="text-xs font-medium text-muted-foreground">{row.next_action}</p> or None}
                    </CardContent>
                </Card>
            }}
        </div>
    </div>
}
