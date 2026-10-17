"""Active Deliveries: every in-progress shipment across all of the buyer's
orders, newest first."""

import from "@jac/runtime" { useNavigate }
import from ....orders.store { my_orders, order_detail, OrderSummaryView, ShipmentView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime, fmt_t }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ....components.ui.badge { Badge }

glob ACTIVE_ORDER_STATUSES: list[str] = ["RESERVED", "DISPATCHING", "IN_PROGRESS", "DELIVERED", "EXCEPTION", "DISPUTED"];
glob INACTIVE_SHIPMENT_STATUSES: list[str] = ["CANCELLED", "COMPLETED"];

obj DeliveryRow {
    has order_id: str,
        order_ref: str,
        shipment: ShipmentView;
}

def:pub ActiveDeliveriesPage() -> JsxPage {
    has rows: list[DeliveryRow] = [],
        loading: bool = True,
        error: str = "";

    nav = useNavigate();
    poll_seq = usePoll(15000);

    async def load {
        loading = True;
        error = "";
        try {
            summary = await my_orders("", poll_seq);
            if not summary.ok {
                error = summary.message or "Could not load your orders.";
                loading = False;
                return;
            }
            next_rows: list[DeliveryRow] = [];
            for o in summary.orders {
                if o.status not in ACTIVE_ORDER_STATUSES {
                    continue;
                }
                detail = await order_detail(o.id, poll_seq);
                if not detail.ok or detail.data is None {
                    continue;
                }
                for sh in detail.data.shipments {
                    if sh.status not in INACTIVE_SHIPMENT_STATUSES {
                        next_rows.append(DeliveryRow(order_id=o.id, order_ref=o.ref, shipment=sh));
                    }
                }
            }
            rows = next_rows;
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Active Deliveries" description="Every load currently on its way or awaiting dispatch." />

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(rows) == 0 {
            <EmptyState title="Nothing in progress" description="Deliveries will show up here once an order is reserved." />
            skip;
        }}

        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
            {for row in rows {
                <Card key={row.shipment.id} className="cursor-pointer" onClick={lambda { nav("/buyer/orders/" + row.order_id); }}>
                    <CardHeader>
                        <div className="flex items-center justify-between">
                            <CardTitle>{row.shipment.ref}</CardTitle>
                            <StatusChip status={row.shipment.status} />
                        </div>
                        <CardDescription>{row.order_ref} · {row.shipment.plant_name} · {fmt_t(row.shipment.quantity_t)}</CardDescription>
                    </CardHeader>
                    <CardContent className="flex flex-col gap-1 text-sm text-muted-foreground">
                        <span>Truck {row.shipment.truck_plate or "unassigned"} · Driver {row.shipment.driver_name or "unassigned"}</span>
                        {row.shipment.can_track and <span>Connectivity: <Badge variant="outline">{row.shipment.connectivity}</Badge></span> or None}
                        {row.shipment.eta_ts > 0 and <span>ETA {fmt_datetime(row.shipment.eta_ts)} (simulated)</span> or None}
                    </CardContent>
                </Card>
            }}
        </div>
    </div>
}
