/// How old a reading is, in words: a refusal that cannot say how long the
/// holder has held the token is an assertion, not a measurement.
String describeAge(Duration age) {
  if (age.isNegative) return 'just now';
  if (age.inSeconds < 1) return 'just now';
  if (age.inSeconds < 60) return '${age.inSeconds}s ago';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 48) return '${age.inHours}h ago';
  return '${age.inDays}d ago';
}
