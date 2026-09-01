import 'package:karmashala/src/app/shell/reveal_in_file_manager.dart';
import 'package:karmashala/src/core/process/command_runner.dart';
import 'package:karmashala/src/core/process/path_translator.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/environments/domain/execution_environment.dart';
import 'package:karmashala/src/features/environments/domain/local_environment.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/fixtures.dart';

/// Right-clicking a row in the Files side panel.
///
/// "in sidebar files panel right click menu to open any file or folder in
/// system file explorer". The reveal is the app's existing
/// [RevealInFileManager]; these tests pin that the menu reaches it, that the
/// entry is withheld where it could not work, and that a failure is said out
/// loud rather than swallowed.
void main() {
  const root = r'C:\src\app';
  const folder = DirEntry(
    name: 'lib',
    isDirectory: true,
    windowsPath: r'C:\src\app\lib',
  );
  const file = DirEntry(
    name: 'pubspec.yaml',
    isDirectory: false,
    windowsPath: r'C:\src\app\pubspec.yaml',
  );

  final windows = ExecutionEnvironment(
    id: localWindowsEnvironmentId,
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: testTime,
  );

  late FakeCommandRunner host;
  late List<String> copied;

  setUp(() {
    host = FakeCommandRunner();
    copied = [];
    // The clipboard is a platform channel; record what would have been put on
    // it instead of reaching one.
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

  /// Pumps the panel over a fixed two-row listing.
  ///
  /// [environments] is what the reveal helper is allowed to resolve; an empty
  /// list is a host that cannot place the path at all, which is the case the
  /// menu entry has to withhold itself for.
  Future<void> pump(
    WidgetTester tester, {
    List<ExecutionEnvironment> environments = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedRepoWindowsRootProvider.overrideWithValue(root),
          directoryListingProvider.overrideWith(
            (ref, dir) async => dir == root ? const [folder, file] : const [],
          ),
          revealInFileManagerProvider.overrideWithValue(
            RevealInFileManager(
              host: host,
              translator: const PathTranslator(),
              environmentFor: (id) =>
                  environments.where((e) => e.id == id).firstOrNull,
              fileManagerOverride: HostFileManager.windowsExplorer,
            ),
          ),
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

  testWidgets('a folder row offers reveal and copy path', (tester) async {
    await pump(tester, environments: [windows]);

    await rightClick(tester, 'lib');

    expect(find.text('Open in File Explorer'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
  });

  testWidgets('a file row offers reveal and copy path', (tester) async {
    await pump(tester, environments: [windows]);

    await rightClick(tester, 'pubspec.yaml');

    // Named for what it does: a file is shown *inside* its folder.
    expect(find.text('Reveal in File Explorer'), findsOneWidget);
    expect(find.text('Copy path'), findsOneWidget);
  });

  testWidgets('revealing a folder opens it through the shared action', (
    tester,
  ) async {
    await pump(tester, environments: [windows]);
    await rightClick(tester, 'lib');

    await tester.tap(find.text('Open in File Explorer'));
    await tester.pumpAndSettle();

    expect(host.requests.single.executable, 'explorer.exe');
    expect(host.requests.single.arguments, [r'C:\src\app\lib']);
  });

  testWidgets('revealing a file selects it inside its folder', (tester) async {
    await pump(tester, environments: [windows]);
    await rightClick(tester, 'pubspec.yaml');

    await tester.tap(find.text('Reveal in File Explorer'));
    await tester.pumpAndSettle();

    expect(host.requests.single.arguments, [
      r'/select,C:\src\app\pubspec.yaml',
    ]);
  });

  testWidgets('copy path puts the row on the clipboard', (tester) async {
    await pump(tester, environments: [windows]);
    await rightClick(tester, 'pubspec.yaml');

    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();

    expect(copied, [r'C:\src\app\pubspec.yaml']);
    expect(find.text('Path copied to clipboard'), findsOneWidget);
  });

  testWidgets('the entry is withheld where reveal cannot work', (tester) async {
    // No environment resolves, so the helper has no host spelling for the row.
    // An entry that always fails is worse than no entry — but the menu itself
    // still opens, because copying a path is still possible.
    await pump(tester);

    await rightClick(tester, 'lib');

    expect(find.text('Open in File Explorer'), findsNothing);
    expect(find.text('Reveal in File Explorer'), findsNothing);
    expect(find.text('Copy path'), findsOneWidget);
    expect(host.requests, isEmpty);
  });

  testWidgets('a reveal that fails anyway says so', (tester) async {
    // The path resolves, so the entry is offered — and then the file manager
    // will not start. Reveal reports that as an outcome, not a throw, so a
    // `catch` would never fire and the click would otherwise be silent.
    host.throwError = CommandException('not found');
    await pump(tester, environments: [windows]);
    await rightClick(tester, 'lib');

    await tester.tap(find.text('Open in File Explorer'));
    await tester.pumpAndSettle();

    expect(find.textContaining('not found'), findsOneWidget);
  });
}
