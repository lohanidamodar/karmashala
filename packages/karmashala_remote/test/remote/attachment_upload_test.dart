/// A file crossing the link, and everything that must be refused instead: does
/// a chunk actually fit inside an envelope once base64 and the seal are on it,
/// and what a half-delivered attachment leaves behind.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import './fake_bindings.dart' show kFakeDeviceId;
import './host_session_api_test.dart' show Harness;

/// One upload driven through the api the way the phone drives it.
extension on Harness {
  Future<String> begin({
    String sessionId = 's1',
    String name = 'IMG_4821.jpg',
    String type = 'image/jpeg',
    required int bytes,
  }) async {
    await request(
      FrameType.attachmentBegin,
      payload: {
        'sessionId': sessionId,
        'name': name,
        'type': type,
        'bytes': bytes,
      },
    );
    return last.payload['uploadId'] as String? ?? '';
  }

  Future<void> chunk(String uploadId, int seq, List<int> data) => request(
    FrameType.attachmentChunk,
    payload: {'uploadId': uploadId, 'seq': seq, 'data': base64Encode(data)},
  );

  Future<void> promptWith(String uploadId, {String text = 'look at this'}) =>
      request(
        FrameType.promptSend,
        payload: {'sessionId': 's1', 'text': text, 'attachment': uploadId},
      );
}

Uint8List _bytes(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) i & 0xff]);

