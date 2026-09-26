import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_terminal_runtime/instances.dart';

import 'fake_instance.dart';

/// A pane whose session lives on the session host, recording the order of the
/// two things that can happen to it: the host ending the session, and the link
/// being dropped.
class _Hosted extends FakeTerminalInstance implements HostedTerminalInstance {
  _Hosted({required super.id, required super.title, required super.profileId});

  final events = <String>[];
  bool running = true;
  final ended = Completer<void>();

  @override
  bool get outlivesApp => running;

  @override
  String get keptBy => 'the session host';

  @override
  Future<void> endHostedSession() {
    events.add('end');
    return ended.future;
  }

  @override
  void dispose() {
    events.add('dispose');
    super.dispose();
  }
}

/// "End session" on a pane the session host keeps: the host ends it, and only
/// then is the link dropped — a drop alone is a disconnect, and the session
/// went on running on the host.
void main() {
  late ProviderContainer container;
  late List<_Hosted> built;

  setUp(() {
    built = [];
    container = ProviderContainer(
      overrides: fakeTerminalOverrides(
        instanceFactory:
            ({
              required id,
              required profile,
              workingDirectory,
              restoredScrollback,
              shellIntegration = false,
              agentLaunch,
              adoptTerminal,
            }) {
              final pane = _Hosted(
                id: id,
                title: profile.label,
                profileId: profile.id,
              );
              built.add(pane);
              return pane;
            },
      ),
    );
    addTearDown(container.dispose);
  });

  TerminalSessionsController sessions() =>
      container.read(terminalSessionsControllerProvider.notifier);

  String openPane() {
    sessions().openTab(TerminalProfile.powerShell);
    return container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .layout
        .panes
        .first;
  }

  test('ending asks the host first, and drops the link only after', () async {
    final paneId = openPane();
    final pane = built.single;

    sessions().endSession(paneId);
    expect(pane.events, ['end'], reason: 'not disposed while the end is out');

    pane.ended.complete();
    await pumpEventQueue();
    expect(pane.events, ['end', 'dispose']);
  });

  test("the tab's own End session ends it too", () async {
    openPane();
    final pane = built.single;
    final tabId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .id;

    sessions().closeTab(tabId, detach: false);
    pane.ended.complete();
    await pumpEventQueue();

    expect(pane.events, ['end', 'dispose']);
  });

  test('closing a tab is a view act: the session is left running', () async {
    openPane();
    final pane = built.single;
    final tabId = container
        .read(terminalSessionsControllerProvider)
        .tabs
        .last
        .id;

    sessions().closeTab(tabId);
    await pumpEventQueue();

    expect(pane.events, isNot(contains('end')));
  });

  test(
    'a session that already exited has nothing on the host to end',
    () async {
      final paneId = openPane();
      final pane = built.single..running = false;

      sessions().endSession(paneId);
      await pumpEventQueue();

      expect(pane.events, ['dispose']);
    },
  );

  testWidgets('a host that never answers cannot hold the pane', (tester) async {
    final paneId = openPane();
    final pane = built.single;

    sessions().endSession(paneId);
    await tester.pump(const Duration(seconds: 6));

    expect(pane.events, ['end', 'dispose']);
  });
}
