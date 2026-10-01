import 'store_client.dart';

/// What was learnt at [checkedAt]: a value, or why there is none. A missing
/// value is never replaced by a guess.
sealed class Reading<T> {
  const Reading(this.checkedAt);

  final DateTime checkedAt;

  T? get valueOrNull => switch (this) {
    ReadingValue<T>(:final value) => value,
    ReadingMissing<T>() => null,
  };

  Map<String, Object?> toJson(Object? Function(T value) encode) =>
      switch (this) {
        ReadingValue<T>(:final value) => {
          'checkedAt': checkedAt.toUtc().toIso8601String(),
          'value': encode(value),
        },
        ReadingMissing<T>(:final kind, :final message) => {
          'checkedAt': checkedAt.toUtc().toIso8601String(),
          'missing': kind.name,
          'message': message,
        },
      };

  static Reading<T> fromJson<T>(
    Map<String, Object?> json,
    T Function(Object? encoded) decode,
  ) {
    final checkedAt = DateTime.parse(json['checkedAt']! as String);
    final missing = json['missing'];
    if (missing is String) {
      return ReadingMissing<T>(
        StoreFailure.values.firstWhere(
          (kind) => kind.name == missing,
          orElse: () => StoreFailure.shape,
        ),
        json['message'] as String? ?? '',
        checkedAt,
      );
    }
    return ReadingValue<T>(decode(json['value']), checkedAt);
  }
}

final class ReadingValue<T> extends Reading<T> {
  const ReadingValue(this.value, super.checkedAt);

  final T value;
}

final class ReadingMissing<T> extends Reading<T> {
  const ReadingMissing(this.kind, this.message, super.checkedAt);

  final StoreFailure kind;
  final String message;

  /// Whether this is the store's or the setup's doing rather than a fault:
  /// worth saying quietly, not as an error.
  bool get expected =>
      kind == StoreFailure.notConfigured || kind == StoreFailure.notSupported;
}
