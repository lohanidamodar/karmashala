import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/editor/application/editor_language.dart';
import 'package:karmashala/src/features/editor/application/editor_tab_actions.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/editor/presentation/editor_tab_view.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_ui/code.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// **A file opens in a tab of this app, and closing one cannot lose an edit.**
///
/// The editor is a document pane, so what the Settings tab proved about
/// document panes is assumed here, and the disk itself is `DocumentStore`'s
/// own suite. What this pins is the wiring an *editor* adds: one tab per file
/// whatever asks for it, the file's bytes on screen, a keystroke that reaches
/// the store only as a buffer, and a close that stops to ask when it would
/// drop one.
///
/// A fake store rather than a temp directory on purpose: `testWidgets` runs
/// with no real event loop, so a genuine `File.readAsString` never completes
/// and every one of these would fail on an empty pane rather than on its
/// subject.
const _path = r'C:\repo\lib\counter.dart';
const _binary = r'C:\repo\build\app.so';
const _initial = 'void main() {\n  print(1);\n}\n';
const _huge = r'C:\repo\build\bundle.js';

class _FakeStore extends DocumentStore {
  _FakeStore(this.disk);

  final Map<String, String> disk;
  final Map<String, DateTime> written = {};

  /// Bumped by a write, and by a test standing in for somebody else's editor.
  DateTime _tick(String hostPath) =>
      written[hostPath] = DateTime.utc(2026, 9, 13, 12, written.length + 1);

  /// Writes [text] the way another process would: the buffer never sees it.
  void writeBehindOurBack(String hostPath, String text) {
    disk[hostPath] = text;
    _tick(hostPath);
  }

  @override
  Future<SourceDocument> load(String hostPath) async {
    final text = disk[hostPath];
    if (text == null) {
      return SourceDocument(
        hostPath: hostPath,
        text: '',
        savedText: '',
        refusal: DocumentRefusal.notFound,
        error: '$hostPath was not found.',
      );
    }
    if (text.contains('\u0000')) {
      return SourceDocument(
        hostPath: hostPath,
        text: '',
        savedText: '',
        refusal: DocumentRefusal.binary,
        error: 'This file is binary, so it cannot be edited as text.',
      );
    }
    return SourceDocument(
      hostPath: hostPath,
      text: text,
      savedText: text,
      language: highlightLanguageFor(hostPath),
      stamp: await stamp(hostPath),
      mode: text.length > kEditableSizeLimit
          ? DocumentMode.view
          : DocumentMode.edit,
    );
  }

  @override
  Future<FileStamp?> stamp(String hostPath) async {
    final text = disk[hostPath];
    if (text == null) return null;
    return FileStamp(length: text.length, modified: written[hostPath]);
  }

  @override
  Future<FileStamp> write(String hostPath, String text) async {
    disk[hostPath] = text;
    _tick(hostPath);
    return (await stamp(hostPath))!;
  }
}

