"""Secrets are read exclusively from ai_server/.env, never the Flutter asset."""
from dataclasses import dataclass, field
from pathlib import Path
from dotenv import dotenv_values

SERVER_DIR = Path(__file__).resolve().parent


@dataclass(frozen=True)
class AssistantSettings:
    api_key: str = field(default="", repr=False)
    signing_secret: str = field(default="", repr=False)
    pairing_code: str = field(default="", repr=False)
    model: str = "gpt-4.1-mini"
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
        # Pricing bounds below are calibrated for this allowlist, not arbitrary models.
        model = values.get("OPENAI_ASSISTANT_MODEL") or "gpt-4.1-mini"
        if model not in {"gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"}:
            return cls()  # Fail closed without breaking navigation startup.
        try:
            daily = min(100, max(0.01, float(values.get("ASSISTANT_DAILY_USD") or 1)))
            device_daily = min(daily, max(.01, float(values.get("ASSISTANT_DEVICE_DAILY_USD") or .5)))
            rpm = min(30, max(1, int(values.get("ASSISTANT_RPM") or 6)))
            return cls(api_key=values.get("OPENAI_API_KEY") or "",
                signing_secret=values.get("ASSISTANT_SIGNING_SECRET") or "",
                pairing_code=values.get("ASSISTANT_PAIRING_CODE") or "", model=model,
                daily_usd=daily, device_daily_usd=device_daily, rpm=rpm,
                allow_insecure_lan=values.get('ASSISTANT_ALLOW_INSECURE_LAN') == '1')
        except (ValueError, TypeError):
            return cls()
