"""Buyer home: My Orders."""

import from "@jac/runtime" { Link, useNavigate }
import from ....orders.store { my_orders, OrderSummaryView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....hooks.usePoll { usePoll }
import from ....shell.format { fmt_date, fmt_t }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.button { Button }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

glob STATUS_OPTIONS: list[str] = [
    "", "DRAFT", "PLANNING", "OPTIONS_READY", "NO_FEASIBLE_OPTION", "RESERVED", "DISPATCHING",
    "IN_PROGRESS", "DELIVERED", "COMPLETED", "DISPUTED", "EXCEPTION", "CANCELLED"
];

def:pub MyOrdersPage() -> JsxPage {
    has orders: list[OrderSummaryView] = [],
        loading: bool = True,
        error: str = "",
        status_filter: str = "";

    nav = useNavigate();
    poll_seq = usePoll(20000);

    async def load {
        loading = True;
        error = "";
        try {
            result = await my_orders(status_filter, poll_seq);
            if result.ok {
                orders = result.orders;
            } else {
                error = result.message or "Could not load your orders.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [status_filter, poll_seq] entry {
        await load();
    }

    def goto_create {
        nav("/buyer/create");
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="My Orders" description="Everything you have ordered, in one place.">
            <Button onClick={goto_create}>New order</Button>
        </PageHeader>

        <div className="flex items-center gap-2">
            <Select value={status_filter} onValueChange={lambda (v: str) { status_filter = v; }}>
                <SelectTrigger className="w-56"><SelectValue placeholder="All statuses" /></SelectTrigger>
                <SelectContent>
                    {for s in STATUS_OPTIONS {
                        <SelectItem key={s or "ALL"} value={s}>{s or "All statuses"}</SelectItem>
                    }}
                </SelectContent>
            </Select>
        </div>

        {if loading {
            <LoadingRows count={5} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if len(orders) == 0 {
            <EmptyState title="No orders yet" description="Create your first mineral order to get plant recommendations." actionLabel="Create order" onAction={goto_create} />
            skip;
        }}

        <Card>
            <CardContent className="p-0">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>Order</TableHead>
                            <TableHead>Destination</TableHead>
                            <TableHead>Load(s)</TableHead>
                            <TableHead>Window</TableHead>
                            <TableHead>Status</TableHead>
                            <TableHead>Next action</TableHead>
                            <TableHead className="text-right">Total</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {for o in orders {
                            <TableRow key={o.id} className="cursor-pointer" onClick={lambda { nav("/buyer/orders/" + o.id); }}>
                                <TableCell className="font-medium"><Link to={"/buyer/orders/" + o.id}>{o.ref}</Link></TableCell>
                                <TableCell>{o.site_name}</TableCell>
                                <TableCell className="text-muted-foreground">{o.lines_text}</TableCell>
                                <TableCell className="text-muted-foreground">{fmt_date(o.window_start)} – {fmt_date(o.window_end)}</TableCell>
                                <TableCell><StatusChip status={o.status} /></TableCell>
                                <TableCell className="text-muted-foreground">{o.next_action}</TableCell>
                                <TableCell className="text-right tabular-nums">{fmt_t(o.total_t)}</TableCell>
                            </TableRow>
                        }}
                    </TableBody>
                </Table>
            </CardContent>
        </Card>
    </div>
}
