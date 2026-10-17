"""Runtime configuration read from environment variables.

`jac run` does not load `.env` on its own, so the first call to `settings()`
loads `./.env` (if present) without overriding variables already exported.
"""

import os;

glob _env_loaded: bool = False;

obj Settings {
    has demo_mode: bool,
        demo_password: str,
        agent_mode: str,
        llm_model: str,
        currency: str,
        haulage_rate_per_tkm: float,
        driver_base_pay: float,
        driver_rate_per_km: float,
        live_seconds: int,
        weak_seconds: int,
        bootstrap_admin_code: str,
        max_upload_bytes: int,
        tz_offset_hours: float,
        max_load_t: float;
}

def load_local_env(path: str = ".env") {
    if not os.path.exists(path) {
        return;
    }
    with open(path, encoding="utf-8") as fh {
        for raw in fh {
            line = raw.strip();
            if not line or line.startswith("#") or "=" not in line {
                continue;
            }
            parts = line.split("=", 1);
            key = parts[0].strip();
            value = parts[1].strip().strip('"').strip("'");
            if key and key not in os.environ {
                os.environ[key] = value;
            }
        }
    }
}

def _ensure_env {
    if not _env_loaded {
        _env_loaded = True;
        load_local_env(os.path.join(os.getcwd(), ".env"));
    }
}

def env_str(key: str, fallback: str) -> str {
    _ensure_env();
    value = os.environ.get(key, "");
    return value if value else fallback;
}

def env_flag(key: str, fallback: bool) -> bool {
    raw = env_str(key, "true" if fallback else "false").lower();
    return raw in ["1", "true", "yes", "on"];
}

def env_float(key: str, fallback: float) -> float {
    try {
        return float(env_str(key, str(fallback)));
    } except ValueError {
        return fallback;
    }
}

def env_int(key: str, fallback: int) -> int {
    try {
        return int(env_str(key, str(fallback)));
    } except ValueError {
        return fallback;
    }
}

def settings -> Settings {
    return Settings(
        demo_mode=env_flag("MINEFLOW_DEMO_MODE", True),
        demo_password=env_str("MINEFLOW_DEMO_PASSWORD", "MineFlow#Demo2026"),
        agent_mode=env_str("MINEFLOW_AGENT_MODE", "auto").lower(),
        llm_model=env_str("MINEFLOW_LLM_MODEL", "anthropic/claude-sonnet-5"),
        currency=env_str("MINEFLOW_CURRENCY", "LKR"),
        haulage_rate_per_tkm=env_float("MINEFLOW_HAULAGE_RATE_PER_TKM", 48.0),
        driver_base_pay=env_float("MINEFLOW_DRIVER_BASE_PAY", 4500.0),
        driver_rate_per_km=env_float("MINEFLOW_DRIVER_RATE_PER_KM", 95.0),
        live_seconds=env_int("MINEFLOW_LIVE_SECONDS", 45),
        weak_seconds=env_int("MINEFLOW_WEAK_SECONDS", 180),
        bootstrap_admin_code=env_str("MINEFLOW_BOOTSTRAP_ADMIN_CODE", ""),
        max_upload_bytes=env_int("MINEFLOW_MAX_UPLOAD_BYTES", 3000000),
        tz_offset_hours=env_float("MINEFLOW_TZ_OFFSET_HOURS", 5.5),
        max_load_t=env_float("MINEFLOW_MAX_LOAD_T", 40.0)
    );
}

"""True only when the configured model's provider credential is present.

Local/self-hosted models (ollama/*, local:*) need an explicit
MINEFLOW_AGENT_MODE=llm so the app never starts a multi-GB download by surprise.
"""
def llm_available -> bool {
    cfg = settings();
    if cfg.agent_mode == "fallback" {
        return False;
    }
    model = cfg.llm_model.lower();
    if model.startswith("anthropic/") or model.startswith("claude") {
        return bool(env_str("ANTHROPIC_API_KEY", ""));
    }
    if model.startswith("openai/") or model.startswith("gpt") or model.startswith("o1") or model.startswith("o3") {
        return bool(env_str("OPENAI_API_KEY", ""));
    }
    if model.startswith("gemini/") {
        return bool(env_str("GEMINI_API_KEY", "") or env_str("GOOGLE_API_KEY", ""));
    }
    if model.startswith("ollama/") or model.startswith("local:") {
        return cfg.agent_mode == "llm";
    }
    return False;
}

def agent_label -> str {
    if llm_available() {
        return "AI agent · " + settings().llm_model;
    }
    if settings().agent_mode == "fallback" {
        return "Deterministic fallback (agent disabled by MINEFLOW_AGENT_MODE)";
    }
    return "Deterministic fallback (no LLM credentials configured)";
}
