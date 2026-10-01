import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/shell_menu_items.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';

import '../../features/terminal/fake_instance.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/shell_menu.dart';
import '../../support/test_machine.dart';
import 'package:agent_cli/process.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

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
  late TestMachine db;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    commandKeyIsMeta = false;
    db = TestMachine();
    server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    data = await server.override();
  });
  tearDown(() {
    commandKeyIsMeta = false;
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

    final container = fakeTerminalContainer(machine: db, data: data);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens [menu] in the title bar's one menu, reads the label and the chord
  /// it draws off every item, and closes it. A row draws its chord as text,
  /// the keymap's own label for the command — so the chord is looked up by
  /// that label among the app's bindings.
  Future<List<(String, SingleActivator)>> chordsIn(
    WidgetTester tester,
    String menu,
  ) async {
    await openShellMenu(tester, menu);
    final found = <(String, SingleActivator)>[];
    for (final item in tester.widgetList<ShellMenuItem>(
      find.byType(ShellMenuItem),
    )) {
      final drawn = item.shortcut;
      if (drawn == null) continue;
      final chord = shellChords.where((c) => c.label == drawn).firstOrNull;
      found.add((
        item.label,
        chord?.activator ??
            // Drawn but in no chord at all: a key no binding can be found for.
            const SingleActivator(LogicalKeyboardKey.f24),
      ));
    }
    await closeShellMenu(tester);
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
    // A sweep that found nothing would pass silently. The terminal's chords
    // moved to View › Terminal, a submenu this sweep does not open (5c1fe3f58).
    expect(checked, greaterThanOrEqualTo(6));
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
    await openShellMenu(tester, 'Workspace');
    final quit = tester
        .widgetList<ShellMenuItem>(find.byType(ShellMenuItem))
        .singleWhere((item) => item.label == 'Quit');
    expect(quit.shortcut, '⌘Q');
    expect(
      shellChords.where((c) => c.label == quit.shortcut),
      isEmpty,
      reason: 'caught natively, so it is in no chord the engine binds',
    );
    await closeShellMenu(tester);
  });
}
