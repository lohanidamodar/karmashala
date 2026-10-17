import 'package:agent_cli/process.dart' show EnvironmentPath;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/automations/application/automation_draft.dart';
import 'package:karmashala/src/features/automations/application/automation_editor_state.dart';
import 'package:karmashala/src/features/automations/application/automation_providers.dart';
import 'package:karmashala/src/features/automations/presentation/automation_editor.dart';
import 'package:karmashala/src/features/automations/presentation/automation_run_status.dart';
import 'package:karmashala/src/features/automations/presentation/automation_runs_view.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/runs.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../terminal/fake_instance.dart';
import '../../support/fake_data_server.dart';

/// The editor's "Where" card and a command as the first step: written,
/// tried once, saved, and its output read back in Runs.
void main() {
  late ProviderContainer container;
  late FakeDataServer server;
  final now = DateTime.utc(2026, 10, 17, 9);

  setUp(() async {
    server = FakeDataServer();
    server.environmentRows.upsert(windowsEnv());
    server.environmentRows.upsert(wslEnv());
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(),
        await server.override(),
        clockProvider.overrideWithValue(FixedClock(now)),
        runNowOfferedProvider.overrideWithValue(true),
        commandsOfferedProvider.overrideWithValue(true),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1440, 1600),
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> editor(
    WidgetTester tester,
    AutomationDraft draft, {
    Size size = const Size(1440, 1600),
    double textScale = 1,
  }) {
    container.read(automationEditorProvider.notifier).open(draft);
    return pump(
      tester,
      Consumer(
        builder: (context, ref, _) {
          final editing = ref.watch(automationEditorProvider);
          return editing == null
              ? const Text('the list')
              : AutomationEditor(
                  key: ValueKey(editing.generation),
                  initial: editing.draft,
                );
        },
      ),
      size: size,
      textScale: textScale,
    );
  }

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).first);
    await tester.tap(find.text(text).first);
    await tester.pumpAndSettle();
  }

  testWidgets('a schedule that runs a command in a folder on WSL: written, '
      'tried once, and saved', (tester) async {
    await editor(tester, const AutomationDraft(repositoryId: 'r1'));
    await tester.enterText(key('automation-name'), 'Sync notes');
    await tapText(tester, 'Command');
    await tapText(tester, 'Any folder');

    await tester.tap(key('automation-machine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WSL · Ubuntu').last);
    await tester.pumpAndSettle();
    expect(find.text('In your login shell on WSL · Ubuntu.'), findsOneWidget);
    expect(key('automation-shell'), findsNothing, reason: 'not Windows');

    await tester.enterText(
      find.descendant(
        of: key('automation-folder'),
        matching: find.byType(TextField),
      ),
      '~/notes',
    );
    await tester.enterText(key('automation-command'), 'git -C ~/notes pull');
    await tester.pumpAndSettle();

    await tester.ensureVisible(key('automation-command-try'));
    await tester.tap(key('automation-command-try'));
    await tester.pumpAndSettle();
    expect(
      server.automationRows.tried.single.command!.text,
      'git -C ~/notes pull',
    );
    expect(key('automation-command-tried'), findsOneWidget);
    expect(find.textContaining('Exited with 0'), findsOneWidget);
    expect(find.textContaining('Already up to date.'), findsOneWidget);
    expect(server.automationRows.rules, isEmpty, reason: 'trying saves none');

    await tester.tap(key('automation-save'));
    await tester.pumpAndSettle();
    final saved = server.automationRows.rules.values.single;
    expect(saved.repositoryId, isEmpty);
    expect(
      saved.folder,
      const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '~/notes'),
    );
    expect(saved.command!.shell, AutomationShell.login);
    expect(saved.maxRuntime, kCommandTimeLimit, reason: 'a command has one');
  });

  testWidgets('on Windows it asks PowerShell or cmd, and refuses a %…% value '
      'in cmd', (tester) async {
    await editor(
      tester,
      const AutomationDraft(
        name: 'Stamp',
        repositoryId: 'r1',
        runsCommand: true,
        maxRuntimeMinutes: 10,
      ),
    );
    expect(find.text('In PowerShell on Windows.'), findsOneWidget);
    await tapText(tester, 'cmd');
    await tester.enterText(
      key('automation-command'),
      'echo %KARMASHALA_AUTOMATION%',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('never %KARMASHALA_'), findsWidgets);
    final save = tester.widget<FilledButton>(key('automation-save'));
    expect(save.onPressed, isNull);
  });

  testWidgets('an agent keeps to projects: Agent moves a folder back', (
    tester,
  ) async {
    await editor(
      tester,
      const AutomationDraft(
        name: 'x',
        runsCommand: true,
        place: DraftPlace.folder,
        environmentId: 'wsl:Ubuntu',
      ),
    );
    expect(key('automation-folder'), findsOneWidget);
    await tapText(tester, 'Agent');
    expect(key('automation-folder'), findsNothing);
    expect(key('automation-checkout'), findsNothing, reason: 'Ubuntu has none');
    expect(find.textContaining('No project on this machine'), findsOneWidget);
  });

  testWidgets('Runs shows what the command printed and how it exited', (
    tester,
  ) async {
    final rule = Automation(
      id: 'sync',
      repositoryId: '',
      name: 'Sync notes',
      schedule: const AutomationSchedule.cron('0 9 * * 1-5'),
      agentInstallationId: '',
      prompt: '',
      permissionMode: null,
      enabled: true,
      armedAt: now,
      command: const AutomationCommand(text: 'git pull'),
      folder: const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '~'),
      steps: AutomationSteps.none,
    );
    server.automationRows.insert(rule);
    final run = AutomationRun(
      id: 'run1',
      automationId: 'sync',
      scheduledFor: now,
      firedAt: now,
      state: AutomationRunState.failed,
      reason: 'It exited with 128.',
      finishedAt: now.add(const Duration(seconds: 1)),
      exitCode: 128,
      output: "fatal: not a git repository: '/home/you'\n",
    );
    await pump(
      tester,
      RunTile(run: run, checks: const [], initiallyOpen: true),
      size: const Size(360, 800),
    );
    expect(find.text('Run a command'), findsOneWidget);
    expect(find.text('It exited with 128.'), findsOneWidget);
    expect(key('run-output'), findsOneWidget);
    expect(find.textContaining('not a git repository'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A finished run with no check step is done, never "Checking" forever.
    await pump(
      tester,
      RunTile(
        run: run.copyWith(
          state: AutomationRunState.finished,
          reason: 'It exited with 0.',
          exitCode: 0,
        ),
        checks: const [],
      ),
      size: const Size(360, 800),
    );
    expect(find.text(RunOutcome.succeeded.label), findsOneWidget);
    expect(find.text(RunOutcome.checking.label), findsNothing);
  });

  testWidgets('it fits 360 px and large text, in a folder and a project', (
    tester,
  ) async {
    for (final draft in const [
      AutomationDraft(
        name: 'Sync notes with a long name that wraps',
        runsCommand: true,
        commandText: 'git -C ~/notes pull --ff-only && date >> ~/notes/.last',
        place: DraftPlace.folder,
        environmentId: 'wsl:Ubuntu',
        folderPath: '~/notes/a/folder/with/a/long/path/in/it',
        maxRuntimeMinutes: 10,
      ),
      AutomationDraft(
        name: 'Stamp',
        repositoryId: 'r1',
        runsCommand: true,
        commandText: 'Get-Date',
        maxRuntimeMinutes: 10,
      ),
      AutomationDraft(
        name: 'Lint',
        repositoryId: 'r1',
        trigger: DraftTrigger.event,
        runsCommand: true,
        commandText: 'make lint',
      ),
    ]) {
      for (final (size, scale) in const [
        (Size(360, 2600), 1.0),
        (Size(360, 3600), 1.6),
        (Size(1440, 1600), 1.0),
      ]) {
        await editor(tester, draft, size: size, textScale: scale);
        expect(key('automation-where'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: '${draft.name} $size $scale',
        );
      }
    }
  });
}
