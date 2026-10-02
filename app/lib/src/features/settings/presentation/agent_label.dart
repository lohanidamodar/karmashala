import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents/application/agent_providers.dart';

/// An agent id as a person reads it — "Claude Code" rather than `claude`, and
/// an added ACP agent's own name rather than its row id. Shared, so the
/// settings surfaces cannot drift into three spellings of it.
String agentLabel(WidgetRef ref, String agentId) =>
    ref.watch(agentRegistryProvider).displayNameFor(agentId);
