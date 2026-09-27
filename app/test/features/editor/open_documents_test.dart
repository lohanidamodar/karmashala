import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/editor/application/editor_language.dart';
import 'package:karmashala/src/features/editor/application/open_documents.dart';
import 'package:karmashala/src/features/editor/data/document_store.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart';
import '../../support/memory_documents.dart';

const _path = r'C:\src\app\lib\main.dart';
const _other = r'C:\src\app\lib\other.dart';

/// A disk described rather than used: the store's own suite covers the real
/// one, and these cases are about what the buffers do with its answers.
class _FakeStore extends DocumentStore {
  _FakeStore(this.disk) : super(noServerFiles());

  final Map<String, String> disk;
  final Map<String, DateTime> written = {};
  final List<String> loads = [];
  final List<String> writes = [];

  /// A read that only finishes when a test says so.
  Completer<void>? gate;

  /// The message the next write throws with, or null to let it through.
  String? refuseWrite;

  @override
  Future<SourceDocument> load(String hostPath) async {
    loads.add(hostPath);
    if (gate != null) await gate!.future;
    final text = disk[hostPath];
    if (text == null) {
      return SourceDocument(
        hostPath: hostPath,
        text: '',
        savedText: '',
        refusal: DocumentRefusal.notFound,
        error: 'main.dart was not found.',
      );
    }
    final crlf = text.contains('\r\n');
    final buffer = crlf ? text.replaceAll('\r\n', '\n') : text;
    return SourceDocument(
      hostPath: hostPath,
      text: buffer,
      savedText: buffer,
      language: highlightLanguageFor(hostPath),
      stamp: await stamp(hostPath),
      crlf: crlf,
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
  Future<FileStamp> write(
    String hostPath,
    String text, {
    WriteExpectation expect = const WriteExpectation.any(),
  }) async {
    final refusal = refuseWrite;
    if (refusal != null) throw DocumentWriteException(refusal);
    writes.add(text);
    disk[hostPath] = text;
    written[hostPath] = DateTime.utc(2026, 9, 13, 12, writes.length);
    return (await stamp(hostPath))!;
  }
}

void main() {
  late _FakeStore store;
  late ProviderContainer container;

  late OpenDocuments documents;

  setUp(() {
    store = _FakeStore({_path: 'one\ntwo\n', _other: 'other\n'});
    container = ProviderContainer(
      overrides: [documentStoreProvider.overrideWithValue(store)],
    );
    documents = container.read(openDocumentsProvider.notifier);
  });
  tearDown(() => container.dispose());

  group('opening', () {
    test('reads the file once, however often a tab asks', () async {
      await documents.open(_path);
      await documents.open(_path);

      expect(store.loads, [_path]);
      expect(container.read(openDocumentProvider(_path))?.text, 'one\ntwo\n');
      expect(container.read(openDocumentProvider(_path))?.language, 'dart');
    });

    test('two tabs opening at once still read once', () async {
      store.gate = Completer<void>();
      final first = documents.open(_path);
      final second = documents.open(_path);
      store.gate!.complete();
      await Future.wait([first, second]);

      expect(store.loads, [_path]);
    });

    test('a buffer is absent until it has been read', () async {
      expect(container.read(openDocumentProvider(_path)), isNull);
      store.gate = Completer<void>();
      final reading = documents.open(_path);
      expect(container.read(openDocumentProvider(_path)), isNull);
      store.gate!.complete();
      await reading;
      expect(container.read(openDocumentProvider(_path)), isNotNull);
    });

    test('a refusal is kept as the buffer, not thrown away', () async {
      await documents.open(r'C:\src\app\gone.dart');

      final document = container.read(
        openDocumentProvider(r'C:\src\app\gone.dart'),
      );
      expect(document?.refusal, DocumentRefusal.notFound);
      expect(document?.error, isNotNull);
    });
  });

  group('editing', () {
    test('an edit marks the file dirty, and only that file', () async {
      await documents.open(_path);
      await documents.open(_other);

      documents.edit(_path, 'one\ntwo\nthree\n');

      expect(documents.isDirty(_path), isTrue);
      expect(documents.isDirty(_other), isFalse);
      expect(container.read(dirtyDocumentPathsProvider), {_path});
      expect(
        container.read(openDocumentProvider(_path))?.text,
        'one\ntwo\nthree\n',
      );
    });

    test('an edit to a file opened read-only is ignored', () async {
      const big = r'C:\src\app\lib\big.dart';
      store.disk[big] = 'a' * (kEditableSizeLimit + 1);
      await documents.open(big);

      documents.edit(big, 'typed\n');

      expect(
        container.read(openDocumentProvider(big))?.text.length,
        kEditableSizeLimit + 1,
      );
      expect(documents.isDirty(big), isFalse);
      expect(container.read(dirtyDocumentPathsProvider), isEmpty);
    });

    test('an edit to a file that is not open is ignored', () {
      documents.edit(_path, 'x');

      expect(container.read(openDocumentProvider(_path)), isNull);
      expect(container.read(dirtyDocumentPathsProvider), isEmpty);
    });
  });

  group('saving', () {
    test('a save writes the buffer and clears the dot', () async {
      await documents.open(_path);
      documents.edit(_path, 'one\ntwo\nthree\n');

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.saved);
      expect(outcome.ok, isTrue);
      expect(store.writes, ['one\ntwo\nthree\n']);
      expect(documents.isDirty(_path), isFalse);
      expect(container.read(dirtyDocumentPathsProvider), isEmpty);
    });

    test('a CRLF file is written back with its own endings', () async {
      store.disk[_path] = 'one\r\ntwo\r\n';
      await documents.open(_path);
      documents.edit(_path, 'one\ntwo\nthree\n');

      await documents.save(_path);

      expect(store.writes, ['one\r\ntwo\r\nthree\r\n']);
      expect(documents.isDirty(_path), isFalse);
    });

    test('nothing to write is said rather than written', () async {
      await documents.open(_path);

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.unchanged);
      expect(outcome.ok, isTrue);
      expect(store.writes, isEmpty);
    });

    test('a file that moved under the buffer is not overwritten', () async {
      await documents.open(_path);
      documents.edit(_path, 'mine\n');
      store.disk[_path] = 'somebody else wrote this\n';

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.stale);
      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('main.dart'));
      expect(store.writes, isEmpty);
      expect(store.disk[_path], 'somebody else wrote this\n');
      expect(documents.isDirty(_path), isTrue);
    });

