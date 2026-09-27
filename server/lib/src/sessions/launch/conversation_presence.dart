import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:agent_cli/read.dart'
    show CliStoreLocator, ConversationPresence, ConversationStoreIndex;

/// Whether an agent's own store on this server's machine holds a
/// conversation: `present` as soon as one store does, `absent` when a store
/// was read to the end without it, else `unknown` — "could not tell" never
/// refuses a resume.
class ConversationPresenceReader {
  ConversationPresenceReader({
    required this.locator,
    required this.environmentsHere,
    this.registry = AgentRegistry.builtIn,
  });

  final CliStoreLocator locator;

  /// The environments whose stores this machine reads.
  final List<ExecutionEnvironment> Function() environmentsHere;
  final AgentRegistry registry;

  Future<ConversationPresence> presenceOf(
    String agentId,
    String conversationId,
  ) async {
    final store = registry.adapterFor(agentId)?.store;
    if (store == null) return ConversationPresence.unknown;
    try {
      var answer = ConversationPresence.unknown;
      for (final located in await locator.locate(environmentsHere())) {
        final home = located.homeFor(agentId);
        if (home == null) continue;
        final found = await const ConversationStoreIndex().presenceOf(
          storeHome: home,
          store: store,
          conversationId: conversationId,
        );
        if (found == ConversationPresence.present) return found;
        if (found == ConversationPresence.absent) answer = found;
      }
      return answer;
    } on Object {
      return ConversationPresence.unknown;
    }
  }
}
