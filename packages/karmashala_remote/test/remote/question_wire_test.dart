/// An agent's multiple-choice question on the wire: carried with the approval
/// the phone already asks about, answered by `question.answer`, and read
/// safely by a phone or a host older than it.
library;

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

import 'host_session_api_test.dart' show Harness, SentFrame;

void main() {
  const fruit = RemoteQuestion(
    toolUseId: 'toolu_1',
    questions: [
      RemoteQuestionItem(
        question: 'Pick a fruit',
        header: 'Fruit',
        options: [
          RemoteQuestionOption(label: 'Apple', description: 'red'),
          RemoteQuestionOption(label: 'Banana'),
        ],
      ),
      RemoteQuestionItem(
        question: 'Pick colours',
        multiSelect: true,
        options: [
          RemoteQuestionOption(label: 'Red'),
          RemoteQuestionOption(label: 'Blue'),
        ],
      ),
    ],
  );

  group('the payload', () {
    test('a question survives the wire whole', () {
      final sent = const RemoteApprovalRequest(
        sessionId: 's1',
        evidence: ['Pick a fruit'],
        waiting: RemoteWaitKind.question,
        question: fruit,
      );
      final read = RemoteApprovalRequest.fromJson(sent.toJson());
      expect(read.waiting, RemoteWaitKind.question);
      expect(read.question!.toolUseId, 'toolu_1');
      expect(read.question!.questions.first.options.first.description, 'red');
      expect(read.question!.questions.last.multiSelect, isTrue);
      expect(read.approveLabel, isNull);
    });

    test('an approval from an older host carries no question', () {
      final read = RemoteApprovalRequest.fromJson(const {
        'sessionId': 's1',
        'evidence': <String>[],
        'waiting': 'approval',
        'approve': 'Yes',
      });
      expect(read.question, isNull);
    });

    test('a question an older phone cannot read is not an approval to it', () {
      // What an older companion does with the new word: the safe direction.
      expect(RemoteWaitKind.parse('question'), RemoteWaitKind.question);
      expect(
        RemoteWaitKind.parse('some-future-word'),
        RemoteWaitKind.unrecorded,
      );
    });

    test('a garbled question is dropped, not half-read', () {
      final read = RemoteApprovalRequest.fromJson(const {
        'sessionId': 's1',
        'waiting': 'question',
        'question': {'toolUseId': 't', 'questions': 'nope'},
      });
      expect(read.question, isNull);
    });

    test('answers: option indexes or own words, and a decline', () {
      const answer = RemoteQuestionAnswerRequest(
        sessionId: 's1',
        toolUseId: 'toolu_1',
        answers: [
          RemoteQuestionAnswer.options([1]),
          RemoteQuestionAnswer.text('Teal'),
        ],
      );
      final read = RemoteQuestionAnswerRequest.fromJson(answer.toJson());
      expect(read.toolUseId, 'toolu_1');
      expect(read.decline, isFalse);
      expect(read.answers.first.options, [1]);
      expect(read.answers.last.text, 'Teal');

      final declined = RemoteQuestionAnswerRequest.fromJson(
        const RemoteQuestionAnswerRequest(
          sessionId: 's1',
          toolUseId: 't',
          decline: true,
        ).toJson(),
      );
      expect(declined.decline, isTrue);
      expect(declined.answers, isEmpty);
    });

    test('an answer outcome an older phone does not know retires the card', () {
      expect(
        RemoteApprovalOutcome.parse('answered'),
        RemoteApprovalOutcome.answered,
      );
      expect(
        RemoteApprovalOutcome.parse('later-word'),
        RemoteApprovalOutcome.elsewhere,
      );
    });
  });

  group('question.answer', () {
    test('needs the approve capability, like any answer', () {
      expect(FrameType.questionAnswer.capability, Capability.approve);
      expect(FrameType.questionAnswer.wire, 'question.answer');
      expect(FrameType.questionAnswer.origin, FrameOrigin.companion);
    });

    Future<Harness> waiting() async {
      final harness = Harness();
      harness.fake.setAwaitingApproval('s1');
      harness.fake.approvals['s1'] = const RemoteApprovalRequest(
        sessionId: 's1',
        waiting: RemoteWaitKind.question,
        question: fruit,
      );
      await harness.api.pushApprovalRequested('s1');
      return harness;
    }

    List<SentFrame> resolutions(Harness harness) => [
      for (final frame in harness.sent)
        if (frame.type == FrameType.approvalResolved) frame,
    ];

    test(
      'is handed to the desktop, and the phone is told it was answered',
      () async {
        final harness = await waiting();
        await harness.request(
          FrameType.questionAnswer,
          payload: const RemoteQuestionAnswerRequest(
            sessionId: 's1',
            toolUseId: 'toolu_1',
            answers: [
              RemoteQuestionAnswer.options([1]),
              RemoteQuestionAnswer.options([0, 1]),
            ],
          ).toJson(),
        );

        final given = harness.fake.questionAnswers.single;
        expect(given.toolUseId, 'toolu_1');
        expect(given.answers.first.options, [1]);
        expect(given.answers.last.options, [0, 1]);
        expect(
          RemoteApprovalResolved.fromJson(
            resolutions(harness).single.payload,
          ).outcome,
          RemoteApprovalOutcome.answered,
        );
        expect(harness.last.type, FrameType.result);
      },
    );

    test('a decline is told as denied', () async {
      final harness = await waiting();
      await harness.request(
        FrameType.questionAnswer,
        payload: const RemoteQuestionAnswerRequest(
          sessionId: 's1',
          toolUseId: 'toolu_1',
          decline: true,
        ).toJson(),
      );
      expect(harness.fake.questionAnswers.single.decline, isTrue);
      expect(
        RemoteApprovalResolved.fromJson(
          resolutions(harness).single.payload,
        ).outcome,
        RemoteApprovalOutcome.denied,
      );
    });

    test(
      'an answer to a question already settled is refused, not typed',
      () async {
        final harness = await waiting();
        harness.fake.setAwaitingApproval('s1', waiting: false);
        await harness.request(
          FrameType.questionAnswer,
          payload: const RemoteQuestionAnswerRequest(
            sessionId: 's1',
            toolUseId: 'toolu_1',
            answers: [
              RemoteQuestionAnswer.options([0]),
            ],
          ).toJson(),
        );
        expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
        expect(harness.fake.questionAnswers, isEmpty);
      },
    );

    test(
      'an answer with neither answers nor a decline is a bad request',
      () async {
        final harness = await waiting();
        await harness.request(
          FrameType.questionAnswer,
          payload: const {'sessionId': 's1', 'toolUseId': 'toolu_1'},
        );
        expect(harness.lastErrorCode(), ErrorCode.badRequest.wire);
        expect(harness.fake.questionAnswers, isEmpty);
      },
    );
  });
}
