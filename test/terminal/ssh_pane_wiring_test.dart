import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/ssh/application/host_session_providers.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala/src/features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala/src/features/terminal/data/ssh_terminal_instance.dart';
import 'package:karmashala/src/features/terminal/data/terminal_grid_text.dart';
import 'package:karmashala_terminal_core/profiles.dart';
import 'package:karmashala_host/protocol.dart';
import 'package:xterm2/xterm.dart';

import 'fake_host_access.dart';

/// Opening an SSH pane through the *real* factory provider, so the wiring
/// between "the deployer answered" and "this pane speaks the host protocol" is
/// asserted rather than assumed.
///
/// The only thing overridden is how a pane reaches a machine's session host —
/// the same seam `terminalInstanceFactoryProvider` itself is.
void main() {
  late AppDatabase db;

  final host = SshHost(
    id: 'h1',
    name: 'build-box',
    host: 'build.example.internal',
    port: 22,
    username: 'dlohani',
    authMethod: SshAuthMethod.password,
    createdAt: DateTime.utc(2026),
  );

  setUp(() {
    db = AppDatabase.memory();
    SshHostDao(db).upsert(host);
  });
  tearDown(() => db.close());

  ProviderContainer containerWith(HostSessionAccess? access) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      hostSessionAccessLookupProvider.overrideWithValue((_) => access),
    ],
  );

  SshTerminalInstance openSshPane(ProviderContainer container) {
    final instance = container.read(terminalInstanceFactoryProvider)(
      id: 'p1',
      profile: TerminalProfile.ssh('h1', hostName: 'build-box'),
    );
    expect(instance, isA<SshTerminalInstance>());
    (instance as SshTerminalInstance).terminal.resize(200, 60);
    return instance;
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  test('a host that answers gives the pane a host-backed session', () async {
    final access = PaneAccess(readyDeployment());
    final container = containerWith(access);
    addTearDown(container.dispose);

    final pane = openSshPane(container);
    await settle();

    expect(pane.hostAccess, same(access), reason: 'the factory wired it through');
    expect(access.deploymentAsks, 1);
    expect(access.execs.single, contains('karmashala_host-0.1.0-linux-x64 attach'));
    // It really spoke the protocol, rather than merely holding the object.
    expect(access.channels.single.only<HelloMessage>().clientId, 'pane-p1');
    expect(access.channels.single.only<OpenMessage>().sessionId, 'karmashala_h1_p1');
    expect(screenText(pane.terminal), contains('session host 0.1.0'));
    pane.dispose();
  });

  test("a refusal reaches the pane in the deployer's own words", () async {
    final access = PaneAccess(
      HostDeployment(
        status: HostDeploymentStatus.unsupportedPlatform,
        observedAt: DateTime.utc(2026),
        reason:
            'build.example.internal runs musl libc. The host binaries are '
            'glibc-linked ELF, so there is nothing to send.',
      ),
    );
    final container = containerWith(access);
    addTearDown(container.dispose);

    final pane = openSshPane(container);
    await settle();

    final text = screenText(pane.terminal);
    expect(text, contains('runs musl libc'));
    expect(text, contains('glibc-linked ELF'));
    expect(text, contains('Falling back to tmux'));
    expect(access.execs, isEmpty, reason: 'the tmux path, not a half-started host one');
    pane.dispose();
  });

  test('a composition that cannot reach SSH leaves the pane silent about hosts', () async {
    final container = containerWith(null);
    addTearDown(container.dispose);

    final pane = openSshPane(container);
    await settle();

    expect(pane.hostAccess, isNull);
    // Unknown is not a negative answer: nothing is claimed either way.
    expect(screenText(pane.terminal), isNot(contains('session host')));
    pane.dispose();
  });

  test('two panes on one host share a single reading', () async {
    final access = PaneAccess(readyDeployment());
    final container = containerWith(access);
    addTearDown(container.dispose);

    final first = openSshPane(container);
    final second = container.read(terminalInstanceFactoryProvider)(
      id: 'p2',
      profile: TerminalProfile.ssh('h1', hostName: 'build-box'),
    );
    await settle();

    expect((second as SshTerminalInstance).hostAccess, same(access));
    first.dispose();
    second.dispose();
  });
}

String screenText(Terminal terminal) =>
    terminalTailLines(terminal, lines: 200).join('\n');