void main() {
  group('the size the link can carry', () {
    // Base64 costs four characters per three bytes, and the envelope and the
    // seal add their own, so a chunk sized against the raw cap would be over it.
    test('a full chunk clears the envelope and transport caps', () {
      final wire = Envelope.of(
        FrameType.attachmentChunk,
        // The widest every field this frame can have ever gets.
        seq: Envelope.maxSequence,
        id: 'q' * 32,
        payload: {
          'uploadId': 'f' * 32,
          'seq': 4095,
          'data': base64Encode(Uint8List(kAttachmentChunkBytes)),
        },
      ).toBytes();
      final sealed = wire.length + kSealedFrameOverhead;

      expect(
        sealed,
        lessThan(kMaxEnvelopeBytes),
        reason:
            '$kAttachmentChunkBytes raw bytes seal to $sealed, which must '
            'clear the $kMaxEnvelopeBytes envelope cap',
      );
      expect(sealed, lessThan(kMaxTransportFrameBytes));
      // And conservatively so, not by a hair: every frame on a device's chain
      // queues behind the transcript sweep, and a frame that fills an envelope
      // is the shape of payload that starved this link before.
      expect(
        sealed,
        lessThan(kMaxEnvelopeBytes ~/ 4),
        reason: 'a chunk should be a fraction of the cap, not most of it',
      );
      expect(Envelope.fromBytes(wire).type, FrameType.attachmentChunk.wire);
    });

    test('a 4 MB photo is a bounded number of chunks, not one frame', () {
      const photo = 4 * 1024 * 1024;
      final chunks = (photo / kAttachmentChunkBytes).ceil();

      expect(chunks, 32);
      expect(
        photo,
        greaterThan(kMaxEnvelopeBytes),
        reason: 'this is why it is chunked at all',
      );
      // The queue drops its oldest frame past this, which is exactly why each
      // chunk is answered before the next goes out.
      expect(chunks, lessThan(256));
    });

    test('the cap is what the desktop already handles for a picture', () {
      expect(kMaxAttachmentBytes, 12 * 1024 * 1024);
      expect(
        (kMaxAttachmentBytes / kAttachmentChunkBytes).ceil(),
        96,
        reason: 'the largest attachment, in slices',
      );
    });
  });

  group('a file the phone sends', () {
    test('crosses in slices and is offered, not sent', () async {
      final harness = Harness();
      final content = _bytes(kAttachmentChunkBytes + 40);
      final uploadId = await harness.begin(bytes: content.length);

      expect(uploadId, isNotEmpty);
      expect(
        harness.last.payload['chunkBytes'],
        kAttachmentChunkBytes,
        reason: 'the host says how big a slice is; the phone does not guess',
      );

      var seq = 0;
      for (var at = 0; at < content.length; at += kAttachmentChunkBytes) {
        final end = (at + kAttachmentChunkBytes).clamp(0, content.length);
        await harness.chunk(
          uploadId,
          seq++,
          Uint8List.sublistView(content, at, end),
        );
        expect(
          harness.last.type,
          FrameType.result,
          reason: 'each slice is answered before the next is sent',
        );
      }
      expect(seq, 2);
      expect(harness.fake.uploads[uploadId], hasLength(content.length));

      await harness.promptWith(uploadId);

      expect(harness.last.type, FrameType.result);
      expect(
        harness.last.payload['delivery'],
        RemotePromptDelivery.offered.wire,
        reason:
            'the phone must not be told "sent" when a person still has to '
            'press Enter on the desktop',
      );
      expect(harness.fake.committed, [uploadId]);
      expect(harness.fake.prompts.single.text, 'look at this');
      expect(harness.fake.promptAttachments.single, uploadId);
    });

    test('a prompt of plain words keeps the old result shape', () async {
      final harness = Harness();

      await harness.request(
        FrameType.promptSend,
        payload: {'sessionId': 's1', 'text': 'carry on'},
      );

      expect(harness.last.payload, isEmpty);
      expect(harness.fake.promptAttachments.single, isNull);
    });
  });

  group('a half-delivered attachment', () {
    test('is refused at the prompt rather than committed short', () async {
      final harness = Harness();
      final uploadId = await harness.begin(bytes: 3000);
      await harness.chunk(uploadId, 0, _bytes(1000));

      await harness.promptWith(uploadId);

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(
        harness.last.payload['message'],
        allOf(contains('1000'), contains('3000')),
      );
      expect(
        harness.fake.committed,
        isEmpty,
        reason:
            'nothing an agent can be told to read comes out of a short '
            'upload',
      );
      expect(
        harness.fake.prompts,
        isEmpty,
        reason: 'and the prompt does not go without it',
      );
    });

    test('with a lost slice is refused at the gap', () async {
      final harness = Harness();
      final uploadId = await harness.begin(bytes: 3000);
      await harness.chunk(uploadId, 0, _bytes(1000));

      // What the outbound queue dropping its oldest frame looks like from here.
      await harness.chunk(uploadId, 2, _bytes(1000));

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
    });

    test('cannot be quoted by a prompt after the link dropped it', () async {
      final harness = Harness();
      final uploadId = await harness.begin(bytes: 4);
      await harness.chunk(uploadId, 0, _bytes(4));

      // What `_DeviceRuntime.close` does: the upload belonged to the link.
      await harness.fake.bindings.discardAttachment(kFakeDeviceId);
      await harness.promptWith(uploadId);

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
    });

    test('a chunk with no upload open is refused, not staged', () async {
      final harness = Harness();

      await harness.chunk('nosuchupload', 0, _bytes(4));

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.fake.uploads, isEmpty);
    });

    test(
      'a chunk that is not base64 is refused before it reaches the store',
      () async {
        final harness = Harness();
        final uploadId = await harness.begin(bytes: 4);

        await harness.request(
          FrameType.attachmentChunk,
          payload: {'uploadId': uploadId, 'seq': 0, 'data': 'not base64 !!'},
        );

        expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
        expect(harness.fake.uploads[uploadId], isEmpty);
      },
    );
  });

  group('refused before a byte crosses', () {
    test(
      'an agent that cannot be handed a file, in the host\'s words',
      () async {
        final harness = Harness();
        harness.fake.addSession(
          's2',
          attachments: const RemoteAttachmentSupport.refused(
            'Codex only takes a picture on the command line that starts it.',
          ),
        );

        await harness.begin(sessionId: 's2', bytes: 4);

        expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
        expect(harness.last.payload['message'], contains('Codex'));
        expect(
          harness.fake.uploads,
          isEmpty,
          reason: 'this is the whole point of a separate begin frame',
        );
      },
    );

    test(
      'a host that has never been asked says so rather than accepting',
      () async {
        final harness = Harness();
        harness.fake.addSession('s3', attachments: null);

        await harness.begin(sessionId: 's3', bytes: 4);

        expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      },
    );

    test('a media type this session does not take', () async {
      final harness = Harness();

      await harness.begin(type: 'audio/mp4', name: 'note.m4a', bytes: 4);

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.last.payload['message'], contains('image/png'));
    });

    test('a file bigger than the session takes', () async {
      final harness = Harness();

      await harness.begin(bytes: kMaxAttachmentBytes + 1);

      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.fake.uploads, isEmpty);
    });

    test('a session that does not exist', () async {
      final harness = Harness();

      await harness.begin(sessionId: 'gone', bytes: 4);

      expect(harness.lastErrorCode(), ErrorCode.notFound.wire);
    });
  });

  group('a pairing made before this existed', () {
    CapabilitySet without(Capability capability) =>
        CapabilitySet(CapabilitySet.all.bits & ~capability.bit);

    test('is refused in words when it asks to send a file', () async {
      final harness = Harness(capabilities: without(Capability.sendAttachment));

      await harness.begin(bytes: 4);

      expect(harness.lastErrorCode(), ErrorCode.notPermitted.wire);
      expect(
        harness.last.payload['message'],
        'this device was not granted send_attachment',
      );
    });

    test('can still send words', () async {
      final harness = Harness(capabilities: without(Capability.sendAttachment));

      await harness.request(
        FrameType.promptSend,
        payload: {'sessionId': 's1', 'text': 'carry on'},
      );

      expect(harness.last.type, FrameType.result);
      expect(harness.fake.prompts.single.text, 'carry on');
    });

    // The second door: `prompt.send` is a frame an old pairing *does* hold a
    // bit for, so the one that would spend an attachment is checked there too.
    test('is refused in the same words on a prompt that quotes one', () async {
      final harness = Harness(capabilities: without(Capability.sendAttachment));

      await harness.promptWith('up1');

      expect(harness.lastErrorCode(), ErrorCode.notPermitted.wire);
      expect(
        harness.last.payload['message'],
        'this device was not granted send_attachment',
      );
      expect(harness.fake.prompts, isEmpty);
    });
  });
}
