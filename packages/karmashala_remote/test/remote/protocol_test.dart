import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  group('envelope', () {
    test('round-trips through bytes', () {
      final sent = Envelope.of(
        FrameType.promptSend,
        seq: 42,
        id: 'req-7',
        payload: {'sessionId': 's1', 'text': 'hello'},
      );

      final got = Envelope.fromBytes(sent.toBytes());

      expect(got.version, kProtocolVersion);
      expect(got.seq, 42);
      expect(got.type, 'prompt.send');
      expect(got.knownType, FrameType.promptSend);
      expect(got.id, 'req-7');
      expect(got.payload, {'sessionId': 's1', 'text': 'hello'});
    });

    test('uses the field names the spec shows', () {
      final json =
          jsonDecode(
                utf8.decode(
                  Envelope.of(
                    FrameType.sessionsList,
                    seq: 1,
                    id: 'a',
                  ).toBytes(),
                ),
              )
              as Map<String, Object?>;

      expect(json.keys.toSet(), {'v', 'seq', 't', 'id', 'p'});
    });

    test('omits id when there is none', () {
      final json =
          jsonDecode(
                utf8.decode(
                  Envelope.of(FrameType.sessionChanged, seq: 3).toBytes(),
                ),
              )
              as Map<String, Object?>;

      expect(json.containsKey('id'), isFalse);
    });

    test('round-trips a payload with nested structure', () {
      final sent = Envelope.of(
        FrameType.transcriptAppended,
        seq: 9,
        payload: {
          'sessionId': 's1',
          'entries': [
            {'role': 'agent', 'text': 'done', 'at': 1700000000},
          ],
          'more': false,
        },
      );

      final got = Envelope.fromBytes(sent.toBytes());

      expect(got.payload['entries'], isA<List<Object?>>());
      expect((got.payload['entries']! as List).single, {
        'role': 'agent',
        'text': 'done',
        'at': 1700000000,
      });
    });

    test('payload is not mutable through the envelope', () {
      final envelope = Envelope.of(
        FrameType.sessionsList,
        seq: 1,
        payload: {'a': 1},
      );

      expect(() => envelope.payload['b'] = 2, throwsUnsupportedError);
    });

    test('a type this build predates decodes and keeps its wire name', () {
      final bytes = utf8.encode(
        jsonEncode({'v': 1, 'seq': 5, 't': 'session.forked', 'p': {}}),
      );

      final got = Envelope.fromBytes(bytes);

      expect(got.type, 'session.forked');
      expect(got.knownType, isNull);
    });

    test('a version outside the supported range is refused', () {
      final bytes = utf8.encode(
        jsonEncode({'v': 2, 'seq': 1, 't': 'sessions.list', 'p': {}}),
      );

      expect(
        () => Envelope.fromBytes(bytes),
        throwsA(isA<UnsupportedProtocolVersion>()),
      );
    });

    test('an out-of-range version can still be read to answer it', () {
      final bytes = utf8.encode(
        jsonEncode({'v': 99, 'seq': 1, 't': 'sessions.list', 'p': {}}),
      );

      final got = Envelope.fromBytes(bytes, accept: VersionRange.any);

      expect(got.version, 99);
      expect(got.knownType, FrameType.sessionsList);
    });

    test('rejects malformed frames', () {
      Object? decode(Object? json) =>
          Envelope.fromBytes(utf8.encode(jsonEncode(json)));

      expect(
        () => decode({'seq': 1, 't': 'x', 'p': {}}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decode({'v': 1, 't': 'x', 'p': {}}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decode({'v': 1, 'seq': 1, 'p': {}}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decode({'v': 1, 'seq': 1, 't': 'x', 'id': 3, 'p': {}}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => decode({'v': 1, 'seq': 1, 't': 'x', 'p': 'nope'}),
        throwsA(isA<ProtocolException>()),
      );
      expect(() => decode([1, 2, 3]), throwsA(isA<ProtocolException>()));
      expect(
        () => Envelope.fromBytes(utf8.encode('not json')),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('refuses an envelope larger than the cap', () {
      final huge = Uint8List(kMaxEnvelopeBytes + 1);

      expect(() => Envelope.fromBytes(huge), throwsA(isA<ProtocolException>()));
    });

    test('refuses a sequence outside the exact-integer range', () {
      expect(
        () => Envelope.of(FrameType.sessionsList, seq: -1),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () =>
            Envelope.of(FrameType.sessionsList, seq: Envelope.maxSequence + 1),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('frame types', () {
    test('cover the spec table', () {
      expect(FrameType.values.map((t) => t.wire).toSet(), {
        'sessions.list',
        'session.subscribe',
        'session.unsubscribe',
        'transcript.get',
        'prompt.send',
        'approval.answer',
        'question.answer',
        'menu.answer',
        'usage.get',
        'notes.get',
        'notifications.register',
        'workspace.list',
        'projects.list',
        'project.add',
        'session.start',
        'session.resume',
        'session.activity',
        'attachment.begin',
        'attachment.chunk',
        'stream.ack',
        // The keepalive and the resume of a dropped switched link (Stage 0).
        'link.ping',
        'link.resume',
        'link.relay.move',
        'link.relay.moved',
        'host.attach',
        'session.options',
        'session.configure',
        'session.changed',
        'transcript.appended',
        'approval.requested',
        'approval.resolved',
        'host.status',
        'pairing.revoked',
        'result',
        'error',
      });
    });

    test('carry the capability the spec gates them with', () {
      expect(FrameType.hostAttach.capability, Capability.desktopClient);
      expect(FrameType.sessionsList.capability, Capability.viewSessions);
      expect(FrameType.sessionSubscribe.capability, Capability.viewSessions);
      expect(FrameType.transcriptGet.capability, Capability.readTranscript);
      expect(FrameType.promptSend.capability, Capability.sendPrompt);
      expect(FrameType.approvalAnswer.capability, Capability.approve);
      expect(FrameType.questionAnswer.capability, Capability.approve);
      expect(
        FrameType.notificationsRegister.capability,
        Capability.receiveNotifications,
      );
      expect(FrameType.workspaceList.capability, Capability.startSession);
      expect(FrameType.projectsList.capability, Capability.viewSessions);
      expect(FrameType.projectAdd.capability, Capability.addProject);
      expect(FrameType.sessionStart.capability, Capability.startSession);
      expect(FrameType.sessionResume.capability, Capability.startSession);
      expect(FrameType.sessionActivity.capability, Capability.viewActivity);
      expect(FrameType.attachmentBegin.capability, Capability.sendAttachment);
      expect(FrameType.attachmentChunk.capability, Capability.sendAttachment);
    });

    // Both are the phone's own verbs. `session.activity` needed
    // [FrameOrigin.either] because the host states it unprompted too; nothing
    // here is ever host-sent.
    test('the attachment frames are the companion\'s alone', () {
      for (final type in [
        FrameType.attachmentBegin,
        FrameType.attachmentChunk,
      ]) {
        expect(type.sentBy(FrameOrigin.companion), isTrue);
        expect(type.sentBy(FrameOrigin.host), isFalse);
        expect(
          CapabilitySet.none.allows(type),
          isFalse,
          reason: 'a pairing without the bit must be refused, never served',
        );
        expect(
          CapabilitySet.of([Capability.sendAttachment]).allows(type),
          isTrue,
        );
      }
      // And holding `send_prompt` grants none of it: a phone paired before
      // this existed can still send words, and is refused the file for ever.
      expect(
        CapabilitySet.of([
          Capability.sendPrompt,
        ]).has(Capability.sendAttachment),
        isFalse,
      );
    });

    test('host events need no capability and are host-sent', () {
      for (final type in [
        FrameType.sessionChanged,
        FrameType.transcriptAppended,
        FrameType.approvalRequested,
        FrameType.hostStatus,
        FrameType.result,
      ]) {
        expect(type.capability, isNull, reason: type.wire);
        expect(type.sentBy(FrameOrigin.host), isTrue, reason: type.wire);
        expect(type.sentBy(FrameOrigin.companion), isFalse, reason: type.wire);
      }
    });

    test('errors travel in both directions', () {
      expect(FrameType.error.sentBy(FrameOrigin.host), isTrue);
      expect(FrameType.error.sentBy(FrameOrigin.companion), isTrue);
    });

    test('an unknown wire name parses to null', () {
      expect(FrameType.tryParse('sessions.list'), FrameType.sessionsList);
      expect(FrameType.tryParse('session.forked'), isNull);
    });

    test('wire names are unique', () {
      expect(
        FrameType.values.map((t) => t.wire).toSet().length,
        FrameType.values.length,
      );
    });
  });

  group('capabilities', () {
    test('are the bitset the pairing payload carries', () {
      final set = CapabilitySet.of([
        Capability.viewSessions,
        Capability.sendPrompt,
      ]);

      expect(set.bits, 0x05);
      expect(CapabilitySet.fromJson(set.toJson()), set);
      expect(set.granted, {Capability.viewSessions, Capability.sendPrompt});
    });

    test('bits are unique and stable', () {
      expect(Capability.viewSessions.bit, 1);
      expect(Capability.readTranscript.bit, 2);
      expect(Capability.sendPrompt.bit, 4);
      expect(Capability.approve.bit, 8);
      expect(Capability.receiveNotifications.bit, 16);
      expect(Capability.startSession.bit, 32);
      expect(Capability.addProject.bit, 64);
      // Its own bit, so a phone paired before this existed holds a bitset
      // without it and is refused for ever rather than quietly gaining a live
      // read of the machine.
      expect(Capability.viewActivity.bit, 128);
      // Same convention again: a phone paired before this existed cannot be
      // handed the power to write a file onto the desktop's disk.
      expect(Capability.sendAttachment.bit, 256);
      expect(
        Capability.values.map((c) => c.bit).toSet().length,
        Capability.values.length,
      );
    });

    test('gate the frame types the spec says they gate', () {
      final viewer = CapabilitySet.of([Capability.viewSessions]);

      expect(viewer.allows(FrameType.sessionsList), isTrue);
      expect(viewer.allows(FrameType.sessionSubscribe), isTrue);
      expect(viewer.allows(FrameType.promptSend), isFalse);
      expect(viewer.allows(FrameType.approvalAnswer), isFalse);
      expect(viewer.allows(FrameType.transcriptGet), isFalse);
    });

    test('never gate host frames', () {
      expect(CapabilitySet.none.allows(FrameType.sessionChanged), isTrue);
      expect(CapabilitySet.none.allows(FrameType.error), isTrue);
    });

    test('a bit this build does not know grants nothing', () {
      final fromNewerPeer = CapabilitySet.fromJson(1 << 20);

      expect(fromNewerPeer.granted, isEmpty);
      expect(fromNewerPeer.allows(FrameType.promptSend), isFalse);
      expect(fromNewerPeer.toJson(), 1 << 20, reason: 'survives round-trip');
    });

    test('combine and intersect', () {
      final a = CapabilitySet.of([Capability.viewSessions]);
      final b = CapabilitySet.of([Capability.approve]);

      expect((a | b).granted, {Capability.viewSessions, Capability.approve});
      expect((a & b), CapabilitySet.none);
      // "all" is a phone's everything: the desktop grants are named.
      expect(
        CapabilitySet.all.granted,
        Capability.values.where((c) => !c.privileged).toSet(),
      );
      expect(Capability.values.where((c) => c.privileged).map((c) => c.bit), [
        1 << 10,
        1 << 11,
        1 << 12,
      ]);
    });

    test('refuses a bitset that is not a non-negative integer', () {
      expect(
        () => CapabilitySet.fromJson('view_sessions'),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => CapabilitySet.fromJson(-1),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('version negotiation', () {
    test('picks the highest version both sides speak', () {
      expect(const VersionRange(1, 3).negotiate(const VersionRange(2, 5)), 3);
      expect(const VersionRange(1, 5).negotiate(const VersionRange(1, 3)), 3);
      expect(const VersionRange(1, 1).negotiate(const VersionRange(1, 1)), 1);
    });

    test('reports no overlap rather than guessing', () {
      expect(
        const VersionRange(1, 1).negotiate(const VersionRange(2, 4)),
        isNull,
      );
      expect(
        const VersionRange(5, 6).intersect(const VersionRange(1, 2)),
        isNull,
      );
    });

    test('round-trips through host.status json', () {
      const range = VersionRange(1, 4);

      expect(VersionRange.fromJson(range.toJson()), range);
    });

    test('rejects a malformed range', () {
      expect(
        () => VersionRange.fromJson({'min': 4, 'max': 1}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => VersionRange.fromJson({'min': 'a', 'max': 1}),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('this build advertises what it can decode', () {
      expect(kSupportedVersions.contains(kProtocolVersion), isTrue);
    });
  });

  group('device ids', () {
    test('round-trip through their hex form', () {
      final id = DeviceId.generate(Random(7));

      expect(id.value.length, 32);
      expect(DeviceId.parse(id.value), id);
      expect(DeviceId.parse(id.value).hashCode, id.hashCode);
    });

    test('are 16 bytes of randomness', () {
      final a = DeviceId.generate();
      final b = DeviceId.generate();

      expect(a.bytes.length, DeviceId.lengthInBytes);
      expect(a, isNot(b));
    });

    test('copy their bytes so the caller cannot mutate them', () {
      final source = Uint8List(16);
      final id = DeviceId(source);
      source[0] = 9;

      expect(id.bytes[0], 0);
    });

    test('refuse the wrong length or non-hex', () {
      expect(() => DeviceId.parse('abcd'), throwsA(isA<ProtocolException>()));
      expect(() => DeviceId.parse('g' * 32), throwsA(isA<ProtocolException>()));
      expect(
        () => DeviceId.parse('AB' * 16),
        throwsA(isA<ProtocolException>()),
        reason: 'uppercase would give one device two spellings',
      );
      expect(() => DeviceId(Uint8List(15)), throwsA(isA<ProtocolException>()));
    });
  });

  group('rendezvous ids', () {
    test('match the path segment the relay accepts', () {
      final id = RendezvousId(
        Uint8List.fromList(List<int>.generate(16, (i) => i)),
      );

      expect(id.value, '000102030405060708090a0b0c0d0e0f');
      expect(RendezvousId.pattern.hasMatch(id.value), isTrue);
      expect(RendezvousId.parse(id.value), id);
    });

    test('the relay pattern refuses anything else', () {
      expect(RendezvousId.pattern.hasMatch(''), isFalse);
      expect(RendezvousId.pattern.hasMatch('0' * 31), isFalse);
      expect(RendezvousId.pattern.hasMatch('0' * 33), isFalse);
      expect(RendezvousId.pattern.hasMatch('../etc/passwd'), isFalse);
      expect(RendezvousId.pattern.hasMatch('0' * 31 + 'Z'), isFalse);
    });
  });

  group('error codes', () {
    test('round-trip through their wire names', () {
      for (final code in ErrorCode.values) {
        expect(ErrorCode.tryParse(code.wire), code);
      }
      expect(ErrorCode.tryParse('teapot'), isNull);
    });

    // Round 50: a server answers a resume of a link that ended while
    // suspended with this. It is the same `error` answer a client that
    // resumes has always taken as "redial", so an older one needs nothing new.
    test('the ended-while-suspended refusal is an ordinary error answer', () {
      final sent = Envelope.of(
        FrameType.error,
        seq: 512,
        id: 'resume-3',
        payload: {
          'code': ErrorCode.notFound.wire,
          'message': kLinkEndedWhileSuspended,
        },
      );
      final got = Envelope.fromBytes(sent.toBytes(), accept: VersionRange.any);
      expect(got.knownType, FrameType.error);
      expect(got.id, 'resume-3');
      expect(
        ErrorCode.tryParse(got.payload['code'] as String),
        ErrorCode.notFound,
      );
      expect(got.payload['message'], kLinkEndedWhileSuspended);
      expect(FrameType.error.sentBy(FrameOrigin.host), isTrue);
    });
  });
}
