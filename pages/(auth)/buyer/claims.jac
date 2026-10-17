"""Claims: grade, quantity or delivery issues the buyer has reported."""

import from ....claims.store { claims_list, ClaimView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ....components.ui.badge { Badge }

def:pub ClaimsPage() -> JsxPage {
    has claims: list[ClaimView] = [],
        loading: bool = True,
        error: str = "";

    poll_seq = usePoll(20000);

    async def load {
        try {
            result = await claims_list("", poll_seq);
            if result.ok {
                claims = result.claims;
            } else {
                error = result.message or "Could not load your claims.";
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
        <PageHeader title="Claims" description="Quality, quantity and delivery issues you've reported, and their outcome." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(claims) == 0 {
            <EmptyState title="No claims filed" description="Report an issue from a delivery's Order Details page if something is wrong." />
            skip;
        }}

        <div className="flex flex-col gap-4">
            {for cl in claims {
                <Card key={cl.id}>
                    <CardHeader>
                        <div className="flex items-center justify-between">
                            <CardTitle>{cl.ref} · {cl.order_ref}</CardTitle>
                            <StatusChip status={cl.status} />
                        </div>
                        <CardDescription>{cl.plant_name} · lot {cl.lot_code} · {fmt_datetime(cl.created_at)}</CardDescription>
                    </CardHeader>
                    <CardContent className="flex flex-col gap-2 text-sm">
                        <div className="flex items-center gap-2">
                            <Badge variant="outline">{cl.claim_type}</Badge>
                            {cl.qty_expected_t > 0 and <span className="text-muted-foreground">expected {fmt_t(cl.qty_expected_t)}, received {fmt_t(cl.qty_received_t)}</span> or None}
                        </div>
                        <p>{cl.description}</p>
                        <p className="text-muted-foreground">Routed to: {cl.routed_to or "not yet routed"}</p>
                        {cl.resolution and <p className="text-muted-foreground">Resolution: {cl.resolution}</p> or None}
                    </CardContent>
                </Card>
            }}
        </div>
    </div>
}
