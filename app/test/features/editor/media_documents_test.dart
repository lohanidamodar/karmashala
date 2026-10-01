import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/editor/application/media_documents.dart';
import 'package:karmashala/src/features/editor/data/media_store.dart';
import 'package:karmashala/src/features/editor/domain/media_document.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart'
    show kDocumentSizeLimit;
import 'package:karmashala/src/features/files/data/files_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show FileChanged;
import 'package:karmashala_files/values.dart' show FileStamp, FileStat;
import 'package:path/path.dart' as p;

const _image = '/repo/assets/shot.png';
const _video = '/srv/clips/talk.mp4';

/// The server's files, held in memory: every write moves the clock, so a
/// stamp tells one version from the next. Watches are recorded so a test can
/// say "the server saw it change".
class _FakeFiles extends FilesClient {
  _FakeFiles() : super(DataClient.unavailable('in-memory media files'));

  final Map<String, Uint8List> contents = {};
  final Map<String, DateTime> _modified = {};

  /// A size stat reports instead of the bytes' own — a file too big to hold.
  final Map<String, int> statSize = {};

  final Map<String, void Function(FileChanged)> _listeners = {};
  var _clock = 0;
  var reads = 0;

  /// The server is away: every call says so.
  bool unreachable = false;

  /// A read that only answers when a test says so.
  Completer<void>? readGate;

  void put(String path, List<int> bytes) {
    contents[path] = Uint8List.fromList(bytes);
    _modified[path] = DateTime.utc(2026, 10, 1, 12, 0, ++_clock);
  }

  void remove(String path) {
    contents.remove(path);
    _modified.remove(path);
  }

  /// What the server's watch would tell the client.
  void changed(String path) => _listeners[path]?.call(
    FileChanged(
      environmentId: localHostEnvironmentId,
      path: path,
      stamp: null,
    ),
  );

  void _reach() {
    if (unreachable) {
      throw const FilesUnreachableException('The server is not answering');
    }
  }

  @override
  Future<FileStat> stat(EnvironmentPath path) async {
    _reach();
    final bytes = contents[path.path];
    if (bytes == null) return const FileStat.absent();
    final size = statSize[path.path] ?? bytes.length;
    return FileStat(
      isDirectory: false,
      size: size,
      stamp: FileStamp(length: size, modified: _modified[path.path]),
    );
  }

  @override
  Future<Uint8List> read(
    EnvironmentPath path, {
    int offset = 0,
    int? length,
  }) async {
    reads++;
    if (readGate != null) await readGate!.future;
    _reach();
    final bytes = contents[path.path];
    if (bytes == null) throw const FilesException('No such file');
    final end = length == null
        ? bytes.length
        : math.min(bytes.length, offset + length);
    return Uint8List.sublistView(bytes, math.min(offset, end), end);
  }

  /// The server is elsewhere: video and audio are copied.
  @override
  Future<String?> localPathOf(EnvironmentPath path) async => null;

  @override
  FileWatch watch(EnvironmentPath path, void Function(FileChanged) onChange) {
    _listeners[path.path] = onChange;
    return super.watch(path, onChange);
  }
}