void main() {
  late CountingDatabase db;
  late _FakeStore store;

  setUp(() {
    db = CountingDatabase();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    store = _FakeStore({
      _path: _initial,
      _binary: 'ELF\u0000\u0001',
      // Comfortably over kEditableSizeLimit, so it opens in the viewer.
      _huge: List.generate(60000, (i) => 'var x$i = $i;').join('\n'),
    });
  });
  tearDown(() => db.close());

  ProviderContainer shellContainer() {
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        documentStoreProvider.overrideWithValue(store),
        commandRunnerFactoryProvider.overrideWithValue(
          FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
        ),
        hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<ProviderContainer> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = shellContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    // Bounded pumps, never `pumpAndSettle`: a terminal pane blinks its cursor
    // for ever, so nothing in this tree ever settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    return container;
  }

  WidgetRef refOf(WidgetTester tester) =>
      tester.element(find.byType(WorkbenchView)) as WidgetRef;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<ProviderContainer> openFile(
    WidgetTester tester, [
    String? path,
  ]) async {
    final container = await launch(tester);
    refOf(tester).read(editorTabActionsProvider).open(path ?? _path);
    await settle(tester);
    return container;
  }

  /// The editor's own field. The shell has other `TextField`s on screen — the
  /// composer and the search bar — so a bare type finder matches several.
  final codeInput = find.descendant(
    of: find.byType(CodeField),
    matching: find.byType(TextField),
  );

  List<String> editorTabsIn(ProviderContainer container) => [
    for (final tab in container.read(terminalSessionsControllerProvider).tabs)
      if (tab.layout.panes.any(isEditorPane)) tab.id,
  ];

  testWidgets('a file opens one tab, and asking again focuses that one', (
    tester,
  ) async {
    final container = await openFile(tester);

    expect(find.byType(EditorTabView), findsOneWidget);
    expect(editorTabsIn(container), hasLength(1));
    final tabId = editorTabsIn(container).single;
    expect(
      container.read(terminalSessionsControllerProvider).activeTabId,
      tabId,
    );
    // The tab is named after the file, not after the pane or the directory.
    expect(find.text('counter.dart'), findsWidgets);

    refOf(tester).read(editorTabActionsProvider).open(_path);
    await settle(tester);

    expect(editorTabsIn(container), [tabId]);
  });

  testWidgets("it shows the file's own bytes, coloured as its language", (
    tester,
  ) async {
    final container = await openFile(tester);

    final field = tester.widget<CodeField>(find.byType(CodeField));
    expect(field.controller.text, _initial);
    expect(container.read(openDocumentProvider(_path))?.language, 'dart');
  });

  testWidgets('an edit reaches the file only when it is saved', (tester) async {
    final container = await openFile(tester);

    await tester.enterText(codeInput, 'edited\n');
    await settle(tester);

    final documents = container.read(openDocumentsProvider.notifier);
    expect(documents.isDirty(_path), isTrue);
    expect(container.read(dirtyDocumentPathsProvider), contains(_path));
    expect(store.disk[_path], _initial, reason: 'typing must not write');

    final outcome = await documents.save(_path);
    await settle(tester);

    expect(outcome.result, SaveResult.saved);
    expect(store.disk[_path], 'edited\n');
    expect(documents.isDirty(_path), isFalse);
    expect(container.read(dirtyDocumentPathsProvider), isEmpty);
  });

  testWidgets('a file changed underneath is not overwritten blind', (
    tester,
  ) async {
    final container = await openFile(tester);

    await tester.enterText(codeInput, 'mine\n');
    await settle(tester);
    store.writeBehindOurBack(_path, 'someone else\n');

    final outcome = await container
        .read(openDocumentsProvider.notifier)
        .save(_path);

    expect(outcome.result, SaveResult.stale);
    expect(store.disk[_path], 'someone else\n');
  });

  testWidgets('closing a tab with unsaved edits asks first', (tester) async {
    final container = await openFile(tester);
    await tester.enterText(codeInput, 'unsaved\n');
    await settle(tester);

    final tabId = editorTabsIn(container).single;
    await tester.tap(find.byTooltip('Unsaved changes — close tab'));
    await settle(tester);

    // Cancel: the tab and the buffer both survive.
    expect(find.text("Close, don't save"), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(editorTabsIn(container), [tabId]);

    await tester.tap(find.byTooltip('Unsaved changes — close tab'));
    await settle(tester);
    await tester.tap(find.text("Close, don't save"));
    await settle(tester);

    expect(editorTabsIn(container), isEmpty);
    expect(container.read(dirtyDocumentPathsProvider), isEmpty);
    expect(store.disk[_path], _initial);
  });

  testWidgets('and saving from that dialog writes before it closes', (
    tester,
  ) async {
    final container = await openFile(tester);
    await tester.enterText(codeInput, 'kept\n');
    await settle(tester);

    await tester.tap(find.byTooltip('Unsaved changes — close tab'));
    await settle(tester);
    await tester.tap(find.text('Save and close'));
    await settle(tester);

    expect(editorTabsIn(container), isEmpty);
    expect(store.disk[_path], 'kept\n');
  });

  testWidgets('a clean tab closes without asking', (tester) async {
    final container = await openFile(tester);

    await tester.tap(find.byTooltip('Close tab'));
    await settle(tester);

    expect(editorTabsIn(container), isEmpty);
    expect(find.byType(EditorTabView), findsNothing);
  });

  testWidgets('it comes back after a restart, and re-reads the file', (
    tester,
  ) async {
    final first = fakeTerminalContainer(database: db);
    final terminals = first.read(terminalSessionsControllerProvider.notifier);
    terminals.openTab(TerminalProfile.powerShell);
    terminals.openEditorTab(_path);
    terminals.persistLayout();
    first.dispose();

    // Changed after the layout was stored: the restored tab must read the file,
    // not restore a buffer.
    store.writeBehindOurBack(_path, 'after the restart\n');

    final container = await launch(tester);
    await settle(tester);

    expect(editorTabsIn(container), hasLength(1));
    final field = tester.widget<CodeField>(find.byType(CodeField));
    expect(field.controller.text, 'after the restart\n');
  });

  testWidgets('a file too big to edit opens read-only, and says so', (
    tester,
  ) async {
    await openFile(tester, _huge);

    // No field to type into, and the reason is on screen rather than left for
    // the reader to discover by pressing a key.
    expect(find.byType(CodeViewer), findsOneWidget);
    expect(find.byType(CodeField), findsNothing);
    expect(find.textContaining('Read-only'), findsOneWidget);
    expect(find.text('Open in external editor'), findsOneWidget);
    // Nothing that claims it could be saved.
    expect(find.byTooltip('Save (Ctrl+S)'), findsNothing);
  });

  testWidgets('and that file cannot be edited or saved behind the viewer', (
    tester,
  ) async {
    final container = await openFile(tester, _huge);
    final documents = container.read(openDocumentsProvider.notifier);
    final before = store.disk[_huge];

    documents.edit(_huge, 'nope');
    final outcome = await documents.save(_huge);

    expect(documents.isDirty(_huge), isFalse);
    expect(outcome.ok, isFalse);
    expect(store.disk[_huge], before);
  });

  testWidgets('a file it will not open says why, and offers the way out', (
    tester,
  ) async {
    await openFile(tester, _binary);

    expect(find.byType(CodeField), findsNothing);
    expect(find.byType(CodeViewer), findsNothing);
    expect(
      find.text('This file is binary, so it cannot be edited as text.'),
      findsOneWidget,
    );
    expect(find.text('Open in external editor'), findsOneWidget);
    // A refused file is not an editable one: `isEditable` is about size alone
    // and stays true for it, so the header must ask whether it opened first.
    expect(find.byTooltip('Save (Ctrl+S)'), findsNothing);
    expect(find.byTooltip('Reload from disk'), findsNothing);
    expect(find.textContaining('Ln 1, Col 1'), findsNothing);
  });
}
