"""Nominatim (OpenStreetMap) geocoding proxy.

Kept server-side so the phone app never has to set the User-Agent header
Nominatim's usage policy requires, and so a cache/rate-limit can be added
later without touching the Flutter client.
"""

from __future__ import annotations

import httpx

NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
USER_AGENT = "SmartNavigationDemo/1.0 (graduation project; contact: n/a)"


class GeocodeError(Exception):
    """Raised when the query has no result or Nominatim cannot be reached."""


async def geocode(query: str) -> dict[str, object]:
    query = query.strip()
    if not query:
        raise GeocodeError("Empty query.")

    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            response = await client.get(
                NOMINATIM_URL,
                params={"q": query, "format": "json", "limit": 1},
                headers={"User-Agent": USER_AGENT},
            )
            response.raise_for_status()
        except httpx.HTTPError as error:
            raise GeocodeError(f"Nominatim request failed: {error}") from error

    results = response.json()
    if not results:
        raise GeocodeError(f"No place found for '{query}'.")

    top = results[0]
    return {
        "lat": float(top["lat"]),
        "lng": float(top["lon"]),
        "display_name": top.get("display_name", query),
    }
