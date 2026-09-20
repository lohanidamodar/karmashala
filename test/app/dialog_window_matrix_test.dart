import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/agents/data/agent_installation_dao.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:karmashala/src/features/projects/data/project_dao.dart';
import 'package:karmashala/src/features/repositories/data/repository_dao.dart';
import 'package:karmashala/src/features/sessions/data/session_dao.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/general_pages.dart';
import 'package:karmashala/src/features/ssh/application/ssh_prompt_controller.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala/src/features/ssh/presentation/host_key_changed_alert.dart';
import 'package:karmashala/src/features/ssh/presentation/host_key_dialog.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_secret_dialog.dart';
import 'package:karmashala_terminal_core/pane_lifecycle.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/session_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/terminal/fake_instance.dart';
import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/window_matrix.dart';

/// The six dialogs `minimum_window_matrix_test.dart` did not reach.
///
/// A second file rather than more of that one: it is already the length this
/// repository treats as too long, and these six are reached differently — two
/// of them only exist behind a route, so they are opened the way a user opens
/// them rather than constructed.
///
/// Every one of these appears *over* work in progress — a host key that changed
/// mid-connect, a password prompt, the list of sessions still running in the
/// background — so a viewport that clips them, or a button Tab cannot reach,
/// lands at exactly the moment the user has least patience for it.

/// Nothing here may shell out.
// ignore: strict_top_level_inference
noProcessOverrides() => [
  commandRunnerFactoryProvider.overrideWithValue(
    FakeCommandRunnerFactory(fallback: FakeCommandRunner()),
  ),
  hostCommandRunnerProvider.overrideWithValue(FakeCommandRunner()),
];

Widget app(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: home, debugShowCheckedModeBanner: false),
    );

Widget panel(ProviderContainer container, Widget body) =>
    app(container, Scaffold(body: body));

SshHost host() => SshHost(
  id: 'h1',
  name: 'build-box',
  host: 'build.example.internal',
  port: 22,
  username: 'dlohani',
  authMethod: SshAuthMethod.password,
  createdAt: testTime,
);

/// A fingerprint of the length a real one has: the dialogs lay these out on one
/// line, and a short placeholder would not reach the edge that breaks.
const _fingerprint = 'SHA256:9qXK2mB7vLpQ4rT8sN1cW3eY6uZ0aI5oJ2hG7fD4kM8';
const _otherFingerprint = 'SHA256:1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdEf';

/// The key this host used to present, trusted long enough ago that the alert
/// renders a real date rather than "just now".
final _trustedAt = DateTime.utc(2025, 11, 3, 9, 12);

