"""Audit Trail: every consequential action within the dispatcher's scope,
including recorded override reasons."""

import from ....dispatch.store { audit_trail, AuditView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardContent }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.badge { Badge }

def:pub AuditTrailPage() -> JsxPage {
    has events: list[AuditView] = [],
        loading: bool = True,
        error: str = "";

    poll_seq = usePoll(20000);

    async def load {
        try {
            result = await audit_trail(150, poll_seq);
            if result.ok {
                events = result.events;
            } else {
                error = result.message or "Could not load the audit trail.";
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
        <PageHeader title="Audit Trail" description="Every consequential action within your plant scope, newest first." />

        {if loading {
            <LoadingRows count={6} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}
        {if not loading and not error and len(events) == 0 {
            <EmptyState title="No activity yet" />
            skip;
        }}

        <Card>
            <CardContent className="p-0">
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>When</TableHead>
                            <TableHead>Who</TableHead>
                            <TableHead>Action</TableHead>
                            <TableHead>Entity</TableHead>
                            <TableHead>Detail</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {for ev in events {
                            <TableRow key={str(ev.at) + ev.entity_id}>
                                <TableCell className="whitespace-nowrap text-muted-foreground">{fmt_datetime(ev.at)}</TableCell>
                                <TableCell>{ev.actor_name} <span className="text-xs text-muted-foreground">({ev.actor_role})</span></TableCell>
                                <TableCell><Badge variant="outline">{ev.action}</Badge></TableCell>
                                <TableCell className="text-muted-foreground">{ev.entity_type}</TableCell>
                                <TableCell className="text-muted-foreground">{ev.summary}{ev.reason and (" — " + ev.reason) or ""}</TableCell>
                            </TableRow>
                        }}
                    </TableBody>
                </Table>
            </CardContent>
        </Card>
    </div>
}
