import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/capabilities/capabilities.dart';
import 'package:karmashala/src/core/data/data_client.dart';
import 'package:karmashala/src/features/editor/application/media_documents.dart';
import 'package:karmashala/src/features/editor/data/media_store.dart';
import 'package:karmashala/src/features/editor/domain/media_document.dart';
import 'package:karmashala/src/features/editor/domain/media_kind.dart';
import 'package:karmashala/src/features/editor/domain/source_document.dart'
    show kDocumentSizeLimit;
import 'package:karmashala/src/features/files/data/files_client.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show FileChanged;
import 'package:karmashala_files/values.dart' show FileStamp, FileStat;
import 'package:karmashala_ui/tokens.dart' show UiDensity;
import 'package:path/path.dart' as p;

const _image = '/repo/assets/shot.png';
const _video = '/srv/clips/talk.mp4';
const _other = '/srv/clips/demo.mp4';

/// Short enough to wait out, long enough that a burst lands inside it.
const _debounce = Duration(milliseconds: 40);

/// Long enough for a debounced reload to fire and finish.
Future<void> _settled() async {
  await Future<void>.delayed(_debounce * 4);
  await pumpEventQueue();
}

/// A client with a media backend, whatever this test runs on.
ClientCapabilities _desktopPlayer() => _client(mediaPlayback: true);

/// A phone: no media backend.
ClientCapabilities _phone() => _client(mediaPlayback: false);

ClientCapabilities _client({required bool mediaPlayback}) => ClientCapabilities(
  systemIntegration: mediaPlayback,
  osToasts: mediaPlayback,
  localNotifications: !mediaPlayback,
  localDevices: mediaPlayback,
  externalApps: mediaPlayback,
  fileDrop: mediaPlayback,
  relaunch: mediaPlayback,
  density: mediaPlayback ? UiDensity.pointer : UiDensity.touch,
  hostsServer: mediaPlayback,
  multicastLock: !mediaPlayback,
  mediaPlayback: mediaPlayback,
  deviceName: 'test client',
  camera: !mediaPlayback,
);

