import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/terminal/application/local_host_providers.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/host_terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/local_host_access.dart';
import 'package:karmashala/src/features/terminal/data/terminal_instance.dart';
import 'package:karmashala_terminal_core/profiles.dart';

/// Which pane the *real* factory builds, so "the setting decides" is asserted
/// rather than assumed.
///
/// The whole point of the default is that with it off nothing changes, and the
/// only way to know that is to open a pane through the same provider the app
/// does and look at what came back.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  ProviderContainer containerWith({
    required bool setting,
    LocalHostSessionAccess? access,
  }) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      hostBackedLocalPanesProvider.overrideWithValue(setting),
      localHostSessionAccessProvider.overrideWithValue(access),
    ],
  );

  TerminalInstance openLocalPane(ProviderContainer container) =>
      container.read(terminalInstanceFactoryProvider)(
        id: 'p1',
        profile: const TerminalProfile(
          id: 'cmd',
          label: 'Command Prompt',
          shell: TerminalShell.commandPrompt,
        ),
      );

  test('with the setting off, a local pane is what it has always been', () {
    final container = containerWith(setting: false, access: LocalHostSessionAccess());
    addTearDown(container.dispose);
    final pane = openLocalPane(container);
    addTearDown(pane.dispose);
    expect(pane, isNot(isA<HostTerminalInstance>()));
  });

  test('with the setting on, a local pane belongs to the session host', () {
    final container = containerWith(setting: true, access: LocalHostSessionAccess());
    addTearDown(container.dispose);
    final pane = openLocalPane(container);
    addTearDown(pane.dispose);
    expect(pane, isA<HostTerminalInstance>());
    // The launch is the one a flutter_pty pane would have spawned: the profile
    // decides the command, and the setting decides only whose child it is.
    expect((pane as HostTerminalInstance).launch.executable, 'cmd.exe');
  });

  test('with the setting on and no host to reach, nothing changes either', () {
    // A companion build, or any platform with no binary to run: the provider
    // answers null and the pane falls through to the path that always worked,
    // rather than to a pane that cannot start.
    final container = containerWith(setting: true, access: null);
    addTearDown(container.dispose);
    final pane = openLocalPane(container);
    addTearDown(pane.dispose);
    expect(pane, isNot(isA<HostTerminalInstance>()));
  });
}
