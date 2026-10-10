import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/agents_data.dart';

/// **One signed-in account**, however many environments it is signed in from:
/// Codex on Windows and Codex in WSL under the same email are one quota, so
/// one entry. The server keys usage by agent and environment; this merges
/// those readings by agent and email.
@immutable
class UsageAccount {
  const UsageAccount({
    required this.agentId,
    required this.email,
    required this.latest,
    required this.states,
  });

  final String agentId;

  /// Who is signed in, or null when the reading did not say — and then the
  /// entry is its one environment's alone.
  final String? email;

  /// The newest reading of the account, which is what is shown.
  final AccountUsageState latest;

  /// Every environment's state for the account, newest reading first.
  final List<AccountUsageState> states;

  List<String> get environmentIds => [for (final s in states) s.environmentId];

  Set<String> get accountKeys => {for (final s in states) s.accountKey};

  /// The highest percentage any window of [latest] reports, or null when it
  /// reports none.
  double? get tightestPercent {
    double? tightest;
    for (final window in latest.usage?.windows ?? const []) {
      final percent = window.percent;
      if (percent != null && (tightest == null || percent > tightest)) {
        tightest = percent;
      }
    }
    return tightest;
  }
}

/// The accounts [states] describe, most constrained first. A state the server
/// has neither read nor failed to read is left out — a failure alone (an
/// expired sign-in) is shown, since it is what needs doing. Ones with no email
/// are never merged, since nothing says two of them are one account.
List<UsageAccount> usageAccountsOf(Iterable<AccountUsageState> states) {
  final groups = <String, List<AccountUsageState>>{};
  for (final state in states) {
    final usage = state.usage;
    if (usage == null && state.failure == null) continue;
    final email = usage?.email;
    final key = email == null
        ? '${state.accountKey}\u0000'
        : '${state.agentId}\u0000${email.toLowerCase()}';
    (groups[key] ??= []).add(state);
  }
  final accounts = [
    for (final group in groups.values)
      () {
        // A failure with no reading sorts oldest: it has no time of its own.
        final never = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        group.sort(
          (a, b) => (b.usage?.fetchedAt ?? never).compareTo(
            a.usage?.fetchedAt ?? never,
          ),
        );
        return UsageAccount(
          agentId: group.first.agentId,
          email: group.first.usage?.email,
          latest: group.first,
          states: List.unmodifiable(group),
        );
      }(),
  ];
  accounts.sort((a, b) {
    final pa = a.tightestPercent;
    final pb = b.tightestPercent;
    if (pa == null || pb == null) {
      if (pa != pb) return pa == null ? 1 : -1;
    } else if (pa != pb) {
      return pb.compareTo(pa);
    }
    return a.agentId.compareTo(b.agentId);
  });
  return accounts;
}

/// Every account the server has a usage reading for, merged and ordered.
final usageAccountsProvider = Provider.autoDispose<List<UsageAccount>>((ref) {
  final usage = ref.watch(agentWorkProvider).usage;
  final listening = usage.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(listening.cancel);
  return usageAccountsOf(usage.values);
});

/// One agent's accounts, for a list grouped by agent.
@immutable
class UsageAccountGroup {
  const UsageAccountGroup({required this.agentId, required this.accounts});

  final String agentId;
  final List<UsageAccount> accounts;
}

/// [accounts] grouped by agent: each group keeps [accounts]' order, and the
/// groups come in the order of their first account — so with
/// [usageAccountsOf]'s order, the most constrained agent leads.
List<UsageAccountGroup> usageAccountGroupsOf(List<UsageAccount> accounts) {
  final groups = <String, List<UsageAccount>>{};
  for (final account in accounts) {
    (groups[account.agentId] ??= []).add(account);
  }
  return [
    for (final MapEntry(:key, :value) in groups.entries)
      UsageAccountGroup(agentId: key, accounts: List.unmodifiable(value)),
  ];
}
