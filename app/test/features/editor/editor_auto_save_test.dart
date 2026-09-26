import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_auto_save.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/editor_settings.dart';
import 'package:karmashala/src/features/settings/domain/settings.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';

import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';
import '../../support/test_machine.dart';

class _Store extends DocumentStore {
  _Store(this.mode);

  final DocumentMode mode;
  var attempts = 0;

  @override
  Future<SourceDocument> load(String hostPath) async =>
      SourceDocument(hostPath: hostPath, text: 'x', savedText: 'x', mode: mode);

  @override
  Future<FileStamp?> stamp(String hostPath) async => null;

  @override
  Future<FileStamp> write(
    String hostPath,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    attempts++;
    return FileStamp(length: text.length, modified: null);
  }
}

/// The autosave setting, and the buffers autosave must leave alone.
void main() {
  const path = '/repo/big.js';

  Future<(ProviderContainer, _Store)> start(
    WidgetTester tester,
    DocumentMode mode,
  ) async {
    final db = TestMachine();
    final store = _Store(mode);
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        documentStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    container.listen(editorAutoSaveProvider, (_, _) {});
    await container.read(openDocumentsProvider.notifier).open(path);
    return (container, store);
  }

  testWidgets('a read-only viewer is never autosaved', (tester) async {
    final (container, store) = await start(tester, DocumentMode.view);
    container.read(openDocumentsProvider.notifier).edit(path, 'changed');
    await tester.pump(const Duration(seconds: 2));
    expect(
      await container.read(editorAutoSaveProvider.notifier).saveNow(path),
      isNull,
    );
    expect(store.attempts, 0);
  });

  testWidgets('an editable buffer is, after the setting\'s own delay', (
    tester,
  ) async {
    final (container, store) = await start(tester, DocumentMode.edit);
    container
        .read(settingsControllerProvider.notifier)
        .setEditorAutoSaveDelay(3000);
    container.read(openDocumentsProvider.notifier).edit(path, 'changed');
    await tester.pump(const Duration(milliseconds: 2900));
    expect(store.attempts, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(store.attempts, 1);
  });

  group('the setting', () {
    test('is after a one-second delay by default', () {
      expect(const Settings().editorAutoSave, EditorAutoSave.afterDelay);
      expect(const Settings().editorAutoSaveDelayMs, 1000);
      expect(
        Settings.fromJson(const {}).editorAutoSave,
        kDefaultEditorAutoSave,
      );
    });

    test('survives a JSON round-trip and takes part in equality', () {
      const settings = Settings(
        editorAutoSave: EditorAutoSave.onWindowChange,
        editorAutoSaveDelayMs: 2500,
      );
      final back = Settings.fromJson(settings.toJson());
      expect(back.editorAutoSave, EditorAutoSave.onWindowChange);
      expect(back.editorAutoSaveDelayMs, 2500);
      expect(back, settings);
      expect(settings, isNot(const Settings()));
    });

    test('an unknown mode or an absurd delay reads back as something sane', () {
      final back = Settings.fromJson(const {
        'editorAutoSave': 'sometimes',
        'editorAutoSaveDelayMs': 0,
      });
      expect(back.editorAutoSave, kDefaultEditorAutoSave);
      expect(back.editorAutoSaveDelayMs, kMinEditorAutoSaveDelayMs);
    });

    testWidgets('the controller persists it', (tester) async {
      final db = TestMachine();
      final server = FakeDataServer();
      final first = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
        ],
      );
      first.read(settingsControllerProvider.notifier)
        ..setEditorAutoSave(EditorAutoSave.off)
        ..setEditorAutoSaveDelay(999999);
      first.dispose();
      await tester.pump();

      final second = ProviderContainer(
        overrides: [
          ...fakeTerminalOverrides(machine: db),
          await server.override(),
        ],
      );
      addTearDown(second.dispose);
      final settings = second.read(settingsControllerProvider);
      expect(settings.editorAutoSave, EditorAutoSave.off);
      expect(settings.editorAutoSaveDelayMs, kMaxEditorAutoSaveDelayMs);
    });

    test('search finds it as "auto save" and "autosave"', () {
      for (final query in ['auto save', 'autosave', 'AutoSave']) {
        expect(
          searchSettings(query).map((e) => e.label),
          contains('Auto save'),
          reason: query,
        );
      }
    });
  });
}
