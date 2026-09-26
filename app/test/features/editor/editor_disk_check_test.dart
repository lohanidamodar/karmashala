import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_auto_save.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import 'package:karmashala/src/features/notifications/application/notification_providers.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/domain/editor_settings.dart';

import '../terminal/fake_instance.dart';
import '../../support/test_machine.dart';

const _path = r'C:\repo\lib\main.dart';

/// A disk another process can write behind the editor's back: every write
/// moves the clock, so a stamp tells one version from the next.
class _Disk extends DocumentStore {
  _Disk(this.files);

  final Map<String, String> files;
  final Map<String, DateTime> _modified = {};
  var _clock = 0;
  var stats = 0;
  var loads = 0;
  final List<String> writes = [];

  /// A stat that only answers when a test says so — a slow WSL share.
  Completer<void>? statGate;

  /// A read that only answers when a test says so.
  Completer<void>? loadGate;

  bool statThrows = false;

  void external(String hostPath, String? text) {
    if (text == null) {
      files.remove(hostPath);
    } else {
      files[hostPath] = text;
    }
    _modified[hostPath] = DateTime.utc(2026, 9, 22, 12, 0, ++_clock);
  }

  @override
  Future<SourceDocument> load(String hostPath) async {
    loads++;
    if (loadGate != null) await loadGate!.future;
    final text = files[hostPath];
    if (text == null) {
      return SourceDocument(
        hostPath: hostPath,
        text: '',
        savedText: '',
        refusal: DocumentRefusal.notFound,
        error: 'not found',
      );
    }
    final stamp = _stampOf(hostPath);
    if (text.contains('\u0000')) {
      return SourceDocument(
        hostPath: hostPath,
        text: '',
        savedText: '',
        stamp: stamp,
        refusal: DocumentRefusal.binary,
        error: 'binary',
      );
    }
    return SourceDocument(
      hostPath: hostPath,
      text: text,
      savedText: text,
      stamp: stamp,
      mode: text.length > kEditableSizeLimit
          ? DocumentMode.view
          : DocumentMode.edit,
    );
  }

  FileStamp? _stampOf(String hostPath) {
    final text = files[hostPath];
    if (text == null) return null;
    return FileStamp(length: text.length, modified: _modified[hostPath]);
  }

  @override
  Future<FileStamp?> stamp(String hostPath) async {
    stats++;
    if (statGate != null) await statGate!.future;
    if (statThrows) throw const FileSystemExceptionLike();
    return _stampOf(hostPath);
  }

  @override
  Future<FileStamp> write(
    String hostPath,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    writes.add(text);
    external(hostPath, text);
    return _stampOf(hostPath)!;
  }
}

class FileSystemExceptionLike implements Exception {
  const FileSystemExceptionLike();
}