void main() {
  group('the SSH dialogs, which appear mid-connect', () {
    testWidgets('SshSecretDialog', (tester) async {
      final container = ProviderContainer(overrides: noProcessOverrides());
      addTearDown(container.dispose);

      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          container,
          SshSecretDialog(host: host(), kind: SshSecretKind.passphrase),
        ),
        because: 'a password prompt over a connection that is already waiting',
      );
    });

    testWidgets('HostKeyTrustDialog', (tester) async {
      final container = ProviderContainer(overrides: noProcessOverrides());
      addTearDown(container.dispose);

      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          container,
          const HostKeyTrustDialog(
            presentation: HostKeyPresentation(
              host: 'build.example.internal',
              port: 22,
              keyType: 'ssh-ed25519',
              fingerprint: _fingerprint,
              verdict: HostKeyVerdict.unknown,
            ),
          ),
        ),
        because: 'a full-length fingerprint on one line, plus trust/refuse',
      );
    });

    testWidgets('ForgetHostKeyDialog', (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          ...noProcessOverrides(),
        ],
      );
      addTearDown(container.dispose);

      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          container,
          const ForgetHostKeyDialog(host: 'build.example.internal', port: 22),
        ),
        because: 'the destructive half of a changed-key alert',
      );
    });

    testWidgets('HostKeyChangedAlert, which carries two fingerprints', (
      tester,
    ) async {
      // Not on the backlog's list, but it is the surface `ForgetHostKeyDialog`
      // opens *from* and the only one here that lays out two full fingerprints
      // stacked — the narrowest thing in the group.
      final container = ProviderContainer(overrides: noProcessOverrides());
      addTearDown(container.dispose);

      await expectSurvivesWindowMatrix(
        tester,
        build: () => app(
          container,
          HostKeyChangedAlert(
            presentation: HostKeyPresentation(
              host: 'build.example.internal',
              port: 22,
              keyType: 'ssh-ed25519',
              fingerprint: _fingerprint,
              verdict: HostKeyVerdict.changed,
              known: KnownHostKey(
                host: 'build.example.internal',
                port: 22,
                keyType: 'ssh-ed25519',
                fingerprint: _otherFingerprint,
                trustedAt: _trustedAt,
              ),
            ),
          ),
        ),
        because: 'two full fingerprints stacked, with a warning above them',
      );
    });
  });

  testWidgets('BackgroundSessionsDialog with enough rows to scroll', (
    tester,
  ) async {
    final container = ProviderContainer(overrides: noProcessOverrides());
    addTearDown(container.dispose);

    // Eight, because the dialog's whole job is to list what is still running
    // and one row proves nothing about a list. Long titles for the same reason
    // the fingerprints above are real length.
    final sessions = [
      for (var i = 0; i < 8; i++)
        DetachedSession(
          paneId: 'p$i',
          title: 'karmashala-app — claude — refactor the terminal ingest $i',
          workingDirectory: r'C:\Users\dlohani\projects\popupbits\karmashala',
          detachedAt: testTime,
        ),
    ];

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(
        container,
        BackgroundSessionsDialog(
          sessions: sessions,
          // Alternating, so the row renders both of its states in one pass.
          livenessOf: (paneId) => paneId.endsWith('0') || paneId.endsWith('4')
              ? PaneLiveness.exited
              : PaneLiveness.live,
          onAttach: (_) {},
          onEnd: (_) {},
          onEndAll: () {},
        ),
      ),
      because: 'a list of what is still running, with per-row actions',
    );
  });

  testWidgets('QuickOpen with results to show', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    ProjectDao(db).insert(project());
    RepositoryDao(db).insert(repository());
    // A session row points at an agent installation; without one the insert
    // fails the foreign key rather than the layout.
    AgentInstallationDao(db).insert(agentInstallation());
    final sessions = SessionDao(db);
    for (var i = 0; i < 6; i++) {
      sessions.insert(
        session(id: 's$i', title: 'refactor the terminal ingest path, part $i'),
      );
    }

    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(database: db),
        ...noProcessOverrides(),
      ],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => app(container, const QuickOpen()),
      // Its list is the point: an empty one would pass at any size.
      warmUp: (tester) => tester.pump(const Duration(milliseconds: 250)),
      // Tab is not this surface's navigation and the ring check describes a
      // form, not a palette: focus stays in the field and Arrow/Enter move the
      // highlighted row (`_onKey`), the way every command palette works. The
      // rows are still `Semantics(button: true)`, so the accessibility check
      // that matters here — every control named — is the one left running.
      checkFocus: false,
      because: 'a search field over a result list, sized to the window',
    );
  });

  testWidgets('the launcher hotkey recorder', (tester) async {
    // Private, so it is reached the way a user reaches it: the Change button on
    // the launcher-hotkey section, which is only enabled while the switch is on.
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        ...noProcessOverrides(),
        clockProvider.overrideWithValue(FixedClock(testTime)),
        idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(settingsControllerProvider.notifier)
        .setLauncherHotkeyEnabled(true);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => panel(container, const LauncherHotkeySection()),
      warmUp: (tester) async {
        await tester.tap(find.widgetWithText(OutlinedButton, 'Change'));
        await tester.pumpAndSettle();
      },
      because: 'a modal that records a chord, over the settings page',
    );
  });
}
