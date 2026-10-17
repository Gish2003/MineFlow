"""Small shared helpers: clock, identifiers, JSON-safe rendering."""

import time;
import json;
import secrets;
import hashlib;

def now -> float {
    return time.time();
}

def new_ref(prefix: str) -> str {
    return prefix + "-" + secrets.token_hex(3).upper();
}

def new_pin -> str {
    return str(100000 + secrets.randbelow(900000));
}

def sha256_hex(data: bytes) -> str {
    return hashlib.sha256(data).hexdigest();
}

def to_json(value: any) -> str {
    try {
        return json.dumps(value, default=str, sort_keys=True);
    } except Exception {
        return str(value);
    }
}

def clip(text: str, limit: int) -> str {
    return text if len(text) <= limit else text[:limit - 1] + "…";
}

def r2(x: float) -> float {
    return round(x, 2);
}

def hours(n: float) -> float {
    return n * 3600.0;
}

def minutes(n: float) -> float {
    return n * 60.0;
}

def fmt_time(ts: float) -> str {
    if ts <= 0.0 {
        return "-";
    }
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts));
}

def clean_text(text: str, limit: int = 2000) -> str {
    return text.strip()[:limit];
}
