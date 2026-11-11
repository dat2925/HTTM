import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from detector import (
    OBSTACLE_CLASSES,
    SERVER_DIR,
    YoloObstacleDetector,
    canonical_class_name,
    danger_for,
    detector_setting,
    normalize_class_name,
    position_for,
    resolve_model_path,
)


class _Scalar:
    def __init__(self, value: float) -> None:
        self._value = value

    def item(self) -> float:
        return self._value


class _XYXY:
    def __init__(self, coords: list[float]) -> None:
        self._coords = coords

    def __getitem__(self, index: int) -> "_XYXY":
        return self

    def tolist(self) -> list[float]:
        return list(self._coords)


class FakeBox:
    def __init__(self, cls_id: int, conf: float, coords: list[float]) -> None:
        self.cls = _Scalar(cls_id)
        self.conf = _Scalar(conf)
        self.xyxy = _XYXY(coords)


class FakeResult:
    def __init__(self, names: dict[int, str], boxes: list[FakeBox]) -> None:
        self.names = names
        self.boxes = boxes


class FakeModel:
    def __init__(self, names: dict[int, str], boxes: list[FakeBox]) -> None:
        self.names = names
        self._boxes = boxes

    def predict(self, **kwargs):
        return [FakeResult(self.names, self._boxes)]


