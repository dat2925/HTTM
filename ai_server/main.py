"""FastAPI entry point for the Smart Navigation MVP."""

from __future__ import annotations

import io
import logging
import os
import threading
import warnings
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, HTTPException, UploadFile, Query
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.exceptions import RequestValidationError
from starlette.responses import JSONResponse
from PIL import Image, UnidentifiedImageError

from detector import YoloObstacleDetector
from geocoder import GeocodeError, GeocodeServiceError, geocode, reverse_geocode
from routing import RouteError, plan_route
from assistant_router import router as assistant_router, AssistantBoundary, error_response
from assistant_guard import AssistantError


DEFAULT_DETECT_MAX_BYTES = 5 * 1024 * 1024
DETECT_MAX_PIXELS = 12_000_000
Image.MAX_IMAGE_PIXELS = DETECT_MAX_PIXELS

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("smart-navigation")

detector = YoloObstacleDetector()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Loading the model takes seconds, longer than the app's 4 s /detect
    # deadline, so do it before the first frame arrives instead of on it.
    if os.getenv("YOLO_PRELOAD", "1") != "0":
        threading.Thread(target=detector.warm_up, name="yolo-preload", daemon=True).start()
    yield


app = FastAPI(title="Smart Navigation AI Server", version="2.0.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)
app.include_router(assistant_router)
app.add_middleware(AssistantBoundary)


@app.exception_handler(AssistantError)
async def assistant_failure(request, error):
    return error_response(error)


@app.exception_handler(RequestValidationError)
async def validation_failure(request, error):
    if request.url.path.startswith('/assistant/'):
        return JSONResponse({"error": {"code": "invalid_request", "message": "Dữ liệu trợ lý không hợp lệ."}}, status_code=422)
    return JSONResponse({"detail": [{"loc": item['loc'], "msg": item['msg'], "type": item['type']} for item in error.errors()]}, status_code=422)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "routing_profile": "pedestrian", "api_version": "2"}


@app.post("/detect")
async def detect(image: UploadFile = File(...)) -> dict[str, object]:
    max_bytes = int(os.getenv("DETECT_MAX_BYTES", str(DEFAULT_DETECT_MAX_BYTES)))
    chunk_size = max(1, min(65536, max_bytes + 1))
    chunks = bytearray()
    while True:
        chunk = await image.read(chunk_size)
        if not chunk:
            break
        chunks.extend(chunk)
        if len(chunks) > max_bytes:
            logger.warning(
                "Upload exceeds size limit: filename=%s content_type=%s limit=%d",
                image.filename,
                image.content_type,
                max_bytes,
            )
            raise HTTPException(status_code=413, detail="Uploaded image exceeds maximum size.")

    data = bytes(chunks)
    if not data:
        logger.warning("Empty upload: filename=%s content_type=%s", image.filename, image.content_type)
        raise HTTPException(status_code=400, detail="The uploaded image is empty.")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", Image.DecompressionBombWarning)
            pil_image = Image.open(io.BytesIO(data))
            if pil_image.width * pil_image.height > DETECT_MAX_PIXELS:
                raise HTTPException(status_code=413, detail="Image exceeds maximum pixel limit.")
            pil_image.load()
    except HTTPException:
        raise
    except Image.DecompressionBombError as error:
        raise HTTPException(status_code=413, detail="Image exceeds maximum pixel limit.") from error
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


@app.get("/geocode")
async def geocode_place(q: str = Query(..., min_length=1, max_length=300),
                        near_lat: float | None = Query(None, ge=-90, le=90),
                        near_lng: float | None = Query(None, ge=-180, le=180)) -> dict[str, object]:
    try:
        place = await geocode(q, near_lat, near_lng)
    except GeocodeServiceError as error:
        logger.warning("Geocode upstream failed for query=%r: %s", q, error)
        raise HTTPException(status_code=502, detail=str(error)) from error
    except GeocodeError as error:
        logger.warning("Geocode failed for query=%r: %s", q, error)
        raise HTTPException(status_code=404, detail=str(error)) from error
    return {"success": True, **place}


@app.get("/route")
async def get_route(
    from_lat: float = Query(..., ge=-90, le=90), from_lng: float = Query(..., ge=-180, le=180),
    to_lat: float = Query(..., ge=-90, le=90), to_lng: float = Query(..., ge=-180, le=180)
) -> dict[str, object]:
    try:
        result = await plan_route(from_lat, from_lng, to_lat, to_lng)
    except RouteError as error:
        logger.warning("Routing failed: %s", error)
        raise HTTPException(status_code=502, detail=str(error)) from error
    return {"success": True, **result}


@app.get("/reverse")
async def reverse_place(lat: float = Query(..., ge=-90, le=90),
                        lng: float = Query(..., ge=-180, le=180)) -> dict[str, object]:
    try:
        result = await reverse_geocode(lat, lng)
    except GeocodeServiceError as error:
        logger.warning("Reverse geocode upstream failed for (%s, %s): %s", lat, lng, error)
        raise HTTPException(status_code=502, detail=str(error)) from error
    except GeocodeError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    return {"success": True, **result}
