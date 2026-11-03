import 'package:dam_for_windows_tools/app/states.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026);
  DateTime at(int ms) => start.add(Duration(milliseconds: ms));

  test('10回続けて押したときだけ成立する', () {
    final keys = KeySequence(count: 10);
    for (var i = 0; i < 9; i++) {
      expect(keys.press(matches: true, at: at(i * 200)), isFalse);
    }
    expect(keys.press(matches: true, at: at(1800)), isTrue);
  });

  test('別のキーや、2秒を超える間隔があると数え直す', () {
    final keys = KeySequence(count: 3);
    keys.press(matches: true, at: at(0));
    keys.press(matches: true, at: at(100));
    expect(keys.press(matches: false, at: at(200)), isFalse);
    expect(keys.press(matches: true, at: at(300)), isFalse);
    expect(keys.press(matches: true, at: at(400)), isFalse);
    expect(keys.press(matches: true, at: at(3000)), isFalse);
    expect(keys.press(matches: true, at: at(3100)), isFalse);
    expect(keys.press(matches: true, at: at(3200)), isTrue);
  });
}
