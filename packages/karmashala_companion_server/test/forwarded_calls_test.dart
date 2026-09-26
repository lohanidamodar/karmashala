import 'dart:convert';

import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// A link that carries each call through JSON text into a dispatcher, the way
/// the host protocol does, so what the host decodes is what the app encoded.
class _JsonLink implements CompanionAppLink {
  _JsonLink(this.dispatcher);

  final CompanionCallDispatcher dispatcher;
  final asked = <String>[];

  @override
  bool connected = true;

  @override
  Future<Map<String, Object?>> call(
    CompanionMethod method,
    Map<String, Object?> arguments,
  ) async {
    asked.add(method.wire);
    final wireArguments =
        jsonDecode(jsonEncode(arguments)) as Map<String, Object?>;
    final result = await dispatcher.run(method.wire, wireArguments);
    return jsonDecode(jsonEncode(result)) as Map<String, Object?>;
  }
}

Never _unused() => throw UnimplementedError();

void main() {
  const snapshot = RemoteSessionSnapshot(
    sessionId: 's1',
    title: 'Fix the cart',
    status: 'running',
    attention: kAttentionNeedsApproval,
    repositoryName: 'shop-api',
    pinned: true,
    worktree: '/src/wt',
    attachments: RemoteAttachmentSupport(
      mediaTypes: ['image/png'],
      maxBytes: 1024,
    ),
  );

  final sent = <(String, String, RemoteAttachmentRef?)>[];
  final bindings = RemoteHostBindings(
    hostName: 'desk',
    listSessions: () => [snapshot],
    sessionById: (id) => id == 's1' ? snapshot : null,
    deliveryStageFor: (_) async => 'pr_open',
    transcriptFor: (id) async => (
      page: RemoteTranscriptPage(
        sessionId: id,
        messages: const [RemoteTranscriptMessage(role: 'user', text: 'hi')],
        cursor: 1,
      ),
      activity: RemoteSessionActivity(
        sessionId: id,
        observedAt: DateTime.utc(2026, 9, 25),
      ),
    ),
    sendPrompt: (id, text, {attachment}) async {
      sent.add((id, text, attachment));
      return attachment == null
          ? RemotePromptDelivery.sent
          : RemotePromptDelivery.offered;
    },
    answerApproval: (_, decision) async =>
        throw const RemoteApiRefusal(ErrorCode.badRequest, 'nothing waits'),
    approvalEvidenceFor: (id) async => RemoteApprovalRequest(
      sessionId: id,
      evidence: const ['Run rm?'],
      approveLabel: 'Yes',
    ),
    registerPush: (_, _, _, _) async => _unused(),
    listWorkspace: () => const [
      RemoteWorkspaceProject(projectId: 'p1', name: 'Shop', path: '/src'),
    ],
    listProjects: () => const [],
    startSession: (request) async => RemoteSessionStarted(
      sessionId: request.worktree ? 'new-in-worktree' : 'new',
      title: request.title ?? '',
      permissionMode: request.permissionMode,
    ),
    addProject: (_, _) async => _unused(),
    resumeSession: (_) async => _unused(),
    beginAttachment: (_, _) async => _unused(),
    writeAttachmentChunk: (_, _, _, _) async => _unused(),
    discardAttachment: (_) async {},
    configureSession: (id, {model, permission}) async {
      expect(model, (id: 'opus'));
      expect(permission, (id: null));
      return RemoteConfigureOutcome.values.first;
    },
  );

  late _JsonLink link;
  late ForwardedBindings forwarded;

  setUp(() {
    sent.clear();
    link = _JsonLink(CompanionCallDispatcher(() => bindings));
    forwarded = ForwardedBindings(link);
  });

  test(
    'a session list crosses whole, attention and attachments included',
    () async {
      final sessions = await forwarded.listSessions();

      expect(sessions.single, snapshot);
      expect(await forwarded.sessionById('s1'), snapshot);
      expect(await forwarded.sessionById('nope'), isNull);
      expect(await forwarded.deliveryStage('s1'), 'pr_open');
    },
  );

  test('a transcript and its activity cross in one call', () async {
    final record = await forwarded.transcript('s1');

    expect(record.page.messages.single.text, 'hi');
    expect(record.activity.sessionId, 's1');
    expect(link.asked, [CompanionMethod.transcript.wire]);
  });

  test('a prompt names its attachment by the link that carried it', () async {
    expect(await forwarded.sendPrompt('s1', 'look'), RemotePromptDelivery.sent);
    expect(
      await forwarded.sendPrompt(
        's1',
        'this one',
        attachment: (deviceId: 'pixel', uploadId: 'u1'),
      ),
      RemotePromptDelivery.offered,
    );
    expect(sent.last.$3, (deviceId: 'pixel', uploadId: 'u1'));
  });

  test('the app\'s refusal is the phone\'s refusal', () async {
    await expectLater(
      forwarded.answerApproval('s1', 'approve'),
      throwsA(
        isA<RemoteApiRefusal>()
            .having((r) => r.code, 'code', ErrorCode.badRequest)
            .having((r) => r.message, 'message', 'nothing waits'),
      ),
    );
    expect((await forwarded.approvalEvidence('s1')).approveLabel, 'Yes');
  });

  test('a start carries the person\'s choices', () async {
    final started = await forwarded.startSession(
      const RemoteSessionStartRequest(
        repositoryId: 'r1',
        installationId: 'a1',
        permissionMode: 'plan',
        title: 'New work',
      ),
    );
    expect(started.title, 'New work');
    expect(started.permissionMode, 'plan');
    expect(started.sessionId, 'new');
    final inWorktree = await forwarded.startSession(
      const RemoteSessionStartRequest(
        repositoryId: 'r1',
        installationId: 'a1',
        permissionMode: 'plan',
        worktree: true,
      ),
    );
    expect(inWorktree.sessionId, 'new-in-worktree', reason: 'carried over');
    expect((await forwarded.listWorkspace()).single.name, 'Shop');
  });

  test('a configure says which fields it moves, and to what', () async {
    await forwarded.configureSession(
      's1',
      model: (id: 'opus'),
      permission: (id: null),
    );
  });

  test('a method the app does not know is refused by name', () async {
    await expectLater(
      CompanionCallDispatcher(() => bindings).run('nonsense', const {}),
      throwsA(
        isA<RemoteApiRefusal>().having(
          (r) => r.code,
          'code',
          ErrorCode.unknownType,
        ),
      ),
    );
  });
}
