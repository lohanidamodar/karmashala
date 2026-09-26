import 'dart:math';

final _random = Random.secure();

/// A version-4 UUID: row ids the host writes are the app's shape, and an agent
/// handed one as its session id wants exactly this.
String newUuid() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int from, int to) => [
    for (final b in bytes.sublist(from, to))
      b.toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
