import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/dropped_paths.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_file_drop.dart';
import 'package:karmashala_terminal_core/profiles.dart';

import 'fake_instance.dart';

/// A file dragged from the Files panel onto a session's pane lands exactly as
/// one dragged in from the OS: its path, pasted at the prompt.
void main() {
  testWidgets('a Files panel drag pastes the path into the pane', (
    tester,
  ) async {
    final container = fakeTerminalContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      terminalSessionsControllerProvider.notifier,
    );
    controller.openTab(TerminalProfile.powerShell);
    final paneId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .layout
        .panes
        .first;
    final written = <String>[];
    controller.instanceFor(paneId)!.terminal.onOutput = written.add;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Draggable<HostPathDrag>(
                  data: HostPathDrag(['/tmp/shot.png']),
                  feedback: SizedBox(width: 10, height: 10),
                  child: SizedBox(width: 80, height: 40, child: Text('drag')),
                ),
                Expanded(
                  child: TerminalFileDrop(
                    paneId: paneId,
                    child: const SizedBox.expand(key: Key('pane')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('drag')),
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byKey(const Key('pane'))));
    await tester.pump();
    expect(find.text('Drop to paste the path'), findsOneWidget);
    await gesture.up();
    await tester.pump();

    expect(written.join(), contains('/tmp/shot.png '));
    expect(find.text('Drop to paste the path'), findsNothing);
  });
}
