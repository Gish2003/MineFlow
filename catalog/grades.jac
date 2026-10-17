"""Mineral grade specifications and lot compatibility.

Grade integrity rule: a line is only ever fulfilled from a single lot of the
same mineral *and* grade code whose assay satisfies every (possibly tightened)
spec parameter. Blends are not modelled, so they are never proposed.
"""

import from core.model { SpecParam, StockLot, GradeSpec, OrderLine }
import from core.enums { LotQuality }
import from core.hub { grade_by_code }

obj ParamCheck {
    has key: str,
        label: str,
        requirement: str,
        actual: float | None,
        ok: bool,
        unit: str = "%";
}

obj GradeCheck {
    has lot_id: str,
        lot_code: str,
        mineral_code: str,
        lot_grade: str,
        requested_grade: str,
        compatible: bool,
        quality: str,
        checks: list[ParamCheck] = [],
        reasons: list[str] = [];
}

def describe_param(p: SpecParam) -> str {
    if p.min_value is not None and p.max_value is not None {
        return f"{p.min_value}–{p.max_value}{p.unit}";
    }
    if p.min_value is not None {
        return f">= {p.min_value}{p.unit}";
    }
    if p.max_value is not None {
        return f"<= {p.max_value}{p.unit}";
    }
    return "any";
}

def param_ok(p: SpecParam, actual: float | None) -> bool {
    if actual is None {
        return False;
    }
    if p.min_value is not None and actual < p.min_value {
        return False;
    }
    if p.max_value is not None and actual > p.max_value {
        return False;
    }
    return True;
}

"""Merge buyer tightening into the catalog spec; loosening is rejected."""
def resolve_spec(grade: GradeSpec, overrides: list[SpecParam]) -> list[SpecParam] {
    out: list[SpecParam] = [];
    for base in grade.params {
        merged = SpecParam(key=base.key, label=base.label, min_value=base.min_value, max_value=base.max_value, unit=base.unit);
        for ov in overrides {
            if ov.key == base.key {
                if ov.min_value is not None and (base.min_value is None or ov.min_value >= base.min_value) {
                    merged.min_value = ov.min_value;
                }
                if ov.max_value is not None and (base.max_value is None or ov.max_value <= base.max_value) {
                    merged.max_value = ov.max_value;
                }
            }
        }
        out.append(merged);
    }
    return out;
}

def spec_problems(grade: GradeSpec, overrides: list[SpecParam]) -> list[str] {
    problems: list[str] = [];
    keys = [p.key for p in grade.params];
    for ov in overrides {
        if ov.key not in keys {
            problems.append("Unknown spec parameter '" + ov.key + "' for grade " + grade.code + ".");
            continue;
        }
        for base in grade.params {
            if base.key == ov.key {
                if ov.min_value is not None and base.min_value is not None and ov.min_value < base.min_value {
                    problems.append(base.label + " minimum cannot be below the grade minimum.");
                }
                if ov.max_value is not None and base.max_value is not None and ov.max_value > base.max_value {
                    problems.append(base.label + " maximum cannot exceed the grade maximum.");
                }
                if ov.min_value is not None and ov.max_value is not None and ov.min_value > ov.max_value {
                    problems.append(base.label + " minimum is above its maximum.");
                }
            }
        }
    }
    return problems;
}

def check_lot(lot: StockLot, mineral_code: str, grade_code: str, spec: list[SpecParam]) -> GradeCheck {
    reasons: list[str] = [];
    checks: list[ParamCheck] = [];
    if lot.mineral_code != mineral_code {
        reasons.append("Lot holds " + lot.mineral_code + ", not " + mineral_code + ".");
    }
    if lot.grade_code != grade_code {
        reasons.append("Lot grade " + lot.grade_code + " differs from requested " + grade_code + " (no blending or substitution).");
    }
    if lot.quality == LotQuality.QUALITY_HOLD {
        reasons.append("Lot is on quality hold.");
    }
    for p in spec {
        actual: float | None = None;
        if p.key in lot.assay {
            actual = float(lot.assay[p.key]);
        }
        passed = param_ok(p, actual);
        checks.append(ParamCheck(key=p.key, label=p.label, requirement=describe_param(p), actual=actual, ok=passed, unit=p.unit));
        if not passed {
            shown = "missing" if actual is None else str(actual) + p.unit;
            reasons.append(p.label + " " + shown + " does not meet " + describe_param(p) + ".");
        }
    }
    return GradeCheck(
        lot_id=jid(lot),
        lot_code=lot.code,
        mineral_code=lot.mineral_code,
        lot_grade=lot.grade_code,
        requested_grade=grade_code,
        compatible=len(reasons) == 0,
        quality=str(lot.quality),
        checks=checks,
        reasons=reasons
    );
}

def check_lot_for_line(lot: StockLot, line: OrderLine) -> GradeCheck {
    return check_lot(lot, line.mineral_code, line.grade_code, line.spec);
}
