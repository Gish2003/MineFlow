"""Spreadsheet Import/Export: preview every row (new/update/unchanged/invalid)
before anything touches stock, commit only the valid rows, and export the
current inventory as CSV or XLSX."""

import from "sonner" { toast }
import from ....inventory.store { manager_plants, PlantSummary }
import from ....inventory.spreadsheet { preview_import, commit_import, import_history, export_inventory, ImportRowView, ImportBatchView }
import from ....shell.PageHeader { PageHeader }
import from ....shell.StateViews { LoadingRows, ErrorState, EmptyState }
import from ....shell.format { fmt_datetime }
import from ....components.ui.card { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter }
import from ....components.ui.button { Button }
import from ....components.ui.badge { Badge }
import from ....components.ui.table { Table, TableHeader, TableBody, TableRow, TableHead, TableCell }
import from ....components.ui.select { Select, SelectTrigger, SelectValue, SelectContent, SelectItem }

def row_tone(action: str) -> str {
    if action == "INVALID" {
        return "destructive";
    }
    if action == "NEW" {
        return "default";
    }
    return "outline";
}

def:pub ImportExportPage() -> JsxPage {
    has plants: list[PlantSummary] = [],
        active_plant: str = "",
        batches: list[ImportBatchView] = [],
        preview_rows: list[ImportRowView] = [],
        batch_id: str = "",
        filename: str = "",
        loading: bool = True,
        previewing: bool = False,
        committing: bool = False,
        exporting: bool = False;

    async def load_plants {
        try {
            result = await manager_plants(0);
            if result.ok {
                plants = result.plants;
                if result.plants and not active_plant {
                    active_plant = result.plants[0].id;
                }
            }
        } except Exception {
            _ = None;
        }
        loading = False;
    }

    async def load_history {
        if not active_plant {
            return;
        }
        try {
            result = await import_history(active_plant);
            if result.ok {
                batches = result.batches;
            }
        } except Exception {
            _ = None;
        }
    }

    async can with entry {
        await load_plants();
    }

    async can with [active_plant] entry {
        await load_history();
    }

    def read_as_base64(file: any, cb: Callable[[str], None]) {
        reader: any = new(FileReader);  # jac:ignore[E1053]
        reader.onload = lambda (ev: any) {
            result: str = reader.result as str;
            parts = result.split(",");
            b64 = parts[1] if len(parts) > 1 else "";
            cb(b64);
        };
        reader.readAsDataURL(file);
    }

    async def handle_file(e: ChangeEvent) {
        target: any = e.target;
        files: any = target.files;
        if not files or int(files.length) == 0 {
            return;
        }
        file: any = files[0];
        filename = file.name as str;
        previewing = True;
        read_as_base64(file, do_preview);
    }

    async def do_preview(b64: str) {
        try {
            result = await preview_import(active_plant, filename, b64);
            if result.ok {
                batch_id = result.batch_id;
                preview_rows = result.rows;
                toast.success("Preview ready - review the rows below before committing.");
            } else {
                toast.error(result.message or "Could not preview this file.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        previewing = False;
    }

    async def do_commit {
        if not batch_id {
            return;
        }
        committing = True;
        try {
            result = await commit_import(batch_id);
            if result.ok {
                toast.success(result.message);
                batch_id = "";
                preview_rows = [];
                await load_history();
            } else {
                toast.error(result.message or "Could not commit this import.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        committing = False;
    }

    def trigger_download(filename_out: str, mime: str, b64: str) {
        a: any = document.createElement("a");
        a.href = "data:" + mime + ";base64," + b64;
        a.download = filename_out;
        a.click();
    }

    async def do_export(fmt: str) {
        if not active_plant {
            return;
        }
        exporting = True;
        try {
            result = await export_inventory(active_plant, fmt);
            if result.ok {
                trigger_download(result.filename, result.mime, result.data_b64);
            } else {
                toast.error(result.message or "Could not export inventory.");
            }
        } except Exception {
            toast.error("Could not reach the server.");
        }
        exporting = False;
    }

    <div className="flex flex-col gap-6">
        <PageHeader title="Import / Export" description="Preview every row before it touches stock; invalid rows never apply.">
            {if len(plants) > 1 {
                <Select value={active_plant} onValueChange={lambda (v: str) { active_plant = v; }}>
                    <SelectTrigger className="w-48"><SelectValue /></SelectTrigger>
                    <SelectContent>
                        {for p in plants {
                            <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
                        }}
                    </SelectContent>
                </Select>
                skip;
            }}
        </PageHeader>

        {if loading {
            <LoadingRows count={3} />
            skip;
        }}

        <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <Card>
                <CardHeader>
                    <CardTitle>Import from CSV / XLSX</CardTitle>
                    <CardDescription>Columns: lot_code, mineral_code, grade_code, stockpile, measured_t, price_per_t, assay:&lt;param&gt;</CardDescription>
                </CardHeader>
                <CardContent className="flex flex-col gap-3">
                    <input type="file" accept=".csv,.xlsx" onChange={handle_file} className="text-sm" />
                    {previewing and <p className="text-sm text-muted-foreground">Parsing and validating…</p> or None}
                    {if preview_rows {
                        <div className="flex flex-col gap-2">
                            <Table>
                                <TableHeader>
                                    <TableRow>
                                        <TableHead>Row</TableHead>
                                        <TableHead>Lot</TableHead>
                                        <TableHead>Action</TableHead>
                                        <TableHead className="text-right">Measured</TableHead>
                                        <TableHead>Errors</TableHead>
                                    </TableRow>
                                </TableHeader>
                                <TableBody>
                                    {for r in preview_rows {
                                        <TableRow key={str(r.row_no)}>
                                            <TableCell>{str(r.row_no)}</TableCell>
                                            <TableCell className="font-medium">{r.lot_code}</TableCell>
                                            <TableCell><Badge variant={row_tone(r.action)}>{r.action}</Badge></TableCell>
                                            <TableCell className="text-right tabular-nums">{r.measured_before} → {r.measured_after}</TableCell>
                                            <TableCell className="text-xs text-destructive">{", ".join(r.errors)}</TableCell>
                                        </TableRow>
                                    }}
                                </TableBody>
                            </Table>
                            <Button disabled={committing} onClick={do_commit}>{committing and "Applying…" or "Commit valid rows"}</Button>
                        </div>
                        skip;
                    }}
                </CardContent>
            </Card>

            <Card>
                <CardHeader>
                    <CardTitle>Export current inventory</CardTitle>
                    <CardDescription>Download a snapshot of this plant's stock lots.</CardDescription>
                </CardHeader>
                <CardFooter className="flex gap-2">
                    <Button variant="outline" disabled={exporting} onClick={lambda { do_export("csv"); }}>Export CSV</Button>
                    <Button variant="outline" disabled={exporting} onClick={lambda { do_export("xlsx"); }}>Export XLSX</Button>
                </CardFooter>
            </Card>
        </div>

        <Card>
            <CardHeader><CardTitle>Import history</CardTitle></CardHeader>
            <CardContent className="p-0">
                {if not batches {
                    <EmptyState title="No imports yet" />
                    skip;
                }}
                <Table>
                    <TableHeader>
                        <TableRow>
                            <TableHead>File</TableHead>
                            <TableHead>When</TableHead>
                            <TableHead>Status</TableHead>
                            <TableHead className="text-right">Applied / Skipped</TableHead>
                        </TableRow>
                    </TableHeader>
                    <TableBody>
                        {for b in batches {
                            <TableRow key={b.id}>
                                <TableCell className="font-medium">{b.filename}</TableCell>
                                <TableCell className="text-muted-foreground">{fmt_datetime(b.at)}</TableCell>
                                <TableCell><Badge variant="outline">{b.status}</Badge></TableCell>
                                <TableCell className="text-right tabular-nums">{str(b.applied)} / {str(b.skipped)}</TableCell>
                            </TableRow>
                        }}
                    </TableBody>
                </Table>
            </CardContent>
        </Card>
    </div>
}
