"""Authenticated device sessions and persistent, atomic rate/spend limits."""
import base64
import hashlib
import hmac
import json
import secrets
import sqlite3
import time
from datetime import datetime, timezone
from contextlib import contextmanager
from assistant_config import AssistantSettings


class AssistantError(Exception):
    def __init__(self, status: int, code: str, message: str):
        self.status, self.code, self.message = status, code, message
        super().__init__(message)


class AssistantGuard:
    def __init__(self, settings: AssistantSettings, clock=time.time):
        self.settings, self.clock = settings, clock
        self._ready = False

    @contextmanager
    def db(self):
        self.settings.state_path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.settings.state_path, timeout=5)
        try:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS clients (id TEXT PRIMARY KEY, nonce TEXT, expires REAL);
                CREATE TABLE IF NOT EXISTS events (actor TEXT, kind TEXT, at REAL);
                CREATE TABLE IF NOT EXISTS turns (id TEXT PRIMARY KEY, client TEXT, day TEXT,
                    cost REAL, status TEXT, at REAL, event TEXT);
                CREATE INDEX IF NOT EXISTS event_lookup ON events(actor,kind,at);
                CREATE INDEX IF NOT EXISTS turn_day ON turns(day,client);
            """)
            db.execute("BEGIN IMMEDIATE")
            yield db
            db.commit()
        except Exception:
            db.rollback()
            raise
        finally:
            db.close()

    def require_enabled(self):
        if not self.settings.enabled:
            raise AssistantError(503, "disabled", "Trợ lý chưa được cấu hình ở backend.")

    def rate(self, actor: str, kind: str, limit: int):
        now = self.clock()
        # Commit failed attempts too; otherwise invalid pairing is unlimited.
        with self.db() as db:
            count = db.execute("SELECT count(*) FROM events WHERE actor=? AND kind=? AND at>?",
                               (actor, kind, now - 60)).fetchone()[0]
            global_count = db.execute("SELECT count(*) FROM events WHERE kind=? AND at>?",
                                      (kind, now - 60)).fetchone()[0]
            allowed = count < limit and global_count < limit * 4
            if allowed:
                db.execute("INSERT INTO events VALUES (?,?,?)", (actor, kind, now))
            db.execute("DELETE FROM events WHERE at<?", (now - 300,))
        if not allowed:
            raise AssistantError(429, "rate_limit", "Đã đạt giới hạn tần suất. Hãy chờ rồi thử lại.")

    @staticmethod
    def _encode(data: bytes):
        return base64.urlsafe_b64encode(data).decode().rstrip("=")

    def pair(self, code: str, device_id: str, remote: str):
        self.require_enabled()
        self.rate(remote, "pair", 5)
        if not hmac.compare_digest(code.encode(), self.settings.pairing_code.encode()):
            raise AssistantError(401, "invalid_pairing", "Mã ghép nối không đúng.")
        client = hmac.new(self.settings.signing_secret.encode(), device_id.encode(), hashlib.sha256).hexdigest()
        nonce, expires = secrets.token_hex(16), int(self.clock() + 86400)
        payload = self._encode(json.dumps({"sub": client, "nonce": nonce, "exp": expires}, separators=(",", ":")).encode())
        signature = self._encode(hmac.new(self.settings.signing_secret.encode(), payload.encode(), hashlib.sha256).digest())
        with self.db() as db:
            db.execute("INSERT OR REPLACE INTO clients VALUES (?,?,?)", (client, nonce, expires))
        return {"access_token": payload + "." + signature, "expires_at": expires}

    def authenticate(self, authorization: str | None):
        self.require_enabled()
        try:
            if not authorization or not authorization.startswith("Bearer ") or len(authorization) > 1200:
                raise ValueError()
            payload, signature = authorization[7:].split(".")
            expected = self._encode(hmac.new(self.settings.signing_secret.encode(), payload.encode(), hashlib.sha256).digest())
            if not hmac.compare_digest(signature, expected): raise ValueError()
            claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
            if claims["exp"] <= self.clock(): raise ValueError()
            with self.db() as db:
                row = db.execute("SELECT nonce,expires FROM clients WHERE id=?", (claims["sub"],)).fetchone()
            if row != (claims["nonce"], claims["exp"]): raise ValueError()
            return claims["sub"]
        except (ValueError, KeyError, TypeError, UnicodeError):
            raise AssistantError(401, "unauthorized", "Hãy ghép nối lại trợ lý trên thiết bị.") from None

    def revoke(self, client: str):
        with self.db() as db: db.execute("DELETE FROM clients WHERE id=?", (client,))

    def reserve(self, client: str, request_id: str, mode: str, event: str | None):
        now = self.clock()
        day = datetime.fromtimestamp(now, timezone.utc).date().isoformat()
        turn_id = client + ":" + request_id
        self.rate(client, "chat", self.settings.rpm)
        with self.db() as db:
            if db.execute("SELECT 1 FROM turns WHERE id=?", (turn_id,)).fetchone():
                raise AssistantError(409, "duplicate_request", "Yêu cầu này đã được xử lý; không tự gửi lại.")
            if db.execute("SELECT 1 FROM turns WHERE client=? AND status='pending' AND at>?", (client, now - 60)).fetchone():
                raise AssistantError(409, "in_progress", "Trợ lý đang xử lý yêu cầu trước.")
            if mode == "proactive" and db.execute("SELECT 1 FROM turns WHERE client=? AND event IS NOT NULL AND at>?",
                                                (client, now - self.settings.proactive_seconds)).fetchone():
                raise AssistantError(429, "proactive_cooldown", "Chưa tới thời điểm thông báo chủ động tiếp theo.")
            spent = db.execute("SELECT coalesce(sum(cost),0) FROM turns WHERE day=?", (day,)).fetchone()[0]
            device_spent = db.execute("SELECT coalesce(sum(cost),0) FROM turns WHERE day=? AND client=?", (day, client)).fetchone()[0]
            reserve = self.settings.reserve_usd
            if spent + reserve > self.settings.daily_usd or device_spent + reserve > self.settings.device_daily_usd:
                raise AssistantError(429, "budget_limit", "Đã đạt ngân sách trợ lý trong ngày. Dẫn đường vẫn hoạt động.")
            db.execute("INSERT INTO turns VALUES (?,?,?,?,?,?,?)", (turn_id, client, day, reserve, "pending", now, event if mode == "proactive" else None))
            db.execute("DELETE FROM turns WHERE at<?", (now - 7 * 86400,))
        return turn_id

    def settle(self, turn_id: str, cost: float | None):
        # On unknown usage/network failure keep the reservation, never under-count.
        with self.db() as db:
            if cost is None:
                db.execute("UPDATE turns SET status='uncertain' WHERE id=?", (turn_id,))
            else:
                db.execute("UPDATE turns SET status='complete',cost=? WHERE id=?", (cost, turn_id))

    def usage(self, client: str):
        day = datetime.fromtimestamp(self.clock(), timezone.utc).date().isoformat()
        with self.db() as db:
            spent = db.execute("SELECT coalesce(sum(cost),0) FROM turns WHERE day=?", (day,)).fetchone()[0]
            own = db.execute("SELECT coalesce(sum(cost),0) FROM turns WHERE day=? AND client=?", (day,client)).fetchone()[0]
        return {"day_utc": day, "daily_limit_usd": self.settings.daily_usd, "spent_usd": round(spent,6),
                "device_limit_usd": self.settings.device_daily_usd, "device_spent_usd": round(own,6)}
