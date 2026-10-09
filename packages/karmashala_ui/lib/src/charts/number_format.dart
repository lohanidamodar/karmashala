/// A count the width of a label: `812`, `1.5k`, `46.3M`, `340k`, `2.1B`.
///
/// One decimal under 100 of a unit, none from there up, and a trailing `.0`
/// dropped. The unit is chosen after rounding, so 999,950 is `1M`, not `1000k`.
String formatCompactCount(int value) {
  if (value < 0) return '-${formatCompactCount(-value)}';
  if (value < 1000) return '$value';
  const units = ['k', 'M', 'B', 'T'];
  var scaled = value / 1000;
  var unit = 0;
  while (true) {
    final text = _rounded(scaled);
    final rounded = double.parse(text);
    if (rounded < 1000 || unit == units.length - 1) {
      return '$text${units[unit]}';
    }
    scaled /= 1000;
    unit++;
  }
}

String _rounded(double value) {
  if (value >= 99.95) return value.round().toString();
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// A whole percentage of [part] in [whole], with `<1%` for a share too small to
/// round to one but not nothing. Null when [whole] is not positive.
String? formatShare(int part, int whole) {
  if (whole <= 0) return null;
  if (part <= 0) return '0%';
  final percent = part * 100 / whole;
  if (percent < 1) return '<1%';
  if (percent > 99 && part < whole) return '>99%';
  return '${percent.round()}%';
}

/// An amount an agent reported spending: `$0.42`, `1.20 EUR`, or `0.42` when
/// it named no currency. Two decimals; never called for an amount nobody
/// recorded — that is "not recorded", not `$0.00`.
String formatMoney(double amount, String? currency) {
  final fixed = amount.toStringAsFixed(2);
  return switch (currency?.trim() ?? '') {
    'USD' => '\$$fixed',
    '' => fixed,
    final other => '$fixed $other',
  };
}
