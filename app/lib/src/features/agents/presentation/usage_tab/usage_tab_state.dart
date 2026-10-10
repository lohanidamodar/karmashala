import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod/riverpod.dart';

import '../../application/usage_accounts.dart';
import '../../application/usage_tab_prefs.dart';

/// How far back the Usage tab looks. 30 days is the most the server keeps.
enum UsageRange {
  day('24h', Duration(hours: 24)),
  week('7d', Duration(days: 7)),
  month('30d', Duration(days: 30));

  const UsageRange(this.label, this.span);

  final String label;
  final Duration span;

  /// "the last 7 days", for a sentence.
  String get phrase => switch (this) {
    UsageRange.day => 'the last 24 hours',
    UsageRange.week => 'the last 7 days',
    UsageRange.month => 'the last 30 days',
  };
}

/// **An account's name that survives a new reading.** The newest environment
/// — and so `latest.accountKey` — changes whenever another machine reads it
/// first; the agent and email do not.
String usageAccountId(UsageAccount account) =>
    '${account.agentId}\u0000'
    '${account.email?.toLowerCase() ?? account.latest.accountKey}';

/// What the Usage tab is showing: which account, over which range.
@immutable
class UsageTabSelection {
  const UsageTabSelection({this.accountId, this.range = UsageRange.week});

  /// [usageAccountId] of the chosen account; null for every account.
  final String? accountId;
  final UsageRange range;

  Map<String, Object?> toJson() => {
    'accountId': ?accountId,
    'range': range.name,
  };

  static UsageTabSelection fromJson(Map<String, Object?> json) =>
      UsageTabSelection(
        accountId: json['accountId'] is String
            ? json['accountId']! as String
            : null,
        range: UsageRange.values.firstWhere(
          (r) => r.name == json['range'],
          orElse: () => UsageRange.week,
        ),
      );
}

/// The tab's choices, held here rather than in `State`: a Usage tab that is
/// not on screen is not built, so its `State` would forget them. Kept on
/// this device too (round 86), so the tab opens on the account and range it
/// was left on; an account since gone shows every account instead.
class UsageTabSelectionController extends Notifier<UsageTabSelection> {
  var _touched = false;

  @override
  UsageTabSelection build() {
    unawaited(_load());
    return const UsageTabSelection();
  }

  Future<void> _load() async {
    final kept = await ref.read(usageTabPrefsStoreProvider).load();
    if (kept != null && ref.mounted && !_touched) {
      state = UsageTabSelection.fromJson(kept);
    }
  }

  void selectAccount(String accountId) =>
      _set(UsageTabSelection(accountId: accountId, range: state.range));

  /// Every account at once.
  void selectAll() => _set(UsageTabSelection(range: state.range));

  void selectRange(UsageRange range) =>
      _set(UsageTabSelection(accountId: state.accountId, range: range));

  void _set(UsageTabSelection next) {
    _touched = true;
    state = next;
    unawaited(
      _written = ref.read(usageTabPrefsStoreProvider).save(next.toJson()),
    );
  }

  Future<void> _written = Future<void>.value();

  /// Settles once every choice so far is on disk; for a test.
  @visibleForTesting
  Future<void> get written => _written;
}

final usageTabSelectionProvider =
    NotifierProvider<UsageTabSelectionController, UsageTabSelection>(
      UsageTabSelectionController.new,
    );
