import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../data/acp_agents_data.dart';
import 'acp_agent_providers.dart';

/// Gives a registry-sourced ACP agent row kept before icons were stored —
/// or whose entry gained one since — the icon URL its registry entry names,
/// so the agent is drawn with it everywhere. Runs when the catalog is
/// fetched ([fillFrom]) and after a Discover or at launch ([fillMissing]),
/// which fetches the catalog only when some row lacks an icon and has not
/// been asked about in this run.
class AcpAgentIconBackfill {
  AcpAgentIconBackfill(this._ref);

  final Ref _ref;

  /// Registry ids already looked up this run and found to name no icon, so a
  /// launch does not fetch the catalog again for them.
  final _withoutIcon = <String>{};

  /// The rows that could still gain an icon.
  List<AcpAgentRow> get missing => [
    for (final row in _ref.read(acpAgentRowsProvider))
      if (row.iconUrl == null &&
          row.registryId != null &&
          !_withoutIcon.contains(row.registryId))
        row,
  ];

  /// Fetches the catalog when a row lacks an icon and fills in what it
  /// names; answers how many rows gained one. Never throws: an unreachable
  /// registry leaves the rows as they are, to be asked again.
  Future<int> fillMissing() async {
    if (missing.isEmpty) return 0;
    final AcpRegistryCatalog catalog;
    try {
      catalog = await _ref.read(acpRegistryCatalogProvider.future);
    } on Object {
      return 0;
    }
    return fillFrom(catalog);
  }

  /// The one fill per fetched catalog, so the fetch's own fill and a caller
  /// awaiting the same catalog share one pass and one answer. A catalog
  /// lives for a dialog; a row saved from it carries its icon already.
  final _filled = Expando<Future<int>>();

  /// Fills in the icons [catalog] names for the rows lacking one; answers
  /// how many rows gained one.
  Future<int> fillFrom(AcpRegistryCatalog catalog) =>
      _filled[catalog] ??= _fill(catalog);

  Future<int> _fill(AcpRegistryCatalog catalog) async {
    var filled = 0;
    for (final row in missing) {
      final icon = catalog.byId(row.registryId!)?.icon?.trim();
      if (icon == null || icon.isEmpty) {
        _withoutIcon.add(row.registryId!);
        continue;
      }
      try {
        await _ref
            .read(acpAgentsDataProvider)
            .put(
              id: row.id,
              name: row.name,
              command: row.command,
              args: row.args,
              env: row.env,
              source: row.source,
              registryId: row.registryId,
              iconUrl: icon,
            );
        filled++;
      } on Object {
        // Left for the next look; the server said why.
      }
    }
    return filled;
  }
}

final acpAgentIconBackfillProvider = Provider<AcpAgentIconBackfill>(
  AcpAgentIconBackfill.new,
);
