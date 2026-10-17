"""Client-safe display formatting. No server import (core.util pulls in Python
stdlib time/json/secrets that cannot run in the browser) - this module builds
dates purely from the JS `Date` object so it can be bundled into client pages.
"""

glob MONTHS: list[str] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

def pad2(n: int) -> str {
    return str(n) if n >= 10 else "0" + str(n);
}

def fmt_date(ts: float) -> str {
    if ts <= 0.0 {
        return "-";
    }
    d: any = new(Date, ts * 1000.0);
    return str(int(d.getDate())) + " " + MONTHS[int(d.getMonth())] + " " + str(int(d.getFullYear()));
}

def fmt_clock(ts: float) -> str {
    if ts <= 0.0 {
        return "-";
    }
    d: any = new(Date, ts * 1000.0);
    hh = int(d.getHours());
    mm = int(d.getMinutes());
    hh_s = str(hh) if hh >= 10 else "0" + str(hh);
    mm_s = str(mm) if mm >= 10 else "0" + str(mm);
    return hh_s + ":" + mm_s;
}

def fmt_datetime(ts: float) -> str {
    if ts <= 0.0 {
        return "-";
    }
    d: any = new(Date, ts * 1000.0);  # jac:ignore[E1053]
    date_part = str(int(d.getDate())) + " " + MONTHS[int(d.getMonth())] + " " + str(int(d.getFullYear()));
    hh = int(d.getHours());
    mm = int(d.getMinutes());
    hh_s = str(hh) if hh >= 10 else "0" + str(hh);
    mm_s = str(mm) if mm >= 10 else "0" + str(mm);
    return date_part + " · " + hh_s + ":" + mm_s;
}

def now_seconds() -> float {
    d: any = new(Date);
    return float(d.getTime()) / 1000.0;
}

def fmt_ago(ts: float) -> str {
    if ts <= 0.0 {
        return "never";
    }
    now_d: any = new(Date);  # jac:ignore[E1053]
    diff = (float(now_d.getTime()) / 1000.0) - ts;
    if diff < 0.0 {
        diff = 0.0;
    }
    if diff < 60.0 {
        return "just now";
    }
    if diff < 3600.0 {
        return str(int(diff / 60.0)) + " min ago";
    }
    if diff < 86400.0 {
        return str(int(diff / 3600.0)) + " h ago";
    }
    return str(int(diff / 86400.0)) + " d ago";
}

def fmt_t(x: float) -> str {
    return f"{x:.1f} t";
}

def fmt_km(x: float) -> str {
    return f"{x:.1f} km";
}

def fmt_pct(x: float) -> str {
    return f"{x:.0f}%";
}

def fmt_int_commas(n: int) -> str {
    neg = n < 0;
    s = str(-n if neg else n);
    out = "";
    count = 0;
    for i in range(len(s) - 1, -1, -1) {
        out = s[i] + out;
        count += 1;
        if count % 3 == 0 and i != 0 {
            out = "," + out;
        }
    }
    return ("-" + out) if neg else out;
}

def fmt_money(amount: float, currency: str) -> str {
    n = int(round(amount));
    neg = n < 0;
    s = str(-n if neg else n);
    out = "";
    count = 0;
    for i in range(len(s) - 1, -1, -1) {
        out = s[i] + out;
        count += 1;
        if count % 3 == 0 and i != 0 {
            out = "," + out;
        }
    }
    return currency + " " + (("-" + out) if neg else out);
}

def fmt_minutes(mins: float) -> str {
    m = int(round(mins));
    if m < 60 {
        return str(m) + " min";
    }
    h = m // 60;
    rem = m % 60;
    return (str(h) + "h " + str(rem) + "m") if rem > 0 else (str(h) + "h");
}
