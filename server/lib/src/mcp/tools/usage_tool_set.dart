import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/usage.dart';

import '../../agents/server_usage.dart';
import 'agent_names.dart';
import 'server_tool_set.dart';

/// `get_usage`: an agent account's usage, read by the server itself (slice
/// 2a) — through the one throttled service the schedule and the phone use,
/// so an agent asking costs no request inside the account's floor. Nothing
/// is forwarded to the app.
class UsageToolSet extends ServerToolSet {
  const UsageToolSet(this._usage, {this.registry = AgentRegistry.builtIn});

  final ServerUsage _usage;
  final AgentRegistry registry;

  @override
  List<Map<String, Object?>> get schemas => usageToolSchemas;

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => runTool(() async {
    final cli = arguments['cli'] as String?;
    final environmentId = arguments['environmentId'] as String?;
    // Unnamed, the first agent in registry order whose adapter reads usage.
    final agentId =
        agentIdForName(registry, cli) ??
        registry.adapters
            .where((adapter) => adapter.usage != null)
            .firstOrNull
            ?.id;
    if (agentId == null) throw StateError('No agent here reports usage.');
    final account = _usage
        .accounts()
        .where(
          (i) =>
              i.agentId == agentId &&
              (environmentId == null || i.environmentId == environmentId),
        )
        .firstOrNull;
    if (account == null) throw StateError('No $agentId installation found.');
    final state = (await _usage.refresh(
      accountKey: usageAccountKey(account),
    )).single;
    final failure = state.failure;
    if (failure != null) {
      throw StateError(failure.message);
    }
    final usage =
        state.usage ?? (throw StateError('No reading of $agentId yet.'));
    // A window with no reading omits `percent`: a `0` would be acted on.
    return {
      'environmentId': account.environmentId,
      'windows': [
        for (final w in usage.windows)
          {
            'label': w.label,
            if (w.percent != null) 'percent': w.percent,
            if (w.resetsAt != null) 'resetsAt': w.resetsAt!.toIso8601String(),
          },
      ],
      if (usage.tokenExpiresAt != null)
        'tokenExpiresAt': usage.tokenExpiresAt!.toIso8601String(),
      'fetchedAt': usage.fetchedAt.toIso8601String(),
    };
  });
}

/// `get_usage`'s schema, its words unchanged from the app's.
const List<Map<String, Object?>> usageToolSchemas = [
  {
    'name': 'get_usage',
    'description':
        'An agent account\'s usage against its limits, read live. cli is '
        '"claude", "codex" or "antigravity"; environmentId is optional '
        '(defaults to the first matching installation). Each window carries '
        'a label and, when the agent reported one, a "percent" used and a '
        '"resetsAt". A window with no "percent" was not measured — '
        'Antigravity names the account\'s tiers and reports no quota '
        'against them — and that absence means unknown, never zero. '
        '"fetchedAt" is when the reading was taken.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'cli': {'type': 'string'},
        'environmentId': {'type': 'string'},
      },
      'required': ['cli'],
    },
  },
];
