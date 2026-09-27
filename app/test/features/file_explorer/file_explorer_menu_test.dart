import 'package:agent_cli/process.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_providers.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fake_data_server.dart';
import 'explorer_fixture.dart';

/// Right-clicking a row in the Files side panel.
///
/// The server names the file's place on this machine (slice 3c); these tests
/// pin that the menu reaches the file manager with it, that the entry is
/// withheld where it could not work, and that a failure is said out loud
/// rather than swallowed.
void main() {
  const root = r'C:\src\app';

  late FakeCommandRunner host;
  late List<String> copied;

  setUp(() {
    host = FakeCommandRunner();
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Pumps the panel over a fixed two-row listing. With [onThisMachine]
  /// false the server runs elsewhere, so nothing it holds has a path here.
  Future<void> pump(WidgetTester tester, {bool onThisMachine = true}) async {
    final server = FakeDataServer();
    final client = await tester.runAsync(
      () => server.connect(serverOnThisMachine: onThisMachine),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dataClientProvider.overrideWithValue(client!),
          ...explorerOverrides(root, {
            root: [
              dirEntry(r'C:\src\app\lib'),
              fileEntry(r'C:\src\app\pubspec.yaml'),
            ],
          }, host: host),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 320, child: FileExplorerView())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, String label) async {
    final target = find.text(label);
    expect(target, findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(target),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Taps a menu entry whose action asks the server first.
  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
  }

  testWidgets('a folder and a file row offer reveal and copy path', (
    tester,
  ) async {
    await pump(tester);

    await rightClick(tester, 'lib');
    expect(find.text('Open in File Explorer'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await rightClick(tester, 'pubspec.yaml');
    // Named for what it does: a file is shown *inside* its folder.
    expect(find.text('Reveal in File Explorer'), findsOneWidget);
  });

  testWidgets('revealing a folder opens it, at the place the server named', (
    tester,
  ) async {
    await pump(tester);
    await rightClick(tester, 'lib');

    await choose(tester, 'Open in File Explorer');

    expect(host.requests.single.executable, 'explorer.exe');
    expect(host.requests.single.arguments, [r'C:\src\app\lib']);
  });

  testWidgets('revealing a file selects it inside its folder', (tester) async {
    await pump(tester);
    await rightClick(tester, 'pubspec.yaml');

    await choose(tester, 'Reveal in File Explorer');

    expect(host.requests.single.arguments, [
      r'/select,C:\src\app\pubspec.yaml',
    ]);
  });

  testWidgets('a file opens with its default app, as a double-click would', (
    tester,
  ) async {
    await pump(tester);
    await rightClick(tester, 'pubspec.yaml');

    await choose(tester, 'Open with default app');

    expect(host.requests.single.executable, 'explorer.exe');
    expect(host.requests.single.arguments, [r'C:\src\app\pubspec.yaml']);
  });

  test('a program is offered as Run, not as opening it', () {
    expect(runsAsProgram('Setup.EXE'), isTrue);
    expect(runsAsProgram('build.bat'), isTrue);
    expect(runsAsProgram('script.ps1'), isFalse);
    expect(runsAsProgram('notes.md'), isFalse);
  });

  testWidgets('copy path puts the row on the clipboard', (tester) async {
    await pump(tester);
    await rightClick(tester, 'pubspec.yaml');

    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();

    expect(copied, [r'C:\src\app\pubspec.yaml']);
    expect(find.text('Path copied to clipboard'), findsOneWidget);
  });

  testWidgets('reveal is withheld where this machine has no path', (
    tester,
  ) async {
    await pump(tester, onThisMachine: false);

    await rightClick(tester, 'lib');

    expect(find.text('Open in File Explorer'), findsNothing);
    expect(find.text('Reveal in File Explorer'), findsNothing);
    expect(find.text('Copy path'), findsOneWidget);
    expect(host.requests, isEmpty);
  });

  /// The half a right-click cannot do: every file must be reachable from the
  /// keyboard with its actions.
  testWidgets('Shift+F10 and the Menu key open the same menu', (tester) async {
    await pump(tester);

    Focus.of(tester.element(find.text('lib'))).requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pumpAndSettle();
    expect(find.text('Open in File Explorer'), findsOneWidget);

    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();
    expect(copied, [r'C:\src\app\lib']);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(find.text('Open in File Explorer'), findsOneWidget);
  });

  testWidgets('a reveal that fails anyway says so', (tester) async {
    host.throwError = CommandException('not found');
    await pump(tester);
    await rightClick(tester, 'lib');

    await choose(tester, 'Open in File Explorer');

    expect(find.textContaining('not found'), findsOneWidget);
  });
}
