import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/records.dart';
import 'package:karmashala_automations/store.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_store/database.dart';
import 'package:test/test.dart';

/// Saving an automation whose first step runs a command: what the server
/// keeps, what it refuses, and what an older client's save leaves alone.
void main() {
  late AppDatabase db;
  late DataSession app;
  final now = DateTime.utc(2026, 10, 17, 9);
  const notes = EnvironmentPath(environmentId: 'wsl', path: '~/notes');
  const sync = AutomationCommand(text: 'git -C ~/notes pull');

  setUp(() {
    db = AppDatabase.memory();
    app = DataService(db, clock: () => now).open((_) {});
    const at = '2026-01-01T00:00:00.000Z';
    db
      ..execute(
        'INSERT INTO execution_environments (id, kind, name, created_at) '
        "VALUES ('wsl', 'wsl', 'archlinux', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO projects '
        '(id, name, root_environment_id, root_path, created_at) '
        "VALUES ('p1', 'Demo', 'wsl', '/src', ?);",
        [at],
      )
      ..execute(
        'INSERT INTO repositories '
        '(id, project_id, name, environment_id, path, created_at) '
        "VALUES ('r1', 'p1', 'app', 'wsl', '/src/app', ?);",
        [at],
      );
  });
  tearDown(() => db.close());

  Automation inFolder({
    AutomationSteps steps = AutomationSteps.none,
    AutomationCommand? command = sync,
  }) => Automation(
    id: 'sync',
    repositoryId: '',
    name: 'Sync notes',
    schedule: const AutomationSchedule.cron('0 9 * * 1-5'),
    agentInstallationId: 'a1',
    prompt: '',
    permissionMode: null,
    enabled: true,
    armedAt: now,
    modelId: 'opus',
    worktree: true,
    command: command,
    folder: notes,
    steps: steps,
  );

  Matcher refused(String words) => throwsA(
    isA<DataRefused>().having((r) => r.message, 'message', contains(words)),
  );

  test('a command in a folder is kept with no checkout and no agent', () {
    final saved = app.handle(AutomationSave(inFolder())).value;
    expect(saved.repositoryId, isEmpty);
    expect(saved.folder, notes);
    expect(saved.command, sync);
    expect(saved.agentInstallationId, isEmpty);
    expect(saved.modelId, isNull);
    expect(saved.worktree, isFalse);
  });

  test('a command in a project keeps its checkout', () {
    final saved = app
        .handle(
          AutomationSave(
            inFolder().copyWith(clearFolder: true, repositoryId: 'r1'),
          ),
        )
        .value;
    expect(saved.repositoryId, 'r1');
    expect(saved.command, sync);
  });

  test('a client that predates commands keeps the command and the folder', () {
    app.handle(AutomationSave(inFolder()));
    final old = automationFromJson(
      automationToJson(inFolder().copyWith(name: 'Renamed'))
        ..remove('command')
        ..remove('folder'),
    );
    final saved = app.handle(AutomationSave(old)).value;
    expect(saved.name, 'Renamed');
    expect(saved.command, sync);
    expect(saved.folder, notes);
    expect(AutomationDao(db).getById('sync')!.command, sync);
  });

  test('an agent never runs in a plain folder', () {
    expect(
      () => app.handle(AutomationSave(inFolder(command: null))),
      refused('an agent runs in a project'),
    );
  });

  test('an empty command, or one that fills variables in, is refused', () {
    expect(
      () => app.handle(
        AutomationSave(inFolder(command: const AutomationCommand(text: ' '))),
      ),
      refused('what command to run'),
    );
    expect(
      () => app.handle(
        AutomationSave(
          inFolder(command: const AutomationCommand(text: 'echo {{project}}')),
        ),
      ),
      refused('environment'),
    );
  });

  test(
    'a folder has no project for checks, and a command no agent to tell',
    () {
      expect(
        () => app.handle(
          AutomationSave(
            inFolder(
              steps: AutomationSteps(const [
                AutomationStep(kind: AutomationStepKind.check, text: 'make'),
              ]),
            ),
          ),
        ),
        refused('needs a project'),
      );
      expect(
        () => app.handle(
          AutomationSave(
            inFolder().copyWith(
              clearFolder: true,
              repositoryId: 'r1',
              steps: AutomationSteps(const [
                AutomationStep(kind: AutomationStepKind.tell, text: 'fix it'),
              ]),
            ),
          ),
        ),
        refused('no agent to tell'),
      );
    },
  );

  test('an event rule watches a project, so it cannot run in a folder', () {
    expect(
      () => app.handle(
        AutomationSave(
          inFolder().copyWith(
            trigger: const AutomationEventTrigger(
              kind: AutomationEventKind.turnFinished,
              action: AutomationEventAction.startSession,
            ),
          ),
        ),
      ),
      refused('runs in one'),
    );
  });

  test('a saved automation keeps a folder or a checkout, not one for the '
      'other', () {
    app.handle(AutomationSave(inFolder()));
    expect(
      () => app.handle(
        AutomationSave(
          inFolder().copyWith(clearFolder: true, repositoryId: 'r1'),
        ),
      ),
      refused('keeps the checkout'),
    );
    final moved = app
        .handle(
          AutomationSave(
            inFolder().copyWith(
              folder: const EnvironmentPath(environmentId: 'wsl', path: '~'),
            ),
          ),
        )
        .value;
    expect(moved.folder!.path, '~', reason: 'the folder itself may move');
  });
}
