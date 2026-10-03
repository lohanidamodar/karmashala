import 'package:meta/meta.dart';

/// A closed set on the wire that stays open here: a string this version does
/// not know is kept as an `unknown` member carrying it, never dropped, so a
/// newer agent's vocabulary survives a round trip through this package.
@immutable
abstract base class WireEnum {
  const WireEnum(this.raw, {this.isKnown = true});

  final String raw;

  /// False for a value this package has no name for.
  final bool isKnown;

  String toJson() => raw;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && other is WireEnum && other.raw == raw;

  @override
  int get hashCode => Object.hash(runtimeType, raw);

  @override
  String toString() => raw;
}

/// [raw] matched against [known], or `null` so the caller can build its own
/// `unknown` member.
T? lookupKnown<T extends WireEnum>(List<T> known, String raw) {
  for (final value in known) {
    if (value.raw == raw) return value;
  }
  return null;
}
