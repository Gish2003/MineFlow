"""Loading Schedule: the hourly bay/slot grid for every plant in scope."""

import from ....dispatch.store { loading_schedule, ScheduleRow }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_date, fmt_clock }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }

def:pub LoadingSchedulePage() -> JsxPage {
    has day_offset: int = 0,
        day_start: float = 0.0,
        plants: list[ScheduleRow] = [],
        loading: bool = True,
        error: str = "";

    poll_seq = usePoll(20000);

    async def load {
        loading = True;
        try {
            result = await loading_schedule(day_offset, poll_seq);
            if result.ok {
                day_start = result.day_start;
                plants = result.plants;
            } else {
                error = result.message or "Could not load the schedule.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [day_offset, poll_seq] entry {
        await load();
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Loading Schedule" description={fmt_date(day_start) if day_start > 0.0 else ""}>
            <Button variant="outline" size="sm" onClick={lambda { day_offset = day_offset - 1; }}>Previous day</Button>
            <Button variant="outline" size="sm" onClick={lambda { day_offset = 0; }}>Today</Button>
            <Button variant="outline" size="sm" onClick={lambda { day_offset = day_offset + 1; }}>Next day</Button>
        </PageHeader>

        {if loading {
            <LoadingRows count={4} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(plants) == 0 {
            <EmptyState title="No plants in scope" />
            skip;
        }}

        <div className="flex flex-col gap-6">
            {for plant in plants {
                <Card key={plant.plant_id}>
                    <CardHeader>
                        <CardTitle>{plant.plant_name}</CardTitle>
                        <CardDescription>{str(len(plant.loaders))} loader(s) on shift today: {", ".join(plant.loaders) or "none"}</CardDescription>
                    </CardHeader>
                    <CardContent>
                        <div className="grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-6">
                            {for slot in plant.slots {
                                <div key={slot.id} className="flex flex-col gap-1 rounded-lg border p-2 text-xs">
                                    <div className="flex items-center justify-between">
                                        <span className="font-medium">Bay {str(slot.bay)}</span>
                                        <StatusChip status={slot.status} />
                                    </div>
                                    <span className="text-muted-foreground">{fmt_clock(slot.start_ts)}–{fmt_clock(slot.end_ts)}</span>
                                    {slot.blocked_reason and <span className="text-destructive">{slot.blocked_reason}</span> or None}
                                </div>
                            }}
                        </div>
                    </CardContent>
                </Card>
            }}
        </div>
    </div>
}
