import 'package:agent_cli/discovery.dart';
import 'package:agent_cli/usage.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../sessions/application/session_providers.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../data/agents_data.dart';
import 'agent_installations_controller.dart';
import 'agent_providers.dart';

/// **Usage as the server reads it.** The server asks each agent's usage
/// endpoint on its own schedule — the floor while the quota moves, longer
/// while it does not, and when a session moves — and tells this app every
/// account's state as it changes. Nothing here asks a vendor: [refresh] asks
/// the server, whose throttle decides whether that costs a request.
class UsageReadings {
  UsageReadings(this._work, this._now);

  final AgentWorkData _work;
  final DateTime Function() _now;

  /// [installation]'s account as the server last read it, or null before it
  /// has said anything of it.
  AccountUsageState? stateOf(AgentInstallation installation) =>
      _work.usage[usageAccountKey(installation)];

  /// The last reading of [installation]'s account, however old.
  AgentUsage? remembered(AgentInstallation installation) =>
      stateOf(installation)?.usage;

  /// The wait the server is sitting out for this account, or null.
  UsageException? pendingPause(AgentInstallation installation) {
    final failure = stateOf(installation)?.failure;
    final until = failure?.until;
    if (failure == null || until == null || !until.isAfter(_now())) {
      return null;
    }
    return failure.toException(_now());
  }

  /// How long until the server asks about this account on its own.
  Duration dueIn(AgentInstallation installation) {
    final next = stateOf(installation)?.nextAt;
    if (next == null) return Duration.zero;
    final left = next.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Asks the server to read [installation]'s account now and answers the
  /// reading. Throws [UsageException] with the server's words when there is
  /// none.
  Future<AgentUsage> fetch(AgentInstallation installation) async {
    final key = usageAccountKey(installation);
    final List<AccountUsageState> states;
    try {
      states = await _work.refreshUsage(key);
    } on DataRefused catch (refusal) {
      throw UsageException(refusal.message, kind: UsageFailureKind.notAsked);
    }
    final state = states.where((s) => s.accountKey == key).firstOrNull;
    return _readingOf(state);
  }

  /// Asks the server to read [accountKey] now; what it read arrives as a
  /// change.
  Future<void> refresh(String accountKey) =>
      _work.refreshUsage(accountKey).then((_) {}, onError: (Object _) {});

  AgentUsage _readingOf(AccountUsageState? state) {
    final failure = state?.failure;
    if (failure != null) throw failure.toException(_now());
    return state?.usage ??
        (throw UsageException(
          'The server has not read this account yet.',
          kind: UsageFailureKind.notAsked,
        ));
  }
}

final usageReadingsProvider = Provider<UsageReadings>(
  (ref) => UsageReadings(
    ref.watch(agentWorkProvider),
    () => ref.read(clockProvider).nowUtc(),
  ),
);

/// One account's state as the server tells it, rebuilt when it changes.
final accountUsageProvider = Provider.autoDispose
    .family<AccountUsageState?, String>((ref, accountKey) {
      final usage = ref.watch(agentWorkProvider).usage;
      final current = usage[accountKey];
      // Only this account's change rebuilds it: a chip on one account does
      // not repaint for another's reading.
      final listening = usage.changes.listen((_) {
        if (!identical(usage[accountKey], current)) ref.invalidateSelf();
      });
      ref.onDispose(listening.cancel);
      return current;
    });

/// Live usage for one installation's account, as the server last read it:
/// the reading, the last attempt's failure, or loading before the server has
/// said anything.
final agentUsageProvider = Provider.autoDispose
    .family<AsyncValue<AgentUsage>, AgentInstallation>((ref, installation) {
      final state = ref.watch(
        accountUsageProvider(usageAccountKey(installation)),
      );
      final failure = state?.failure;
      if (failure != null) {
        return AsyncError(
          failure.toException(ref.read(clockProvider).nowUtc()),
          StackTrace.empty,
        );
      }
      final usage = state?.usage;
      return usage == null ? const AsyncLoading() : AsyncData(usage);
    });

/// **Whose quota one session is spending**: keyed by session, not by whatever
/// is focused. Null — and no chip at all — for an agent with no endpoint.
final usageInstallationForSessionProvider = Provider.autoDispose
    .family<AgentInstallation?, String>((ref, sessionId) {
      ref.watchSessionKinds(const {SessionChangeKind.membership});
      final session = ref.read(sessionsDataProvider).getById(sessionId);
      if (session == null) return null;
      for (final installation in ref.watch(
        agentInstallationsControllerProvider,
      )) {
        if (installation.id != session.agentInstallationId) continue;
        final usage = ref
            .watch(agentRegistryProvider)
            .adapterFor(installation.agentId)
            ?.usage;
        return usage == null ? null : installation;
      }
      return null;
    });
