import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/sessions/application/session_subagents_providers.dart';
import 'package:karmashala/src/features/sessions/presentation/session_subagents_panel.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// On desktop the subagents are a surface of the docked side panel, read beside
/// the parent's chat, not a modal drawer that has to be closed to get back to
/// it. A phone keeps its bottom sheet.
void main() {
  const list = SessionSubagentList(sessionId: 's1');

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required Size size,
    String? onScreen = 's1',
    bool room = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        panelSessionIdProvider.overrideWithValue(onScreen),
        sessionChildCountProvider.overrideWith(
          (ref, _) => (count: 2, running: 1),
        ),
        sessionSubagentsProvider.overrideWith((ref, _) => Stream.value(list)),
      ],
    );
    addTearDown(container.dispose);
    container.read(sidePanelRoomProvider.notifier).report(room);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: SessionSubagentsBadge(sessionId: 's1')),
          ),
        ),
      ),
    );
    return container;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('session-subagents-badge')));
    await tester.pumpAndSettle();
  }

  testWidgets('at desktop width the badge opens the docked Subagents surface, '
      'and no modal', (tester) async {
    final container = await pump(tester, size: const Size(1440, 900));
    await open(tester);
    expect(container.read(sidePanelProvider), SidePanelSurface.subagents);
    expect(find.byType(SessionSubagentsPanel), findsNothing);
    expect(find.byType(ModalBarrier), findsOneWidget); // the app's own route
  });

  testWidgets('a session that is not the one on screen still opens, in the '
      'drawer', (tester) async {
    final container = await pump(
      tester,
      size: const Size(1440, 900),
      onScreen: 'other',
    );
    await open(tester);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.byType(SessionSubagentsPanel), findsOneWidget);
  });

  testWidgets('a window with no room for the panel opens the drawer', (
    tester,
  ) async {
    final container = await pump(
      tester,
      size: const Size(1440, 900),
      room: false,
    );
    await open(tester);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.byType(SessionSubagentsPanel), findsOneWidget);
  });

  testWidgets('on a phone it stays a bottom sheet', (tester) async {
    final container = await pump(tester, size: const Size(390, 844));
    await open(tester);
    expect(container.read(sidePanelProvider), isNull);
    expect(find.byType(SessionSubagentsPanel), findsOneWidget);
  });

  testWidgets('the surface shows the on-screen session\'s subagents', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          panelSessionIdProvider.overrideWithValue('s1'),
          sessionSubagentsProvider.overrideWith((ref, _) => Stream.value(list)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SessionSubagentsSurface()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SessionSubagentsPanel>(find.byType(SessionSubagentsPanel))
          .sessionId,
      's1',
    );
  });

  testWidgets('with no session on screen the surface says what to do', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [panelSessionIdProvider.overrideWithValue(null)],
        child: const MaterialApp(
          home: Scaffold(body: SessionSubagentsSurface()),
        ),
      ),
    );
    expect(find.byType(SessionSubagentsPanel), findsNothing);
    expect(find.textContaining('Open a session'), findsOneWidget);
  });
}