class HeuristicTests(unittest.TestCase):
    def test_position_boundaries(self) -> None:
        self.assertEqual(position_for(32, 100), "left")
        self.assertEqual(position_for(33, 100), "center")
        self.assertEqual(position_for(66, 100), "right")

    def test_danger_boundaries(self) -> None:
        self.assertEqual(danger_for(0.049), "low")
        self.assertEqual(danger_for(0.05), "medium")
        self.assertEqual(danger_for(0.15), "high")

    def test_normalize_and_canonical_class_mapping(self) -> None:
        self.assertEqual(normalize_class_name("  Đèn_giao   thông "), "den giao thong")
        self.assertEqual(normalize_class_name("Ổ_gà"), "o ga")
        expected_httm = {
            "Nguoi": "person",
            "Xe dap": "bicycle",
            "Xe may": "motorcycle",
            "Xe hoi": "car",
            "Cot": "pole",
            "Cay coi": "tree",
            "O ga": "pothole",
            "Thung rac": "trash_bin",
            "Bang hieu": "signboard",
            "Den giao thong": "traffic_light",
        }
        for raw, canonical in expected_httm.items():
            self.assertEqual(canonical_class_name(raw), canonical)
            self.assertIn(canonical, OBSTACLE_CLASSES)

        # COCO traffic light (with space) must not be added so old COCO behavior is unchanged.
        self.assertIsNone(canonical_class_name("traffic light"))
        self.assertIsNone(canonical_class_name("airplane"))

    def test_fake_model_maps_httm_classes_and_preserves_model_class_name(self) -> None:
        names = {
            0: "Bang hieu",
            1: "Cay coi",
            2: "Cot",
            3: "Den giao thong",
            4: "Nguoi",
            5: "O ga",
            6: "Thung rac",
            7: "Xe dap",
            8: "Xe hoi",
            9: "Xe may",
        }
        boxes = [FakeBox(i, 0.85, [10, 10, 30, 30]) for i in range(10)]
        det = YoloObstacleDetector()
        det._model = FakeModel(names, boxes)

        objects = det.detect(Image.new("RGB", (100, 100)))
        self.assertEqual(
            [(o["model_class_name"], o["class_name"]) for o in objects],
            [
                ("Bang hieu", "signboard"),
                ("Cay coi", "tree"),
                ("Cot", "pole"),
                ("Den giao thong", "traffic_light"),
                ("Nguoi", "person"),
                ("O ga", "pothole"),
                ("Thung rac", "trash_bin"),
                ("Xe dap", "bicycle"),
                ("Xe hoi", "car"),
                ("Xe may", "motorcycle"),
            ],
        )

    def test_coco_model_behavior_unchanged_and_unknown_classes_ignored(self) -> None:
        names = {
            0: "person",
            1: "car",
            2: "traffic light",
            3: "airplane",
            4: "unknown_object",
        }
        boxes = [
            FakeBox(0, 0.9, [40, 10, 60, 50]),
            FakeBox(1, 0.8, [0, 10, 20, 40]),
            FakeBox(2, 0.95, [40, 10, 60, 50]),
            FakeBox(3, 0.7, [10, 10, 30, 30]),
            FakeBox(4, 0.75, [10, 10, 30, 30]),
        ]
        det = YoloObstacleDetector()
        det._model = FakeModel(names, boxes)

        with self.assertLogs("smart-navigation", level="WARNING") as logs:
            objects = det.detect(Image.new("RGB", (100, 100)))
            # Second call should not log warning again for the same model instance.
            det.detect(Image.new("RGB", (100, 100)))

        self.assertEqual(len(logs.output), 1)
        self.assertEqual([o["class_name"] for o in objects], ["person", "car"])
        self.assertEqual([o["model_class_name"] for o in objects], ["person", "car"])

    def test_logs_error_when_no_model_classes_map(self) -> None:
        det = YoloObstacleDetector()
        det._model = FakeModel({0: "spaceship", 1: "ufo"}, [FakeBox(0, 0.9, [0, 0, 10, 10])])
        with self.assertLogs("smart-navigation", level="ERROR") as logs:
            objects = det.detect(Image.new("RGB", (100, 100)))
        self.assertEqual(objects, [])
        self.assertEqual(len(logs.output), 1)

    def test_pothole_danger_rules(self) -> None:
        names = {0: "O ga", 1: "Cot"}
        boxes = [
            # Small pothole on the left (area_ratio = 0.01, y2/h = 0.80) -> minimum medium
            FakeBox(0, 0.9, [5, 70, 15, 80]),
            # Small pothole in center, above bottom threshold (y2/h = 0.65) -> medium
            FakeBox(0, 0.9, [45, 55, 55, 65]),
            # Small pothole in center, at bottom threshold (y2/h = 0.66) -> high
            FakeBox(0, 0.9, [45, 56, 55, 66]),
            # Small pole in center at bottom (area_ratio = 0.01, y2/h = 0.80) -> stays low
            FakeBox(1, 0.9, [45, 70, 55, 80]),
        ]
        det = YoloObstacleDetector()
        det._model = FakeModel(names, boxes)

        objects = det.detect(Image.new("RGB", (100, 100)))
        self.assertEqual(
            [(o["class_name"], o["position"], o["danger"]) for o in objects],
            [
                ("pothole", "left", "medium"),
                ("pothole", "center", "medium"),
                ("pothole", "center", "high"),
                ("pole", "center", "low"),
            ],
        )

    def test_resolve_model_path_uses_ai_server_directory_for_relative_file(self) -> None:
        cwd = os.getcwd()
        with tempfile.TemporaryDirectory() as temp_dir:
            try:
                os.chdir(temp_dir)
                resolved = resolve_model_path("yolo11n.pt")
                self.assertEqual(Path(resolved), SERVER_DIR / "yolo11n.pt")
                self.assertEqual(resolve_model_path("missing_custom_model.pt"), "missing_custom_model.pt")
            finally:
                os.chdir(cwd)

    def test_setting_reads_env_file_but_process_env_wins(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            Path(temp_dir, ".env").write_text("YOLO_MODEL=from_file.pt\n", encoding="utf-8")
            with patch("detector.SERVER_DIR", Path(temp_dir)), \
                    patch.dict(os.environ, {}, clear=False):
                os.environ.pop("YOLO_MODEL", None)
                self.assertEqual(detector_setting("YOLO_MODEL", "yolo11n.pt"), "from_file.pt")
                self.assertEqual(detector_setting("YOLO_CONFIDENCE", "0.35"), "0.35")
                os.environ["YOLO_MODEL"] = "from_env.pt"
                self.assertEqual(detector_setting("YOLO_MODEL", "yolo11n.pt"), "from_env.pt")

    def test_real_httm_models_all_classes_map(self) -> None:
        model_files = sorted(SERVER_DIR.glob("httm_yolo11*.pt"))
        if not model_files:
            self.skipTest("no local httm_yolo11*.pt weights")
        for model_file in model_files:
            with self.subTest(model=model_file.name), \
                    patch.dict(os.environ, {"YOLO_MODEL": model_file.name}):
                model = YoloObstacleDetector()._get_model()
                raw_names = list(model.names.values()) if isinstance(model.names, dict) else list(model.names)
                self.assertEqual(len(raw_names), 10)
                for raw_name in raw_names:
                    mapped = canonical_class_name(str(raw_name))
                    self.assertIsNotNone(mapped, f"Unmapped class in {model_file.name}: {raw_name!r}")
                    self.assertIn(mapped, OBSTACLE_CLASSES)


if __name__ == "__main__":
    unittest.main()
