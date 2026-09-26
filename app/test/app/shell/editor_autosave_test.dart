import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/karmashala_app.dart';
import 'package:karmashala/src/app/shell/workbench.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/editor/application/editor_tab_actions.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/editor_settings.dart';
import 'package:karmashala/src/features/system/system_integration_service.dart';
import 'package:karmashala_ui/code.dart';

import '../../features/scale/scale_harness.dart';
import '../../features/system/fake_native_adapters.dart';
import '../../features/terminal/fake_instance.dart';
import '../../support/fake_command_runner.dart';
import '../../support/fakes.dart';
import '../../support/fixtures.dart';

const _path = r'C:\repo\lib\counter.dart';
const _initial = 'void main() {}\n';

class _Store extends DocumentStore {
  final disk = <String, String>{_path: _initial};
  final written = <String, DateTime>{};
  var writes = 0;
  var attempts = 0;

  /// Set to make the next writes fail the way a locked file does.
  String? failWith;

  void writeBehindOurBack(String text) {
    disk[_path] = text;
    written[_path] = DateTime.utc(2026, 9, 17, 12, written.length + 1);
  }

  @override
  Future<SourceDocument> load(String hostPath) async => SourceDocument(
    hostPath: hostPath,
    text: disk[hostPath]!,
    savedText: disk[hostPath]!,
    stamp: await stamp(hostPath),
  );

  @override
  Future<FileStamp?> stamp(String hostPath) async =>
      FileStamp(length: disk[hostPath]!.length, modified: written[hostPath]);

  @override
  Future<FileStamp> write(
    String hostPath,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    attempts++;
    final failure = failWith;
    if (failure != null) throw DocumentWriteException(failure);
    writes++;
    disk[hostPath] = text;
    written[hostPath] = DateTime.utc(2026, 9, 17, 13, writes);
    return (await stamp(hostPath))!;
  }
}

