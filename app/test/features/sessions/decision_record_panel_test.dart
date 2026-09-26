import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/side_panel.dart';
import 'package:karmashala/src/app/shell/side_panel_state.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/sessions/application/session_decision_providers.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/sessions/data/sessions_data.dart';
import 'package:karmashala/src/features/sessions/presentation/decision_record_panel.dart';

import '../../support/fake_data_server.dart';
import '../../support/fakes.dart';
import '../terminal/fake_instance.dart';
import '../../support/fixtures.dart';
import 'package:agent_cli/process.dart';

/// The records, counting the decision reads the panel costs.
///
/// The number, not a proxy for it: every row the surface draws comes through
/// [decisionsFor], so a closed panel that reads zero has subscribed to nothing.
class _CountingRecords extends SessionRecordsData {
  _CountingRecords(super.client);

  int reads = 0;

  @override
  List<DecisionRecord> decisionsFor(String sessionId) {
    reads++;
    return super.decisionsFor(sessionId);
  }
}

/// **The decision record, as a person can finally read it.**
///
/// The finding this closes: the record shapes every handoff prompt — it is
/// rendered *ahead* of the quoted transcript — and its only reader in the app
/// was `HandoffPacket`. Nobody could see what the next agent would be told, and
/// nobody could add the constraint they had just imposed out loud.
void main() {
  final recordedAt = testTime.add(const Duration(hours: 1));
  late AppDatabase db;
  late FakeDataServer server;
  _CountingRecords? counting;
  int reads() => counting?.reads ?? 0;

  setUp(() {
    db = AppDatabase.memory();
    server = FakeDataServer()..sessionRows.insert(session());
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
  });
  tearDown(() => db.close());

  void seed() {
    server.decisionRows.append(
      DecisionRecord(
        sessionId: 's1',
        kind: DecisionKind.constraintAccepted,
        summary: 'Windows is the primary target; nothing may need WSL.',
        origin: DecisionOrigin.decisionTool,
        decidedBy: 'Claude Code',
        recordedAt: recordedAt,
      ),
    );
    server.decisionRows.append(
      DecisionRecord(
        sessionId: 's1',
        kind: DecisionKind.approachRejected,
        summary: 'The isolate pool deadlocked on Windows.',
        detail: 'Two runs, both hung on the second spawn.',
        origin: DecisionOrigin.decisionTool,
        decidedBy: 'Claude Code',
        recordedAt: recordedAt,
      ),
    );
  }

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final client = await server.connect();
    final records = counting = _CountingRecords(client);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        dataClientProvider.overrideWithValue(client),
        sessionRecordsProvider.overrideWithValue(records),
        decisionsPanelSessionIdProvider.overrideWithValue('s1'),
        // Two hours after the writing, so the age on each row is the test's own
        // arithmetic rather than the wall clock's.
        clockProvider.overrideWithValue(
          FixedClock(recordedAt.add(const Duration(hours: 2))),
        ),
      ],
    );
    addTearDown(container.dispose);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// The rail's own glyph. Once the panel is open its header carries the same
  /// label, so the button has to be named by the thing only the rail has.
  Finder railButton() => find.descendant(
    of: find.bySemanticsLabel(SidePanelSurface.decisions.label),
    matching: find.byType(InkWell),
  );

  test('Decisions is offered on the rail like any other surface', () {
    expect(
      SidePanelSurface.offered(debugMode: false),
      contains(SidePanelSurface.decisions),
    );
    // It describes a *session*'s record, not the selected checkout, so the
    // repository context line above the scoped surfaces would answer a question
    // nobody asked here.
    expect(SidePanelSurface.decisions.scopedToRepository, isFalse);
    expect(SidePanel.iconFor(SidePanelSurface.decisions).fontPackage, 'picons');
  });

  testWidgets('the rail opens it and lists the record, oldest first', (
    tester,
  ) async {
    seed();
    final container = await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();

    expect(container.read(sidePanelProvider), SidePanelSurface.decisions);
    expect(find.byType(DecisionRecordPanel), findsOneWidget);
    expect(
      find.text('Windows is the primary target; nothing may need WSL.'),
      findsOneWidget,
    );
    expect(
      find.text('The isolate pool deadlocked on Windows.'),
      findsOneWidget,
    );
    // The kind is a heading a reader scans, not a stored enum name.
    expect(find.text(DecisionKind.constraintAccepted.label), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#2'), findsOneWidget);
  });

  testWidgets('every row says who decided it, how old it is and from what', (
    tester,
  ) async {
    seed();
    await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();

    // §19 at the line the reading is on.
    expect(find.textContaining('2h ago'), findsNWidgets(2));
    expect(find.textContaining('Claude Code'), findsNWidgets(2));
    expect(
      find.textContaining(DecisionOrigin.decisionTool.label),
      findsNWidgets(2),
    );
    // Never a bare timestamp.
    expect(find.textContaining(recordedAt.toLocal().toString()), findsNothing);
  });

  testWidgets('an empty record reads as not recorded, never as nothing '
      'decided', (tester) async {
    await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();

    expect(find.textContaining('Not recorded'), findsOneWidget);
    expect(find.textContaining('explicit acts'), findsOneWidget);
    expect(find.textContaining('No decisions'), findsNothing);
  });

  testWidgets('a person can record one, and it lands through the recorder', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Record a decision'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'What was decided'),
      'The device claim is per session, not per device.',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record'));
    await tester.pumpAndSettle();

    final stored = server.decisionRows.forSession('s1');
    expect(stored, hasLength(1));
    expect(
      stored.single.summary,
      'The device claim is per session, not per device.',
    );
    // A person's row is its own origin: filing it as an agent's tool call would
    // misattribute the one kind of row that carries the most authority.
    expect(stored.single.origin, DecisionOrigin.userEntry);
    expect(stored.single.decidedBy, 'the user');
    // And the panel shows it without anything having polled.
    expect(
      find.text('The device claim is per session, not per device.'),
      findsOneWidget,
    );
  });

  testWidgets('a blank summary cannot be recorded', (tester) async {
    await pumpApp(tester);

    await tester.tap(railButton());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Record a decision'));
    await tester.pumpAndSettle();

    // The recorder drops a blank summary; a button that appeared to work would
    // hide that, so it is disabled instead.
    final record = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Record'),
    );
    expect(record.onPressed, isNull);
  });

  test('a person may not write a verdict or a marked checkpoint', () {
    // Both would name a run or a checkpoint that does not exist — the argument
    // `DecisionControlTools` makes about an agent, unchanged by the writer
    // being a person.
    expect(
      kHandWritableKinds,
      isNot(contains(DecisionKind.verificationVerdict)),
    );
    expect(kHandWritableKinds, isNot(contains(DecisionKind.checkpointMarked)));
    expect(kHandWritableKinds, contains(DecisionKind.approvalGranted));
  });

  testWidgets('a closed panel costs zero decision reads', (tester) async {
    seed();
    final container = await pumpApp(tester);

    // The panel opens on Changes, so Decisions has never been built.
    expect(reads(), 0);
    expect(container.exists(sessionDecisionsProvider('s1')), isFalse);

    await tester.tap(railButton());
    await tester.pumpAndSettle();
    expect(reads(), greaterThan(0));

    // Closing it disposes the subscription again — nothing keeps reading behind
    // a panel nobody is looking at.
    await tester.tap(railButton());
    await tester.pumpAndSettle();
    final settled = reads();
    expect(container.exists(sessionDecisionsProvider('s1')), isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(reads(), settled, reason: 'nothing polls');
  });
}
