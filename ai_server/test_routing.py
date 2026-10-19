import unittest
from unittest.mock import AsyncMock, patch
import httpx
from routing import decode_shape, normalize_route, plan_route, RouteError, _instruction_for


def fixture():
    return {"trip": {"status": 0, "summary": {"length": 0.3, "time": 270}, "legs": [{
        "shape": "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        "maneuvers": [
            {"type": 1, "begin_shape_index": 0, "length": .2, "street_names": ["Lối đi A"], "travel_mode": "pedestrian"},
            {"type": 15, "begin_shape_index": 1, "length": .1, "travel_mode": "pedestrian"},
            {"type": 4, "begin_shape_index": 2, "travel_mode": "pedestrian"},
        ]}]}}


class GeometryTests(unittest.TestCase):
    def test_polyline6_and_route_preserve_geometry_and_maneuver_indices(self):
        self.assertEqual(decode_shape(fixture()["trip"]["legs"][0]["shape"]),
                         [[3.85, -12.02], [4.07, -12.095], [4.3252, -12.6453]])
        route = normalize_route(fixture())
        self.assertEqual(route["profile"], "pedestrian")
        self.assertEqual(route["distance_meters"], 300)
        self.assertEqual(route["waypoints"][1]["shape_index"], 1)
        self.assertEqual(route["waypoints"][1]["instruction"], "Rẽ trái")
        self.assertEqual(route["waypoints"][-1]["type"], "arrive")

    def test_rejects_driving_maneuver_and_broken_shape(self):
        data = fixture()
        data["trip"]["legs"][0]["maneuvers"][0]["travel_mode"] = "drive"
        with self.assertRaises(ValueError): normalize_route(data)
        with self.assertRaises(ValueError): decode_shape("_")

    def test_walking_special_maneuvers(self):
        self.assertEqual(_instruction_for({"type": 23}), "Giữ bên phải")
        self.assertEqual(_instruction_for({"type": 24}), "Giữ bên trái")
        self.assertIn("thứ 3", _instruction_for({"type": 26, "roundabout_exit_count": 3}))
        self.assertIn("cầu thang", _instruction_for({"type": 40}))


class RequestTests(unittest.IsolatedAsyncioTestCase):
    async def test_requests_real_pedestrian_costing(self):
        client = AsyncMock()
        client.post.return_value = httpx.Response(200, json=fixture(), request=httpx.Request("POST", "https://example.test/route"))
        with patch("routing.httpx.AsyncClient") as constructor:
            constructor.return_value.__aenter__.return_value = client
            result = await plan_route(21, 105, 21.001, 105.001)
        payload = client.post.call_args.kwargs["json"]
        self.assertEqual(payload["costing"], "pedestrian")
        self.assertEqual(payload["units"], "kilometers")
        self.assertEqual(result["profile"], "pedestrian")

    async def test_failure_does_not_fall_back_to_car(self):
        client = AsyncMock()
        client.post.side_effect = httpx.ConnectError("offline")
        with patch("routing.httpx.AsyncClient") as constructor:
            constructor.return_value.__aenter__.return_value = client
            with self.assertRaises(RouteError): await plan_route(21, 105, 21.001, 105.001)
        self.assertEqual(client.post.await_count, 1)

    async def test_invalid_coordinates_are_rejected_before_network(self):
        with self.assertRaises(RouteError): await plan_route(float("nan"), 105, 21, 105)
        with self.assertRaises(RouteError): await plan_route(91, 105, 21, 105)


if __name__ == "__main__":
    unittest.main()
