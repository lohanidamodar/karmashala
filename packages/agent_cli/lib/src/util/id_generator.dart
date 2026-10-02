// The code is a copy of packages/karmashala_core/lib/src/util/id_generator.dart, kept identical to it.
// The doc comments are not kept in step: they are this package's
// pub.dev documentation, and the original's were trimmed.
import 'dart:math';

/// Generates unique identifiers for new domain entities.
///
/// Abstracted so the application layer can inject a deterministic generator in
/// tests instead of relying on randomness.
abstract interface class IdGenerator {
  /// Returns a new, unique identifier.
  String newId();
}

/// Produces RFC-4122 version-4 (random) UUID strings using a secure RNG.
class RandomIdGenerator implements IdGenerator {
  RandomIdGenerator([Random? random]) : _random = random ?? Random.secure();

  final Random _random;

  @override
  String newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    // Set version (4) and variant (10xx) bits per RFC 4122.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
    return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
        '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
        '${hex.sublist(10, 16).join()}';
  }
}
