import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/capabilities/capabilities.dart';
import '../../../core/data/data_client.dart';
import '../../../core/data/data_providers.dart';
import '../../explorer/application/session_diff_stat.dart'
    show sessionProjectIdsProvider;

/// The server's agent tool access settings, as it last told.
final toolAccessProvider = StreamProvider<McpToolAccessPolicy>((ref) {
  final client = ref.watch(dataClientProvider);
  return (() async* {
    yield client.toolAccess;
    yield* client.toolAccessChanges;
  })();
});

/// Changing them. The server owns the policy, whole, and tells every client.
class ToolAccessActions {
  const ToolAccessActions(this._client);

  final DataClient _client;

  Future<void> set(McpToolAccessPolicy policy) => _client.write(
    AgentsToolAccessSet(policy: policy.toJson()),
    domain: DataDomain.sessions,
  );
}

final toolAccessActionsProvider = Provider<ToolAccessActions>(
  (ref) => ToolAccessActions(ref.watch(dataClientProvider)),
);

/// The tool groups session [sessionId] may use without Operate Karmashala, by
/// its project's settings; null on an older server, where the grant alone
/// decides.
final sessionToolGroupsOpenProvider = Provider.autoDispose
    .family<List<McpToolGroup>?, String>((ref, sessionId) {
      final offered = ref.watch(
        capabilitiesProvider.select(
          (c) => c.serverOffers(AgentsToolAccessSet.feature),
        ),
      );
      if (!offered) return null;
      final policy =
          ref.watch(toolAccessProvider).value ?? McpToolAccessPolicy.defaults;
      final projectId = ref.watch(
        sessionProjectIdsProvider.select((ids) => ids[sessionId]),
      );
      return policy.groupsOpen(projectId: projectId);
    });
