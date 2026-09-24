import unittest

from detector import danger_for, position_for


class HeuristicTests(unittest.TestCase):
    def test_position_boundaries(self) -> None:
        self.assertEqual(position_for(32, 100), "left")
        self.assertEqual(position_for(33, 100), "center")
        self.assertEqual(position_for(66, 100), "right")

    def test_danger_boundaries(self) -> None:
        self.assertEqual(danger_for(0.049), "low")
        self.assertEqual(danger_for(0.05), "medium")
        self.assertEqual(danger_for(0.15), "high")


if __name__ == "__main__":
    unittest.main()