void main() {
  late _Disk disk;
  late ProviderContainer container;
  late OpenDocuments documents;

  SourceDocument doc() => container.read(openDocumentProvider(_path))!;

  setUp(() async {
    disk = _Disk({});
    disk.external(_path, 'one\ntwo\n');
    container = ProviderContainer(
      overrides: [documentStoreProvider.overrideWithValue(disk)],
    );
    documents = container.read(openDocumentsProvider.notifier);
    await documents.open(_path);
  });
  tearDown(() => container.dispose());

  test('an unchanged file costs one stat and changes nothing', () async {
    final before = doc();
    await documents.checkOnDisk(_path);

    expect(disk.stats, 1);
    expect(disk.loads, 1, reason: 'only the open read it');
    expect(identical(doc(), before), isTrue);
  });

  test('a clean buffer takes the new text silently', () async {
    disk.external(_path, 'one\ntwo\nthree\n');

    await documents.checkOnDisk(_path);

    expect(doc().text, 'one\ntwo\nthree\n');
    expect(doc().isDirty, isFalse);
    expect(doc().disk, DiskState.current);
  });

  group('a dirty buffer', () {
    setUp(() => documents.edit(_path, 'mine\n'));

    test('keeps its text and is marked changed', () async {
      disk.external(_path, 'theirs\n');

      await documents.checkOnDisk(_path);

      expect(doc().text, 'mine\n');
      expect(doc().disk, DiskState.changed);
      expect(doc().diskStamp?.length, 'theirs\n'.length);
    });

    test('is not re-marked for the same change', () async {
      disk.external(_path, 'theirs\n');
      await documents.checkOnDisk(_path);
      final marked = doc();

      await documents.checkOnDisk(_path);
      await documents.checkOnDisk(_path);

      expect(identical(doc(), marked), isTrue);
    });

    test('still refuses a plain save over the change', () async {
      disk.external(_path, 'theirs\n');
      await documents.checkOnDisk(_path);

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.stale);
      expect(disk.files[_path], 'theirs\n');
    });

    test('after Keep mine, a save overwrites without asking', () async {
      disk.external(_path, 'theirs\n');
      await documents.checkOnDisk(_path);

      documents.keepMine(_path);
      expect(doc().disk, DiskState.current);
      await documents.checkOnDisk(_path);
      expect(doc().disk, DiskState.current, reason: 'no nag for that change');

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.saved);
      expect(disk.files[_path], 'mine\n');
      expect(doc().isDirty, isFalse);
    });

    test('Keep mine does not cover a later change', () async {
      disk.external(_path, 'theirs\n');
      await documents.checkOnDisk(_path);
      documents.keepMine(_path);

      disk.external(_path, 'theirs again\n');
      await documents.checkOnDisk(_path);

      expect(doc().disk, DiskState.changed);
      expect((await documents.save(_path)).result, SaveResult.stale);
    });

    test('Reload discards the buffer for the disk', () async {
      disk.external(_path, 'theirs\n');
      await documents.checkOnDisk(_path);

      await documents.reload(_path);

      expect(doc().text, 'theirs\n');
      expect(doc().disk, DiskState.current);
    });

    test('is back in sync when the file returns to what was read', () async {
      final original = disk.files[_path]!;
      final stamp = doc().stamp!;
      disk.external(_path, 'theirs\n');
      await documents.checkOnDisk(_path);
      // Put back byte for byte, time and all — a `git checkout` that restored
      // the mtime.
      disk.files[_path] = original;
      disk._modified[_path] = stamp.modified!;

      await documents.checkOnDisk(_path);

      expect(doc().disk, DiskState.current);
      expect(doc().text, 'mine\n');
    });
  });

  group('a deleted file', () {
    test('keeps the text and is marked, clean or not', () async {
      disk.external(_path, null);

      await documents.checkOnDisk(_path);

      expect(doc().isReadable, isTrue);
      expect(doc().text, 'one\ntwo\n');
      expect(doc().disk, DiskState.deleted);
    });

    test('saving puts it back, even with nothing typed', () async {
      disk.external(_path, null);
      await documents.checkOnDisk(_path);

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.saved);
      expect(disk.files[_path], 'one\ntwo\n');
      expect(doc().disk, DiskState.current);
    });

    test('an unseen deletion still stops a save', () async {
      disk.external(_path, null);

      expect((await documents.save(_path)).result, SaveResult.stale);
      expect(disk.files.containsKey(_path), isFalse);
    });

    test('that reappears is re-read into a clean buffer', () async {
      disk.external(_path, null);
      await documents.checkOnDisk(_path);
      disk.external(_path, 'back\n');

      await documents.checkOnDisk(_path);

      expect(doc().text, 'back\n');
      expect(doc().disk, DiskState.current);
    });

    test('that reappears under edits is a change', () async {
      disk.external(_path, null);
      await documents.checkOnDisk(_path);
      documents.edit(_path, 'mine\n');
      disk.external(_path, 'back\n');

      await documents.checkOnDisk(_path);

      expect(doc().text, 'mine\n');
      expect(doc().disk, DiskState.changed);
      expect((await documents.save(_path)).result, SaveResult.stale);
    });
  });

  test('one stat in flight per path, however often it is asked', () async {
    disk.statGate = Completer<void>();
    final first = documents.checkOnDisk(_path);
    final second = documents.checkOnDisk(_path);
    final third = documents.checkAllOnDisk();
    disk.statGate!.complete();
    await Future.wait([first, second, third]);

    expect(disk.stats, 1);
    // And once it is back, the next check goes out.
    await documents.checkOnDisk(_path);
    expect(disk.stats, 2);
  });

  test('a stat that fails is not evidence of anything', () async {
    disk.statThrows = true;
    final before = doc();

    await documents.checkOnDisk(_path);

    expect(identical(doc(), before), isTrue);
  });

  test('typing while the new text is read keeps the typing', () async {
    disk.external(_path, 'theirs\n');
    disk.loadGate = Completer<void>();
    final checking = documents.checkOnDisk(_path);
    await pumpEventQueue();
    documents.edit(_path, 'typed meanwhile\n');
    disk.loadGate!.complete();
    await checking;

    expect(doc().text, 'typed meanwhile\n');
    expect(doc().disk, DiskState.changed);
  });

  test('a file grown past the edit limit comes back read-only', () async {
    disk.external(_path, 'x' * (kEditableSizeLimit + 1));

    await documents.checkOnDisk(_path);

    expect(doc().isEditable, isFalse);
    expect(doc().text.length, kEditableSizeLimit + 1);
  });

  test('a file that turned binary is refused, and recovers as text', () async {
    disk.external(_path, 'ELF\u0000');
    await documents.checkOnDisk(_path);
    expect(doc().refusal, DocumentRefusal.binary);

    // Still binary: the refusal's own stamp says nothing new, so no re-read.
    final loads = disk.loads;
    await documents.checkOnDisk(_path);
    expect(disk.loads, loads);

    disk.external(_path, 'text again\n');
    await documents.checkOnDisk(_path);
    expect(doc().isReadable, isTrue);
    expect(doc().text, 'text again\n');
  });

  test('a closed buffer is never checked back into existence', () async {
    disk.statGate = Completer<void>();
    final checking = documents.checkOnDisk(_path);
    documents.close(_path);
    disk.external(_path, 'theirs\n');
    disk.statGate!.complete();
    await checking;

    expect(container.read(openDocumentProvider(_path)), isNull);
  });

  test('coming back to the window checks every open buffer', () async {
    const other = r'C:\repo\lib\other.dart';
    disk.files[other] = 'other\n';
    await documents.open(other);
    disk.external(_path, 'changed while away\n');
    disk.external(other, 'this too\n');

    final focus = container.read(windowFocusedProvider.notifier);
    focus.set(false);
    focus.set(true);
    await pumpEventQueue();

    expect(doc().text, 'changed while away\n');
    expect(container.read(openDocumentProvider(other))?.text, 'this too\n');
  });

  testWidgets('autosave never writes over a change or a deletion', (
    tester,
  ) async {
    final db = TestMachine();
    final disk = _Disk({_path: 'one\n'});
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        documentStoreProvider.overrideWithValue(disk),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(settingsControllerProvider.notifier)
        .setEditorAutoSave(EditorAutoSave.afterDelay);
    container.listen(editorAutoSaveProvider, (_, _) {});
    final documents = container.read(openDocumentsProvider.notifier);
    await documents.open(_path);
    final autosave = container.read(editorAutoSaveProvider.notifier);

    documents.edit(_path, 'mine\n');
    disk.external(_path, 'theirs\n');
    await documents.checkOnDisk(_path);
    expect(await autosave.saveNow(_path), isNull);
    // A keystroke after the bar appeared is still not an answer to it.
    documents.edit(_path, 'mine, more\n');
    await tester.pump(const Duration(seconds: 5));
    expect(disk.writes, isEmpty);
    expect(disk.files[_path], 'theirs\n');

    // Keep mine is the answer: from there autosave may write.
    documents.keepMine(_path);
    expect((await autosave.saveNow(_path))?.result, SaveResult.saved);
    expect(disk.files[_path], 'mine, more\n');

    disk.external(_path, null);
    await documents.checkOnDisk(_path);
    documents.edit(_path, 'after delete\n');
    await tester.pump(const Duration(seconds: 5));
    expect(disk.files.containsKey(_path), isFalse);
  });
}
