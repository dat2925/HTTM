"""Pedestrian routing with Valhalla. Never falls back to a driving route."""
from __future__ import annotations

import math
import os
import httpx

VALHALLA_URL = os.getenv("VALHALLA_URL", "https://valhalla1.openstreetmap.de").rstrip("/")


class RouteError(Exception):
    pass


def decode_shape(encoded: str) -> list[list[float]]:
    """Decode native Valhalla polyline6 into [lat, lng] points."""
    points, offset, lat, lng = [], 0, 0, 0
    while offset < len(encoded):
        deltas = []
        for _ in range(2):
            value, shift = 0, 0
            while True:
                if offset >= len(encoded) or shift > 30:
                    raise ValueError("Invalid route shape")
                byte = ord(encoded[offset]) - 63
                offset += 1
                if not 0 <= byte <= 63:
                    raise ValueError("Invalid route shape")
                value |= (byte & 31) << shift
                shift += 5
                if byte < 32:
                    break
            deltas.append(~(value >> 1) if value & 1 else value >> 1)
        lat += deltas[0]
        lng += deltas[1]
        points.append([lat / 1e6, lng / 1e6])
    return points


def _instruction_for(maneuver: dict) -> str:
    kind = maneuver.get("type", 0)
    instructions = {
        0: "Đi theo lối đi", 1: "Bắt đầu đi bộ", 2: "Bắt đầu đi bộ sang phải",
        3: "Bắt đầu đi bộ sang trái", 4: "Đã đến nơi", 5: "Đích ở bên phải",
        6: "Đích ở bên trái", 7: "Tiếp tục đi", 8: "Đi thẳng",
        9: "Hơi rẽ phải", 10: "Rẽ phải", 11: "Rẽ phải gắt",
        12: "Quay lại", 13: "Quay lại", 14: "Rẽ trái gắt",
        15: "Rẽ trái", 16: "Hơi rẽ trái", 17: "Đi theo lối dốc",
        18: "Đi theo lối dốc bên phải", 19: "Đi theo lối dốc bên trái",
        20: "Đi ra bên phải", 21: "Đi ra bên trái", 22: "Đi thẳng",
        23: "Giữ bên phải", 24: "Giữ bên trái", 25: "Nhập vào lối đi",
        26: "Đi vào vòng xuyến", 27: "Ra khỏi vòng xuyến",
        28: "Đi tới bến phà", 29: "Rời bến phà", 37: "Nhập vào lối bên phải",
        38: "Nhập vào lối bên trái", 39: "Đi tới thang máy", 40: "Có cầu thang phía trước",
        41: "Đi tới thang cuốn", 42: "Đi vào tòa nhà", 43: "Đi ra khỏi tòa nhà",
    }
    text = instructions.get(kind, "Đi theo lối đi")
    if kind == 26 and maneuver.get("roundabout_exit_count"):
        text += f", ra ở lối thứ {maneuver['roundabout_exit_count']}"
    names = maneuver.get("street_names") or []
    if names and kind not in (4, 5, 6):
        text += f" trên {names[0]}"
    return text


def normalize_route(data: dict) -> dict:
    trip = data["trip"]
    if trip.get("status", 0) != 0 or len(trip["legs"]) != 1:
        raise ValueError("Invalid pedestrian route")
    leg = trip["legs"][0]
    geometry = decode_shape(leg["shape"])
    if len(geometry) < 2:
        raise ValueError("Empty pedestrian route")
    waypoints = []
    for maneuver in leg["maneuvers"]:
        if maneuver.get("travel_mode", "pedestrian") != "pedestrian":
            raise ValueError("Non-pedestrian maneuver")
        index = int(maneuver["begin_shape_index"])
        if not 0 <= index < len(geometry):
            raise ValueError("Invalid maneuver shape index")
        lat, lng = geometry[index]
        waypoints.append({
            "lat": lat, "lng": lng, "shape_index": index,
            "distance_meters": round(float(maneuver.get("length", 0)) * 1000, 1),
            "instruction": _instruction_for(maneuver),
            "type": "arrive" if maneuver.get("type") in (4, 5, 6) else "turn",
            "street_name": (maneuver.get("street_names") or [""])[0],
        })
    if not waypoints:
        raise ValueError("No walking instructions")
    return {
        "profile": "pedestrian", "provider": "valhalla",
        "distance_meters": round(float(trip["summary"]["length"]) * 1000, 1),
        "duration_seconds": trip["summary"]["time"],
        "geometry": geometry, "waypoints": waypoints,
    }


async def plan_route(from_lat: float, from_lng: float, to_lat: float, to_lng: float) -> dict:
    if not all(math.isfinite(value) for value in (from_lat, from_lng, to_lat, to_lng)):
        raise RouteError("Tọa độ không hợp lệ.")
    if not (-90 <= from_lat <= 90 and -90 <= to_lat <= 90 and
            -180 <= from_lng <= 180 and -180 <= to_lng <= 180):
        raise RouteError("Tọa độ nằm ngoài phạm vi.")
    payload = {
        "locations": [{"lat": from_lat, "lon": from_lng}, {"lat": to_lat, "lon": to_lng}],
        "costing": "pedestrian",
        "costing_options": {"pedestrian": {"walking_speed": 4.0, "step_penalty": 120,
                                             "walkway_factor": 0.8, "sidewalk_factor": 0.8}},
        "units": "kilometers", "language": "en-US",
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.post(f"{VALHALLA_URL}/route", json=payload)
            response.raise_for_status()
        return normalize_route(response.json())
    except (httpx.HTTPError, ValueError, KeyError, TypeError, IndexError) as error:
        raise RouteError("Không tính được tuyến đi bộ. Hãy kiểm tra kết nối và thử lại.") from error
