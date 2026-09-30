import 'package:karmashala/src/app/shell/quick_open/quick_open.dart';
import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/core/util/id_generator_provider.dart';
import 'package:karmashala/src/features/settings/application/settings_controller.dart';
import 'package:karmashala/src/features/settings/presentation/general_pages.dart';
import 'package:karmashala_environments/ssh.dart';
import 'package:karmashala/src/features/ssh/presentation/host_key_changed_alert.dart';
import 'package:karmashala/src/features/ssh/presentation/host_key_dialog.dart';
import 'package:karmashala/src/features/ssh/presentation/ssh_secret_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/terminal/fake_instance.dart';
import '../support/fake_command_runner.dart';
import '../support/fakes.dart';
import '../support/fixtures.dart';
import '../support/window_matrix.dart';
import '../support/fake_data_server.dart';
import '../support/test_machine.dart';
import 'package:agent_cli/process.dart';

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
          SshSecretDialog(
            hostName: host().name,
            address: host().address,
            passphrase: true,
          ),
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
      final container = ProviderContainer(overrides: [...noProcessOverrides()]);
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

  testWidgets('QuickOpen with results to show', (tester) async {
    final db = TestMachine();
    // Sessions are still in the database, and their foreign keys reach the
    // workspace rows the server holds.
    final server = FakeDataServer()..runsOn(db);
    server.environmentRows.upsert(
      localHostEnvironment(FixedClock(testTime).nowUtc()),
    );
    server.projectRows.insert(project());
    server.repositoryRows.insert(repository());
    // A session row points at an agent installation; without one the insert
    // fails the foreign key rather than the layout.
    server.installationRows.insert(agentInstallation());
    final sessions = db.server.sessionRows;
    for (var i = 0; i < 6; i++) {
      sessions.insert(
        session(id: 's$i', title: 'refactor the terminal ingest path, part $i'),
      );
    }

    final data = await server.override();
    final container = ProviderContainer(
      overrides: [
        ...fakeTerminalOverrides(machine: db),
        ...noProcessOverrides(),
        data,
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
    final data = await FakeDataServer().override();
    final container = ProviderContainer(
      overrides: [
        data,
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
