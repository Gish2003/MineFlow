"""Operations Overview: KPIs, on-road risk list and a 7-day trip trend."""

import from "@jac/runtime" { useNavigate }
import from ....dispatch.store { ops_overview, OverviewKpis, OnRoadItem }
import from ....shell.PageHeader { PageHeader }
import from ....shell.KpiCard { KpiCard }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime, fmt_date }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ....components.ui.badge { Badge }

def:pub OpsOverviewPage() -> JsxPage {
    has kpis: OverviewKpis | None = None,
        on_road: list[OnRoadItem] = [],
        trips: list[dict[str, float]] = [],
        scope_names: list[str] = [],
        loading: bool = True,
        error: str = "";

    nav = useNavigate();
    poll_seq = usePoll(15000);

    async def load {
        try {
            result = await ops_overview(poll_seq);
            if result.ok {
                kpis = result.kpis;
                on_road = result.on_road;
                trips = result.trips_by_day;
                scope_names = result.scope_names;
            } else {
                error = result.message or "Could not load the operations overview.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    if loading {
        return <div className="flex flex-col gap-4"><LoadingRows count={5} /></div>;
    }
    if error {
        return <ErrorState message={error} onRetry={load} />;
    }
    k = kpis;
    if k is None {
        return <ErrorState message="No data available." />;
    }

    max_trips = 1.0;
    for row in trips {
        v = row["count"] or 0.0;
        if v > max_trips {
            max_trips = v;
        }
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Operations Overview" description={"Covering " + (", ".join(scope_names) if scope_names else "no plants yet")} />

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <KpiCard label="Awaiting dispatch" value={str(k.awaiting_dispatch)} hint={(str(k.open_exceptions) + " exceptions") if k.open_exceptions > 0 else ""} tone="destructive" />
            <KpiCard label="On the road" value={str(k.loading + k.in_transit)} hint={str(k.scheduled) + " scheduled"} />
            <KpiCard label="On-time delivery" value={str(int(k.on_time_pct)) + "%"} hint={str(k.completed_7d) + " completed (7d)"} />
            <KpiCard label="Fleet available" value={str(k.trucks_available) + " / " + str(k.trucks_total)} hint={(str(k.offline_trucks) + " offline") if k.offline_trucks > 0 else ""} tone={"destructive" if k.offline_trucks > 0 else "default"} />
        </div>

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <Card>
                <CardHeader>
                    <CardTitle>On the road</CardTitle>
                    <CardDescription>Sorted by delivery risk.</CardDescription>
                </CardHeader>
                <CardContent className="flex flex-col gap-2">
                    {if not on_road {
                        <EmptyState title="Nothing on the road right now" />
                        skip;
                    }}
                    {for item in on_road {
                        <div key={item.shipment_id} className="flex items-center justify-between rounded-lg border p-3 text-sm">
                            <div className="flex flex-col">
                                <span className="font-medium">{item.ref} · {item.site_name}</span>
                                <span className="text-muted-foreground">{item.truck_plate} · {item.driver_name} · ETA {fmt_datetime(item.eta_ts)}</span>
                            </div>
                            <div className="flex items-center gap-2">
                                {item.at_risk and <Badge variant="destructive">At risk</Badge> or None}
                                <StatusChip status={item.connectivity} />
                            </div>
                        </div>
                    }}
                </CardContent>
            </Card>

            <Card>
                <CardHeader>
                    <CardTitle>Trips per day</CardTitle>
                    <CardDescription>Last 7 days, completed deliveries.</CardDescription>
                </CardHeader>
                <CardContent>
                    <div className="flex items-end gap-2 h-40">
                        {for row in trips {
                            <div key={str(row["day"])} className="flex flex-1 flex-col items-center gap-1">
                                <div className="w-full rounded-t-md bg-primary" style={{"height": str((row["count"] or 0.0) / max_trips * 100.0) + "%"}}></div>
                                <span className="text-xs text-muted-foreground">{fmt_date(row["day"] or 0.0)[:6]}</span>
                                <span className="text-xs font-medium">{str(int(row["count"] or 0.0))}</span>
                            </div>
                        }}
                    </div>
                </CardContent>
            </Card>
        </div>
    </div>
}
