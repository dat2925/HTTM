"""FastAPI entry point for the Smart Navigation MVP."""

from __future__ import annotations

import io
import logging

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from PIL import Image, UnidentifiedImageError

from detector import YoloObstacleDetector


logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("smart-navigation")

app = FastAPI(title="Smart Navigation AI Server", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
detector = YoloObstacleDetector()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/detect")
async def detect(image: UploadFile = File(...)) -> dict[str, object]:
    data = await image.read()
    if not data:
        logger.warning("Empty upload: filename=%s content_type=%s", image.filename, image.content_type)
        raise HTTPException(status_code=400, detail="The uploaded image is empty.")
    try:
        pil_image = Image.open(io.BytesIO(data))
        pil_image.load()
    except (UnidentifiedImageError, OSError) as error:
        logger.warning(
            "Invalid image upload: filename=%s content_type=%s bytes=%d",
            image.filename,
            image.content_type,
            len(data),
        )
        raise HTTPException(status_code=400, detail="Invalid image data.") from error

    width, height = pil_image.size
    try:
        objects = await run_in_threadpool(detector.detect, pil_image)
    except Exception as error:
        logger.exception("YOLO inference failed")
        raise HTTPException(status_code=500, detail="Object detection failed.") from error

    return {
        "success": True,
        "image_width": width,
        "image_height": height,
        "objects": objects,
    }
