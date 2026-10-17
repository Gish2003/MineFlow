"""Payment Status: your loading service fees and where each one is in the
settlement flow. Simulated ledger - no real money moves."""

import from ....payments.ledger { ledger_entries, LedgerView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime, fmt_money }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.badge { Badge }

def:pub LoaderPaymentsPage() -> JsxPage {
    has entries: list[LedgerView] = [],
        totals: dict[str, float] = {},
        loading: bool = True,
        error: str = "";

    poll_seq = usePoll(20000);

    async def load {
        try {
            result = await ledger_entries("LOADER_FEE", poll_seq);
            if result.ok {
                entries = result.entries;
                totals = result.totals;
            } else {
                error = result.message or "Could not load your payments.";
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
        <PageHeader title="Payment Status" description="Loading fees (simulated - no real money moves)." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(entries) == 0 {
            <EmptyState title="No fees recorded yet" description="Fees appear once you finish loading a job." />
            skip;
        }}

        <div className="flex flex-wrap gap-2">
            {for status in ["PENDING", "APPROVED", "PAID", "FAILED"] {
                <Badge key={status} variant="outline">{status}: {fmt_money(totals[status] or 0.0, "LKR")}</Badge>
            }}
        </div>

        <Card>
            <CardContent className="p-0">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>Shipment</TableHead>
                            <TableHead>Order</TableHead>
                            <TableHead className="text-right">Amount</TableHead>
                            <TableHead>Status</TableHead>
                            <TableHead>Updated</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {for e in entries {
                            <TableRow key={e.id}>
                                <TableCell className="font-medium">{e.shipment_ref}</TableCell>
                                <TableCell className="text-muted-foreground">{e.order_ref}</TableCell>
                                <TableCell className="text-right tabular-nums">{fmt_money(e.amount, e.currency)}</TableCell>
                                <TableCell><StatusChip status={e.status} /></TableCell>
                                <TableCell className="text-muted-foreground">{fmt_datetime(e.updated_at)}</TableCell>
                            </TableRow>
                        }}
                    </TableBody>
                </Table>
            </CardContent>
        </Card>
    </div>
}
