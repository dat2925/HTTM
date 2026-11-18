import copy
import unittest

from detection_benchmark import evaluate


def obj(name="pole", confidence=.8, box=None):
    return dict(class_name=name, confidence=confidence, box=box or [1, 2, 10, 20])


class BenchmarkTests(unittest.TestCase):
    def setUp(self):
        self.truth = [dict(frame_id="a", image_width=100, image_height=100, objects=[obj()])]
        self.pred = copy.deepcopy(self.truth)
        self.pred[0].update(latency_ms=100, backend="test", model="fixture-only")

    def test_duplicate_prediction_is_false_positive(self):
        self.pred[0]["objects"].append(obj(confidence=.6))
        result = evaluate(self.truth, self.pred)
        self.assertEqual(result["overall"], dict(tp=1, fp=1, fn=0, precision=.5, recall=1))
        self.assertEqual(result["latency_ms"], dict(p50=100, p95=100))

    def test_wrong_class_is_false_positive_and_miss(self):
        self.pred[0]["objects"] = [obj("tree")]
        self.assertEqual(evaluate(self.truth, self.pred)["overall"]["fn"], 1)
        self.assertEqual(evaluate(self.truth, self.pred)["overall"]["fp"], 1)

    def test_empty_prediction_is_a_measured_miss(self):
        self.pred[0]["objects"] = []
        self.assertEqual(evaluate(self.truth, self.pred)["overall"]["recall"], 0)
        self.assertIsNone(evaluate(self.truth, self.pred)["overall"]["precision"])

    def test_missing_frame_mismatch_duplicate_nonfinite_rejected(self):
        for mutation in [lambda p: p.clear(), lambda p: p.append(copy.deepcopy(p[0])),
                         lambda p: p[0].update(image_width=200),
                         lambda p: p[0].update(latency_ms=float("nan")),
                         lambda p: p[0]["objects"][0].update(box=[0, 0, 0, 0])]:
            p = copy.deepcopy(self.pred)
            mutation(p)
            with self.assertRaises(ValueError):
                evaluate(self.truth, p)

    def test_non_overlapping_box_is_not_a_match(self):
        self.pred[0]["objects"] = [obj(box=[50, 50, 60, 60])]
        self.assertEqual(evaluate(self.truth, self.pred)["overall"]["tp"], 0)
