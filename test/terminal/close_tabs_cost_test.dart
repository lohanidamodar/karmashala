import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/terminal_workspace_dao.dart';
import 'package:karmashala/src/features/terminal/domain/terminal_profile.dart';
import 'package:karmashala/src/features/terminal/presentation/terminal_panel.dart';

import '../features/terminal/fake_instance.dart';

/// What clearing the deck is allowed to cost.
///
/// The bulk closes could have been a loop over `closeTab`, and that loop would
/// have been correct and unbearable: every tab republishing the whole workspace
/// to every consumer and writing the whole workspace to disk. Closing twenty
/// tabs is one act, so it is one publish and one save — and these count them,
/// because a cost test counts work rather than timing it.
void main() {
  late AppDatabase db;
  late _CountingWorkspaceDao dao;
  late ProviderContainer container;
  late TerminalSessionsController controller;

  setUp(() {
    db = AppDatabase.memory();
    dao = _CountingWorkspaceDao(db);
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        terminalWorkspaceDaoProvider.overrideWithValue(dao),
      ],
    );
    controller = container.read(terminalSessionsControllerProvider.notifier);
  });

  tearDown(() {
    container.dispose();
    db.close();
  });

  List<String> openTabs(int count) => [
    for (var i = 0; i < count; i++)
      controller.openTab(TerminalProfile.powerShell),
  ];

  /// Counts every state the controller publishes while [act] runs.
  int publishesDuring(void Function() act) {
    var published = 0;
    final sub = container.listen(
      terminalSessionsControllerProvider,
      (_, _) => published++,
    );
    act();
    sub.close();
    return published;
  }

  test('closing five tabs at once is one publish and one save', () {
    final ids = openTabs(6);
    final savesBefore = dao.saves;

    final publishes = publishesDuring(() => controller.closeTabs(ids.skip(1)));

    expect(publishes, 1);
    expect(dao.saves - savesBefore, 1);
    expect(container.read(terminalTabsProvider).map((t) => t.id), [ids.first]);
  });

  test('the same five one at a time is what that saves', () {
    // The contrast the number above only means something against: a loop over
    // `closeTab` is five of each, and the bulk verb exists to not be that.
    final ids = openTabs(6);
    final savesBefore = dao.saves;

    final publishes = publishesDuring(() {
      for (final id in ids.skip(1)) {
        controller.closeTab(id);
      }
    });

    expect(publishes, 5);
    expect(dao.saves - savesBefore, 5);
  });

  test('ids that name no tab cost nothing at all', () {
    openTabs(2);
    final savesBefore = dao.saves;

    final publishes = publishesDuring(() => controller.closeTabs(['gone']));

    expect(publishes, 0);
    expect(dao.saves - savesBefore, 0);
    expect(container.read(terminalTabsProvider), hasLength(2));
  });

  test('a bulk close keeps the tab it was invoked from in front', () {
    final ids = openTabs(4);
    controller.activateTab(ids[3]);

    controller.closeTabs([ids[2], ids[3]], activate: ids[1]);

    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      ids[1],
    );
  });

  group('TabCloseScope', () {
    const ids = ['a', 'b', 'c', 'd'];

    test('names the set it closes', () {
      expect(TabCloseScope.others.apply(ids, 1), ['a', 'c', 'd']);
      expect(TabCloseScope.toTheRight.apply(ids, 1), ['c', 'd']);
      expect(TabCloseScope.toTheLeft.apply(ids, 2), ['a', 'b']);
      expect(TabCloseScope.all.apply(ids, 2), ids);
    });

    test('says when it would close nothing', () {
      expect(TabCloseScope.toTheRight.closesAnything(3, 4), isFalse);
      expect(TabCloseScope.toTheRight.closesAnything(2, 4), isTrue);
      expect(TabCloseScope.toTheLeft.closesAnything(0, 4), isFalse);
      expect(TabCloseScope.toTheLeft.closesAnything(1, 4), isTrue);
      for (final scope in TabCloseScope.values) {
        expect(scope.closesAnything(0, 1), isFalse, reason: scope.label);
      }
    });
  });
}

/// The workspace dao, counting the writes the controller asks it for.
class _CountingWorkspaceDao extends TerminalWorkspaceDao {
  _CountingWorkspaceDao(super.db);

  int saves = 0;

  @override
  void saveWorkspace(
    List<StoredTerminalTab> tabs, {
    String? activeTabId,
    bool userClosed = false,
  }) {
    saves++;
    super.saveWorkspace(tabs, activeTabId: activeTabId, userClosed: userClosed);
  }
}
