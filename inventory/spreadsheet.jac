"""Inventory spreadsheet import (CSV/XLSX) and export.

Import is two-step and auditable: `preview_import` parses and validates every
row (nothing is written to stock), storing an ImportBatch with per-row results;
`commit_import` re-validates against current state and applies only rows that
are still valid. Invalid rows never touch inventory. Columns:

    lot_code, mineral_code, grade_code, stockpile, measured_t, price_per_t,
    assay:<KEY> (one column per grade parameter, e.g. assay:CaCO3)
"""

import io;
import csv;
import json;
import base64;
import binascii;
import from openpyxl { load_workbook, Workbook }
import from core.model { Plant, StockLot, HoldsLot, ImportBatch, HasImportBatch }
import from core.enums { Role }
import from core.hub { get_plant, lots_of, fetch }
import from core.access { AppError, Caller, require_roles, require_plant_manager, manages_plant, not_found, invalid, bad_state }
import from core.audit { audit, notify_dispatchers }
import from core.views { ActionResult, FileDownload }
import from core.util { now, sha256_hex, clean_text, fmt_time }
import from inventory.availability { availability }
import from inventory.store { lot_write_problems }

glob REQUIRED_COLS: list[str] = ["lot_code", "mineral_code", "grade_code", "stockpile", "measured_t", "price_per_t"];
glob MAX_ROWS: int = 500;

obj ImportRowView {
    has row_no: int,
        lot_code: str,
        action: str,
        measured_before: float,
        measured_after: float,
        errors: list[str] = [],
        warnings: list[str] = [];
}

obj ImportPreview {
    has ok: bool,
        code: str = "",
        message: str = "",
        batch_id: str = "",
        filename: str = "",
        rows: list[ImportRowView] = [],
        counts: dict[str, int] = {};
}

obj ImportBatchView {
    has id: str,
        filename: str,
        at: float,
        status: str,
        total_rows: int,
        applied: int,
        skipped: int,
        errors: list[str];
}

obj ImportHistory {
    has ok: bool,
        code: str = "",
        message: str = "",
        batches: list[ImportBatchView] = [];
}

def read_rows(filename: str, data: bytes) -> list[dict[str, str]] {
    name = filename.lower();
    if name.endswith(".xlsx") {
        wb = load_workbook(io.BytesIO(data), read_only=True, data_only=True);
        ws = wb.worksheets[0];
        rows: list[dict[str, str]] = [];
        header: list[str] = [];
        for (i, values) in enumerate(ws.iter_rows(values_only=True)) {
            cells = ["" if v is None else str(v).strip() for v in values];
            if i == 0 {
                header = [h.strip() for h in cells];
                continue;
            }
            if not any(cells) {
                continue;
            }
            rows.append({header[j]: cells[j] for j in range(min(len(header), len(cells)))});
        }
        return rows;
    }
    text = data.decode("utf-8-sig");
    return [{(k or "").strip(): (v or "").strip() for (k, v) in r.items()} for r in csv.DictReader(io.StringIO(text))];
}

obj ParsedRow {
    has row_no: int,
        lot_code: str,
        mineral_code: str,
        grade_code: str,
        stockpile: str,
        measured_t: float,
        price_per_t: float,
        assay: dict[str, float];
}

def parse_row(i: int, raw: dict[str, str], errors: list[str]) -> ParsedRow | None {
    try {
        measured = float(raw.get("measured_t", ""));
        price = float(raw.get("price_per_t", "") or "0");
    } except ValueError {
        errors.append("measured_t / price_per_t must be numbers.");
        return None;
    }
    assay: dict[str, float] = {};
    for (k, v) in raw.items() {
        if k.startswith("assay:") and v != "" {
            try {
                assay[k[6:].strip()] = float(v);
            } except ValueError {
                errors.append("Assay " + k[6:] + " must be a number.");
            }
        }
    }
    return ParsedRow(
        row_no=i, lot_code=raw.get("lot_code", "").upper(), mineral_code=raw.get("mineral_code", "").upper(),
        grade_code=raw.get("grade_code", "").upper(), stockpile=raw.get("stockpile", ""), measured_t=measured,
        price_per_t=price, assay=assay
    );
}

