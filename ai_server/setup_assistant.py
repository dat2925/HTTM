"""Provision local pairing secrets without printing or changing OPENAI_API_KEY."""
import argparse
import json
import re
import secrets
from pathlib import Path
from dotenv import dotenv_values


def provision(path: Path):
    values = dotenv_values(path, interpolate=False)
    additions = []
    if not values.get("ASSISTANT_SIGNING_SECRET"):
        additions.append("ASSISTANT_SIGNING_SECRET=" + secrets.token_urlsafe(32))
    if not values.get("ASSISTANT_PAIRING_CODE"):
        additions.append("ASSISTANT_PAIRING_CODE=" + secrets.token_urlsafe(12))
    if additions:
        with path.open("a", encoding="utf-8") as handle:
            handle.write("\n# Local assistant access control\n" + "\n".join(additions) + "\n")
    return dotenv_values(path, interpolate=False)


def pairing_payload(values):
    """An enrollment credential only; never serialize the .env dictionary."""
    code = values.get("ASSISTANT_PAIRING_CODE") or ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{12,128}", code):
        raise ValueError("Pairing code must contain 12-128 URL-safe characters for QR.")
    return json.dumps({"type": "smart_navigation_pairing", "version": 1,
                       "pairing_code": code}, separators=(",", ":"))


def write_pairing_qr(values, output: Path):
    import qrcode
    payload = pairing_payload(values)
    output.parent.mkdir(parents=True, exist_ok=True)
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M,
                       box_size=8, border=4)
    qr.add_data(payload)
    qr.make(fit=True)
    qr.make_image(fill_color="black", back_color="white").save(output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--show-pairing-code", action="store_true")
    parser.add_argument("--qr", action="store_true", help="Write a private pairing QR PNG locally (not served by HTTP).")
    args = parser.parse_args()
    values = provision(Path(__file__).resolve().with_name(".env"))
    print("Backend assistant secrets configured. OpenAI key present:", bool(values.get("OPENAI_API_KEY")))
    if args.show_pairing_code:
        print("Device pairing code:", values["ASSISTANT_PAIRING_CODE"])
    if args.qr:
        output = Path(__file__).resolve().parent / ".assistant-state" / "pairing-qr.png"
        write_pairing_qr(values, output)
        print("Pairing QR written locally:", output)
        print("Keep this QR private; anyone with it can request a device token.")
