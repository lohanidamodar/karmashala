import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// Every chord the menu bar *draws* is a chord the app actually *binds*.
///
/// Flutter is explicit that a menu registers nothing it displays —
/// `MenuItemButton.shortcut` is a label and only a label — and for several
/// loops the Workspace menu was quietly relying on that going unnoticed:
/// `Ctrl+N`, `Ctrl+Shift+N` and `Ctrl+,` were painted beside New session, New
/// project and Settings, and pressing any of them did nothing at all. A menu
/// that teaches a keystroke which does not work is worse than one that teaches
/// none, so the sweep below reads the shortcut off every item in every menu and
/// fails unless `shellShortcutMap` has it too.
void main() {
  late AppDatabase db;

  setUp(() {
    commandKeyIsMeta = false;
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
  });
  tearDown(() {
    commandKeyIsMeta = false;
    db.close();
  });

  /// `SingleActivator` has no `==`, so chords are compared by what they are.
  bool same(SingleActivator a, SingleActivator b) =>
      a.trigger == b.trigger &&
      a.control == b.control &&
      a.shift == b.shift &&
      a.alt == b.alt &&
      a.meta == b.meta;

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = fakeTerminalContainer(database: db);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens [menu], reads the label and chord off every item, and closes it.
  ///
  /// `CheckboxMenuButton` builds a `MenuItemButton` of its own, so one pass
  /// over that type covers the View menu's toggles as well.
  Future<List<(String, SingleActivator)>> chordsIn(
    WidgetTester tester,
    String menu,
  ) async {
    await tester.tap(find.text(menu));
    await tester.pumpAndSettle();
    final found = <(String, SingleActivator)>[];
    for (final button in tester.widgetList<MenuItemButton>(
      find.byType(MenuItemButton),
    )) {
      final shortcut = button.shortcut;
      if (shortcut is! SingleActivator) continue;
      final label = button.child;
      found.add((label is Text ? label.data ?? '?' : '?', shortcut));
    }
    await tester.tap(find.text(menu));
    await tester.pumpAndSettle();
    return found;
  }

  testWidgets('every chord the menus draw is one the app binds', (
    tester,
  ) async {
    await pumpShell(tester);
    final bound = shellShortcutMap.keys.whereType<SingleActivator>().toList();

    var checked = 0;
    for (final menu in ['Workspace', 'View', 'Tools']) {
      for (final (label, chord) in await chordsIn(tester, menu)) {
        expect(
          bound.any((b) => same(b, chord)),
          isTrue,
          reason:
              '$menu → "$label" shows a shortcut the app never registers. '
              'Declare it in shellChords, or stop drawing it.',
        );
        checked++;
      }
    }
    // A sweep that found nothing would pass silently.
    expect(checked, greaterThanOrEqualTo(8));
  });

  testWidgets('the three the menu used to only pretend to have now work', (
    tester,
  ) async {
    await pumpShell(tester);
    final workspace = await chordsIn(tester, 'Workspace');
    final tools = await chordsIn(tester, 'Tools');

    SingleActivator chordFor(
      List<(String, SingleActivator)> menu,
      String label,
    ) => menu.firstWhere((e) => e.$1 == label).$2;

    final newSession = chordFor(workspace, 'New session');
    expect(newSession.trigger, LogicalKeyboardKey.keyN);
    expect(newSession.shift, isFalse);

    final newProject = chordFor(workspace, 'New project');
    expect(newProject.trigger, LogicalKeyboardKey.keyN);
    expect(newProject.shift, isTrue);

    expect(chordFor(tools, 'Settings').trigger, LogicalKeyboardKey.comma);

    // The claim the sweep above makes, spelled out for these three.
    for (final chord in [newSession, newProject, chordFor(tools, 'Settings')]) {
      expect(
        shellShortcutMap.keys.whereType<SingleActivator>().any(
          (b) => same(b, chord),
        ),
        isTrue,
      );
    }
  });

  testWidgets('the View menu shows the inbox chord it always had', (
    tester,
  ) async {
    // Ctrl+Shift+A has opened the inbox since it was bound; the menu just
    // never drew it, so the only way to learn it was to read the source. This
    // labels a key that already works rather than claiming a new one — and the
    // other side-panel surfaces stay bare, which is the whole point.
    await pumpShell(tester);
    final view = await chordsIn(tester, 'View');
    final inbox = view.where((e) => e.$1 == 'Inbox').single.$2;
    expect(inbox.trigger, LogicalKeyboardKey.keyA);
    expect(inbox.shift, isTrue);
    expect(
      view.where((e) => e.$1 == 'Changes' || e.$1 == 'Todos'),
      isEmpty,
      reason: 'only the surface with a chord should advertise one',
    );
  });

  testWidgets('Ctrl+N is offered back to the shell, Ctrl+Shift+N is not', (
    tester,
  ) async {
    // ^N is readline's next-history, so who gets it is a real question and
    // Settings must list it. A terminal cannot encode Ctrl+Shift+<letter> at
    // all, so the shifted one is not a question and is not listed.
    final n = shellChords.firstWhere((c) => c.label == 'Ctrl+N');
    expect(n.contested, isTrue);
    expect(n.shellCost, contains('next-history'));
    expect(
      shellChords.firstWhere((c) => c.label == 'Ctrl+Shift+N').contested,
      isFalse,
    );
  });

  testWidgets('Quit shows ⌘Q on a Mac and nothing anywhere else', (
    tester,
  ) async {
    // Ctrl+Q is XON — the key that resumes output after Ctrl+S paused it — so
    // Quit is bound on the one platform whose command modifier is not a
    // terminal control key, and left alone on the two where it is. The macOS
    // keystroke is caught natively in `MainFlutterWindow`, ahead of the engine,
    // which is why it is the one label here with no entry in the chord map.
    await pumpShell(tester);
    expect(
      (await chordsIn(tester, 'Workspace')).where((e) => e.$1 == 'Quit'),
      isEmpty,
      reason: 'Ctrl+Q must never be advertised: it is XON',
    );

    commandKeyIsMeta = true;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await pumpShell(tester);
    final quit = (await chordsIn(tester, 'Workspace'))
        .where((e) => e.$1 == 'Quit')
        .single
        .$2;
    expect(quit.trigger, LogicalKeyboardKey.keyQ);
    expect(quit.meta, isTrue);
    expect(quit.control, isFalse);
  });
}
