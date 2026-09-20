/// The browser as the user meets it: two machines side by side, a folder made
/// from the toolbar, and a file copied across — against two real directories,
/// because a file manager that is right about a fake filesystem is worth
/// nothing.
library;

import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/files/application/file_space_providers.dart';
import 'package:karmashala/src/features/files/data/local_file_space.dart';
import 'package:karmashala/src/features/files/presentation/file_panel_view.dart';
import 'package:karmashala/src/features/files/presentation/files_tab_view.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:path/path.dart' as p;

import '../../support/temp_directory.dart';

/// Lets the panel's real file work finish and the frames it causes be drawn.
///  cannot be used here: a listing is real IO, which a pump
/// does not advance, and the spinner that covers it never stops animating.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory left;
  late Directory right;
  late ProviderContainer container;

  ExecutionEnvironment environment(String id, String name) =>
      ExecutionEnvironment(
        id: id,
        name: name,
        kind: EnvironmentKind.windowsNative,
        createdAt: DateTime.utc(2026, 9, 20),
      );

  setUp(() {
    left = Directory.systemTemp.createTempSync('ks-tab-left-');
    right = Directory.systemTemp.createTempSync('ks-tab-right-');
    container = ProviderContainer(
      overrides: [
        browsableEnvironmentsProvider.overrideWithValue([
          environment('left', 'Left machine'),
          environment('right', 'Right machine'),
        ]),
        fileSpaceProvider.overrideWith(
          (ref, id) => LocalFileSpace(
            environmentId: id,
            label: id == 'left' ? 'Left machine' : 'Right machine',
            homeAt: () async => EnvironmentPath(
              environmentId: id,
              path: id == 'left' ? left.path : right.path,
            ),
          ),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    removeTempDirectory(left);
    removeTempDirectory(right);
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: FilesTabView(
              paneId: filesPaneId(
                leftEnvironmentId: 'left',
                rightEnvironmentId: 'right',
                leftPath: left.path,
                rightPath: right.path,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('both machines are listed, each in its own folder', (
    tester,
  ) async {
    File(p.join(left.path, 'here.txt')).writeAsStringSync('left');
    File(p.join(right.path, 'there.txt')).writeAsStringSync('right');

    await pumpBrowser(tester);

    expect(find.text('here.txt'), findsOneWidget);
    expect(find.text('there.txt'), findsOneWidget);
    expect(find.text('Left machine'), findsWidgets);
    expect(find.text('Right machine'), findsWidgets);
  });

  testWidgets('New folder makes one where the panel is looking', (
    tester,
  ) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('New folder').first);
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'work');
    await tester.tap(find.text('Create'));
    await settle(tester);

    expect(Directory(p.join(left.path, 'work')).existsSync(), isTrue);
    expect(find.text('work'), findsOneWidget);
  });

  testWidgets('a name with a separator is refused in the dialog, and nothing '
      'is made', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.text('New folder').first);
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'a/b');
    await tester.tap(find.text('Create'));
    await settle(tester);

    expect(
      find.text('A name cannot contain a path separator.'),
      findsOneWidget,
    );
    expect(Directory(left.path).listSync(), isEmpty);
  });

  testWidgets('a file selected on the left is copied to the right', (
    tester,
  ) async {
    File(p.join(left.path, 'notes.md')).writeAsStringSync('carry me');

    await pumpBrowser(tester);
    await tester.tap(find.text('notes.md'));
    await settle(tester);
    await tester.tap(find.text('Copy to Right machine'));
    await settle(tester);

    expect(File(p.join(right.path, 'notes.md')).readAsStringSync(), 'carry me');
    expect(
      File(p.join(left.path, 'notes.md')).existsSync(),
      isTrue,
      reason: 'a copy leaves the original where it was',
    );
  });

  testWidgets('a folder is not copied across, and the browser says so', (
    tester,
  ) async {
    Directory(p.join(left.path, 'tree')).createSync();

    await pumpBrowser(tester);
    await tester.tap(find.text('tree'));
    await settle(tester);
    await tester.tap(find.text('Copy to Right machine'));
    await settle(tester);

    expect(find.textContaining('Folders are not copied'), findsOneWidget);
    expect(Directory(p.join(right.path, 'tree')).existsSync(), isFalse);
  });

  testWidgets('deleting asks first, and takes it once confirmed', (
    tester,
  ) async {
    File(p.join(left.path, 'gone.txt')).writeAsStringSync('bye');

    await pumpBrowser(tester);
    await tester.tap(find.text('gone.txt'));
    await settle(tester);
    await tester.tap(find.text('Delete').first);
    await settle(tester);

    expect(find.text('Delete "gone.txt"?'), findsOneWidget);
    expect(
      File(p.join(left.path, 'gone.txt')).existsSync(),
      isTrue,
      reason: 'nothing is deleted while the question is still up',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Delete'),
      ),
    );
    await settle(tester);

    expect(File(p.join(left.path, 'gone.txt')).existsSync(), isFalse);
  });

  testWidgets('a machine this build cannot browse leaves the panel saying so '
      'rather than empty', (tester) async {
    container.dispose();
    container = ProviderContainer(
      overrides: [
        browsableEnvironmentsProvider.overrideWithValue([
          environment('left', 'Left machine'),
          environment('right', 'Right machine'),
        ]),
        fileSpaceProvider.overrideWith((ref, id) => null),
      ],
    );

    await pumpBrowser(tester);

    // No panel, no crash: the spinner stands where a listing would be.
    expect(find.byType(FilePanelView), findsNothing);
  });
}
