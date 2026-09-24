"""Small YOLO obstacle detector used by the graduation demo."""

from __future__ import annotations

import os
import threading
from typing import Any

import numpy as np
from PIL import Image


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
}


def position_for(center_x: float, image_width: int) -> str:
    ratio = center_x / image_width
    if ratio < 0.33:
        return "left"
    if ratio < 0.66:
        return "center"
    return "right"


def danger_for(area_ratio: float) -> str:
    # Demo heuristic based on bounding-box size, not true physical distance.
    if area_ratio < 0.05:
        return "low"
    if area_ratio < 0.15:
        return "medium"
    return "high"


class YoloObstacleDetector:
    """Lazy-loads a stable nano model and serializes inference calls."""

    def __init__(self) -> None:
        self._model: Any | None = None
        self._model_lock = threading.Lock()
        self._inference_lock = threading.Lock()
        self.model_name = os.getenv("YOLO_MODEL", "yolo11n.pt")
        self.confidence = float(os.getenv("YOLO_CONFIDENCE", "0.35"))

    def _get_model(self) -> Any:
        if self._model is None:
            with self._model_lock:
                if self._model is None:
                    from ultralytics import YOLO

                    self._model = YOLO(self.model_name)
        return self._model

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
        for box in result.boxes:
            class_id = int(box.cls.item())
            class_name = str(names[class_id])
            if class_name not in OBSTACLE_CLASSES:
                continue

            x1, y1, x2, y2 = (float(value) for value in box.xyxy[0].tolist())
            center_x = (x1 + x2) / 2
            center_y = (y1 + y2) / 2
            box_width = max(0.0, x2 - x1)
            box_height = max(0.0, y2 - y1)
            area_ratio = (box_width * box_height) / image_area

            objects.append(
                {
                    "class_name": class_name,
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
                    "position": position_for(center_x, image_width),
                    "danger": danger_for(area_ratio),
                }
            )

        return objects


# TODO: Replace the bounding-box proximity heuristic with Depth Anything V2
# Small or MiDaS when implementing the production depth-estimation pipeline.
