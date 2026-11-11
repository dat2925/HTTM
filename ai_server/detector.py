"""Small YOLO obstacle detector used by the graduation demo."""

from __future__ import annotations

import logging
import os
import re
import threading
import unicodedata
from pathlib import Path
from typing import Any

import numpy as np
from dotenv import dotenv_values
from PIL import Image


logger = logging.getLogger("smart-navigation")
SERVER_DIR = Path(__file__).resolve().parent

OBSTACLE_CLASSES = {
    "person",
    "bicycle",
    "motorcycle",
    "car",
    "bus",
    "truck",
    "chair",
    "bench",
    "dog",
    "backpack",
    "suitcase",
    "pole",
    "tree",
    "pothole",
    "trash_bin",
    "signboard",
    "traffic_light",
}

CLASS_ALIASES: dict[str, str] = {
    "person": "person",
    "bicycle": "bicycle",
    "motorcycle": "motorcycle",
    "car": "car",
    "bus": "bus",
    "truck": "truck",
    "chair": "chair",
    "bench": "bench",
    "dog": "dog",
    "backpack": "backpack",
    "suitcase": "suitcase",
    "nguoi": "person",
    "xe dap": "bicycle",
    "xe_dap": "bicycle",
    "xe may": "motorcycle",
    "xe_may": "motorcycle",
    "xe hoi": "car",
    "xe_hoi": "car",
    "cot": "pole",
    "cay coi": "tree",
    "cay_coi": "tree",
    "o ga": "pothole",
    "o_ga": "pothole",
    "thung rac": "trash_bin",
    "thung_rac": "trash_bin",
    "bang hieu": "signboard",
    "bang_hieu": "signboard",
    "den giao thong": "traffic_light",
    "den_giao_thong": "traffic_light",
    "pole": "pole",
    "tree": "tree",
    "pothole": "pothole",
    "trash_bin": "trash_bin",
    "trash bin": "trash_bin",
    "signboard": "signboard",
}


def normalize_class_name(name: str) -> str:
    decomposed = unicodedata.normalize("NFD", str(name).strip().lower()).replace("đ", "d")
    stripped = "".join(
        ch for ch in decomposed
        if not unicodedata.combining(ch) and unicodedata.category(ch) != "Cf"
    )
    return re.sub(r"[\s_]+", " ", stripped).strip()


def canonical_class_name(raw_name: str) -> str | None:
    normalized = normalize_class_name(raw_name)
    canonical = CLASS_ALIASES.get(normalized)
    if canonical in OBSTACLE_CLASSES:
        return canonical
    return None


def detector_setting(key: str, default: str) -> str:
    """Process environment first, then ai_server/.env, like assistant_config."""
    value = os.getenv(key)
    if value:
        return value
    env_file = SERVER_DIR / ".env"
    if env_file.is_file():
        try:
            value = dotenv_values(env_file, interpolate=False).get(key)
        except OSError:
            value = None
    return value or default


def resolve_model_path(model_name: str) -> str:
    candidate = Path(model_name)
    if not candidate.is_absolute():
        server_candidate = SERVER_DIR / candidate
        if server_candidate.is_file():
            return str(server_candidate)
    return model_name


def position_for(center_x: float, image_width: int) -> str:
    ratio = center_x / image_width
    if ratio < 0.33:
        return "left"
    if ratio < 0.66:
        return "center"
    return "right"


def danger_for(
    area_ratio: float,
    class_name: str | None = None,
    position: str | None = None,
    bottom_ratio: float | None = None,
) -> str:
    # Legacy API field: visual attention priority only. Not distance, collision
    # probability, velocity or proof that this object intersects a walking route.
    if area_ratio < 0.05:
        danger = "low"
    elif area_ratio < 0.15:
        danger = "medium"
    else:
        danger = "high"

    if class_name == "pothole":
        if position == "center" and bottom_ratio is not None and bottom_ratio >= 0.66:
            return "high"
        if danger == "low":
            return "medium"
    return danger


