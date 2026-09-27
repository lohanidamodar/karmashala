import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';

/// Opens a pane on each run the server starts while this app is connected —
/// a Flutter run or gate, a project build — attached to the session the
/// server hosts, so the person sees it as before; closing the app leaves it
/// running (slice 3d). Must be watched.
class HostedRunPanes extends Notifier<void> {
  final _seen = <String>{};

  @override
  void build() {
    final client = ref.watch(dataClientProvider);
    // Runs already going when this app joined are not opened: a restored
    // layout brings back the panes this app had.
    _seen.addAll(client.hostedRuns.keys);
    final changes = client.runsChanges.listen((change) {
      if (change case HostedRunChanged(
        :final run,
      ) when run.isLive && _seen.add(run.runId)) {
        ref
            .read(terminalSessionsControllerProvider.notifier)
            .openHostedRunTab(paneId: run.paneId, title: run.title);
      }
    });
    ref.onDispose(changes.cancel);
  }
}

final hostedRunPanesProvider = NotifierProvider<HostedRunPanes, void>(
  HostedRunPanes.new,
);