void main() {
  late Directory cache;
  late _FakeFiles files;
  late ProviderContainer container;
  late MediaDocuments media;

  MediaDocument? doc(String id) => container.read(mediaDocumentsProvider)[id];

  setUp(() {
    cache = Directory.systemTemp.createTempSync('karmashala_media_');
    files = _FakeFiles();
    container = ProviderContainer(
      overrides: [
        filesClientProvider.overrideWithValue(files),
        mediaStoreProvider.overrideWithValue(
          MediaStore(files, cacheDirectory: cache.path),
        ),
      ],
    );
    media = container.read(mediaDocumentsProvider.notifier);
  });
  tearDown(() {
    container.dispose();
    cache.deleteSync(recursive: true);
  });

  test('an image arrives as its bytes, with its stamp', () async {
    files.put(_image, [1, 2, 3, 4]);

    await media.open(_image);

    final shown = doc(_image)!;
    expect(shown.refusal, MediaRefusal.none);
    expect(shown.isReady, isTrue);
    expect(shown.bytes, [1, 2, 3, 4]);
    expect(shown.stamp?.length, 4);
    expect(shown.error, isNull);
    expect(shown.revision, 0);
  });

  test('opening twice reads once', () async {
    files.put(_image, [1, 2, 3]);

    await media.open(_image);
    await media.open(_image);

    expect(files.reads, 1);
  });

  test('a file that is not media is left to the text editor', () async {
    files.put('/repo/main.dart', [0x61]);

    await media.open('/repo/main.dart');

    expect(doc('/repo/main.dart'), isNull);
  });

  test('an image over the cap is refused, unread', () async {
    files
      ..put(_image, [1])
      ..statSize[_image] = kDocumentSizeLimit + 1;

    await media.open(_image);

    final shown = doc(_image)!;
    expect(shown.refusal, MediaRefusal.tooLarge);
    expect(shown.bytes, isNull);
    expect(shown.error, contains('shot.png'));
    expect(files.reads, 0);
  });

  test('a missing file is notFound', () async {
    await media.open(_image);

    final shown = doc(_image)!;
    expect(shown.refusal, MediaRefusal.notFound);
    expect(shown.error, contains(_image));
  });

  test('a watch event with a new stamp reloads and bumps revision', () async {
    files.put(_image, [1, 2, 3]);
    await media.open(_image);

    files.put(_image, [9, 9]);
    files.changed(_image);
    await pumpEventQueue();

    final shown = doc(_image)!;
    expect(shown.bytes, [9, 9]);
    expect(shown.revision, 1);
  });

  test('a reload of an unchanged file reads nothing', () async {
    files.put(_image, [1, 2, 3]);
    await media.open(_image);
    final before = doc(_image);

    await media.reload(_image);

    expect(files.reads, 1);
    expect(identical(doc(_image), before), isTrue);
  });

  test('a file deleted under the viewer becomes notFound', () async {
    files.put(_image, [1, 2, 3]);
    await media.open(_image);

    files.remove(_image);
    await media.reload(_image);

    expect(doc(_image)!.refusal, MediaRefusal.notFound);
    expect(doc(_image)!.revision, 1);
  });

  test('an unreachable server keeps the bytes and says so', () async {
    files.put(_image, [1, 2, 3]);
    await media.open(_image);

    files.unreachable = true;
    await media.reload(_image);

    var shown = doc(_image)!;
    expect(shown.bytes, [1, 2, 3]);
    expect(shown.refusal, MediaRefusal.none);
    expect(shown.error, 'The server is not answering');

    // Back, and changed meanwhile: the next load clears the warning.
    files
      ..unreachable = false
      ..put(_image, [4, 5]);
    await media.reload(_image);

    shown = doc(_image)!;
    expect(shown.bytes, [4, 5]);
    expect(shown.error, isNull);
  });

  test('a load in flight when its tab closes puts nothing back', () async {
    files
      ..put(_image, [1, 2, 3])
      ..readGate = Completer<void>();

    final opening = media.open(_image);
    await pumpEventQueue();
    media.close(_image);
    files.readGate!.complete();
    await opening;

    expect(doc(_image), isNull);
    expect(container.read(mediaDocumentsProvider), isEmpty);
  });

  test('a remote video is copied to the cache, with its progress', () async {
    final bytes = List<int>.generate(
      kMediaCopyChunkBytes * 2 + 10,
      (i) => i % 251,
    );
    files.put(_video, bytes);
    final progress = <double>[];
    final sub = container.listen(
      mediaDocumentsProvider.select((open) => open[_video]?.copyProgress),
      (_, next) {
        if (next != null) progress.add(next);
      },
    );

    await media.open(_video);
    sub.close();

    final shown = doc(_video)!;
    expect(shown.isReady, isTrue);
    expect(shown.copyProgress, isNull);
    expect(p.isWithin(cache.path, shown.localPath!), isTrue);
    expect(File(shown.localPath!).readAsBytesSync(), bytes);
    expect(progress, isNotEmpty);
    expect(progress.last, 1.0);
  });
}
