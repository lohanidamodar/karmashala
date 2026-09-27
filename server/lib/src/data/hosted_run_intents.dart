import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

import 'data_service.dart';

/// Asks the window a person last used to show each run the server starts —
/// a Flutter run or gate, a project build — in a tab attached to it (slice
/// 5b; 3d's `HostedRunPanes` had every connected app open one). A run that
/// started with no window connected is not shown later: a restored layout
/// brings back the tabs a window had.
class HostedRunIntents {
  HostedRunIntents(this._data);

  final DataService _data;
  final _seen = <String>{};

  /// Watches [DataService.watchers] for runs starting.
  void attach() => _data.watchers.add(_watch);

  void detach() => _data.watchers.remove(_watch);

  void _watch(List<DataChange> changes) {
    for (final change in changes) {
      if (change case HostedRunChanged(:final run)
          when run.isLive && _seen.add(run.runId)) {
        _data.tellIntent(OpenTerminalTab(paneId: run.paneId, title: run.title));
      }
    }
  }
}
