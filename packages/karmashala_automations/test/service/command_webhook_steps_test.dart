import 'dart:convert';

import 'package:karmashala_automations/karmashala_automations.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service_fixtures.dart';

class _Commands implements StepCommandRunner {
  _Commands(this.answer);

  StepCommandResult answer;
  final calls = <({String command, Map<String, String> environment})>[];

  @override
  Future<StepCommandResult> run(
    Automation automation,
    AutomationRun run, {
    required String command,
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    calls.add((command: command, environment: environment));
    return answer;
  }
}

class _Webhooks implements StepWebhookPoster {
  final posts = <({Uri url, String body, String key, bool private})>[];
  var status = 200;

  @override
  Future<StepWebhookResult> post(
    Uri url, {
    required String body,
    required String idempotencyKey,
    required bool allowPrivate,
    required Duration timeout,
  }) async {
    posts.add((
      url: url,
      body: body,
      key: idempotencyKey,
      private: allowPrivate,
    ));
    return StepWebhookResult(status: status, body: '{"ok": true}');
  }
}

/// "Run a command" and "Call a webhook": values reach a command only as its
/// environment, a body only JSON-escaped, and what each returned is a
/// variable for the steps after it.
void main() {
  const hostile = r'x"; rm -rf ~; echo "$(whoami)` & calc';

  group('the pure rules', () {
    test('a command with a variable in its text is refused', () {
      const step = AutomationStep(
        kind: AutomationStepKind.command,
        text: 'git push origin {{github.pr.branch}}',
      );
      expect(step.refusal, contains('environment'));
      expect(
        const AutomationStep(
          kind: AutomationStepKind.command,
          text: r'git push origin "$KARMASHALA_GITHUB_PR_BRANCH"',
        ).refusal,
        isNull,
      );
    });

    test('values become KARMASHALA_ variables, unchanged', () {
      expect(stepEnvironment({'github.pr.branch': hostile}), {
        'KARMASHALA_GITHUB_PR_BRANCH': hostile,
      });
      expect(
        stepEnvironmentName('steps.command.exit_code'),
        'KARMASHALA_STEPS_COMMAND_EXIT_CODE',
      );
    });

    test('a body template escapes each value where it stands', () {
      const value = 'he said "hi"\n}, "admin": true, "x": "';
      final body = fillJsonBody('{"text": "{{github.comment.body}}"}', {
        'github.comment.body': value,
      });
      expect(jsonDecode(body), {'text': value});
    });

    test('a webhook needs an http URL and a JSON body', () {
      expect(webhookStepRefusal('ftp://x', '{}'), contains('http'));
      expect(
        webhookStepRefusal('https://x.dev/h', '{"a": {{run.status}}}'),
        contains('not JSON'),
      );
      expect(
        webhookStepRefusal('https://x.dev/h', '{"a": "{{run.status}}"}'),
        isNull,
      );
    });

    test('the new step fields round-trip', () {
      final steps = AutomationSteps(const [
        AutomationStep(
          kind: AutomationStepKind.webhook,
          url: 'http://10.0.0.2/hook',
          text: '{}',
          allowPrivate: true,
          timeoutSeconds: 5,
        ),
        AutomationStep(kind: AutomationStepKind.command, text: 'make'),
      ]);
      expect(AutomationSteps.fromColumn(steps.toColumn()), steps);
      expect(steps.after.map((s) => s.kind), [
        AutomationStepKind.command,
        AutomationStepKind.webhook,
      ]);
      expect(steps.after.first.timeout, const Duration(minutes: 10));
    });
  });

  group('after a run', () {
    late AppDatabase db;
    late AutomationDao dao;
    late List<String> notified;
    late _Commands commands;
    late _Webhooks webhooks;
    var checksOn = true;

    AutomationFollowUps followUps() => AutomationFollowUps(
      automations: dao,
      resumes: ScheduledResumeDao(db),
      repositoryName: (_) => 'repo',
      notify: (automation, run, text, {required failed}) => notified.add(text),
      now: () => fixtureTime,
      newId: () => 'id',
      commands: commands,
      webhooks: webhooks,
      checksOn: (_) => checksOn,
    );

    AutomationRun arm(List<AutomationStep> steps) {
      dao.insert(
        fixtureAutomation(
          armedAt: fixtureTime,
        ).copyWith(steps: AutomationSteps(steps)),
      );
      final run = AutomationRun(
        id: 'run1',
        automationId: 'auto1',
        scheduledFor: fixtureTime,
        firedAt: fixtureTime,
        state: AutomationRunState.finished,
        reason: 'done',
        variables: const {'github.pr.branch': hostile},
      );
      dao.insertRun(run);
      return run;
    }

    setUp(() {
      db = fixtureDatabase();
      dao = AutomationDao(db);
      notified = [];
      checksOn = true;
      commands = _Commands(
        const StepCommandResult(exitCode: 0, output: 'pushed'),
      );
      webhooks = _Webhooks();
    });
    tearDown(() => db.close());

    test('a command gets the values as environment, never in its text, and '
        'its output reaches the next step', () async {
      final run = arm(const [
        AutomationStep(kind: AutomationStepKind.command, text: 'push'),
        AutomationStep(
          kind: AutomationStepKind.notify,
          when: AutomationStepWhen.always,
          text: '{{steps.command.exit_code}}: {{steps.command.output}}',
        ),
      ]);
      await followUps().after(run);
      expect(commands.calls.single.command, 'push');
      expect(
        commands.calls.single.environment['KARMASHALA_GITHUB_PR_BRANCH'],
        hostile,
      );
      expect(notified.single, '0: pushed');
      expect(
        dao.runById('run1')!.stepResults.first.outcome,
        AutomationStepOutcome.done,
      );
    });

    test('a command runs only where checks are on', () async {
      checksOn = false;
      final run = arm(const [
        AutomationStep(kind: AutomationStepKind.command, text: 'push'),
      ]);
      await followUps().after(run);
      expect(commands.calls, isEmpty);
      final result = dao.runById('run1')!.stepResults.single;
      expect(result.outcome, AutomationStepOutcome.failed);
      expect(result.detail, contains('checks are off'));
    });

    test(
      'a command past its time limit fails, and a failure step runs',
      () async {
        commands.answer = const StepCommandResult(
          exitCode: null,
          output: '',
          timedOut: true,
        );
        final run = arm(const [
          AutomationStep(
            kind: AutomationStepKind.command,
            text: 'sleep 9999',
            timeoutSeconds: 1,
          ),
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.failure,
            text: '{{run.status}}',
          ),
        ]);
        await followUps().after(run);
        final results = dao.runById('run1')!.stepResults;
        expect(results.first.detail, contains('time limit'));
        expect(notified.single, 'failed');
      },
    );

    test(
      'a webhook posts its escaped body with the run\'s idempotency key',
      () async {
        final run = arm(const [
          AutomationStep(
            kind: AutomationStepKind.webhook,
            url: 'https://hooks.example.com/k',
            text: '{"branch": "{{github.pr.branch}}"}',
          ),
          AutomationStep(
            kind: AutomationStepKind.notify,
            when: AutomationStepWhen.always,
            text: '{{steps.webhook.status}}',
          ),
        ]);
        await followUps().after(run);
        final post = webhooks.posts.single;
        expect(post.key, 'run1-webhook');
        expect(post.private, isFalse);
        expect(jsonDecode(post.body), {'branch': hostile});
        expect(notified.single, '200');
      },
    );

    test('a webhook that answers an error fails its step', () async {
      webhooks.status = 500;
      final run = arm(const [
        AutomationStep(
          kind: AutomationStepKind.webhook,
          url: 'https://hooks.example.com/k',
          text: '{}',
        ),
      ]);
      await followUps().after(run);
      expect(
        dao.runById('run1')!.stepResults.single.outcome,
        AutomationStepOutcome.failed,
      );
    });

    test('the run keeps its trigger\'s variables in the store', () {
      arm(const []);
      expect(dao.runById('run1')!.variables, {'github.pr.branch': hostile});
      expect(
        automationRunFromJson(
          automationRunToJson(dao.runById('run1')!),
        ).variables,
        {'github.pr.branch': hostile},
      );
    });
  });
}
