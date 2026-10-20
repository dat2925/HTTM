import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from setup_assistant import provision, pairing_payload, write_pairing_qr
from PIL import Image


class PairingQrTests(unittest.TestCase):
    def test_payload_contains_only_enrollment_credential(self):
        values = {"ASSISTANT_PAIRING_CODE": "demo-code-123456",
                  "OPENAI_API_KEY": "dummy-provider-secret",
                  "ASSISTANT_SIGNING_SECRET": "dummy-signing-secret"}
        payload = pairing_payload(values)
        self.assertEqual(json.loads(payload), {"type": "smart_navigation_pairing",
                         "version": 1, "pairing_code": "demo-code-123456"})
        self.assertNotIn(values["OPENAI_API_KEY"], payload)
        self.assertNotIn(values["ASSISTANT_SIGNING_SECRET"], payload)

    def test_qr_png_encodes_the_same_validated_payload(self):
        import qrcode
        values = {"ASSISTANT_PAIRING_CODE": "demo-code-123456"}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "private" / "qr.png"
            with patch.object(qrcode.QRCode, "add_data", autospec=True,
                              side_effect=qrcode.QRCode.add_data) as add_data:
                write_pairing_qr(values, output)
                self.assertEqual(add_data.call_args.args[1], pairing_payload(values))
            with Image.open(output) as image:
                self.assertEqual(image.format, "PNG")
                self.assertEqual(image.width, image.height)
            import cv2
            detectors = [cv2.QRCodeDetector()]
            if hasattr(cv2, "QRCodeDetectorAruco"):
                detectors.append(cv2.QRCodeDetectorAruco())
            image = cv2.imread(str(output))
            self.assertTrue(any(reader.detectAndDecode(image)[0] == pairing_payload(values)
                                for reader in detectors))

    def test_existing_backend_secrets_unchanged_by_provisioning(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            original = ("OPENAI_API_KEY=dummy-provider-secret\n"
                        "ASSISTANT_SIGNING_SECRET=dummy-signing-secret\n"
                        "ASSISTANT_PAIRING_CODE=demo-code-123456\n")
            path.write_text(original, encoding="utf-8")
            provision(path)
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_bad_qr_code_fails_without_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "qr.png"
            with self.assertRaises(ValueError):
                write_pairing_qr({"ASSISTANT_PAIRING_CODE": "bad"}, output)
            self.assertFalse(output.exists())
