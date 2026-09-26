import 'dart:convert';

import 'package:riverpod/riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;

import '../../../core/data/data_providers.dart';

/// The last typed commands that ran, fully resolved, newest first. Kept in
/// `app_metadata` — no migration, and an older build simply ignores the key.
class TypedCommandHistory {
  TypedCommandHistory(this._preferences);

  final PreferenceStore _preferences;

  static const String key = 'quick_open.command_history.v1';

  /// Commands kept; the oldest fall off.
  static const int limit = 20;

  /// Newest first. A value this build cannot read is no history, not an error.
  List<String> list() {
    final raw = _preferences.read(key);
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is String && entry.trim().isNotEmpty) entry,
      ];
    } on FormatException {
      return const [];
    }
  }

  /// Puts [command] first, dropping an earlier copy of it.
  void record(String command) {
    final text = command.trim();
    if (text.isEmpty) return;
    final next = [text, ...list().where((c) => c != text)].take(limit);
    _preferences.write(key, jsonEncode(next.toList()));
  }
}

final typedCommandHistoryProvider = Provider<TypedCommandHistory>(
  (ref) => TypedCommandHistory(ref.watch(appPreferencesProvider)),
);
