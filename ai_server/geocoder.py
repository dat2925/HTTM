"""Nominatim (OpenStreetMap) geocoding proxy.

Kept server-side so the phone app never has to set the User-Agent header
Nominatim's usage policy requires, and so a cache/rate-limit can be added
later without touching the Flutter client.
"""

from __future__ import annotations

import httpx
import asyncio
import time
import math

NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "SmartNavigationDemo/1.0 (graduation project; contact: n/a)"
_request_lock = asyncio.Lock()
_last_request = 0.0
_cache: dict[tuple, tuple[float, dict]] = {}


class GeocodeError(Exception):
    """Raised when the query has no result or Nominatim cannot be reached."""


async def geocode(query: str, near_lat: float | None = None, near_lng: float | None = None) -> dict[str, object]:
    query = query.strip()
    if not query:
        raise GeocodeError("Empty query.")

    params = {"q": query, "format": "json", "limit": 1, "accept-language": "vi"}
    if near_lat is not None and near_lng is not None:
        if not (math.isfinite(near_lat) and math.isfinite(near_lng) and
                -90 <= near_lat <= 90 and -180 <= near_lng <= 180):
            raise GeocodeError("Tọa độ tìm kiếm không hợp lệ.")
        # Bias towards the current area without excluding a deliberately distant destination.
        params["viewbox"] = f"{max(-180, near_lng-.25)},{min(90, near_lat+.25)},{min(180, near_lng+.25)},{max(-90, near_lat-.25)}"
    key = (query.casefold(), params.get("viewbox"))
    cached = _cache.get(key)
    if cached and time.monotonic() - cached[0] < 300:
        return cached[1]
    global _last_request
    async with _request_lock, httpx.AsyncClient(timeout=10.0) as client:
        await asyncio.sleep(max(0, 1.1 - (time.monotonic() - _last_request)))
        _last_request = time.monotonic()
        try:
            response = await client.get(
                NOMINATIM_URL,
                params=params,
                headers={"User-Agent": USER_AGENT},
            )
            response.raise_for_status()
        except httpx.HTTPError as error:
            raise GeocodeError(f"Nominatim request failed: {error}") from error

    results = response.json()
    if not results:
        raise GeocodeError(f"No place found for '{query}'.")

    top = results[0]
    place = {
        "lat": float(top["lat"]),
        "lng": float(top["lon"]),
        "display_name": top.get("display_name", query),
    }
    if len(_cache) >= 256:
        _cache.pop(next(iter(_cache)))
    _cache[key] = (time.monotonic(), place)
    return place


async def reverse_geocode(lat: float, lng: float) -> dict[str, object]:
    key = ("reverse", round(lat, 3), round(lng, 3))
    cached = _cache.get(key)
    if cached and time.monotonic() - cached[0] < 300:
        return cached[1]
    global _last_request
    async with _request_lock, httpx.AsyncClient(timeout=10.0) as client:
        await asyncio.sleep(max(0, 1.1 - (time.monotonic() - _last_request)))
        _last_request = time.monotonic()
        try:
            response = await client.get("https://nominatim.openstreetmap.org/reverse",
                params={"lat": lat, "lon": lng, "format": "json", "zoom": 18, "accept-language": "vi"},
                headers={"User-Agent": USER_AGENT})
            response.raise_for_status()
            data = response.json()
            if not data.get("display_name"):
                raise ValueError("No address")
            result = {"display_name": data["display_name"]}
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as error:
            raise GeocodeError("Không tìm được địa chỉ ở vị trí này.") from error
    if len(_cache) >= 256:
        _cache.pop(next(iter(_cache)))
    _cache[key] = (time.monotonic(), result)
    return result
