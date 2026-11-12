"""Secrets are read exclusively from ai_server/.env, never the Flutter asset."""
from dataclasses import dataclass, field
from pathlib import Path
from dotenv import dotenv_values

SERVER_DIR = Path(__file__).resolve().parent

# OpenAI Responses API pricing (USD per 1M tokens: input, output).
OPENAI_MODEL_PRICES: dict[str, tuple[float, float]] = {
    "gpt-4.1-mini": (0.40, 1.60),
    "gpt-4.1-mini-2025-04-14": (0.40, 1.60),
}

# Gemini Developer API standard paid-tier pricing (USD per 1M tokens: text/image input, output incl. thinking).
# Source: https://aistudio.google.com/docs/pricing (read 2026-11-12). The 2.5 models are closed to new keys.
DEFAULT_GEMINI_MODEL = "gemini-3.5-flash-lite"
GEMINI_MODEL_PRICES: dict[str, tuple[float, float]] = {
    "gemini-3.5-flash-lite": (0.30, 2.50),
}


@dataclass(frozen=True)
class AssistantSettings:
    api_key: str = field(default="", repr=False)
    signing_secret: str = field(default="", repr=False)
    pairing_code: str = field(default="", repr=False)
    provider: str = "openai"
    model: str = "gpt-4.1-mini"
    input_usd_per_1m: float = 0.40
    output_usd_per_1m: float = 1.60
    daily_usd: float = 1.0
    device_daily_usd: float = 0.5
    rpm: int = 6
    proactive_seconds: int = 120
    timeout_seconds: float = 25
    max_output_tokens: int = 500
    max_rounds: int = 3
    max_input_bytes: int = 24000
    reserve_usd: float = 0.05
    allow_insecure_lan: bool = False
    state_path: Path = SERVER_DIR / ".assistant-state" / "limits.sqlite3"

    @property
    def enabled(self):
        return bool(self.api_key and len(self.signing_secret) >= 32 and len(self.pairing_code) >= 12)

    @classmethod
    def load(cls):
        try:
            values = dotenv_values(SERVER_DIR / ".env", interpolate=False)
        except (OSError, UnicodeError):
            return cls()
        raw_provider = (values.get("ASSISTANT_PROVIDER") or "").strip().lower()
        openai_key = (values.get("OPENAI_API_KEY") or "").strip()
        gemini_key = (values.get("GEMINI_API_KEY") or "").strip()
        if raw_provider:
            if raw_provider not in {"openai", "gemini"}:
                return cls()  # Fail closed on unknown provider without breaking navigation startup.
            provider = raw_provider
        elif openai_key:
            provider = "openai"
        elif gemini_key:
            provider = "gemini"
        else:
            provider = "openai"
        # Pricing bounds below are calibrated for these allowlists, not arbitrary models.
        if provider == "gemini":
            api_key = gemini_key
            model = (values.get("GEMINI_ASSISTANT_MODEL") or "").strip() or DEFAULT_GEMINI_MODEL
            if model not in GEMINI_MODEL_PRICES:
                return cls()
            input_price, output_price = GEMINI_MODEL_PRICES[model]
        else:
            api_key = openai_key
            model = (values.get("OPENAI_ASSISTANT_MODEL") or "").strip() or "gpt-4.1-mini"
            if model not in OPENAI_MODEL_PRICES:
                return cls()  # Fail closed without breaking navigation startup.
            input_price, output_price = OPENAI_MODEL_PRICES[model]
        try:
            daily = min(100, max(0.01, float(values.get("ASSISTANT_DAILY_USD") or 1)))
            device_daily = min(daily, max(.01, float(values.get("ASSISTANT_DEVICE_DAILY_USD") or .5)))
            rpm = min(30, max(1, int(values.get("ASSISTANT_RPM") or 6)))
            return cls(api_key=api_key,
                signing_secret=values.get("ASSISTANT_SIGNING_SECRET") or "",
                pairing_code=values.get("ASSISTANT_PAIRING_CODE") or "",
                provider=provider, model=model,
                input_usd_per_1m=input_price, output_usd_per_1m=output_price,
                daily_usd=daily, device_daily_usd=device_daily, rpm=rpm,
                allow_insecure_lan=values.get('ASSISTANT_ALLOW_INSECURE_LAN') == '1')
        except (ValueError, TypeError):
            return cls()