def validate_rows(p: Plant, raws: list[dict[str, str]]) -> tuple[list[ImportRowView], list[ParsedRow]] {
    existing = {l.code: l for l in lots_of(p)};
    views: list[ImportRowView] = [];
    good: list[ParsedRow] = [];
    seen: list[str] = [];
    for (i, raw) in enumerate(raws) {
        n = i + 2;
        errors: list[str] = [];
        warnings: list[str] = [];
        missing = [c for c in REQUIRED_COLS if c not in raw];
        if missing {
            errors.append("Missing columns: " + ", ".join(missing));
            views.append(ImportRowView(row_no=n, lot_code=raw.get("lot_code", ""), action="INVALID", measured_before=0.0, measured_after=0.0, errors=errors));
            continue;
        }
        row = parse_row(n, raw, errors);
        if row is None {
            views.append(ImportRowView(row_no=n, lot_code=raw.get("lot_code", ""), action="INVALID", measured_before=0.0, measured_after=0.0, errors=errors));
            continue;
        }
        if row.lot_code in seen {
            errors.append("Duplicate lot code in the file.");
        }
        seen.append(row.lot_code);
        lot = existing.get(row.lot_code);
        errors = errors + lot_write_problems(p, lot, row.lot_code, row.mineral_code, row.grade_code, row.measured_t, row.price_per_t, row.assay);
        action = "NEW" if lot is None else "UPDATE";
        before = lot.measured_t if lot is not None else 0.0;
        if lot is not None and abs(lot.measured_t - row.measured_t) < 1e-9 and lot.assay == row.assay and lot.price_per_t == row.price_per_t and lot.stockpile == row.stockpile {
            action = "UNCHANGED";
        }
        if lot is not None and row.measured_t < before * 0.5 {
            warnings.append("Measured stock drops by more than half.");
        }
        if lot is None {
            warnings.append("New lots start as PENDING until a quality record verifies them.");
        }
        if errors {
            action = "INVALID";
        } else {
            good.append(row);
        }
        views.append(ImportRowView(row_no=n, lot_code=row.lot_code, action=action, measured_before=before, measured_after=row.measured_t, errors=errors, warnings=warnings));
    }
    return (views, good);
}

def _counts(rows: list[ImportRowView]) -> dict[str, int] {
    out: dict[str, int] = {"NEW": 0, "UPDATE": 0, "UNCHANGED": 0, "INVALID": 0};
    for r in rows {
        out[r.action] = out.get(r.action, 0) + 1;
    }
    return out;
}

def:protect preview_import(plant_id: str, filename: str, data_b64: str) -> ImportPreview {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        require_plant_manager(c, plant_id);
        p = get_plant(plant_id);
        if p is None {
            raise not_found("Plant");
        }
        name = clean_text(filename, 120);
        if not (name.lower().endswith(".csv") or name.lower().endswith(".xlsx")) {
            raise invalid("Upload a .csv or .xlsx file.");
        }
        raw = data_b64.split(",", 1)[1] if data_b64.startswith("data:") else data_b64;
        try {
            data = base64.b64decode(raw, validate=True);
        } except (binascii.Error, ValueError) {
            raise invalid("The file could not be decoded.");
        }
        if len(data) > 2000000 {
            raise invalid("Spreadsheet is larger than 2 MB.");
        }
        try {
            raws = read_rows(name, data);
        } except Exception as e {
            raise invalid("Could not read the spreadsheet: " + str(e)[:160]);
        }
        if not raws {
            raise invalid("The spreadsheet has no data rows.");
        }
        if len(raws) > MAX_ROWS {
            raise invalid("At most " + str(MAX_ROWS) + " rows per import.");
        }
        (views, good) = validate_rows(p, raws);
        batch = ImportBatch(
            plant_id=plant_id, filename=name, sha256=sha256_hex(data), uploaded_by=c.account_id, at=now(),
            total_rows=len(views), errors=["Row " + str(v.row_no) + ": " + "; ".join(v.errors) for v in views if v.errors][:100],
            payload_json=json.dumps([r.__dict__ for r in good])
        );
        p +>:HasImportBatch():+> batch;
        audit(c, "IMPORT_PREVIEWED", "ImportBatch", jid(batch), name + ": " + str(len(views)) + " rows, " + str(len(good)) + " valid", "", [plant_id]);
        return ImportPreview(ok=True, batch_id=jid(batch), filename=name, rows=views, counts=_counts(views));
    } except AppError as e {
        return ImportPreview(ok=False, code=e.code, message=e.message);
    }
}

