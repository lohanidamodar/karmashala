import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/remote/application/host_session_api.dart';
import 'package:karmashala/src/features/remote/application/session_start_ledger.dart';
import 'package:karmashala/src/features/remote/domain/remote_payloads.dart';
import 'package:karmashala/src/features/remote/protocol.dart';

import 'fake_bindings.dart';

void main() {
  test('projects.list includes empty projects and strips checkout agents', () async {
    final fake = FakeRemoteBindings()..addWorkspace();
    fake.workspace.add(const RemoteWorkspaceProject(projectId: 'empty', name: 'Empty'));
    final sent = <Map<String, Object?>>[];
    final api = HostSessionApi(
      device: fakeDevice(capabilities: CapabilitySet.of([Capability.viewSessions])),
      bindings: fake.bindings,
      send: (type, {id, payload = const {}}) async {
        sent.add(payload);
        return true;
      },
    );

    await api.handleEnvelope(Envelope.of(FrameType.projectsList, seq: 0, id: 'q'));

    final rows = sent.single['projects']! as List;
    expect(rows, hasLength(2));
    expect((rows.first as Map<String, Object?>)['checkouts'], isNull);
  });

  test('project.add is refused without its distinct capability', () async {
    final fake = FakeRemoteBindings();
    final sent = <Map<String, Object?>>[];
    final api = HostSessionApi(
      device: fakeDevice(capabilities: CapabilitySet.of([Capability.viewSessions])),
      bindings: fake.bindings,
      send: (type, {id, payload = const {}}) async {
        sent.add(payload);
        return true;
      },
    );
    await api.handleEnvelope(Envelope.of(FrameType.projectAdd, seq: 0, id: 'q', payload: {
      'requestId': 'p1', 'name': 'P', 'path': r'C:\P',
    }));
    expect(sent.single['code'], ErrorCode.notPermitted.wire);
    expect(fake.addProjectCalls, 0);
  });

  test('resume is refused without start capability', () async {
    final fake = FakeRemoteBindings();
    final sent = <Map<String, Object?>>[];
    final api = HostSessionApi(
      device: fakeDevice(capabilities: CapabilitySet.of([Capability.viewSessions])),
      bindings: fake.bindings,
      send: (type, {id, payload = const {}}) async {
        sent.add(payload);
        return true;
      },
    );
    await api.handleEnvelope(Envelope.of(FrameType.sessionResume, seq: 0, id: 'q', payload: {
      'requestId': 'r1', 'sessionId': 's1',
    }));
    expect(sent.single['code'], ErrorCode.notPermitted.wire);
    expect(fake.resumeCalls, 0);
  });

  test('add and resume replay across fresh APIs call bindings once', () async {
    final fake = FakeRemoteBindings();
    final addLedger = SessionStartLedger<RemoteWorkspaceProject>();
    final resumeLedger = SessionStartLedger<RemoteSessionStarted>();
    final sent = <Map<String, Object?>>[];
    HostSessionApi api() => HostSessionApi(
          device: fakeDevice(capabilities: CapabilitySet.all),
          bindings: fake.bindings,
          projectLedger: addLedger,
          resumeLedger: resumeLedger,
          send: (type, {id, payload = const {}}) async {
            sent.add(payload);
            return true;
          },
        );
    await api().handleEnvelope(Envelope.of(FrameType.projectAdd, seq: 0, id: 'a', payload: {
      'requestId': 'same', 'name': 'P', 'path': r'C:\P',
    }));
    await api().handleEnvelope(Envelope.of(FrameType.projectAdd, seq: 1, id: 'b', payload: {
      'requestId': 'same', 'name': 'P', 'path': r'C:\P',
    }));
    await api().handleEnvelope(Envelope.of(FrameType.sessionResume, seq: 2, id: 'c', payload: {
      'requestId': 'same', 'sessionId': 's1',
    }));
    await api().handleEnvelope(Envelope.of(FrameType.sessionResume, seq: 3, id: 'd', payload: {
      'requestId': 'same', 'sessionId': 's1',
    }));
    expect(fake.addProjectCalls, 1);
    expect(fake.resumeCalls, 1);
    expect(sent, hasLength(4));
  });
}
