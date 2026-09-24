import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/file_explorer/application/file_explorer_providers.dart';
import 'package:karmashala/src/features/file_explorer/data/file_listing_service.dart';
import 'package:karmashala/src/features/file_explorer/presentation/file_explorer_view.dart';
import 'package:path/path.dart' as p;

/// Making a file or folder from the Files side panel.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ks-file-create'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('the service', () {
    const service = FileListingService();

    test('makes a folder and an empty file where it was asked', () async {
      final folder = await service.createDirectory(tmp.path, 'lib');
      final file = await service.createFile(folder, 'main.dart');
      expect(Directory(folder).existsSync(), isTrue);
      expect(File(file).readAsStringSync(), isEmpty);
      expect(p.dirname(file), folder);
    });

    test('refuses a name that is already there, file or folder', () async {
      File(p.join(tmp.path, 'a.txt')).writeAsStringSync('keep me');
      await expectLater(
        service.createFile(tmp.path, 'a.txt'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        service.createDirectory(tmp.path, 'a.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(tmp.path, 'a.txt')).readAsStringSync(), 'keep me');
    });
  });

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

  testWidgets('the header makes a folder at the root and selects it', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        selectedRepoWindowsRootProvider.overrideWithValue(tmp.path),
        activeEditorHostPathProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FileExplorerView())),
      ),
    );

    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'docs');
    await tester.tap(find.text('Create'));
    // The create is real file I/O, which fake time does not advance: pump so
    // the dialog's answer reaches it, then wait on the disk in real time.
    for (var i = 0; i < 50; i++) {
      await tester.pump();
      if (container.read(fileRevealTargetProvider) != null) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }

    expect(Directory(p.join(tmp.path, 'docs')).existsSync(), isTrue);
    expect(
      container.read(fileRevealTargetProvider)?.hostPath,
      p.join(tmp.path, 'docs'),
    );
  });

  testWidgets('a name with a separator is refused in the dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedRepoWindowsRootProvider.overrideWithValue(tmp.path),
          activeEditorHostPathProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: Scaffold(body: FileExplorerView())),
      ),
    );
    await tester.tap(find.byTooltip('New file'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '../escape.txt');
    await tester.pump();
    expect(find.textContaining('path separator'), findsOneWidget);
  });
}
