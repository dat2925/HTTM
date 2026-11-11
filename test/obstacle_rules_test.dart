import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_navigation/services/obstacle_rules.dart';

void main() {
  final cases =
      jsonDecode(
            File(
              'test/fixtures/detection_rules_parity.json',
            ).readAsStringSync(),
          )
          as List;
  for (var i = 0; i < cases.length; i++) {
    final row = cases[i] as Map;
    test('shared rules fixture $i: ${row['class_name_raw']}', () {
      final name = canonicalClassName(row['class_name_raw'] as String);
      final expected = row['expected'];
      if (expected == null) {
        expect(name, isNull);
        return;
      }
      final box = (row['box'] as List).cast<num>();
      final position = positionFor((box[0] + box[2]) / 2);
      final area =
          math.max(0.0, box[2] - box[0]) * math.max(0.0, box[3] - box[1]);
      expect(name, expected['class_name']);
      expect(position, expected['position']);
      expect(
        dangerFor(area.toDouble(), name, position, box[3].toDouble()),
        expected['danger'],
      );
    });
  }

  test('normalization preserves the Python alias-table quirks', () {
    expect(normalizeClassName('  ĐÈN_giao   thông '), 'den giao thong');
    expect(normalizeClassName('O\u0302\u0309_gà'), 'o ga');
    expect(normalizeClassName('N\u200bGƯỜI'), 'nguoi');
    expect(canonicalClassName('traffic_light'), isNull);
    expect(canonicalClassName('trash_bin'), 'trash_bin');
    expect(normalizeClassName('?'), '?');
  });

  test('exact threshold boundaries', () {
    expect(positionFor(0.329), 'left');
    expect(positionFor(0.33), 'center');
    expect(positionFor(0.66), 'right');
    expect(dangerFor(0.049), 'low');
    expect(dangerFor(0.05), 'medium');
    expect(dangerFor(0.15), 'high');
    expect(dangerFor(0.01, 'pothole', 'center', 0.66), 'high');
  });
}