/// [length] bytes of a recognisable pattern.
List<int> _clip(int length, {int seed = 0}) =>
    List<int>.generate(length, (i) => (i + seed) % 251);

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

  /// The first read [readGate] holds — 0 is every read, 1 lets one chunk of
  /// a copy through first.
  var gateFrom = 0;

  /// Completes when a read reaches [readGate] and starts waiting on it — the
  /// point a test can be sure every earlier read went through.
  final held = Completer<void>();

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
    FileChanged(environmentId: localHostEnvironmentId, path: path, stamp: null),
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
    final n = reads++;
    if (readGate != null && n >= gateFrom) {
      if (!held.isCompleted) held.complete();
      await readGate!.future;
    }
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
  var attached = false;

  MediaDocument? doc(String id) => container.read(mediaDocumentsProvider)[id];

  /// The cache's files, part files included.
  List<String> cached() => cache
      .listSync()
      .whereType<File>()
      .map((file) => p.basename(file.path))
      .toList();

  /// Swaps the container for one on [client] whose store caps its cache at
  /// [cacheLimit].
  void attach({
    ClientCapabilities? client,
    int cacheLimit = kMediaCacheLimitBytes,
  }) {
    if (attached) container.dispose();
    attached = true;
    container = ProviderContainer(
      overrides: [
        filesClientProvider.overrideWithValue(files),
        clientCapabilitiesProvider.overrideWithValue(
          client ?? _desktopPlayer(),
        ),
        mediaWatchDebounceProvider.overrideWithValue(_debounce),
        mediaStoreProvider.overrideWithValue(
          MediaStore(
            files,
            cacheDirectory: cache.path,
            cacheLimitBytes: cacheLimit,
          ),
        ),
      ],
    );
    media = container.read(mediaDocumentsProvider.notifier);
  }

  setUp(() {
    cache = Directory.systemTemp.createTempSync('karmashala_media_');
    files = _FakeFiles();
    attach();
  });
  tearDown(() {
    container.dispose();
    attached = false;
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
    await _settled();

    final shown = doc(_image)!;
    expect(shown.bytes, [9, 9]);
    expect(shown.revision, 1);
  });

  test(
    'a burst of watch events reloads once, after the file settles',
    tags: 'shared-runner',
    () async {
      files.put(_image, [1, 2, 3]);
      await media.open(_image);

      // An agent writing the file: three events, the last version is [7].
      files
        ..put(_image, [5])
        ..changed(_image)
        ..put(_image, [6])
        ..changed(_image)
        ..put(_image, [7])
        ..changed(_image);
      await pumpEventQueue();

      // Not yet quiet for the debounce: nothing read, nothing bumped.
      expect(files.reads, 1);
      expect(doc(_image)!.revision, 0);

      await _settled();

      expect(files.reads, 2);
      expect(doc(_image)!.bytes, [7]);
      expect(doc(_image)!.revision, 1);
    },
  );

  test('a watch event for an unchanged file bumps nothing', () async {
    files.put(_image, [1, 2, 3]);
    await media.open(_image);

    files.changed(_image);
    await _settled();

    expect(files.reads, 1);
    expect(doc(_image)!.revision, 0);
  });

  test('a closed tab cancels its pending watch reload', () async {
    files.put(_image, [1, 2, 3]);
    await media.open(_image);

    files
      ..put(_image, [4])
      ..changed(_image);
    media.close(_image);
    await _settled();

    expect(files.reads, 1);
    expect(doc(_image), isNull);
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

  test('a phone holds a remote video by path, never reading it', () async {
    attach(client: _phone());
    files.put(_video, _clip(kMediaCopyChunkBytes + 10));

    await media.open(_video);

    var shown = doc(_video)!;
    expect(shown.refusal, MediaRefusal.none);
    expect(shown.kind, MediaKind.video);
    expect(shown.localPath, isNull);
    expect(shown.bytes, isNull);
    expect(shown.stamp, isNotNull);
    expect(shown.copyProgress, isNull);
    expect(files.reads, 0);
    expect(cached(), isEmpty);

    // A new version is noticed by its stamp, and still not copied.
    files
      ..put(_video, _clip(20))
      ..changed(_video);
    await _settled();

    shown = doc(_video)!;
    expect(shown.stamp?.length, 20);
    expect(shown.revision, 1);
    expect(shown.localPath, isNull);
    expect(files.reads, 0);
    expect(cached(), isEmpty);
  });

  test(
    'closing a tab mid-copy stops the copy and leaves no part file',
    () async {
      files
        ..put(_video, _clip(kMediaCopyChunkBytes * 3))
        ..gateFrom = 1
        ..readGate = Completer<void>();

      final opening = media.open(_video);
      // Not pumpEventQueue: the part file's open and first write are real
      // disk I/O, which a few event-loop turns do not reliably outlast.
      await files.held.future;
      // One chunk through, the second held: the part file is on disk.
      expect(cached().where((name) => name.endsWith('.part')), hasLength(1));

      media.close(_video);
      files.readGate!.complete();
      await opening;
      await pumpEventQueue();

      expect(doc(_video), isNull);
      expect(cached(), isEmpty);
      // The held read finished; no third chunk was asked for.
      expect(files.reads, 2);
    },
  );

  test('a new version replaces the older copy in the cache', () async {
    files.put(_video, _clip(100));
    await media.open(_video);
    final first = doc(_video)!.localPath!;

    files.put(_video, _clip(120, seed: 7));
    await media.reload(_video);

    final second = doc(_video)!;
    expect(second.localPath, isNot(first));
    expect(second.revision, 1);
    expect(File(second.localPath!).readAsBytesSync(), _clip(120, seed: 7));
    expect(File(first).existsSync(), isFalse);
    expect(cached(), [p.basename(second.localPath!)]);
  });

  test('the cache drops its least recently used copy over the cap', () async {
    attach(cacheLimit: 150);
    files
      ..put(_video, _clip(100))
      ..put(_other, _clip(100, seed: 3));

    await media.open(_video);
    final old = doc(_video)!.localPath!;
    File(old).setLastModifiedSync(DateTime.utc(2020));
    await media.open(_other);

    final kept = doc(_other)!.localPath!;
    expect(File(old).existsSync(), isFalse);
    expect(cached(), [p.basename(kept)]);
  });
}