/// **Files autosave after a delay by default** (owner, 2026-09-17): a buffer is
/// written once typing has paused, never over a file that changed on disk and
/// never from a read-only viewer, and quitting writes what is pending instead
/// of asking about it.
void main() {
  late CountingDatabase db;
  late _Store store;

  setUp(() {
    db = CountingDatabase();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    AgentInstallationDao(db).insert(agentInstallation());
    store = _Store();
  });
  tearDown(() => db.close());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<ProviderContainer> openFile(
    WidgetTester tester, {
    EditorAutoSave? mode,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
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
    if (mode != null) {
      container
          .read(settingsControllerProvider.notifier)
          .setEditorAutoSave(mode);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KarmashalaApp(),
      ),
    );
    await settle(tester);
    (tester.element(find.byType(WorkbenchView)) as WidgetRef)
        .read(editorTabActionsProvider)
        .open(_path);
    await settle(tester);
    return container;
  }

  Future<void> type(WidgetTester tester, String text) async {
    tester.widget<AppCodeEditor>(find.byType(AppCodeEditor)).controller.text =
        text;
    await tester.pump();
  }

  Future<List<String>> quit(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final reached = <String>[];
    final service = SystemIntegrationService(
      container,
      adapters: FakeNatives().adapters,
      registerOsQuit: (_) {},
      endProcess: () => reached.add('ended'),
      onQuitRequested: () async => reached.add('shutdown'),
    );
    unawaited(service.quit());
    await settle(tester);
    return reached;
  }

  testWidgets('by default an edit is written once typing pauses for a second', (
    tester,
  ) async {
    final container = await openFile(tester);

    await type(tester, 'void main() { print(1); }\n');
    await tester.pump(const Duration(milliseconds: 600));
    await type(tester, 'void main() { print(2); }\n');
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.writes, 0, reason: 'typing again restarts the wait');
    expect(container.read(dirtyDocumentPathsProvider), contains(_path));

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(store.writes, 1);
    expect(store.disk[_path], 'void main() { print(2); }\n');
    expect(container.read(dirtyDocumentPathsProvider), isEmpty);
  });

  testWidgets(
    'by default quitting writes a pending autosave instead of asking',
    (tester) async {
      final container = await openFile(tester);
      await type(tester, 'kept\n');

      final reached = await quit(tester, container);

      expect(find.text('Save counter.dart before quitting?'), findsNothing);
      expect(store.disk[_path], 'kept\n');
      expect(reached, contains('shutdown'));
    },
  );

  testWidgets('off: nothing is written, and quitting asks', (tester) async {
    final container = await openFile(tester, mode: EditorAutoSave.off);
    await type(tester, 'unsaved\n');
    await tester.pump(const Duration(seconds: 5));
    expect(store.attempts, 0);

    final reached = await quit(tester, container);
    expect(find.text('Save counter.dart before quitting?'), findsOneWidget);
    expect(reached, isEmpty);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });

  testWidgets('on focus change: written when the editor loses focus', (
    tester,
  ) async {
    await openFile(tester, mode: EditorAutoSave.onFocusChange);
    final editor = tester.widget<AppCodeEditor>(find.byType(AppCodeEditor));
    editor.focusNode!.requestFocus();
    await tester.pump();
    await type(tester, 'focus\n');
    await tester.pump(const Duration(seconds: 3));
    expect(store.attempts, 0, reason: 'no delay-based write in this mode');

    editor.focusNode!.unfocus();
    await settle(tester);
    expect(store.disk[_path], 'focus\n');
  });

  testWidgets('on window change: written when the window loses focus', (
    tester,
  ) async {
    final container = await openFile(
      tester,
      mode: EditorAutoSave.onWindowChange,
    );
    await type(tester, 'window\n');
    await tester.pump(const Duration(seconds: 3));
    expect(store.attempts, 0);

    container.read(windowFocusedProvider.notifier).set(false);
    await settle(tester);
    expect(store.disk[_path], 'window\n');
  });

  testWidgets('a file changed on disk is not overwritten; the bar says so '
      'without a dialog, and later edits wait for its answer', (tester) async {
    await openFile(tester);
    store.writeBehindOurBack('someone else\n');
    await type(tester, 'mine\n');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);

    expect(store.disk[_path], 'someone else\n');
    // Non-modal: typing goes on under it.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Changed on disk'), findsOneWidget);

    await type(tester, 'mine, again\n');
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    expect(store.disk[_path], 'someone else\n');
    expect(find.byType(AlertDialog), findsNothing);

    // Keep mine is the answer, and the next autosave writes.
    await tester.tap(find.text('Keep mine'));
    await settle(tester);
    await type(tester, 'mine, kept\n');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);
    expect(store.disk[_path], 'mine, kept\n');
  });

  testWidgets('a failed write says why and waits for the next edit', (
    tester,
  ) async {
    final container = await openFile(tester);
    store.failWith = 'counter.dart is locked by another process.';
    await type(tester, 'blocked\n');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);

    expect(store.attempts, 1);
    expect(
      find.text('counter.dart is locked by another process.'),
      findsOneWidget,
    );
    expect(container.read(dirtyDocumentPathsProvider), contains(_path));

    await tester.pump(const Duration(seconds: 5));
    expect(store.attempts, 1, reason: 'not retried on its own');

    store.failWith = null;
    await type(tester, 'unblocked\n');
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);
    expect(store.disk[_path], 'unblocked\n');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('quitting still asks about a file autosave could not write', (
    tester,
  ) async {
    final container = await openFile(tester);
    store.writeBehindOurBack('someone else\n');
    await type(tester, 'mine\n');

    final reached = await quit(tester, container);
    expect(find.text('Save counter.dart before quitting?'), findsOneWidget);
    expect(reached, isEmpty);
    expect(store.disk[_path], 'someone else\n');
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
  });
}
