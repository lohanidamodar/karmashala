import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/charts.dart';

void main() {
  group('formatCompactCount', () {
    test('small counts are written out', () {
      expect(formatCompactCount(0), '0');
      expect(formatCompactCount(812), '812');
      expect(formatCompactCount(999), '999');
    });

    test('one decimal under a hundred of a unit, none above', () {
      expect(formatCompactCount(1000), '1k');
      expect(formatCompactCount(1500), '1.5k');
      expect(formatCompactCount(12400), '12.4k');
      expect(formatCompactCount(34000), '34k');
      expect(formatCompactCount(340000), '340k');
      expect(formatCompactCount(1250000), '1.3M');
      expect(formatCompactCount(46343099), '46.3M');
      expect(formatCompactCount(120000000), '120M');
      expect(formatCompactCount(2100000000), '2.1B');
    });

    test('rounding that reaches the next unit moves to it', () {
      expect(formatCompactCount(9999), '10k');
      expect(formatCompactCount(99960), '100k');
      expect(formatCompactCount(999499), '999k');
      expect(formatCompactCount(999950), '1M');
      expect(formatCompactCount(999999999), '1B');
    });

    test('a negative count keeps its sign', () {
      expect(formatCompactCount(-1500), '-1.5k');
    });
  });

  group('formatShare', () {
    test('whole percentages', () {
      expect(formatShare(1, 4), '25%');
      expect(formatShare(4, 4), '100%');
      expect(formatShare(0, 4), '0%');
    });

    test('never rounds a sliver to nothing or a remainder to all', () {
      expect(formatShare(1, 1000), '<1%');
      expect(formatShare(999, 1000), '>99%');
    });

    test('no whole, no share', () {
      expect(formatShare(1, 0), isNull);
    });
  });

  group('formatMoney', () {
    test('dollars, another currency, and none named', () {
      expect(formatMoney(0.426, 'USD'), '\$0.43');
      expect(formatMoney(1.2, 'EUR'), '1.20 EUR');
      expect(formatMoney(3, null), '3.00');
      expect(formatMoney(3, ' '), '3.00');
    });
  });
}
