"""Exercise upload validation and inference failures without loading YOLO weights."""

import io
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient
from PIL import Image

from main import app, detector


class DetectEndpointTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        buffer = io.BytesIO()
        Image.new("RGB", (12, 8)).save(buffer, format="PNG")
        self.png = buffer.getvalue()

    def upload(self, data):
        return self.client.post("/detect", files={"image": ("frame.png", data, "image/png")})

    def test_missing_image(self):
        self.assertEqual(self.client.post("/detect").status_code, 422)

    def test_empty_and_invalid_images_never_reach_inference(self):
        with patch.object(detector, "detect") as inference:
            for data in (b"", b"not an image", self.png[:20]):
                with self.subTest(data=data[:20]):
                    self.assertEqual(self.upload(data).status_code, 400)
            inference.assert_not_called()

    def test_valid_image_preserves_dimensions_and_objects(self):
        with patch.object(detector, "detect", return_value=[]) as inference:
            response = self.upload(self.png)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), {
                "success": True, "image_width": 12, "image_height": 8, "objects": []
            })
            inference.assert_called_once()

    def test_inference_error_has_stable_response(self):
        with patch.object(detector, "detect", side_effect=RuntimeError("internal model detail")):
            response = self.upload(self.png)
            self.assertEqual(response.status_code, 500)
            self.assertEqual(response.json(), {"detail": "Object detection failed."})


if __name__ == "__main__":
    unittest.main()
