"""Claims against this plant's stock, grade or quantity - routed here by
dispatch for the store manager to investigate and resolve."""

import from "sonner" { toast }
import from ....claims.store { claims_list, resolve_claim, ClaimView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.badge { Badge }
import from ....components.ui.button { Button }
import from ....components.ui.input { Input }

def:pub PlantClaimsPage() -> JsxPage {
    has claims: list[ClaimView] = [],
        loading: bool = True,
        error: str = "",
        resolutions: dict[str, str] = {},
        acting: str = "";

    poll_seq = usePoll(15000);

    async def load {
        try {
            result = await claims_list("", poll_seq);
            if result.ok {
                claims = result.claims;
            } else {
                error = result.message or "Could not load claims.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def do_resolve(cl: ClaimView, outcome: str) {
        text = resolutions[cl.id] or "";
        if len(text) < 3 {
            toast.error("Add a short resolution note.");
            return;
        }
        acting = cl.id;
        try {
            result = await resolve_claim(cl.id, outcome, text);
            if result.ok {
                toast.success(result.message);
                await load();
            } else {
                toast.error(result.message or "Could not resolve this claim.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        acting = "";
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Claims" description="Issues routed to you by dispatch for investigation." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(claims) == 0 {
            <EmptyState title="No claims" />
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
                        <CardDescription>lot {cl.lot_code} · {fmt_datetime(cl.created_at)}</CardDescription>
                    </CardHeader>
                    <CardContent className="flex flex-col gap-2 text-sm">
                        <div className="flex items-center gap-2">
                            <Badge variant="outline">{cl.claim_type}</Badge>
                            {cl.qty_expected_t > 0 and <span className="text-muted-foreground">expected {fmt_t(cl.qty_expected_t)}, received {fmt_t(cl.qty_received_t)}</span> or None}
                        </div>
                        <p>{cl.description}</p>
                        {cl.resolution and <p className="text-muted-foreground">Resolution: {cl.resolution}</p> or None}
                    </CardContent>
                    {if cl.can_resolve {
                        <CardFooter className="flex flex-wrap items-center gap-2">
                            <Input placeholder="Resolution note" value={resolutions[cl.id] or ""} onChange={lambda (e: ChangeEvent) { resolutions = {**resolutions, cl.id: e.target.value}; }} className="w-64" />
                            <Button size="sm" disabled={acting == cl.id} onClick={lambda { do_resolve(cl, "RESOLVED"); }}>Resolve</Button>
                            <Button size="sm" variant="outline" disabled={acting == cl.id} onClick={lambda { do_resolve(cl, "REJECTED"); }}>Reject</Button>
                        </CardFooter>
                        skip;
                    }}
                </Card>
            }}
        </div>
    </div>
}
