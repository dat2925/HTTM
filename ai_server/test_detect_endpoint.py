"""Exercise upload validation, geocoding error mapping, and inference failures."""

import io
import os
import unittest
from unittest.mock import AsyncMock, patch

import httpx
from fastapi import UploadFile
from fastapi.testclient import TestClient
from PIL import Image

import geocoder
import main
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

    def test_upload_exceeding_max_bytes_returns_413_without_reading_all(self):
        bytes_read = 0
        original_read = UploadFile.read

        async def counting_read(upload_self, size: int = -1) -> bytes:
            nonlocal bytes_read
            chunk = await original_read(upload_self, size)
            bytes_read += len(chunk)
            return chunk

        payload = b"x" * 10000
        with patch.dict(os.environ, {"DETECT_MAX_BYTES": "500"}), patch.object(
            UploadFile, "read", counting_read
        ), patch.object(detector, "detect") as inference:
            response = self.upload(payload)
            self.assertEqual(response.status_code, 413)
            self.assertLess(bytes_read, len(payload))
            inference.assert_not_called()

    def test_image_exceeding_max_pixels_returns_413_before_load(self):
        self.assertEqual(Image.MAX_IMAGE_PIXELS, 12_000_000)
        large_buffer = io.BytesIO()
        Image.new("L", (4000, 3001)).save(large_buffer, format="PNG")
        large_png = large_buffer.getvalue()
        with patch.object(Image.Image, "load") as load_mock, patch.object(
            detector, "detect"
        ) as inference:
            response = self.upload(large_png)
            self.assertEqual(response.status_code, 413)
            load_mock.assert_not_called()
            inference.assert_not_called()


class GeocodeEndpointTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)
        geocoder._cache.clear()
        geocoder._last_request = 0.0

    def test_geocode_and_reverse_return_502_on_network_or_http_error(self):
        http_client = AsyncMock()
        http_client.get.side_effect = httpx.ConnectError("network down")
        with patch("geocoder.httpx.AsyncClient") as constructor, patch(
            "geocoder.asyncio.sleep", new=AsyncMock()
        ):
            constructor.return_value.__aenter__.return_value = http_client
            self.assertEqual(self.client.get("/geocode", params={"q": "Bến Thành"}).status_code, 502)
            self.assertEqual(
                self.client.get("/reverse", params={"lat": 10.77, "lng": 106.69}).status_code, 502
            )

        req = httpx.Request("GET", "https://nominatim.openstreetmap.org/search")
        http_client.get.side_effect = None
        http_client.get.return_value = httpx.Response(503, text="unavailable", request=req)
        with patch("geocoder.httpx.AsyncClient") as constructor, patch(
            "geocoder.asyncio.sleep", new=AsyncMock()
        ):
            constructor.return_value.__aenter__.return_value = http_client
            self.assertEqual(self.client.get("/geocode", params={"q": "Bến Thành"}).status_code, 502)
            self.assertEqual(
                self.client.get("/reverse", params={"lat": 10.77, "lng": 106.69}).status_code, 502
            )

    def test_geocode_and_reverse_return_404_when_no_result(self):
        http_client = AsyncMock()
        req = httpx.Request("GET", "https://nominatim.openstreetmap.org/search")
        http_client.get.return_value = httpx.Response(200, json=[], request=req)
        with patch("geocoder.httpx.AsyncClient") as constructor, patch(
            "geocoder.asyncio.sleep", new=AsyncMock()
        ):
            constructor.return_value.__aenter__.return_value = http_client
            self.assertEqual(
                self.client.get("/geocode", params={"q": "NonexistentPlaceXYZ"}).status_code, 404
            )

        rev_req = httpx.Request("GET", "https://nominatim.openstreetmap.org/reverse")
        http_client.get.return_value = httpx.Response(
            200, json={"error": "Unable to geocode"}, request=rev_req
        )
        with patch("geocoder.httpx.AsyncClient") as constructor, patch(
            "geocoder.asyncio.sleep", new=AsyncMock()
        ):
            constructor.return_value.__aenter__.return_value = http_client
            self.assertEqual(
                self.client.get("/reverse", params={"lat": 0.0, "lng": 0.0}).status_code, 404
            )

    def test_user_agent_uses_nominatim_contact_env_with_default_fallback(self):
        with patch.dict(os.environ, {"NOMINATIM_CONTACT": ""}):
            self.assertEqual(
                geocoder.build_user_agent(),
                "SmartNavigationDemo/1.0 (graduation project; contact: n/a)",
            )
        with patch.dict(os.environ, {"NOMINATIM_CONTACT": "team@example.edu"}):
            self.assertEqual(
                geocoder.build_user_agent(),
                "SmartNavigationDemo/1.0 (graduation project; contact: team@example.edu)",
            )


if __name__ == "__main__":
    unittest.main()
