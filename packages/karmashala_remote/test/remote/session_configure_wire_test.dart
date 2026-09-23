/// `session.options` and `session.configure`: routed to the host's bindings,
/// judged against the device's grant, and round-tripped by the client's types.
library;

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import './fake_bindings.dart';

typedef Frame = ({FrameType type, String? id, Map<String, Object?> payload});

void main() {
  late FakeRemoteBindings fake;
  late List<Frame> sent;
  late List<({String sessionId, ({String? id})? model, ({String? id})? mode})>
  configured;
  var seq = 0;

  HostSessionApi api({CapabilitySet? capabilities}) {
    final base = fake.bindings;
    return HostSessionApi(
      device: fakeDevice(capabilities: capabilities),
      bindings: RemoteHostBindings(
        hostName: base.hostName,
        listSessions: base.listSessions,
        sessionById: base.sessionById,
        deliveryStageFor: base.deliveryStageFor,
        transcriptFor: base.transcriptFor,
        sendPrompt: base.sendPrompt,
        answerApproval: base.answerApproval,
        approvalEvidenceFor: base.approvalEvidenceFor,
        registerPush: base.registerPush,
        listWorkspace: base.listWorkspace,
        listProjects: base.listProjects,
        startSession: base.startSession,
        addProject: base.addProject,
        resumeSession: base.resumeSession,
        beginAttachment: base.beginAttachment,
        writeAttachmentChunk: base.writeAttachmentChunk,
        discardAttachment: base.discardAttachment,
        sessionOptions: (id) async => RemoteSessionOptions(
          sessionId: id,
          models: const [RemoteChoice(id: 'sonnet', label: 'Sonnet')],
          modelId: 'sonnet',
        ),
        configureSession: (id, {model, permission}) async {
          configured.add((sessionId: id, model: model, mode: permission));
          return RemoteConfigureOutcome.afterTurn;
        },
      ),
      send: (type, {id, payload = const {}}) async {
        sent.add((type: type, id: id, payload: payload));
        return true;
      },
    );
  }

  Future<void> ask(
    HostSessionApi host,
    FrameType type,
    Map<String, Object?> payload,
  ) => host.handleEnvelope(
    Envelope.of(type, seq: seq++, id: 'q$seq', payload: payload),
  );

  setUp(() {
    fake = FakeRemoteBindings()..addSession('s1');
    sent = [];
    configured = [];
  });

  test('options come back in a shape the client reads', () async {
    await ask(api(), FrameType.sessionOptions, {'sessionId': 's1'});
    final options = RemoteSessionOptions.fromJson(sent.single.payload);
    expect(options.models.single.label, 'Sonnet');
    expect(options.modelId, 'sonnet');
  });

  test('a configure names only what it changes', () async {
    await ask(api(), FrameType.sessionConfigure, {
      'sessionId': 's1',
      'permission': 'mode=plan',
    });
    expect(configured.single.model, isNull, reason: 'left alone');
    expect(configured.single.mode, (id: 'mode=plan'));
    expect(
      RemoteConfigureOutcome.parse(sent.single.payload['outcome']),
      RemoteConfigureOutcome.afterTurn,
    );
  });

  test('null hands a field back to the desktop default', () async {
    await ask(api(), FrameType.sessionConfigure, {
      'sessionId': 's1',
      'model': null,
    });
    expect(configured.single.model, (id: null));
  });

  test('a phone without send_prompt is refused, in words', () async {
    await ask(
      api(capabilities: CapabilitySet.of(const [Capability.viewSessions])),
      FrameType.sessionConfigure,
      {'sessionId': 's1', 'model': 'sonnet'},
    );
    expect(configured, isEmpty);
    expect(sent.single.type, FrameType.error);
    expect(sent.single.payload['code'], ErrorCode.notPermitted.wire);
  });

  test('an unknown outcome word reads as recorded', () {
    expect(
      RemoteConfigureOutcome.parse('teleported'),
      RemoteConfigureOutcome.recorded,
    );
  });
}