def:protect commit_import(batch_id: str) -> ActionResult {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        n = fetch(batch_id, ImportBatch);
        batch = None if n is None else n as ImportBatch;
        if batch is None or not manages_plant(c, batch.plant_id) {
            raise not_found("Import");
        }
        if batch.status != "PREVIEWED" {
            raise bad_state("This import was already " + batch.status.lower() + ".");
        }
        p = get_plant(batch.plant_id);
        if p is None {
            raise not_found("Plant");
        }
        rows = [ParsedRow(**r) for r in json.loads(batch.payload_json or "[]")];
        existing = {l.code: l for l in lots_of(p)};
        applied = 0;
        skipped: list[str] = [];
        t = now();
        for r in rows {
            lot = existing.get(r.lot_code);
            problems = lot_write_problems(p, lot, r.lot_code, r.mineral_code, r.grade_code, r.measured_t, r.price_per_t, r.assay);
            if problems {
                skipped.append("Row " + str(r.row_no) + " (" + r.lot_code + "): stock changed since preview - " + "; ".join(problems));
                continue;
            }
            if lot is None {
                p +>:HoldsLot():+> StockLot(code=r.lot_code, plant_id=batch.plant_id, mineral_code=r.mineral_code, grade_code=r.grade_code, stockpile=r.stockpile, measured_t=r.measured_t, assay=r.assay, price_per_t=r.price_per_t, updated_at=t, notes="Imported from " + batch.filename);
            } else {
                lot.stockpile = r.stockpile;
                lot.measured_t = r.measured_t;
                lot.assay = r.assay;
                lot.price_per_t = r.price_per_t;
                lot.updated_at = t;
            }
            applied += 1;
        }
        batch.applied = applied;
        batch.skipped = batch.total_rows - applied;
        batch.errors = batch.errors + skipped;
        batch.status = "COMMITTED";
        notify_dispatchers(batch.plant_id, "info", "Inventory imported at " + p.name, str(applied) + " lot(s) updated from " + batch.filename);
        audit(c, "IMPORT_COMMITTED", "ImportBatch", batch_id, batch.filename + ": applied " + str(applied) + ", skipped " + str(batch.skipped), "", [batch.plant_id]);
        return ActionResult(ok=True, id=batch_id, message="Applied " + str(applied) + " row(s); skipped " + str(batch.skipped) + ".");
    } except AppError as e {
        return ActionResult(ok=False, code=e.code, message=e.message);
    }
}

def:protect import_history(plant_id: str) -> ImportHistory {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        require_plant_manager(c, plant_id);
        p = get_plant(plant_id);
        if p is None {
            raise not_found("Plant");
        }
        rows = sorted([p ->:HasImportBatch:-> [?:ImportBatch]], key=lambda (b: ImportBatch) { -b.at; });
        return ImportHistory(ok=True, batches=[ImportBatchView(id=jid(b), filename=b.filename, at=b.at, status=b.status, total_rows=b.total_rows, applied=b.applied, skipped=b.skipped, errors=b.errors[:20]) for b in rows[:20]]);
    } except AppError as e {
        return ImportHistory(ok=False, code=e.code, message=e.message);
    }
}

glob EXPORT_COLS: list[str] = ["lot_code", "mineral_code", "grade_code", "stockpile", "quality", "measured_t", "reserved_t", "quality_held_t", "available_t", "price_per_t"];

def:protect export_inventory(plant_id: str, fmt: str = "csv") -> FileDownload {
    try {
        c = require_roles([Role.STORE_MANAGER]);
        require_plant_manager(c, plant_id);
        p = get_plant(plant_id);
        if p is None {
            raise not_found("Plant");
        }
        rows = [availability(l) for l in sorted(lots_of(p), key=lambda (x: StockLot) { x.code; })];
        keys: list[str] = [];
        for r in rows {
            for k in r.assay.keys() {
                if k not in keys {
                    keys.append(k);
                }
            }
        }
        header = EXPORT_COLS + ["assay:" + k for k in keys];
        table: list[list[any]] = [];
        for r in rows {
            table.append([r.lot_code, r.mineral_code, r.grade_code, r.stockpile, r.quality, r.measured_t, r.reserved_t, r.quality_held_t, r.available_t, r.price_per_t] + [r.assay.get(k, "") for k in keys]);
        }
        stamp = fmt_time(now()).replace(" ", "_").replace(":", "");
        if fmt == "xlsx" {
            wb = Workbook();
            ws = wb.active;
            ws.title = p.code + " inventory";
            ws.append(header);
            for row in table {
                ws.append(row);
            }
            buf = io.BytesIO();
            wb.save(buf);
            data = buf.getvalue();
            mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            name = p.code + "-inventory-" + stamp + ".xlsx";
        } else {
            sio = io.StringIO();
            w = csv.writer(sio);
            w.writerow(header);
            for row in table {
                w.writerow(row);
            }
            data = sio.getvalue().encode("utf-8");
            mime = "text/csv";
            name = p.code + "-inventory-" + stamp + ".csv";
        }
        audit(c, "INVENTORY_EXPORTED", "Plant", plant_id, name, "", [plant_id]);
        return FileDownload(ok=True, filename=name, mime=mime, data_b64=base64.b64encode(data).decode("ascii"));
    } except AppError as e {
        return FileDownload(ok=False, code=e.code, message=e.message);
    }
}
