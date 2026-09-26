import 'dart:convert';

/// Which `app_metadata` keys are client preferences — readable and writable
/// through the data API — and which belong to the server or to a domain that
/// writes its own (and is refused here).
abstract final class PreferenceKeys {
  static const int maxKeyLength = 200;
  static const int maxValueBytes = 1024 * 1024;

  /// Written by the server itself, or by a domain's own store.
  static const Set<String> reserved = {
    'schema_version',
    'remote.host_device_id',
    'conversation_index_generation',
    'conversation_index_backfilled_at',
    // Which (agent, environment) pairs the server's detection has searched
    // (slice 2a): the server's own record.
    'agents_probed',
  };

  /// Domains whose keys their own store writes (worktree setup) — not a
  /// preference, even though they share the table.
  static const List<String> reservedPrefixes = ['worktree_setup.'];

  static final RegExp _shape = RegExp(r'^[\x21-\x7e]+$');

  static bool isReserved(String key) =>
      reserved.contains(key) ||
      reservedPrefixes.any((prefix) => key.startsWith(prefix));

  /// Why [key] cannot name a preference, or null when it can.
  static String? keyProblem(String key) {
    if (key.isEmpty || key.length > maxKeyLength || !_shape.hasMatch(key)) {
      return 'a preference key is 1–$maxKeyLength printable ASCII characters '
          'with no spaces';
    }
    return null;
  }

  /// Why [value] cannot be kept, or null when it can.
  static String? valueProblem(String value) =>
      utf8.encode(value).length > maxValueBytes
      ? 'a preference is at most $maxValueBytes bytes'
      : null;
}

/// A client's preferences as its code reads them: at once, from the copy the
/// server keeps it up to date with. A write lands in that copy now and at the
/// server after.
abstract interface class PreferenceStore {
  String? read(String key);

  void write(String key, String value);

  void remove(String key);
}
