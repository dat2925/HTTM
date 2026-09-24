"""OSRM route-planning proxy.

Uses the public OSRM demo server, which today only serves the "driving"
profile (the foot/bike profiles were dropped from the public demo years
ago). Routes therefore follow roads, not sidewalks. A real deployment
should self-host OSRM with a foot profile for accurate pedestrian
routing; this proxy exists so that swap can happen without touching the
Flutter client (only `OSRM_URL` below changes).
"""

from __future__ import annotations

import httpx

OSRM_URL = "https://router.project-osrm.org/route/v1/driving"

_MODIFIER_VI = {
    "left": "rẽ trái",
    "right": "rẽ phải",
    "slight left": "hơi rẽ trái",
    "slight right": "hơi rẽ phải",
    "sharp left": "rẽ trái gắt",
    "sharp right": "rẽ phải gắt",
    "straight": "đi thẳng",
    "uturn": "quay đầu",
}


class RouteError(Exception):
    """Raised when OSRM cannot be reached or returns no route."""


def _instruction_for(step: dict) -> str:
    maneuver = step.get("maneuver", {})
    step_type = maneuver.get("type")
    modifier = maneuver.get("modifier")

    if step_type == "depart":
        return "Bắt đầu di chuyển"
    if step_type == "arrive":
        return "Đã đến nơi"
    if step_type in ("turn", "end of road", "fork", "ramp"):
        return _MODIFIER_VI.get(modifier, "Đi theo tuyến đường").capitalize()
    if step_type in ("continue", "new name", "merge"):
        return "Đi thẳng"
    if step_type == "roundabout":
        return "Đi vào vòng xuyến"
    return "Đi theo tuyến đường"


async def plan_route(
    from_lat: float, from_lng: float, to_lat: float, to_lng: float
) -> dict[str, object]:
    url = f"{OSRM_URL}/{from_lng},{from_lat};{to_lng},{to_lat}"
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            response = await client.get(
                url, params={"steps": "true", "overview": "false"}
            )
            response.raise_for_status()
        except httpx.HTTPError as error:
            raise RouteError(f"OSRM request failed: {error}") from error

    data = response.json()
    if data.get("code") != "Ok" or not data.get("routes"):
        raise RouteError("No route found between the given points.")

    route0 = data["routes"][0]
    steps = route0["legs"][0]["steps"]

    waypoints: list[dict[str, object]] = []
    for step in steps:
        lng, lat = step["maneuver"]["location"]
        waypoints.append(
            {
                "lat": lat,
                "lng": lng,
                "distance_meters": round(step["distance"], 1),
                "instruction": _instruction_for(step),
            }
        )

    return {
        "distance_meters": round(route0["distance"], 1),
        "waypoints": waypoints,
    }
