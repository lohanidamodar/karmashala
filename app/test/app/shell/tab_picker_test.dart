import 'package:karmashala/src/app/shell/quick_open/quick_open_item.dart';
import 'package:karmashala/src/app/shell/tab_picker.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The tabs the picker is showing, mutable so a close really removes one.
  late List<String> tabs;
  late String active;
  late List<String> switchedTo;
  late List<String> closed;

  /// Where each tab is, so two `zsh` tabs are told apart by something.
  const whereabouts = {
    'zsh-1': 'Fix login redirect · /src/app',
    'zsh-2': 'Write release notes · /src/docs',
    'vite': 'Dev server · /src/web',
  };

  setUp(() {
    tabs = ['zsh-1', 'zsh-2', 'vite'];
    active = 'zsh-2';
    switchedTo = [];
    closed = [];
  });

  /// The picker's titles are deliberately duplicated for the shell tabs — that
  /// is the case the whereabouts line exists for.
  String titleOf(String id) => id.startsWith('zsh') ? 'zsh' : 'vite';

  List<TabEntry> entries(WidgetRef ref) => [
    for (final id in tabs)
      TabEntry(
        item: QuickOpenItem(
          id: id,
          group: QuickOpenGroup.tabs,
          title: titleOf(id),
          subtitle: whereabouts[id],
          icon: AppIcons.terminal,
          onSelect: () => switchedTo.add(id),
        ),
        active: id == active,
        onClose: () {
          closed.add(id);
          tabs.remove(id);
        },
      ),
  ];

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => TabPicker.show(context, entries),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> type(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('lists every tab and marks the one on screen', (tester) async {
    await open(tester);

    expect(find.text('zsh'), findsNWidgets(2));
    expect(find.text('vite'), findsOneWidget);
    expect(find.text('3 tabs'), findsOneWidget);
    // Exactly one row says where you already are.
    expect(find.text('current'), findsOneWidget);
  });

  testWidgets('every row says where its tab is, so two zsh tabs differ', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Fix login redirect · /src/app'), findsOneWidget);
    expect(find.text('Write release notes · /src/docs'), findsOneWidget);
  });

  testWidgets('Enter switches to the highlighted tab and closes the list', (
    tester,
  ) async {
    await open(tester);

    // The cursor starts on the tab you are already in, so Enter alone is a
    // no-op and one arrow press is the next tab.
    await press(tester, LogicalKeyboardKey.enter);

    expect(switchedTo, ['zsh-2']);
    expect(find.byType(TabPicker), findsNothing);
  });

  testWidgets('the arrows move the cursor off the active tab', (tester) async {
    await open(tester);

    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);

    expect(switchedTo, ['vite']);
  });

  testWidgets('Home and End reach both ends without wrapping', (tester) async {
    await open(tester);

    await press(tester, LogicalKeyboardKey.home);
    // Already at the top: this must not wrap round to the bottom.
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.enter);
    expect(switchedTo, ['zsh-1']);

    switchedTo.clear();
    await open(tester);
    await press(tester, LogicalKeyboardKey.end);
    await press(tester, LogicalKeyboardKey.enter);
    expect(switchedTo, ['vite']);
  });

  testWidgets('a filter finds a tab by title', (tester) async {
    await open(tester);

    await type(tester, 'vite');

    // Asserted on the whereabouts line: a matched title is drawn as rich text
    // with the hit characters picked out, and is not one `Text` any more.
    expect(find.text('Dev server · /src/web'), findsOneWidget);
    expect(find.text('Fix login redirect · /src/app'), findsNothing);
    expect(find.text('1 tab'), findsOneWidget);
  });

  testWidgets('a filter finds a tab by its session and by its directory', (
    tester,
  ) async {
    await open(tester);

    // Nothing in the *title* says "login": the session is the only way in.
    await type(tester, 'login');
    expect(find.text('Fix login redirect · /src/app'), findsOneWidget);
    expect(find.text('1 tab'), findsOneWidget);

    await type(tester, 'src/docs');
    expect(find.text('Write release notes · /src/docs'), findsOneWidget);
    expect(find.text('1 tab'), findsOneWidget);
  });

  testWidgets('Enter after a filter opens the tab the filter found', (
    tester,
  ) async {
    await open(tester);

    await type(tester, 'login');
    await press(tester, LogicalKeyboardKey.enter);

    expect(switchedTo, ['zsh-1']);
  });

  testWidgets('closing from the list closes that tab and drops its row', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(find.byTooltip('Close vite'));
    await tester.pumpAndSettle();

    expect(closed, ['vite']);
    expect(find.text('vite'), findsNothing);
    expect(find.text('2 tabs'), findsOneWidget);
    // Closing is not switching.
    expect(switchedTo, isEmpty);
    expect(find.byType(TabPicker), findsOneWidget);
  });

  testWidgets('Escape dismisses without switching', (tester) async {
    await open(tester);

    await press(tester, LogicalKeyboardKey.escape);

    expect(find.byType(TabPicker), findsNothing);
    expect(switchedTo, isEmpty);
  });

  testWidgets('it opens in the frame quick open does, not a fixed inset', (
    tester,
  ) async {
    // The smallest window: quick open's inset follows the window's height, and
    // the picker kept a desktop 64px that the window does not have to spare.
    tester.view.physicalSize = const Size(720, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);

    final top = tester
        .getTopLeft(
          find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byType(Material),
              )
              .first,
        )
        .dy;
    expect(top, closeTo(560 * 0.09, 0.5));
  });

  testWidgets('Page Down moves the cursor as in quick open', (tester) async {
    tabs = [for (var i = 0; i < 20; i++) 'tab-$i'];
    active = 'tab-0';
    await open(tester);

    await press(tester, LogicalKeyboardKey.pageDown);
    await press(tester, LogicalKeyboardKey.enter);

    expect(switchedTo, ['tab-8']);
  });

  testWidgets('a hundred tabs stay findable', (tester) async {
    tabs = [for (var i = 0; i < 100; i++) 'tab-$i'];
    active = 'tab-0';
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => TabPicker.show(context, (ref) {
                  return [
                    for (final id in tabs)
                      TabEntry(
                        item: QuickOpenItem(
                          id: id,
                          group: QuickOpenGroup.tabs,
                          title: 'zsh',
                          subtitle: '/src/$id',
                          icon: AppIcons.terminal,
                          onSelect: () => switchedTo.add(id),
                        ),
                        active: id == active,
                      ),
                  ];
                }),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('100 tabs'), findsOneWidget);
    // Virtualised: a hundred identical rows are not a hundred built widgets.
    expect(find.text('zsh').evaluate().length, lessThan(100));

    // The whole point: one of a hundred `zsh` tabs, reached by typing.
    await type(tester, 'tab-77');
    expect(find.text('1 tab'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);
    expect(switchedTo, ['tab-77']);
  });
}
