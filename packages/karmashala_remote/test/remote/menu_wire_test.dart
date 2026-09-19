/// A menu the agent drew on its screen — folder trust, a permission prompt —
/// on the wire: carried with the approval the phone already asks about,
/// answered by `menu.answer`, and read safely by a phone or host older than it.
library;

import 'package:karmashala_remote/host.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import 'host_session_api_test.dart' show Harness, SentFrame;

void main() {
  const trust = RemoteMenu(
    menuId: 'a1b2c3d4',
    prompt: ['Accessing workspace:', 'Security guide'],
    options: ['No, exit', 'Yes, I trust this folder'],
    highlighted: 0,
  );

  group('the payload', () {
    test('a menu survives the wire whole', () {
      final read = RemoteApprovalRequest.fromJson(
        const RemoteApprovalRequest(
          sessionId: 's1',
          waiting: RemoteWaitKind.approval,
          menu: trust,
        ).toJson(),
      );
      expect(read.menu!.menuId, 'a1b2c3d4');
      expect(read.menu!.options, ['No, exit', 'Yes, I trust this folder']);
      expect(read.menu!.highlighted, 0);
      expect(read.menu!.prompt.last, 'Security guide');
    });

    test('an approval from an older host carries no menu', () {
      final read = RemoteApprovalRequest.fromJson(const {
        'sessionId': 's1',
        'waiting': 'approval',
        'approve': 'Approve',
      });
      expect(read.menu, isNull);
      expect(read.approveLabel, 'Approve');
    });

    test('a garbled menu is dropped, not half-read', () {
      for (final garbled in const [
        {'menuId': 'm', 'options': ['only one'], 'highlighted': 0},
        {'menuId': 'm', 'options': ['a', 'b'], 'highlighted': 2},
        {'menuId': 'm', 'options': ['a', 3], 'highlighted': 0},
        {'options': ['a', 'b'], 'highlighted': 0},
      ]) {
        expect(
          RemoteApprovalRequest.fromJson({'sessionId': 's1', 'menu': garbled})
              .menu,
          isNull,
          reason: '$garbled',
        );
      }
    });

    test('an answer names the menu and the option', () {
      final read = RemoteMenuAnswerRequest.fromJson(
        const RemoteMenuAnswerRequest(
          sessionId: 's1',
          menuId: 'a1b2c3d4',
          option: 1,
        ).toJson(),
      );
      expect(read.menuId, 'a1b2c3d4');
      expect(read.option, 1);
    });
  });

  group('menu.answer', () {
    test('needs the approve capability, like any answer', () {
      expect(FrameType.menuAnswer.capability, Capability.approve);
      expect(FrameType.menuAnswer.wire, 'menu.answer');
      expect(FrameType.menuAnswer.origin, FrameOrigin.companion);
    });

    Future<Harness> waiting() async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');
      harness.fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        waiting: RemoteWaitKind.approval,
        menu: trust,
      );
      await harness.api.pushApprovalRequested('s1');
      return harness;
    }

    List<SentFrame> resolutions(Harness harness) => [
      for (final frame in harness.sent)
        if (frame.type == FrameType.approvalResolved) frame,
    ];

    test('is handed to the desktop, and the phone is told it was answered',
        () async {
      final harness = await waiting();
      await harness.request(
        FrameType.menuAnswer,
        payload: const RemoteMenuAnswerRequest(
          sessionId: 's1',
          menuId: 'a1b2c3d4',
          option: 1,
        ).toJson(),
      );

      final given = harness.fake.menuAnswers.single;
      expect(given.menuId, 'a1b2c3d4');
      expect(given.option, 1);
      expect(
        RemoteApprovalResolved.fromJson(resolutions(harness).single.payload)
            .outcome,
        RemoteApprovalOutcome.answered,
      );
      expect(harness.last.type, FrameType.result);
      expect(harness.last.payload['chosen'], 'option 1');
    });

    test('an answer to a prompt already settled is refused, not typed',
        () async {
      final harness = await waiting();
      harness.fake.setAwaitingApproval('s1', waiting: false);
      await harness.request(
        FrameType.menuAnswer,
        payload: const RemoteMenuAnswerRequest(
          sessionId: 's1',
          menuId: 'a1b2c3d4',
          option: 1,
        ).toJson(),
      );
      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.fake.menuAnswers, isEmpty);
    });

    test('a refusal from the desktop reaches the phone and resolves nothing',
        () async {
      final harness = await waiting();
      harness.fake.menuRefusal = const RemoteApiRefusal(
        ErrorCode.badRequest,
        'the prompt changed since it was shown, so nothing was chosen',
      );
      await harness.request(
        FrameType.menuAnswer,
        payload: const RemoteMenuAnswerRequest(
          sessionId: 's1',
          menuId: 'a1b2c3d4',
          option: 1,
        ).toJson(),
      );
      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(resolutions(harness), isEmpty);
    });

    test('a malformed answer is a bad request', () async {
      final harness = await waiting();
      await harness.request(
        FrameType.menuAnswer,
        payload: const {'sessionId': 's1', 'menuId': 'a1b2c3d4'},
      );
      expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
      expect(harness.fake.menuAnswers, isEmpty);
    });
  });
}