class YoloObstacleDetector:
    """Lazy-loads a stable nano model and serializes inference calls."""

    def __init__(self) -> None:
        self._model: Any | None = None
        self._logged_model_id: int | None = None
        self._model_lock = threading.Lock()
        self._inference_lock = threading.Lock()
        self.model_name = detector_setting("YOLO_MODEL", "yolo11n.pt")
        self.confidence = float(detector_setting("YOLO_CONFIDENCE", "0.35"))

    def _log_model_classes(self, names: Any) -> None:
        raw_names = list(names.values()) if isinstance(names, dict) else list(names or [])
        if not raw_names:
            return
        mapped = [str(name) for name in raw_names if canonical_class_name(str(name)) is not None]
        unmapped = [str(name) for name in raw_names if canonical_class_name(str(name)) is None]
        if not mapped:
            logger.error(
                "YOLO model %r has no classes mapped to OBSTACLE_CLASSES: %s",
                self.model_name,
                unmapped,
            )
        elif unmapped:
            logger.warning(
                "YOLO model %r has %d unmapped class(es): %s",
                self.model_name,
                len(unmapped),
                unmapped,
            )

    def _get_model(self) -> Any:
        if self._model is None:
            with self._model_lock:
                if self._model is None:
                    from ultralytics import YOLO

                    self._model = YOLO(resolve_model_path(self.model_name))
                    if getattr(self._model, "names", None) is not None:
                        self._log_model_classes(self._model.names)
                        self._logged_model_id = id(self._model)
        elif id(self._model) != self._logged_model_id and getattr(self._model, "names", None) is not None:
            self._log_model_classes(self._model.names)
            self._logged_model_id = id(self._model)
        return self._model

    def warm_up(self) -> None:
        """Load the model ahead of the first request; failures only get logged."""
        try:
            model = self._get_model()
            # The first predict() fuses layers and allocates buffers; pay that here too.
            with self._inference_lock:
                model.predict(source=np.zeros((480, 640, 3), dtype=np.uint8),
                              conf=self.confidence, verbose=False, device="cpu")
            logger.info("YOLO model %r loaded", self.model_name)
        except Exception:  # noqa: BLE001 - /detect will surface the real error later
            logger.exception("YOLO model %r failed to preload", self.model_name)

    def detect(self, image: Image.Image) -> list[dict[str, Any]]:
        rgb_image = image.convert("RGB")
        image_width, image_height = rgb_image.size
        image_area = image_width * image_height

        with self._inference_lock:
            results = self._get_model().predict(
                source=np.asarray(rgb_image),
                conf=self.confidence,
                verbose=False,
                device="cpu",
            )

        objects: list[dict[str, Any]] = []
        if not results:
            return objects

        result = results[0]
        names = result.names
        if id(self._model) != self._logged_model_id and names is not None:
            self._log_model_classes(names)
            self._logged_model_id = id(self._model)
        for box in result.boxes:
            class_id = int(box.cls.item())
            model_class_name = str(names[class_id])
            class_name = canonical_class_name(model_class_name)
            if class_name is None:
                continue

            x1, y1, x2, y2 = (float(value) for value in box.xyxy[0].tolist())
            center_x = (x1 + x2) / 2
            center_y = (y1 + y2) / 2
            box_width = max(0.0, x2 - x1)
            box_height = max(0.0, y2 - y1)
            area_ratio = (box_width * box_height) / image_area
            position = position_for(center_x, image_width)
            danger = danger_for(
                area_ratio,
                class_name=class_name,
                position=position,
                bottom_ratio=y2 / image_height,
            )

            objects.append(
                {
                    "class_name": class_name,
                    "model_class_name": model_class_name,
                    "confidence": round(float(box.conf.item()), 4),
                    "x1": round(x1, 2),
                    "y1": round(y1, 2),
                    "x2": round(x2, 2),
                    "y2": round(y2, 2),
                    "center_x": round(center_x, 2),
                    "center_y": round(center_y, 2),
                    "width_ratio": round(box_width / image_width, 4),
                    "height_ratio": round(box_height / image_height, 4),
                    "area_ratio": round(area_ratio, 4),
                    "position": position,
                    "danger": danger,
                }
            )

        return objects


# Integration boundary: measured metric depth/tracking need their own validated
# sensor timestamps and calibration. Relative monocular depth alone is not metres.
