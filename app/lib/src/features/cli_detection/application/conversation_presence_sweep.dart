import 'package:riverpod/riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import 'package:agent_cli/descriptors.dart';
import '../../environments/application/environment_providers.dart';
import 'package:agent_cli/read.dart';
import 'cli_detection_providers.dart';

/// One reading of every CLI store, answering [ConversationPresence] for any
/// number of conversations — the same rule as `conversationPresenceProvider`.
class ConversationPresenceSweep {
  const ConversationPresenceSweep({
    required this.idsByEnvironmentAndAgent,
    required this.checkedAt,
  });

  /// Nothing was read at all, so every question answers
  /// [ConversationPresence.unknown].
  ConversationPresenceSweep.empty(DateTime checkedAt)
    : this(idsByEnvironmentAndAgent: const {}, checkedAt: checkedAt);

  /// `'<environmentId>/<agentId>'` → the ids that store holds, `null` when it
  /// was asked and could not answer — which keeps a dead share out of a delete.
  final Map<String, Set<String>?> idsByEnvironmentAndAgent;

  /// When this reading was taken. Rendered with `describeAge` wherever it is
  /// shown: a reading that is not live must not look live (§19).
  final DateTime checkedAt;

  /// How many stores answered. Zero means this sweep proves nothing.
  int get storesRead =>
      idsByEnvironmentAndAgent.values.where((ids) => ids != null).length;

  /// How many stores were located and could not be read.
  int get storesUnreadable =>
      idsByEnvironmentAndAgent.values.where((ids) => ids == null).length;

  static String _key(String environmentId, String agentId) =>
      '$environmentId/$agentId';

  ConversationPresence presenceOf({
    required String agentId,
    required String environmentId,
    required String conversationId,
  }) {
    if (conversationId.isEmpty) return ConversationPresence.unknown;
    // Anywhere at all is proof. Checked before the environment's own store so
    // that a conversation found in the wrong place is `present`, not `absent`.
    for (final entry in idsByEnvironmentAndAgent.entries) {
      if (!entry.key.endsWith('/$agentId')) continue;
      if (entry.value?.contains(conversationId) ?? false) {
        return ConversationPresence.present;
      }
    }
    if (!idsByEnvironmentAndAgent.containsKey(_key(environmentId, agentId))) {
      return ConversationPresence.unknown;
    }
    final here = idsByEnvironmentAndAgent[_key(environmentId, agentId)];
    return here == null
        ? ConversationPresence.unknown
        : ConversationPresence.absent;
  }
}

/// Reads every located store once, on demand. A function, not a `FutureProvider`
/// — a probe costs real work and must never run because something watched it.
final conversationPresenceSweepProvider =
    Provider<Future<ConversationPresenceSweep> Function()>((ref) {
      return () async {
        final now = ref.read(clockProvider).nowUtc();
        final registry = ref.read(agentRegistryProvider);
        // Only agents whose adapter can read their store; anything else adds
        // no key, so every question about it answers `unknown`.
        final readable = <String, AgentStore>{
          for (final adapter in registry.adapters)
            if (adapter.descriptor.store != null) adapter.id: ?adapter.store,
        };
        if (readable.isEmpty) return ConversationPresenceSweep.empty(now);

        final List<CliStore> stores;
        try {
          final environments = ref
              .read(executionEnvironmentDaoProvider)
              .getAll();
          stores = await ref.read(cliStoreLocatorProvider).locate(environments);
        } on Object {
          // We could not even find out where to look. Nothing read, so nothing
          // claimed.
          return ConversationPresenceSweep.empty(now);
        }

        final index = ref.read(conversationStoreIndexProvider);
        final ids = <String, Set<String>?>{};
        for (final store in stores) {
          for (final entry in readable.entries) {
            final home = store.homeFor(entry.key);
            if (home == null) continue;
            ids['${store.environmentId}/${entry.key}'] = await index.idsIn(
              storeHome: home,
              store: entry.value,
            );
          }
        }
        return ConversationPresenceSweep(
          idsByEnvironmentAndAgent: ids,
          checkedAt: now,
        );
      };
    });
