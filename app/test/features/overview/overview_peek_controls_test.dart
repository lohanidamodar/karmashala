import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/session_more_button.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/overview/presentation/overview_peek.dart';
import 'package:karmashala/src/features/overview/presentation/session_fact_list.dart';
import 'package:karmashala/src/features/sessions/presentation/operator_chip.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala/src/features/sessions/application/session_launcher.dart'
    show kPermissionCycleSettle;
import 'package:karmashala/src/features/sessions/presentation/delivery_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/permission_mode_chip.dart';
import 'package:karmashala/src/app/widgets/status_strip.dart';
import 'package:karmashala/src/features/sessions/presentation/model_chip.dart';
import 'package:karmashala/src/features/sessions/presentation/session_notice_line.dart';
import 'package:karmashala_session/launch.dart' show SessionSurface;
import 'package:karmashala_session/session.dart';

import '../../support/fake_data_server.dart';
import '../../support/fixtures.dart';
import '../../support/test_machine.dart';
import '../terminal/fake_instance.dart';

/// **The session's own controls in the dashboard's peek** (round 56, item
/// 6): the bar's widgets — not copies — so a choice made in the peek is the
/// one the session's tab shows.
void main() {
  late TestMachine db;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(820, 600),
    double textScale = 1,
    double? stripWidth,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = TestMachine();
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(windowsEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    server.installationRows.insert(
      agentInstallation(agentId: AgentIds.claudeCode),
    );
    db.server.sessionRows.insert(
      Session(
        id: 's1',
        repositoryId: repository().id,
        agentInstallationId: agentInstallation(agentId: AgentIds.claudeCode).id,
        title: 'Session',
        useWorktree: false,
        status: SessionStatus.running,
        createdAt: testTime,
        surface: SessionSurface.pane,
        permissionMode: 'mode=manual',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          await server.override(),
          ...fakeTerminalOverrides(machine: db),
          conversationPresenceProvider.overrideWithValue(
            ({
              required descriptor,
              required environmentId,
              required conversationId,
            }) async => ConversationPresence.unknown,
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: stripWidth ?? size.width,
                    child: const OverviewPeekControls(sessionId: 's1'),
                  ),
                ),
                // What the session's own tab draws on its bar.
                const KeyedSubtree(
                  key: ValueKey('the-tab'),
                  child: PermissionModeChip(sessionId: 's1'),
                ),
                const SessionNoticeLine(sessionId: 's1'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inList(Finder matching) =>
      find.descendant(of: find.byType(SessionFactList), matching: matching);

  Finder inPeek(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('overview-peek-controls')),
    matching: matching,
  );

  testWidgets('the bar\'s own controls, each for this session', (tester) async {
    await pump(tester);

    expect(
      tester.widget<SessionModelChip>(inPeek(find.byType(SessionModelChip))),
      isA<SessionModelChip>().having((c) => c.sessionId, 'sessionId', 's1'),
    );
    expect(inPeek(find.byType(PermissionModeChip)), findsOneWidget);
    expect(
      tester.widget<DeliveryStrip>(inPeek(find.byType(DeliveryStrip))),
      isA<DeliveryStrip>().having((c) => c.sessionId, 'sessionId', 's1'),
    );
    expect(
      tester.widget<SessionMoreButton>(inPeek(find.byType(SessionMoreButton))),
      isA<SessionMoreButton>().having((c) => c.sessionId, 'sessionId', 's1'),
    );
  });

  testWidgets('a permission chosen in the peek is the one the tab shows', (
    tester,
  ) async {
    await pump(tester);

    await tester.tap(inPeek(find.byType(PermissionModeChip)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Build · Accept edits').last);
    await tester.pumpAndSettle();
    await tester.pump(kPermissionCycleSettle * 2);
    await tester.pumpAndSettle();

    expect(
      db.server.sessionRows.getById('s1')!.permissionMode,
      'mode=acceptEdits',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('the-tab')),
        matching: find.text('Build · Accept edits'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('at 360 px and text scale 1.6 it fits, the verbs in reach', (
    tester,
  ) async {
    await pump(tester, size: const Size(360, 640), textScale: 1.6);

    expect(tester.takeException(), isNull);
    // Short of room, ⋯ gives its place to +N, whose sheet holds its verbs.
    final fold = tester.getRect(inPeek(find.byKey(StatusStrip.foldKey)));
    expect(fold.right, lessThanOrEqualTo(360));
    await tester.tap(inPeek(find.byKey(StatusStrip.foldKey)));
    await tester.pumpAndSettle();
    expect(find.byType(SessionFactList), findsOneWidget);
    expect(inList(find.text('Rename')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('the +N list (round 66)', () {
    Future<void> openList(
      WidgetTester tester, {
      Size size = const Size(360, 800),
      double textScale = 1,
      double? stripWidth,
    }) async {
      await pump(
        tester,
        size: size,
        textScale: textScale,
        stripWidth: stripWidth,
      );
      await tester.tap(inPeek(find.byKey(StatusStrip.foldKey)));
      await tester.pumpAndSettle();
      expect(find.byType(SessionFactList), findsOneWidget);
    }

    /// A row with something to say has height; one without draws nothing.
    bool drawn(WidgetTester tester, String id) {
      final row = inList(find.byKey(ValueKey('session-list:$id')));
      return row.evaluate().isNotEmpty && tester.getSize(row).height > 0;
    }

    testWidgets('one row per fact, under its group', (tester) async {
      await openList(tester);
      for (final group in const [
        'STATUS',
        'AGENT',
        'CODE',
        'WHERE',
        'SESSION',
      ]) {
        expect(inList(find.text(group)), findsOneWidget, reason: group);
      }
      for (final id in const [
        'model',
        'permission',
        'operator',
        'place',
        'delivery',
        'open',
        'rename',
        'more',
        'subagents',
      ]) {
        expect(drawn(tester, id), isTrue, reason: id);
      }
      // The repository, starred as the primary and saying so.
      expect(
        inList(find.byKey(ValueKey('session-repository:${repository().id}'))),
        findsOneWidget,
      );
      expect(inList(find.text('Primary')), findsOneWidget);
      // A fact with nothing to say draws no row: no mode, no origin here.
      expect(drawn(tester, 'mode'), isFalse);
      expect(drawn(tester, 'origin'), isFalse);
    });

    testWidgets('Operate Karmashala is one row, a switch', (tester) async {
      await openList(tester);
      expect(inList(find.textContaining('Operate')), findsOneWidget);
      expect(inList(find.byType(OperatorChip)), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('session-list:operator')),
          matching: find.byType(Switch),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a picker opens from its row', (tester) async {
      await openList(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('session-list:permission')),
          matching: find.byType(PermissionModeChip),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Follow the Settings default'), findsOneWidget);
      expect(find.text('Build · Accept edits'), findsWidgets);
    });

    testWidgets("the session's verbs are labelled rows", (tester) async {
      await openList(tester);
      // The session menu every place has, as rows (round 66).
      for (final label in const [
        'Open in a tab',
        'Continue with…',
        'Rename',
        'More…',
        'Subagents and child sessions',
      ]) {
        expect(inList(find.text(label)), findsOneWidget, reason: label);
      }
      // The old row of bare glyphs is gone.
      expect(find.byType(SessionMoreBody), findsNothing);
    });

    testWidgets('a bottom sheet on a phone', (tester) async {
      await openList(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('a popover on a desktop, of the token width', (tester) async {
      await openList(tester, size: const Size(1100, 800), stripWidth: 360);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('status-strip-sheet'))).width,
        lessThanOrEqualTo(DialogWidth.popover),
      );
    });

    for (final (size, strip) in const [
      (Size(360, 800), null),
      (Size(390, 844), null),
      (Size(1100, 800), 360.0),
    ]) {
      testWidgets('${size.width.round()} px at text 1.6: nothing overflows', (
        tester,
      ) async {
        await openList(tester, size: size, textScale: 1.6, stripWidth: strip);
        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(
          find.byKey(const ValueKey('status-strip-sheet')),
        );
        for (final id in const ['model', 'permission', 'place']) {
          final row = tester.getRect(find.byKey(ValueKey('session-list:$id')));
          expect(row.right, lessThanOrEqualTo(sheet.right + 0.5), reason: id);
        }
      });
    }
  });
}
