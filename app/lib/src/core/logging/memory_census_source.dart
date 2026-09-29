import 'package:riverpod/riverpod.dart';

import 'package:karmashala_core/logging.dart';

import '../../features/notifications/application/notification_providers.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'diagnostics_providers.dart';

/// One reading of what this app is holding, taken from [container].
///
/// Every provider is reached through `exists`: creating the terminal controller
/// would restore a whole layout, so a census must never be the thing that
/// builds what it counts. A subsystem that has not been started this run reads
/// as zero, which is what it is holding. So does every one while no server
/// session is open (a null [container], mid-switch): only the process's own
/// figures are read then.
MemoryCensus takeMemoryCensus(ProviderContainer? container) {
  final resident = readProcessResident();
  final panes = container != null &&
          container.exists(terminalSessionsControllerProvider)
      ? container
            .read(terminalSessionsControllerProvider.notifier)
            .paneFootprint
      : (live: 0, detached: 0, unparsedPanes: 0, rows: 0, heldChars: 0);
  return MemoryCensus(
    residentBytes: resident.resident,
    peakResidentBytes: resident.peak,
    panes: panes.live,
    detachedPanes: panes.detached,
    unparsedPanes: panes.unparsedPanes,
    scrollbackRows: panes.rows,
    heldScrollbackChars: panes.heldChars,
    watchedSessions:
        container != null && container.exists(sessionStatusRegistryProvider)
        ? container.read(sessionStatusRegistryProvider).trackedCount
        : 0,
    logLinesHeld: (container?.read(diagnosticsProvider) ?? Diagnostics.instance)
        .buffer
        .length,
  );
}
