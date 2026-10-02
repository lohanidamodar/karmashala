import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import '../data/data_service.dart';

/// The server's agent registry as it stands now: the shipped agents plus one
/// adapter per ACP agent a person added, recomposed whenever those rows
/// change. A reader that must see a row added after start reads [current]
/// each time rather than keeping a registry of its own.
class AgentRegistryHolder {
  AgentRegistryHolder([AgentRegistry? initial])
    : _current = initial ?? AgentRegistry.builtIn;

  /// Composed from [rows]; [follow] keeps it so.
  AgentRegistryHolder.composed(Iterable<AcpAgentRow> rows)
    : _current = compose(rows);

  AgentRegistry _current;

  AgentRegistry get current => _current;

  /// The shipped agents plus [rows] as adapters.
  static AgentRegistry compose(Iterable<AcpAgentRow> rows) =>
      AgentRegistry.withExtra([for (final row in rows) acpAgentAdapter(row)]);

  void replace(AgentRegistry registry) => _current = registry;

  /// Recomposes from [data]'s rows after every write that touched them.
  void follow(DataService data) {
    data.addChangeListener((changes) {
      if (changes.any((change) => change is AcpAgentsChange)) {
        _current = compose(data.acpAgents);
      }
    });
  }
}
