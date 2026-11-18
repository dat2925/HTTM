"""Compare labelled upright frames with real device/server predictions (JSONL).

No sample measurements are generated. All coordinates are upright image pixels.
Run --help for capture and evaluation modes. Video frames must be extracted once
and labelled with stable frame IDs so both backends see identical pixels.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import time
from collections import Counter
from pathlib import Path


def read_jsonl(path: Path) -> list[dict]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    ids = [row["frame_id"] for row in rows]
    if not rows or any(not isinstance(i, str) or not i for i in ids) or len(set(ids)) != len(ids):
        raise ValueError("Input must contain unique, nonempty frame IDs")
    return rows


def box_for(obj: dict) -> list[float]:
    box = obj.get("box", [obj.get(k) for k in ("x1", "y1", "x2", "y2")])
    if len(box) != 4 or any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in box):
        raise ValueError("Box must contain four finite pixel coordinates")
    if box[2] <= box[0] or box[3] <= box[1]:
        raise ValueError("Box must have positive area")
    if not isinstance(obj.get("class_name"), str) or not obj["class_name"]:
        raise ValueError("class_name is required")
    return box


def iou(a: list, b: list) -> float:
    intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - intersection
    return intersection / union


def evaluate(truth: list[dict], predictions: list[dict], threshold: float = .5) -> dict:
    if not 0 < threshold <= 1:
        raise ValueError("IoU must be in (0, 1]")
    gt = {r["frame_id"]: r for r in truth}
    pred = {r["frame_id"]: r for r in predictions}
    if not gt or len(gt) != len(truth) or len(pred) != len(predictions) or gt.keys() != pred.keys():
        raise ValueError("Truth/predictions must have identical unique frame IDs; missing inference is not an empty detection")
    counts = {}
    latencies = []
    for frame_id, row in gt.items():
        actual = pred[frame_id]
        if any(not isinstance(row[k], int) or row[k] <= 0 for k in ("image_width", "image_height")):
            raise ValueError("Image dimensions must be positive integers")
        if (row["image_width"], row["image_height"]) != (actual["image_width"], actual["image_height"]):
            raise ValueError(f"Image geometry mismatch: {frame_id}")
        labels = row["objects"]
        detections = actual["objects"]
        for obj in labels + detections:
            x1, y1, x2, y2 = box_for(obj)
            if x1 < 0 or y1 < 0 or x2 > row["image_width"] or y2 > row["image_height"]:
                raise ValueError(f"Box outside upright image: {frame_id}")
            counts.setdefault(obj["class_name"], Counter(tp=0, fp=0, fn=0))
        used = set()
        for obj in sorted(detections, key=lambda o: o["confidence"], reverse=True):
            confidence = obj["confidence"]
            if not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
                raise ValueError("Invalid confidence")
            candidates = [(iou(box_for(obj), box_for(label)), i) for i, label in enumerate(labels)
                          if i not in used and label["class_name"] == obj["class_name"]]
            best = max(candidates, default=(0, -1))
            if best[0] >= threshold:
                used.add(best[1])
                counts[obj["class_name"]]["tp"] += 1
            else:
                counts[obj["class_name"]]["fp"] += 1
        for i, label in enumerate(labels):
            if i not in used:
                counts[label["class_name"]]["fn"] += 1
        latency = actual["latency_ms"]
        if not isinstance(latency, (int, float)) or not math.isfinite(latency) or latency < 0:
            raise ValueError("Invalid latency")
        latencies.append(latency)

    def metrics(c):
        tp, fp, fn = (c[k] for k in ("tp", "fp", "fn"))
        return dict(c, precision=tp / (tp + fp) if tp + fp else None,
                    recall=tp / (tp + fn) if tp + fn else None)

    total = Counter(tp=0, fp=0, fn=0)
    for c in counts.values():
        total.update(c)
    return {"frames": len(gt), "iou": threshold, "overall": metrics(total),
            "per_class": {k: metrics(v) for k, v in sorted(counts.items())},
            "latency_ms": {"p50": statistics.median(latencies),
                           "p95": sorted(latencies)[math.ceil(.95 * len(latencies)) - 1]},
            "models": sorted({r.get("model", "unknown") for r in predictions}),
            "backends": sorted({r.get("backend", "unknown") for r in predictions})}


def capture_server(manifest: Path, url: str, output: Path) -> None:
    import httpx
    rows = read_jsonl(manifest)
    # Exclusive creation prevents overwriting earlier measurements.
    with output.open("x", encoding="utf-8") as dest, httpx.Client(timeout=30) as client:
        for row in rows:
            image = (manifest.parent / row["image"]).read_bytes()
            started = time.perf_counter()
            response = client.post(url.rstrip("/") + "/detect?diagnostics=true",
                                   files={"image": ("frame.jpg", image, "image/jpeg")})
            response.raise_for_status()
            result = response.json()
            if result.get("success") is not True:
                raise ValueError("Inference unsuccessful")
            record = {"frame_id": row["frame_id"], "backend": "server",
                      "model": result.get("diagnostics", {}).get("model", "unknown"),
                      "latency_ms": (time.perf_counter() - started) * 1000,
                      "image_width": result["image_width"], "image_height": result["image_height"],
                      "objects": result["objects"]}
            dest.write(json.dumps(record, ensure_ascii=False) + "\n")
            dest.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    capture = sub.add_parser("server")
    capture.add_argument("manifest", type=Path)
    capture.add_argument("url")
    capture.add_argument("output", type=Path)
    evaluate_parser = sub.add_parser("evaluate")
    evaluate_parser.add_argument("truth", type=Path)
    evaluate_parser.add_argument("predictions", type=Path)
    evaluate_parser.add_argument("--iou", type=float, default=.5)
    args = parser.parse_args()
    if args.command == "server":
        capture_server(args.manifest, args.url, args.output)
    else:
        print(json.dumps(evaluate(read_jsonl(args.truth), read_jsonl(args.predictions), args.iou),
                         indent=2, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    main()
