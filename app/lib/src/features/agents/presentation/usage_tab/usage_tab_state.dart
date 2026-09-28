import 'package:flutter/foundation.dart';
import 'package:riverpod/riverpod.dart';

import '../../application/usage_accounts.dart';

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

  /// [usageAccountId] of the chosen account; null for the tightest one.
  final String? accountId;
  final UsageRange range;

  UsageTabSelection copyWith({String? accountId, UsageRange? range}) =>
      UsageTabSelection(
        accountId: accountId ?? this.accountId,
        range: range ?? this.range,
      );
}

/// The tab's choices, held here rather than in `State`: a Usage tab that is
/// not on screen is not built, so its `State` would forget them. In memory
/// only — a restart lands on the tightest account again, which is the one
/// most worth seeing.
class UsageTabSelectionController extends Notifier<UsageTabSelection> {
  @override
  UsageTabSelection build() => const UsageTabSelection();

  void selectAccount(String accountId) =>
      state = state.copyWith(accountId: accountId);

  void selectRange(UsageRange range) => state = state.copyWith(range: range);
}

final usageTabSelectionProvider =
    NotifierProvider<UsageTabSelectionController, UsageTabSelection>(
      UsageTabSelectionController.new,
    );
