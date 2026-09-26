import 'package:karmashala/src/features/explorer/application/explorer_actions.dart';
import 'package:karmashala/src/features/sessions/application/session_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_runtime/persistence.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_dormant_resume_test.dart'
    show containerOver, layoutOf, paneOf, seededDatabase, startSession;

/// Resuming everything a restart left dormant, and what it is allowed to cost.
///
/// The owner asked for the button — *"give me an easy button to resume all
/// active tabs"* — and, in the same breath, said what the naive version of it
/// feels like: *"starting each session took a lot of CPU and RAM and it was
/// lagging for some time. After I pressed Start on one and tried to switch to
/// another it was very laggy."*
///
/// So the shape of the verb is as much the feature as the verb is. Four resumes
/// in a plain `for` loop are one unbroken block of main-isolate work with four
/// full layout writes in it, and nothing yields, so the window is frozen for
/// the sum. These count both halves of the answer: **one** layout write for the
/// whole bulk, and a frame handed back between every pane.
void main() {
  /// Opens four sessions in [container] and returns their ids.
  Future<List<String>> startFour(ProviderContainer container) async {
    final ids = <String>[];
    for (var i = 0; i < 4; i++) {
      ids.add(await startSession(container, externalId: 'ext-$i'));
    }
    return ids;
  }

  test('resuming four restored sessions is one layout write, where four '
      'separate resumes are four', () async {
    final db = await seededDatabase();

    final first = containerOver(db);
    final sessions = await startFour(first);
    final panes = [for (final id in sessions) paneOf(first, id)];
    first.read(terminalSessionsControllerProvider.notifier).persistLayout();
    first.dispose();

    // --- the bulk verb -------------------------------------------------------
    final bulkDao = _CountingLayoutDao(layoutOf(db));
    final bulk = containerOver(
      db,
      idPrefix: 't-',
      layoutDao: bulkDao,
      frameYield: () async {},
    );
    addTearDown(bulk.dispose);
    for (final paneId in panes) {
      expect(
        bulk.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.restored,
      );
    }
    final before = bulkDao.saves;

    final report = await bulk
        .read(explorerActionsProvider)
        .resumeAllRestoredPanes();

    expect(report.resumed, 4);
    expect(report.refused, 0);
    expect(report.message, isNull);
    for (final paneId in panes) {
      expect(
        bulk.read(terminalSessionsControllerProvider).livenessOf(paneId),
        PaneLiveness.live,
      );
    }
    final bulkWrites = bulkDao.saves - before;
    expect(
      bulkWrites,
      1,
      reason:
          'the layout changed once as far as the user is concerned, and '
          '`withOneLayoutSave` is what makes that one write',
    );

    // --- the same four, one at a time ---------------------------------------
    // The number the bulk verb is being measured against, taken rather than
    // assumed: a loop over the single-pane verb writes the whole layout per
    // pane, which is the cost `closeTabs` refused for the same reason.
    final soloDao = _CountingLayoutDao(layoutOf(db));
    final solo = containerOver(
      db,
      idPrefix: 'u-',
      layoutDao: soloDao,
      frameYield: () async {},
    );
    addTearDown(solo.dispose);
    // The list first, so building the controller (and whatever its restore
    // writes) is not counted as one of the four.
    final dormant = solo
        .read(terminalSessionsControllerProvider.notifier)
        .restoredAgentPanes();
    expect(dormant, hasLength(4));
    final soloBefore = soloDao.saves;
    for (final paneId in dormant) {
      await solo.read(explorerActionsProvider).resumeRestoredPane(paneId);
    }

    expect(soloDao.saves - soloBefore, greaterThan(bulkWrites));
    expect(soloDao.saves - soloBefore, 4);
  });

  test('a frame is handed back between every pane, and not around the '
      'edges', () async {
    final db = await seededDatabase();

    final first = containerOver(db);
    final sessions = await startFour(first);
    final panes = [for (final id in sessions) paneOf(first, id)];
    first.read(terminalSessionsControllerProvider.notifier).persistLayout();
    first.dispose();

    var yields = 0;
    final next = containerOver(
      db,
      idPrefix: 't-',
      frameYield: () async => yields++,
    );
    addTearDown(next.dispose);

    final report = await next
        .read(explorerActionsProvider)
        .resumeAllRestoredPanes();

    expect(report.resumed, 4);
    expect(
      yields,
      panes.length - 1,
      reason:
          'one pane per frame: three gaps between four panes, and no wait '
          'before the first or after the last, which would only be a delay',
    );
  });

  test('nothing dormant is nothing done, and no frame given up', () async {
    final db = await seededDatabase();
    var yields = 0;
    final container = containerOver(db, frameYield: () async => yields++);
    addTearDown(container.dispose);

    // A live session, which is not what this acts on.
    await startSession(container);

    final report = await container
        .read(explorerActionsProvider)
        .resumeAllRestoredPanes();

    expect(report.resumed, 0);
    expect(report.refused, 0);
    expect(report.message, isNull);
    expect(yields, 0);
  });

  test('one session that cannot be resumed does not hold the other three '
      'back, and is still reported', () async {
    final db = await seededDatabase();

    final first = containerOver(db);
    final sessions = await startFour(first);
    // The CLI never named this conversation, so resuming it would open a *new*
    // one wearing this row's title — the one thing every resume path refuses.
    first.read(sessionsDataProvider).updateExternalSessionId(sessions[1], '');
    final panes = [for (final id in sessions) paneOf(first, id)];
    first.read(terminalSessionsControllerProvider.notifier).persistLayout();
    first.dispose();

    final next = containerOver(db, idPrefix: 't-', frameYield: () async {});
    addTearDown(next.dispose);

    final report = await next
        .read(explorerActionsProvider)
        .resumeAllRestoredPanes();

    expect(report.resumed, 3);
    expect(report.refused, 1);
    expect(report.message, isNotNull);
    final state = next.read(terminalSessionsControllerProvider);
    expect(state.livenessOf(panes[1]), PaneLiveness.restored);
    for (final paneId in [panes[0], panes[2], panes[3]]) {
      expect(state.livenessOf(paneId), PaneLiveness.live);
    }
  });
}

class _CountingLayoutDao extends TerminalLayoutDao {
  _CountingLayoutDao(super.db);

  int saves = 0;

  @override
  void saveLayout(
    List<StoredTerminalTab> tabs, {
    String? activeTabId,
    bool userClosed = false,
  }) {
    saves++;
    super.saveLayout(tabs, activeTabId: activeTabId, userClosed: userClosed);
  }
}
