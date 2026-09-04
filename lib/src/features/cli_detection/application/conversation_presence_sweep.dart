import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/util/clock_provider.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/domain/agent_descriptor.dart';
import '../../environments/application/environment_providers.dart';
import '../domain/conversation_presence.dart';
import 'cli_detection_providers.dart';
import 'cli_detection_service.dart';

/// One reading of every CLI store, able to answer [ConversationPresence] for
/// any number of conversations without touching the disk again.
///
/// The bulk counterpart of `conversationPresenceProvider`, and deliberately the
/// **same rule** rather than a second opinion:
///
/// * found in *any* located store → [ConversationPresence.present], because
///   finding the conversation anywhere at all is proof it exists, and a user
///   who moved a repository between WSL and Windows must not have their history
///   called missing;
/// * only the store belonging to the session's own environment may say
///   [ConversationPresence.absent] — it is the one the agent would have written
///   to;
/// * everything else is [ConversationPresence.unknown].
///
/// The two must agree, because they are asked about the same rows for opposite
/// reasons: the single-row probe decides whether to *refuse a resume*, and this
/// one decides what to *offer for deletion*. A sweep that called something
/// absent which the resume path would have found would be offering a live
/// conversation up for removal.
///
/// **Why a snapshot object and not a provider per row.** A `family` provider
/// would make each row a cache entry and each cache entry a scan; this is one
/// pass, held by value, whose cost is O(stores × agents with a store format)
/// and flat in the number of rows asked about. It is never built on a timer and
/// never on app start — see [conversationPresenceSweepProvider].
class ConversationPresenceSweep {
  const ConversationPresenceSweep({
    required this.idsByEnvironmentAndAgent,
    required this.checkedAt,
  });

  /// Nothing was read at all. Every question answers
  /// [ConversationPresence.unknown], which is the honest state for a machine
  /// whose stores could not be located.
  ConversationPresenceSweep.empty(DateTime checkedAt)
    : this(idsByEnvironmentAndAgent: const {}, checkedAt: checkedAt);

  /// `'<environmentId>/<agentId>'` → the conversation ids that store holds, or
  /// `null` for a store that told us nothing.
  ///
  /// A key with a `null` value is the case that matters: the store was located
  /// and *asked*, and could not answer. Distinguishing that from an absent key
  /// is what keeps an unreachable WSL share out of the delete list.
  final Map<String, Set<String>?> idsByEnvironmentAndAgent;

  /// When this reading was taken. Rendered with `describeAge` wherever it is
  /// shown, for the reason §19 gives: a reading that is not live must not look
  /// live.
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

/// Reads every located store once, on demand.
///
/// A `Provider` returning a function rather than a `FutureProvider`, for the
/// third rule in §19: probes cost real work and must never run because
/// something watched them. Nothing here is built when the app starts, when a
/// row is drawn, or on a tick — it runs when a user asks a question that needs
/// it.
final conversationPresenceSweepProvider =
    Provider<Future<ConversationPresenceSweep> Function()>((ref) {
      return () async {
        final now = ref.read(clockProvider).nowUtc();
        final registry = ref.read(agentRegistryProvider);
        // Only agents that keep a store we know how to read. An agent with no
        // format contributes no key, so every question about it answers
        // `unknown` rather than being judged against a store nobody read.
        final formats = <String, AgentStoreFormat>{
          for (final descriptor in registry.descriptors)
            if (descriptor.store case final spec?)
              if (spec.format != AgentStoreFormat.none)
                descriptor.id: spec.format,
        };
        if (formats.isEmpty) return ConversationPresenceSweep.empty(now);

        final List<CliStore> stores;
        try {
          final environments = ref.read(executionEnvironmentDaoProvider).getAll();
          stores = await ref.read(cliStoreLocatorProvider).locate(environments);
        } on Object {
          // We could not even find out where to look. Nothing read, so nothing
          // claimed.
          return ConversationPresenceSweep.empty(now);
        }

        final index = ref.read(conversationStoreIndexProvider);
        final ids = <String, Set<String>?>{};
        for (final store in stores) {
          for (final entry in formats.entries) {
            final home = store.homesByAgentId[entry.key];
            if (home == null) continue;
            ids['${store.environmentId}/${entry.key}'] = await index.idsIn(
              storeHome: home,
              format: entry.value,
            );
          }
        }
        return ConversationPresenceSweep(
          idsByEnvironmentAndAgent: ids,
          checkedAt: now,
        );
      };
    });
