import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/automations/application/automation_draft.dart';
import 'package:karmashala/src/features/automations/application/automation_dry_run.dart';
import 'package:karmashala/src/features/automations/application/turn_on_review.dart';
import 'package:karmashala_automations/automations.dart';

/// A schedule whose first step runs a command, in a project or any folder:
/// what the draft asks for before it saves, and what it saves.
void main() {
  final now = DateTime.utc(2026, 10, 17, 9);

  const inFolder = AutomationDraft(
    name: 'Sync notes',
    runsCommand: true,
    commandText: 'git -C ~/notes pull',
    place: DraftPlace.folder,
    environmentId: 'wsl:Ubuntu',
    folderPath: '~/notes',
  );

  group('what is missing', () {
    test('an empty command', () {
      expect(
        inFolder.copyWith(commandText: '  ').missing,
        'Say what command to run.',
      );
    });

    test('no folder, or no machine for it', () {
      expect(
        inFolder.copyWith(folderPath: ' ').missing,
        'Say which folder it runs in.',
      );
      expect(
        const AutomationDraft(
          name: 'x',
          runsCommand: true,
          commandText: 'date',
          place: DraftPlace.folder,
        ).missing,
        'Pick the machine it runs on.',
      );
    });

    test('a project, when it runs in one', () {
      expect(
        inFolder.copyWith(place: DraftPlace.project).missing,
        'Pick where it runs.',
      );
    });

    test('an agent never runs in a plain folder', () {
      expect(
        inFolder.copyWith(runsCommand: false, prompt: 'go').missing,
        contains('An agent runs in a project'),
      );
    });

    test('an event or GitHub rule watches a project', () {
      for (final trigger in [DraftTrigger.event, DraftTrigger.github]) {
        expect(
          inFolder.copyWith(trigger: trigger).missing,
          contains('watches a project'),
          reason: '$trigger',
        );
      }
    });

    test('a value read as %…% in cmd, which cmd would run', () {
      final draft = inFolder.copyWith(
        windowsMachine: true,
        shell: AutomationShell.cmd,
        commandText: 'echo %KARMASHALA_AUTOMATION%',
      );
      expect(draft.missing, contains('!KARMASHALA_'));
      expect(
        draft.copyWith(commandText: 'echo !KARMASHALA_AUTOMATION!').missing,
        isNull,
      );
    });

    test('no agent to tell, and no project to check in a folder', () {
      final tell = inFolder.copyWith(
        steps: AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.tell, text: 'fix it'),
        ]),
      );
      expect(tell.missing, contains('no agent to tell'));
      final check = inFolder.copyWith(
        steps: AutomationSteps(const [
          AutomationStep(kind: AutomationStepKind.check, text: 'make'),
        ]),
      );
      expect(check.missing, contains('no project to check'));
    });

    test('a command names no agent and needs no prompt', () {
      expect(inFolder.namesAgent, isFalse);
      expect(inFolder.missing, isNull);
    });
  });

  group('what it saves', () {
    test('a folder command: no checkout, no agent, the login shell', () {
      final saved = inFolder.toAutomation(id: 'a1', now: now)!;
      expect(saved.repositoryId, isEmpty);
      expect(
        saved.folder,
        const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '~/notes'),
      );
      expect(saved.command!.text, 'git -C ~/notes pull');
      expect(saved.command!.shell, AutomationShell.login);
      expect(saved.agentInstallationId, isEmpty);
      expect(saved.prompt, isEmpty);
    });

    test('on Windows the shell it picked', () {
      final saved = inFolder
          .copyWith(
            windowsMachine: true,
            environmentId: 'windows',
            shell: AutomationShell.cmd,
            commandText: 'date /t',
          )
          .toAutomation(id: 'a1', now: now)!;
      expect(saved.command!.shell, AutomationShell.cmd);
    });

    test('a project command keeps its checkout and no folder', () {
      final saved = inFolder
          .copyWith(place: DraftPlace.project, repositoryId: 'r1')
          .toAutomation(id: 'a1', now: now)!;
      expect(saved.repositoryId, 'r1');
      expect(saved.folder, isNull);
    });

    test('an event rule runs its command as its first step', () {
      final saved =
          const AutomationDraft(
                name: 'Lint',
                repositoryId: 'r1',
                trigger: DraftTrigger.event,
              )
              .withFirstStep(EventFirstStep.command)
              .copyWith(commandText: 'make lint');
      expect(saved.firstStep, EventFirstStep.command);
      final rule = saved.toAutomation(id: 'a1', now: now)!;
      expect(rule.command!.text, 'make lint');
      expect(rule.trigger!.action, AutomationEventAction.startSession);
      expect(rule.startsAgent, isFalse);
    });

    test('reads back the way it was saved', () {
      final saved = inFolder.toAutomation(id: 'a1', now: now)!;
      final read = AutomationDraft.from(saved);
      expect(read.runsCommand, isTrue);
      expect(read.inFolder, isTrue);
      expect(read.folderPath, '~/notes');
      expect(read.environmentId, 'wsl:Ubuntu');
      expect(read.commandText, 'git -C ~/notes pull');
      expect(read.asNewCopy().inFolder, isTrue);
    });
  });

  group('what a person is shown', () {
    final saved = inFolder
        .copyWith(maxRuntimeMinutes: 5)
        .toAutomation(id: 'a1', now: now)!;

    test(
      'turning it on names the exact command, folder, machine and shell',
      () {
        final review = turnOnReview(
          saved,
          checkout: '~/notes',
          agent: 'the agent',
          permissions: null,
          machine: 'Ubuntu',
        );
        final lines = {for (final l in review.changes) l.label: l.text};
        expect(lines['Command'], 'git -C ~/notes pull');
        expect(lines['Folder'], '~/notes');
        expect(lines['Machine'], 'Ubuntu');
        expect(lines['Shell'], 'your login shell');
        expect(
          review.limits.firstWhere((l) => l.label == 'Time limit').text,
          'A run is stopped after 5 min',
        );
        expect(actsUnattended(saved), isTrue);
      },
    );

    test('the dry run says what it would run, and where', () {
      final step = dryRunSteps(
        saved,
        checkout: '~/notes on Ubuntu',
        agent: 'the agent',
      ).first;
      expect(step.title, 'Run a command');
      expect(step.would, contains('git -C ~/notes pull'));
      expect(step.would, contains('your login shell'));
      expect(step.would, isNot(contains('checkpoint')));
    });

    test('in plain words it runs a command', () {
      expect(
        automationWords(saved, checkout: '~/notes', agent: 'x', now: now),
        contains('run a command'),
      );
    });
  });
}
