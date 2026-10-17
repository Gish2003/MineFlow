"""Drivers & Vehicles: fleet status and driver workload, with a quick way to
take a truck in or out of service for maintenance."""

import from "sonner" { toast }
import from ....dispatch.store { fleet_overview, set_truck_status, FleetTruck, FleetDriver }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StatusChip { StatusChip }
import from ....shell.StateViews { LoadingRows, ErrorState }
import from ....hooks.usePoll { usePoll }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardContent }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.button { Button }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def:pub FleetPage() -> JsxPage {
    has trucks: list[FleetTruck] = [],
        drivers: list[FleetDriver] = [],
        loading: bool = True,
        error: str = "",
        busy_id: str = "";

    poll_seq = usePoll(15000);

    async def load {
        try {
            result = await fleet_overview(poll_seq);
            if result.ok {
                trucks = result.trucks;
                drivers = result.drivers;
            } else {
                error = result.message or "Could not load the fleet.";
            }
        } except Exception {
            error = "Could not reach the server.";
        }
        loading = False;
    }

    async can with [poll_seq] entry {
        await load();
    }

    async def change_status(truck_id: str, status: str) {
        busy_id = truck_id;
        try {
            result = await set_truck_status(truck_id, status, "");
            if result.ok {
                await load();
            } else {
                toast.error(result.message or "Could not update the truck.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        busy_id = "";
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Drivers & Vehicles" description="Fleet status and current workload." />

        {if loading {
            <LoadingRows count={5} />
            skip;
        }}
        {if error {
            <ErrorState message={error} onRetry={load} />
            skip;
        }}

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <Card>
                <CardHeader><CardTitle>Trucks</CardTitle></CardHeader>
                <CardContent className="p-0">
                    <Table>
                        <TableHeader>
                            <TableRow>
                                <TableHead>Plate</TableHead>
                                <TableHead>Payload</TableHead>
                                <TableHead>Body</TableHead>
                                <TableHead>Status</TableHead>
                                <TableHead>Job</TableHead>
                                <TableHead></TableHead>
                            </TableRow>
                        </TableHeader>
                        <TableBody>
                            {for t in trucks {
                                <TableRow key={t.id}>
                                    <TableCell className="font-medium">{t.plate}</TableCell>
                                    <TableCell>{str(t.payload_t)} t</TableCell>
                                    <TableCell>{t.body_type}</TableCell>
                                    <TableCell><StatusChip status={t.status} /></TableCell>
                                    <TableCell className="text-muted-foreground">{t.current_job or "-"}</TableCell>
                                    <TableCell>
                                        <Select value={t.status} onValueChange={lambda (v: str) { change_status(t.id, v); }}>
                                            <SelectTrigger className="h-7 w-32 text-xs" disabled={busy_id == t.id or t.status == "IN_USE"}><SelectValue /></SelectTrigger>
                                            <SelectContent>
                                                <SelectItem value="AVAILABLE">Available</SelectItem>
                                                <SelectItem value="MAINTENANCE">Maintenance</SelectItem>
                                            </SelectContent>
                                        </Select>
                                    </TableCell>
                                </TableRow>
                            }}
                        </TableBody>
                    </Table>
                </CardContent>
            </Card>

            <Card>
                <CardHeader><CardTitle>Drivers</CardTitle></CardHeader>
                <CardContent className="p-0">
                    <Table>
                        <TableHeader>
                            <TableRow>
                                <TableHead>Name</TableHead>
                                <TableHead>Licence</TableHead>
                                <TableHead>Active jobs</TableHead>
                                <TableHead>Connectivity</TableHead>
                            </TableRow>
                        </TableHeader>
                        <TableBody>
                            {for d in drivers {
                                <TableRow key={d.id}>
                                    <TableCell className="font-medium">{d.name}</TableCell>
                                    <TableCell>{d.license_class}</TableCell>
                                    <TableCell>{str(d.active_jobs)}{d.current_job and (" · " + d.current_job) or ""}</TableCell>
                                    <TableCell>{d.connectivity and <StatusChip status={d.connectivity} /> or "-"}</TableCell>
                                </TableRow>
                            }}
                        </TableBody>
                    </Table>
                </CardContent>
            </Card>
        </div>
    </div>
}
