import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/runs.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

import 'service/service_fixtures.dart';

/// An automation whose first step runs a command, in a checkout or a folder.
void main() {
  const notes = EnvironmentPath(environmentId: 'wsl', path: '~/notes');
  const sync = AutomationCommand(text: 'git -C ~/notes pull');

  Automation inFolder() => Automation(
    id: 'sync',
    repositoryId: '',
    name: 'Sync notes',
    schedule: const AutomationSchedule.cron('0 9 * * 1-5'),
    agentInstallationId: '',
    prompt: '',
    permissionMode: null,
    enabled: true,
    armedAt: fixtureTime,
    command: sync,
    folder: notes,
  );

  group('the command', () {
    test('refuses an empty one, and variables in its text', () {
      expect(const AutomationCommand(text: '  ').refusal, isNotNull);
      expect(
        const AutomationCommand(text: 'echo {{automation}}').refusal,
        contains('environment'),
      );
      expect(sync.refusal, isNull);
    });

    test('in cmd, refuses a value read as %…%, which cmd would run', () {
      expect(
        const AutomationCommand(
          text: 'echo %KARMASHALA_AUTOMATION%',
          shell: AutomationShell.cmd,
        ).refusal,
        contains('!KARMASHALA_'),
      );
      expect(
        const AutomationCommand(
          text: 'echo !KARMASHALA_AUTOMATION!',
          shell: AutomationShell.cmd,
        ).refusal,
        isNull,
      );
      // PowerShell reads $env: values as values.
      expect(
        const AutomationCommand(
          text: 'echo %KARMASHALA_AUTOMATION%',
          shell: AutomationShell.powershell,
        ).refusal,
        isNull,
      );
    });

    test('starts no agent, and holds its folder rather than a checkout', () {
      final automation = inFolder();
      expect(automation.runsCommand, isTrue);
      expect(automation.startsAgent, isFalse);
      expect(automation.placeKey, 'folder:wsl:~/notes');
      expect(fixtureAutomation(armedAt: fixtureTime).placeKey, 'r1');
    });
  });

  group('on the wire', () {
    test('round-trips the command and the folder', () {
      final read = automationFromJson(automationToJson(inFolder()));
      expect(read.command, sync);
      expect(read.folder, notes);
      expect(read.repositoryId, isEmpty);
      expect(read.commandStated, isTrue);
    });

    test('an agent automation says it has no command', () {
      final json = automationToJson(fixtureAutomation(armedAt: fixtureTime));
      expect(json.containsKey('command'), isTrue);
      expect(json['command'], isNull);
      expect(automationFromJson(json).commandStated, isTrue);
    });

    test('a sender that predates commands reads as unstated', () {
      final json = automationToJson(inFolder())
        ..remove('command')
        ..remove('folder');
      final read = automationFromJson(json);
      expect(read.commandStated, isFalse);
      expect(read.command, isNull);
    });

    test("a run's exit code and output round-trip", () {
      final run = AutomationRun(
        id: 'run',
        automationId: 'sync',
        scheduledFor: fixtureTime,
        firedAt: fixtureTime,
        state: AutomationRunState.failed,
        reason: 'It exited with 3.',
        exitCode: 3,
        output: 'nope\n',
      );
      final read = automationRunFromJson(automationRunToJson(run));
      expect(read.exitCode, 3);
      expect(read.output, 'nope\n');
    });
  });

  group('in the store', () {
    late AppDatabase db;
    late AutomationDao dao;

    setUp(() {
      // Foreign keys on, as the server keeps them: a folder automation names
      // no checkout at all.
      db = AppDatabase.memory();
      dao = AutomationDao(db);
    });
    tearDown(() => db.close());

    test('a folder automation is kept with no checkout', () {
      dao.insert(inFolder());
      final read = dao.getById('sync')!;
      expect(read.repositoryId, isEmpty);
      expect(read.command, sync);
      expect(read.folder, notes);
    });

    test('an edit moves the folder and the command', () {
      dao.insert(inFolder());
      dao.update(
        inFolder().copyWith(
          folder: const EnvironmentPath(environmentId: 'wsl', path: '~'),
          command: sync.copyWith(text: 'date'),
        ),
      );
      final read = dao.getById('sync')!;
      expect(read.folder!.path, '~');
      expect(read.command!.text, 'date');
    });

    test("a run keeps its command's exit code and output", () {
      dao.insert(inFolder());
      final run = AutomationRun(
        id: 'run',
        automationId: 'sync',
        scheduledFor: fixtureTime,
        firedAt: fixtureTime,
        state: AutomationRunState.running,
        reason: '',
      );
      dao.insertRun(run);
      dao.updateRun(
        run.copyWith(
          state: AutomationRunState.finished,
          exitCode: 0,
          output: 'Already up to date.\n',
        ),
      );
      final read = dao.runById('run')!;
      expect(read.exitCode, 0);
      expect(read.output, 'Already up to date.\n');
    });
  });
}
