import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_status_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import '../terminal/fake_instance.dart';

/// The inbox listens to the foreground panes from startup, before the terminal
/// is ever opened. Asked that early, the panes must still follow the terminal
/// once it opens, or going to a session's tab never marks its items read.
void main() {
  test(
    'panes read before the terminal opened follow it once it does',
    () async {
      final container = ProviderContainer(overrides: fakeTerminalOverrides());
      addTearDown(container.dispose);
      final seen = <List<String>>[];
      container.listen(
        foregroundTerminalPaneIdsProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      expect(seen.single, isEmpty);

      final controller = container.read(
        terminalSessionsControllerProvider.notifier,
      );
      controller.openTab(TerminalProfile.powerShell);
      final pane = container
          .read(terminalSessionsControllerProvider)
          .activeTab!
          .layout
          .panes
          .single;
      await pumpEventQueue();

      expect(container.read(foregroundTerminalPaneIdsProvider), [pane]);
    },
  );
}
