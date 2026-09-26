import 'dart:async';

import 'package:karmashala_host/karmashala_host.dart';
import 'package:karmashala_host/lifecycle_client.dart';
import 'package:test/test.dart';

import '../serve/pipe_connection.dart';

Future<void> pump() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Stands in for the daemon's automations: records what the app said.
class _Handler implements AutomationHandler {
  final notices = <AutomationNoticeKind>[];
  final answers = <AutomationResultMessage>[];
  void Function(HostMessage)? send;
  var detached = 0;

  @override
  void notice(
    Object owner,
    AutomationNoticeMessage notice,
    void Function(HostMessage) send,
  ) {
    notices.add(notice.kind);
    this.send = send;
  }

  @override
  void answer(Object owner, AutomationResultMessage result) =>
      answers.add(result);

  @override
  Future<ChecksRanMessage> runChecks(ChecksRunMessage request) async =>
      ChecksRanMessage(
        requestId: request.requestId,
        outcome: ChecksRunOutcome.ran,
        verificationRunId: 'run-for-${request.sessionId}',
      );

  @override
  void detach(Object owner) => detached++;
}

void main() {
  late HostServer server;
  late _Handler handler;

  setUp(() {
    server = HostServer(
      registry: SessionRegistry(launcher: FakePtyLauncher()),
      ptyLibrary: 'libc',
    );
    handler = _Handler();
    server.automations = handler;
  });

  Future<HostLifecycleWatch> watch() {
    final (client, host) = PipeEnd.pair();
    unawaited(server.serveConnection(host));
    return HostLifecycleWatch.over(client, clientId: 'app');
  }

  test('the app says it is the app, and hears the host write rows', () async {
    final app = await watch();
    final changes = <void>[];
    app.automationsChanged.listen(changes.add);
    app.noticeAutomations(AutomationNoticeKind.ready);
    await pump();
    expect(handler.notices, [AutomationNoticeKind.ready]);

    server.lifecycle.publishAutomationsChanged();
    await pump();
    expect(changes, hasLength(1));
    await app.close();
    await pump();
    expect(handler.detached, 1);
  });

  test('a forwarded call reaches the app and its answer comes back', () async {
    final app = await watch();
    final calls = <AutomationCallMessage>[];
    app.automationCalls.listen((call) {
      calls.add(call);
      app.answerAutomationCall(call.callId, error: 'no such resume');
    });
    app.noticeAutomations(AutomationNoticeKind.ready);
    await pump();
    handler.send!(
      const AutomationCallMessage(
        callId: 1,
        kind: AutomationCallKind.fireResume,
        id: 'resume1',
      ),
    );
    await pump();
    expect(calls.single.id, 'resume1');
    expect(handler.answers.single.message, 'no such resume');
    await app.close();
  });

  test('checks asked for over the link are answered on it', () async {
    final app = await watch();
    final ran = await app.runChecks('s1');
    expect(ran.outcome, ChecksRunOutcome.ran);
    expect(ran.verificationRunId, 'run-for-s1');
    await app.close();
  });

  test('a host with no store sends a check request back to the app', () async {
    server.automations = null;
    final app = await watch();
    final ran = await app.runChecks('s1');
    expect(ran.outcome, ChecksRunOutcome.elsewhere);
    await app.close();
  });
}
