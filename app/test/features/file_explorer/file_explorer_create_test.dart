import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_data_server.dart';
import '../../support/temp_directory.dart';
import 'explorer_fixture.dart';

/// The Files side panel over the server (slice 3c): it lists what the server
/// lists, makes what the server makes, and lists again when the server's
/// watch says a folder changed — nothing here reads a disk.
void main() {
  late Directory tmp;
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ks-file-create');
    server = FakeDataServer();
    data = await server.override();
  });
  tearDown(() => removeTempDirectory(tmp));

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        data,
        fileTreeRootProvider.overrideWithValue(at(tmp.path)),
        activeEditorPathProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FileExplorerView())),
      ),
    );
    await settle(tester);
    return container;
  }

  test('a folder offers to make things in it; a file does not', () {
    List<String?> values(bool isDirectory) => [
      for (final item in fileEntryMenuItems(
        isDirectory: isDirectory,
        canReveal: false,
      ))
        if (item is PopupMenuItem<String>) item.value,
    ];
    expect(values(true), containsAll(['new-file', 'new-folder']));
    expect(values(false), isNot(contains('new-file')));
  });

  testWidgets('the header makes a folder at the root through the server and '
      'selects it', (tester) async {
    final container = await pump(tester);

    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'docs');
    await tester.tap(find.text('Create'));
    for (var i = 0; i < 50; i++) {
      await settle(tester);
      if (container.read(fileRevealTargetProvider) != null) break;
    }

    expect(Directory(p.join(tmp.path, 'docs')).existsSync(), isTrue);
    expect(server.filesWork.kinds, contains('files.mkdir'));
    expect(
      container.read(fileRevealTargetProvider)?.path,
      at(p.join(tmp.path, 'docs')),
    );
  });

  testWidgets('a folder the server says changed is listed again', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Empty'), findsOneWidget);
    expect(server.filesWork.watched, contains(at(tmp.path)));

    // An agent wrote a file; the server's watch tells this link.
    File(p.join(tmp.path, 'agent.txt')).writeAsStringSync('x');
    await tester.runAsync(() => server.filesWork.changed(at(tmp.path)));
    await settle(tester);

    expect(find.text('agent.txt'), findsOneWidget);
  });

  testWidgets('a name with a separator is refused in the dialog', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byTooltip('New file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '../escape.txt');
    await tester.pump();
    expect(find.textContaining('path separator'), findsOneWidget);
  });
}

/// Lets the fake server's real file I/O land: pumps, then waits a moment in
/// real time, a few times.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pump();
}
