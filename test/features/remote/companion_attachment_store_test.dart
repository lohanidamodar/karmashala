/// What a phone's bytes become on this disk, and what becomes of them after.
///
/// Everything here is counted, never timed: how many chunks were accepted, how
/// many files survive a prune, how many bytes reached the committed file. The
/// one place a clock appears is `setLastModified`, which is the test *setting*
/// the order a prune reads — not measuring anything.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/features/remote/data/companion_attachment_store.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const String _device = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

RemoteAttachmentBegin _request({
  String name = 'IMG_4821.jpg',
  String type = 'image/jpeg',
  required int bytes,
}) => RemoteAttachmentBegin(
  sessionId: 's1',
  name: name,
  mediaType: type,
  bytes: bytes,
);

Uint8List _bytes(int length, [int seed = 0]) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (seed + i) & 0xff]);

int _countFiles(Directory dir, String prefix) {
  if (!dir.existsSync()) return 0;
  return dir
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) => f.uri.pathSegments.last.startsWith(prefix))
      .length;
}

void main() {
  late Directory root;
  late CompanionAttachmentStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('attach_store');
    store = CompanionAttachmentStore(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('a whole file arrives, and only the committed name is a real file',
      () async {
    final content = _bytes(300);
    final offer = await store.begin(_device, _request(bytes: content.length));
    await store.write(_device, offer.uploadId, 0, content);

    // Before the commit there is nothing an agent could be handed: the bytes
    // are in `incoming/`, under a name nothing outside this store knows.
    expect(_countFiles(root, kCompanionAttachmentPrefix), 0);

    final file = await store.commit(_device, offer.uploadId);

    expect(await file.readAsBytes(), content);
    expect(file.uri.pathSegments.last, endsWith('_IMG_4821.jpg'));
    expect(_countFiles(root, kCompanionAttachmentPrefix), 1);
    expect(
      Directory('${root.path}/incoming').listSync().whereType<File>(),
      isEmpty,
      reason: 'the staged copy is renamed, not duplicated',
    );
  });

  test('a photo-sized file crosses in chunks and reassembles exactly',
      () async {
    // Two and a bit chunks: enough that a boundary bug shows, small enough
    // that the test is about the arithmetic rather than about megabytes.
    final content = _bytes(kAttachmentChunkBytes * 2 + 517, 7);
    final offer = await store.begin(_device, _request(bytes: content.length));

    var seq = 0;
    for (var at = 0; at < content.length; at += offer.chunkBytes) {
      final end = (at + offer.chunkBytes).clamp(0, content.length);
      await store.write(
        _device,
        offer.uploadId,
        seq++,
        Uint8List.sublistView(content, at, end),
      );
    }

    expect(seq, 3, reason: 'a $kAttachmentChunkBytes byte chunk, three of them');
    final file = await store.commit(_device, offer.uploadId);
    expect(await file.length(), content.length);
    expect(await file.readAsBytes(), content);
  });

  group('a half-delivered attachment', () {
    test('is refused at the commit rather than written short', () async {
      final offer = await store.begin(_device, _request(bytes: 1000));
      await store.write(_device, offer.uploadId, 0, _bytes(400));

      await expectLater(
        store.commit(_device, offer.uploadId),
        throwsA(
          isA<AttachmentUploadException>().having(
            (e) => e.message,
            'message',
            allOf(contains('400'), contains('1000')),
          ),
        ),
      );
      expect(
        _countFiles(root, kCompanionAttachmentPrefix),
        0,
        reason: 'nothing an agent can be told to read may come out of this',
      );
      expect(
        _countFiles(Directory('${root.path}/incoming'), _device),
        0,
        reason: 'and the staged bytes go with the refusal',
      );
    });

    test('with a missing slice is refused at the gap, not padded', () async {
      final offer = await store.begin(_device, _request(bytes: 3000));
      await store.write(_device, offer.uploadId, 0, _bytes(1000));

      // What the outbound queue dropping its oldest frame looks like here.
      await expectLater(
        store.write(_device, offer.uploadId, 2, _bytes(1000)),
        throwsA(
          isA<AttachmentUploadException>().having(
            (e) => e.message,
            'message',
            contains('a slice was lost'),
          ),
        ),
      );
    });

    test('is dropped when the same device starts another', () async {
      final first = await store.begin(_device, _request(bytes: 1000));
      await store.write(_device, first.uploadId, 0, _bytes(400));
      final second = await store.begin(_device, _request(bytes: 10));

      expect(
        _countFiles(Directory('${root.path}/incoming'), _device),
        1,
        reason: 'one upload per device: the abandoned one is gone, not kept',
      );
      await expectLater(
        store.write(_device, first.uploadId, 1, _bytes(10)),
        throwsA(isA<AttachmentUploadException>()),
      );
      await store.write(_device, second.uploadId, 0, _bytes(10));
      expect(await (await store.commit(_device, second.uploadId)).length(), 10);
    });

    test('is dropped when the device\'s link ends', () async {
      final offer = await store.begin(_device, _request(bytes: 1000));
      await store.write(_device, offer.uploadId, 0, _bytes(400));

      await store.discard(_device);

      expect(_countFiles(Directory('${root.path}/incoming'), _device), 0);
      await expectLater(
        store.commit(_device, offer.uploadId),
        throwsA(isA<AttachmentUploadException>()),
      );
    });

    test('left by a previous run is cleared by the start sweep', () async {
      final stale = Directory('${root.path}/incoming')
        ..createSync(recursive: true);
      File('${stale.path}/somebody_else.part').writeAsBytesSync(_bytes(50));

      await store.sweep();

      expect(stale.existsSync(), isFalse);
    });
  });

  group('what the declaration alone can refuse', () {
    test('an oversized file, before a byte crosses', () async {
      await expectLater(
        store.begin(_device, _request(bytes: kMaxAttachmentBytes + 1)),
        throwsA(isA<AttachmentUploadException>()),
      );
      expect(Directory('${root.path}/incoming').existsSync(), isFalse);
    });

    test('a media type this desktop cannot name a file for', () async {
      await expectLater(
        store.begin(
          _device,
          _request(type: 'audio/mp4', name: 'note.m4a', bytes: 10),
        ),
        throwsA(
          isA<AttachmentUploadException>().having(
            (e) => e.message,
            'message',
            contains('audio/mp4'),
          ),
        ),
      );
    });

    test('a chunk longer than a chunk', () async {
      final offer = await store.begin(
        _device,
        _request(bytes: kAttachmentChunkBytes * 2),
      );
      await expectLater(
        store.write(_device, offer.uploadId, 0, _bytes(kAttachmentChunkBytes + 1)),
        throwsA(isA<AttachmentUploadException>()),
      );
    });

    test('more bytes than were declared', () async {
      final offer = await store.begin(_device, _request(bytes: 100));
      await expectLater(
        store.write(_device, offer.uploadId, 0, _bytes(101)),
        throwsA(
          isA<AttachmentUploadException>().having(
            (e) => e.message,
            'message',
            contains('longer than it said'),
          ),
        ),
      );
    });
  });

  group('the name is the host\'s, not the phone\'s', () {
    Future<String> committedNameFor(String sent, {String type = 'image/png'}) async {
      final offer = await store.begin(
        _device,
        _request(name: sent, type: type, bytes: 4),
      );
      await store.write(_device, offer.uploadId, 0, _bytes(4));
      final file = await store.commit(_device, offer.uploadId);
      return file.uri.pathSegments.last;
    }

    test('a path in the name cannot choose where a byte lands', () async {
      final name = await committedNameFor(r'../../../../Users/x/.ssh/id_rsa');
      expect(name, endsWith('_id_rsa.png'));
      expect(name, isNot(contains('..')));
      expect(name, isNot(contains('/')));
    });

    test('the extension comes from the media type, never from the name',
        () async {
      expect(
        await committedNameFor('shot.exe', type: 'image/png'),
        endsWith('.png'),
      );
    });

    test('a name that survives to nothing still gets one', () async {
      // A path an agent cannot pronounce is worse than a generic one.
      expect(await committedNameFor('***'), endsWith('_attachment.png'));
      expect(await committedNameFor('.'), endsWith('_attachment.png'));
      expect(await committedNameFor('..hidden.png'), endsWith('_hidden.png'));
    });
  });

  test('committed attachments are pruned to the newest, and only ours',
      () async {
    const keep = 3;
    store = CompanionAttachmentStore(root, keep: keep);
    root.createSync(recursive: true);
    // What the desktop composer's own attach leaves in this same directory.
    final theirs = File('${root.path}/img_1234.png')
      ..writeAsBytesSync(_bytes(4));

    final committed = <File>[];
    for (var i = 0; i < keep + 2; i++) {
      final offer = await store.begin(
        _device,
        _request(name: 'shot$i.png', type: 'image/png', bytes: 4),
      );
      await store.write(_device, offer.uploadId, 0, _bytes(4));
      final file = await store.commit(_device, offer.uploadId);
      // The order the prune reads, said outright rather than raced for.
      file.setLastModifiedSync(DateTime.utc(2026, 9, 1 + i));
      committed.add(file);
    }
    // One more commit, so the prune runs against the order just written.
    final last = await store.begin(
      _device,
      _request(name: 'newest.png', type: 'image/png', bytes: 4),
    );
    await store.write(_device, last.uploadId, 0, _bytes(4));
    final newest = await store.commit(_device, last.uploadId);

    expect(_countFiles(root, kCompanionAttachmentPrefix), keep);
    expect(newest.existsSync(), isTrue);
    expect(committed.first.existsSync(), isFalse, reason: 'the oldest goes');
    expect(
      theirs.existsSync(),
      isTrue,
      reason: 'the composer\'s own attachments are not ours to delete',
    );
  });
}
