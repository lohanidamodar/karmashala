import 'package:agent_cli/process.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/features/projects/presentation/new_project_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_files/values.dart' show FileStat;

import '../../support/fixtures.dart';
import '../../support/fake_data_server.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

/// The dialog's environment list is the one place a project's *namespace* is
/// chosen, so what it offers has to be what the app can actually create.
void main() {
  late FakeDataServer server;
  late Override data;

  setUp(() async {
    server = FakeDataServer();
    final dao = server.environmentRows
      ..upsert(windowsEnv())
      ..upsert(wslEnv())
      ..upsert(
        ExecutionEnvironment(
          id: 'ssh:h1',
          kind: EnvironmentKind.ssh,
          name: 'build-box',
          sshHostId: 'h1',
          createdAt: testTime,
        ),
      );
    expect(dao.getAll(), hasLength(3));
    data = await server.override();
  });

  Override offer({required bool createsFolders}) =>
      serverOfferProvider.overrideWithValue(
        ServerOffer(
          sameMachine: true,
          serverOs: 'windows',
          features: {if (createsFolders) ProjectFoldersCreate.feature},
        ),
      );

  Future<void> pump(
    WidgetTester tester, {
    bool createsFolders = true,
    bool viaRoute = false,
  }) async {
    final container = ProviderContainer(
      overrides: [data, offer(createsFolders: createsFolders)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: viaRoute
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => showDialog<bool>(
                        context: context,
                        builder: (_) => const NewProjectDialog(),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                )
              : const Scaffold(body: NewProjectDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (viaRoute) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> pumpDialog(WidgetTester tester) async {
    await pump(tester);
    // Open the environment dropdown.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
  }

  /// Every folder the dialog asks about is missing on the server.
  void foldersMissing() => server.filesWork.answer = (request) =>
      request is FilesStatOf ? const FileStat.absent() : FakeFilesWork.unhandled;

  Future<void> typeFolder(WidgetTester tester, String path) async {
    await tester.enterText(find.widgetWithText(TextField, 'Folder path'), path);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
  }

  Finder filled(String label) => find.widgetWithText(FilledButton, label);
  Finder outlined(String label) => find.widgetWithText(OutlinedButton, label);

  testWidgets('an SSH environment is offered as a target', (tester) async {
    await pumpDialog(tester);

    expect(find.text('SSH · build-box'), findsOneWidget);
  });

  testWidgets('WSL rows are labelled WSL and Windows is labelled Windows', (
    tester,
  ) async {
    await pumpDialog(tester);

    expect(find.text('Windows'), findsWidgets);
    expect(find.text('WSL · Ubuntu'), findsWidgets);
  });

  group('the buttons', () {
    testWidgets('plain Create is the main one, Create & scan the second', (
      tester,
    ) async {
      await pump(tester);

      expect(filled('Create'), findsOneWidget);
      expect(outlined('Create & scan'), findsOneWidget);
      expect(filled('Create & scan'), findsNothing);
    });

    testWidgets('a Git URL leaves only Clone & create', (tester) async {
      await pump(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Git repository URL (optional)'),
        'https://github.com/o/repo.git',
      );
      await tester.pumpAndSettle();

      expect(filled('Clone & create'), findsOneWidget);
      expect(find.text('Create & scan'), findsNothing);
      expect(filled('Create'), findsNothing);
    });

    testWidgets('a server too old to record a root alone keeps the one '
        'Create & scan', (tester) async {
      await pump(tester, createsFolders: false);

      expect(filled('Create & scan'), findsOneWidget);
      expect(outlined('Create & scan'), findsNothing);
      expect(filled('Create'), findsNothing);
    });
  });

  group('a folder that does not exist', () {
    testWidgets('offers to create it and initialise Git, both ticked', (
      tester,
    ) async {
      foldersMissing();
      await pump(tester);
      await typeFolder(tester, r'C:\nowhere\fresh');

      expect(find.text("This folder doesn't exist yet."), findsOneWidget);
      final create = find.byKey(const ValueKey('new-project-create-folder'));
      final git = find.byKey(const ValueKey('new-project-init-git'));
      expect(tester.widget<CheckboxListTile>(create).value, isTrue);
      expect(tester.widget<CheckboxListTile>(git).value, isTrue);
      // Nothing to scan in a folder about to be made.
      expect(outlined('Create & scan'), findsNothing);

      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(git, findsNothing, reason: 'git only where a folder is made');

      await typeFolder(tester, '');
      expect(find.text("This folder doesn't exist yet."), findsNothing);
      expect(create, findsNothing);
    });

    testWidgets('Create asks the server to make it, init Git, and not scan', (
      tester,
    ) async {
      foldersMissing();
      await pump(tester, viaRoute: true);
      await tester.enterText(
        find.widgetWithText(TextField, 'Project name'),
        'Fresh',
      );
      await typeFolder(tester, r'C:\nowhere\fresh');

      await tester.tap(filled('Create'));
      await tester.pumpAndSettle();

      final asked = server.gitWork.asked.whereType<ProjectFoldersCreate>();
      expect(asked, hasLength(1));
      final request = asked.single;
      expect(request.root.path, r'C:\nowhere\fresh');
      expect(
        (request.createFolder, request.initGit, request.scan),
        (true, true, false),
      );
      expect(find.text('Created "Fresh"'), findsOneWidget);
      expect(find.byType(NewProjectDialog), findsNothing);
    });

    testWidgets('from a server too old to make it, says so plainly', (
      tester,
    ) async {
      foldersMissing();
      await pump(tester, createsFolders: false);
      await typeFolder(tester, r'C:\nowhere\fresh');

      expect(
        find.textContaining('this server is too old to create it'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('new-project-create-folder')),
        findsNothing,
      );
    });

    testWidgets('fits a 360-wide phone at text scale 1.6', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      foldersMissing();
      await pump(tester);
      await typeFolder(tester, r'C:\a\rather\long\folder\that\is\not\there');

      expect(tester.takeException(), isNull);
      expect(find.text('Create this folder'), findsOneWidget);
      expect(find.text('Initialise Git'), findsOneWidget);
    });
  });
}