    test('forcing writes over it anyway', () async {
      await documents.open(_path);
      documents.edit(_path, 'mine\n');
      store.disk[_path] = 'somebody else wrote this\n';

      final outcome = await documents.save(_path, force: true);

      expect(outcome.result, SaveResult.saved);
      expect(store.disk[_path], 'mine\n');
      expect(documents.isDirty(_path), isFalse);
    });

    test('a write that failed leaves the dot where it was', () async {
      await documents.open(_path);
      documents.edit(_path, 'mine\n');
      store.refuseWrite = 'main.dart could not be saved: access is denied.';

      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.failed);
      expect(outcome.ok, isFalse);
      expect(
        outcome.message,
        'main.dart could not be saved: access is denied.',
      );
      expect(documents.isDirty(_path), isTrue);
      expect(container.read(dirtyDocumentPathsProvider), {_path});
    });

    test(
      'a refused document reports its refusal rather than writing',
      () async {
        const gone = r'C:\src\app\gone.dart';
        await documents.open(gone);

        final outcome = await documents.save(gone);

        expect(outcome.result, SaveResult.failed);
        expect(outcome.message, contains('was not found'));
        expect(store.writes, isEmpty);
      },
    );

    test('a file too big to edit is not written, and says why', () async {
      const big = r'C:\src\app\lib\big.dart';
      store.disk[big] = 'a' * (kEditableSizeLimit + 1);
      await documents.open(big);

      expect(container.read(openDocumentProvider(big))?.isEditable, isFalse);

      final outcome = await documents.save(big);

      expect(outcome.result, SaveResult.failed);
      expect(outcome.ok, isFalse);
      expect(outcome.message, contains('big.dart'));
      expect(outcome.message, contains('read-only'));
      expect(store.writes, isEmpty);
      expect(store.disk[big]!.length, kEditableSizeLimit + 1);
    });

    test('a file nobody opened cannot be saved', () async {
      final outcome = await documents.save(_path);

      expect(outcome.result, SaveResult.failed);
      expect(store.writes, isEmpty);
    });

    test(
      'a save stamps the file it just wrote, so the next one is clean',
      () async {
        await documents.open(_path);
        documents.edit(_path, 'first\n');
        expect((await documents.save(_path)).result, SaveResult.saved);

        documents.edit(_path, 'second\n');
        final outcome = await documents.save(_path);

        expect(outcome.result, SaveResult.saved);
        expect(store.disk[_path], 'second\n');
      },
    );
  });

  group('reloading and closing', () {
    test('a reload discards the buffer for what is on disk', () async {
      await documents.open(_path);
      documents.edit(_path, 'mine\n');
      store.disk[_path] = 'theirs\n';

      await documents.reload(_path);

      expect(container.read(openDocumentProvider(_path))?.text, 'theirs\n');
      expect(documents.isDirty(_path), isFalse);
      expect(container.read(dirtyDocumentPathsProvider), isEmpty);
    });

    test('closing drops the buffer, and reopening reads again', () async {
      await documents.open(_path);
      documents.edit(_path, 'mine\n');

      documents.close(_path);

      expect(container.read(openDocumentProvider(_path)), isNull);
      expect(documents.isDirty(_path), isFalse);
      expect(container.read(dirtyDocumentPathsProvider), isEmpty);

      await documents.open(_path);
      expect(store.loads, [_path, _path]);
      expect(container.read(openDocumentProvider(_path))?.text, 'one\ntwo\n');
    });

    test('closing one file leaves the others alone', () async {
      await documents.open(_path);
      await documents.open(_other);
      documents.edit(_other, 'edited\n');

      documents.close(_path);

      expect(container.read(openDocumentProvider(_other)), isNotNull);
      expect(container.read(dirtyDocumentPathsProvider), {_other});
    });
  });
}
