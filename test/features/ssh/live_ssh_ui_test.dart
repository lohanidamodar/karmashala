@Tags(['live-ssh'])
library;

import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/agents/data/agent_installation_dao.dart';
import 'package:chitragupta/src/features/agents/domain/agent_ids.dart';
import 'package:chitragupta/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/environments/presentation/environments_section.dart';
import 'package:chitragupta/src/features/ssh/data/known_host_dao.dart';
import 'package:chitragupta/src/features/ssh/data/ssh_host_dao.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_host_key.dart';
import 'package:chitragupta/src/features/ssh/presentation/ssh_hosts_section.dart';
import 'package:chitragupta/src/features/ssh/presentation/ssh_prompt_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The whole feature, driven through its actual widgets, against a **real**
/// SSH server.
///
/// This is the test that answers the question Loop 43 exists to answer: can a
/// person who has never connected to a machine add it here, be shown its
/// fingerprint, accept it, and see the agents that are installed on it? A mock
/// cannot answer that — it would agree with whatever the code already believes.
///
/// Opt-in, like the Loop 37 live suite: set `CHITRAGUPTA_SSH_HOST`,
/// `CHITRAGUPTA_SSH_USER`, `CHITRAGUPTA_SSH_KEY` and optionally
/// `CHITRAGUPTA_SSH_PORT`.
String? _env(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

void main() {
  final address = _env('CHITRAGUPTA_SSH_HOST');
  final username = _env('CHITRAGUPTA_SSH_USER');
  final keyPath = _env('CHITRAGUPTA_SSH_KEY');
  final port = _env('CHITRAGUPTA_SSH_PORT') ?? '22';
  final browseDir = _env('CHITRAGUPTA_SSH_BROWSE_DIR');

  if (address == null || username == null || keyPath == null) {
    test(
      'live SSH UI tests are skipped',
      () {},
      skip:
          'Set CHITRAGUPTA_SSH_HOST, CHITRAGUPTA_SSH_USER and '
          'CHITRAGUPTA_SSH_KEY to run the live SSH UI suite.',
    );
    return;
  }

  late AppDatabase db;
  late KnownHostDao known;
  late SshHostDao hosts;
  late AgentInstallationDao installations;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    known = KnownHostDao(db);
    hosts = SshHostDao(db);
    installations = AgentInstallationDao(db);
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        ],
        child: MaterialApp(
          home: SshPromptHost(
            child: Scaffold(body: SingleChildScrollView(child: body)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Pumps frames while letting the real event loop run, until [done] holds.
  ///
  /// A widget test runs inside a fake clock, and a real socket does not. Real
  /// I/O completions only reach the widget tree if the test alternates between
  /// yielding to the real event loop and pumping a frame.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() done, {
    Duration timeout = const Duration(seconds: 30),
    String what = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (done()) return;
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    if (!done()) fail('Timed out waiting for $what');
  }

  Future<void> fillHostForm(WidgetTester tester, {String? directory}) async {
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'live-box');
    await tester.enterText(find.widgetWithText(TextField, 'Host'), address);
    await tester.enterText(find.widgetWithText(TextField, 'Port'), port);
    await tester.enterText(
      find.widgetWithText(TextField, 'Username'),
      username,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Private key path'),
      keyPath,
    );
    if (directory != null) {
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Default directory on the host (optional)',
        ),
        directory,
      );
    }
    await tester.pump();
  }

  Future<void> openAddDialog(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
  }

  Future<void> pressTestConnection(WidgetTester tester) async {
    final button = find.widgetWithText(OutlinedButton, 'Test connection');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
  }

  Future<void> acceptTheHostKey(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Trust this key'));
    await tester.pump();
  }

  testWidgets('add a host, be shown its key, accept it, and connect', (
    tester,
  ) async {
    await pump(tester, const SshHostsSection());
    await openAddDialog(tester);
    await fillHostForm(tester);
    await pressTestConnection(tester);

    // The server we have never met is not connected to until we say so.
    await pumpUntil(
      tester,
      () => find.text('Unrecognised host key').evaluate().isNotEmpty,
      what: 'the host key prompt',
    );

    // Everything needed to compare against what the operator published.
    expect(find.textContaining('$address:$port'), findsWidgets);
    final fingerprint = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.data ?? '')
        .firstWhere((t) => t.startsWith('SHA256:'), orElse: () => '');
    expect(fingerprint, startsWith('SHA256:'));
    expect(find.text('ssh-ed25519'), findsOneWidget);
    expect(known.find(address, int.parse(port)), isNull);

    await acceptTheHostKey(tester);

    await pumpUntil(
      tester,
      () => find.textContaining('Connected in').evaluate().isNotEmpty,
      what: 'a successful connection',
    );
    // The remote answered for itself.
    expect(find.textContaining('Linux'), findsOneWidget);

    // Accepting is what pinned it, with exactly what was shown.
    final pinned = known.find(address, int.parse(port))!;
    expect(pinned.fingerprint, fingerprint);
    expect(pinned.keyType, 'ssh-ed25519');

    // Saving keeps it, and creates the execution environment it owns.
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await pumpUntil(
      tester,
      () => find.text('Add SSH host').evaluate().isEmpty,
      what: 'the host to be saved',
    );
    expect(hosts.getAll().single.address, '$username@$address:$port');
  });

  testWidgets('the second connection does not ask again', (tester) async {
    await pump(tester, const SshHostsSection());
    await openAddDialog(tester);
    await fillHostForm(tester);
    await pressTestConnection(tester);
    await pumpUntil(
      tester,
      () => find.text('Unrecognised host key').evaluate().isNotEmpty,
      what: 'the first prompt',
    );
    await acceptTheHostKey(tester);
    await pumpUntil(
      tester,
      () => find.textContaining('Connected in').evaluate().isNotEmpty,
      what: 'the first connection',
    );

    await pressTestConnection(tester);
    await pumpUntil(
      tester,
      () => find.textContaining('Connected in').evaluate().isNotEmpty,
      what: 'the second connection',
    );
    expect(find.text('Unrecognised host key'), findsNothing);
  });

  testWidgets('a changed host key is refused, with no way to click through', (
    tester,
  ) async {
    // A key pinned for this address that the server will not present: exactly
    // what a substituted host looks like.
    known.trust(
      KnownHostKey(
        host: address,
        port: int.parse(port),
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:pLaNtEdImPoStOrFiNgErPrInT0000000000000000',
        trustedAt: testTime,
      ),
    );

    await pump(tester, const SshHostsSection());
    await openAddDialog(tester);
    await fillHostForm(tester);
    await pressTestConnection(tester);

    await pumpUntil(
      tester,
      () => find
          .text('REMOTE HOST IDENTIFICATION HAS CHANGED')
          .evaluate()
          .isNotEmpty,
      what: 'the changed-key alarm',
    );

    // Never asked, never accepted, never overwritten.
    expect(find.text('Unrecognised host key'), findsNothing);
    expect(find.text('Trust this key'), findsNothing);
    expect(find.textContaining('Connected in'), findsNothing);
    expect(
      known.find(address, int.parse(port))!.fingerprint,
      'SHA256:pLaNtEdImPoStOrFiNgErPrInT0000000000000000',
    );

    // The escape hatch, and only after its own confirmation.
    await tester.ensureVisible(find.text('Forget the pinned key…'));
    await tester.pump();
    await tester.tap(find.text('Forget the pinned key…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget it'));
    await tester.pumpAndSettle();
    expect(known.find(address, int.parse(port)), isNull);

    // And now it is a first connection again — which asks.
    await pressTestConnection(tester);
    await pumpUntil(
      tester,
      () => find.text('Unrecognised host key').evaluate().isNotEmpty,
      what: 'the prompt after forgetting',
    );
  });

  testWidgets('the remote filesystem can be browsed over SFTP', (tester) async {
    await pump(tester, const SshHostsSection());
    await openAddDialog(tester);
    await fillHostForm(tester, directory: browseDir);
    await pressTestConnection(tester);
    await pumpUntil(
      tester,
      () => find.text('Unrecognised host key').evaluate().isNotEmpty,
      what: 'the host key prompt',
    );
    await acceptTheHostKey(tester);
    await pumpUntil(
      tester,
      () => find.textContaining('Connected in').evaluate().isNotEmpty,
      what: 'a successful connection',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await pumpUntil(
      tester,
      () => find.text('Add SSH host').evaluate().isEmpty,
      what: 'the host to be saved',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Browse files'));
    await pumpUntil(
      tester,
      () => find.text('hello.txt').evaluate().isNotEmpty,
      what: 'the remote listing',
    );

    // Real SFTP metadata, not parsed `ls` output.
    expect(find.text('nested'), findsOneWidget);
    expect(find.text('6 B'), findsOneWidget);
    // Dotfiles are hidden until asked for, the way a file manager does it.
    expect(find.text('.hidden-marker'), findsNothing);
    await tester.tap(find.byTooltip('Show dotfiles'));
    await tester.pump();
    expect(find.text('.hidden-marker'), findsOneWidget);

    await tester.tap(find.text('nested'));
    await pumpUntil(
      tester,
      () => find.textContaining('$browseDir/nested').evaluate().isNotEmpty,
      what: 'descending into a remote directory',
    );
    // And back up again.
    await tester.tap(find.byTooltip('Up one level'));
    await pumpUntil(
      tester,
      () => find.text('hello.txt').evaluate().isNotEmpty,
      what: 'the parent listing',
    );
    // ignore: avoid_redundant_argument_values
  }, skip: browseDir == null);

  testWidgets('the agents installed on the remote host are listed', (
    tester,
  ) async {
    // Add and trust through the UI first, exactly as a user would.
    await pump(tester, const SshHostsSection());
    await openAddDialog(tester);
    await fillHostForm(tester);
    await pressTestConnection(tester);
    await pumpUntil(
      tester,
      () => find.text('Unrecognised host key').evaluate().isNotEmpty,
      what: 'the host key prompt',
    );
    await acceptTheHostKey(tester);
    await pumpUntil(
      tester,
      () => find.textContaining('Connected in').evaluate().isNotEmpty,
      what: 'a successful connection',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await pumpUntil(
      tester,
      () => find.text('Add SSH host').evaluate().isEmpty,
      what: 'the host to be saved',
    );

    await pump(tester, const EnvironmentsSection());
    await pumpUntil(
      tester,
      () => find.text('Connect and find agents').evaluate().isNotEmpty,
      what: 'the remote environment card',
    );
    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('ssh:id-0 · $username@$address:$port'), findsOneWidget);

    await tester.tap(find.text('Connect and find agents'));
    await tester.pump();
    await pumpUntil(
      tester,
      () => installations.getByEnvironment('ssh:id-0').isNotEmpty,
      what: 'remote agent discovery',
    );
    await tester.pump();

    final found = installations.getByEnvironment('ssh:id-0');
    // Bound to the SSH environment, so they can never be confused with a local
    // install at the same path.
    for (final installation in found) {
      expect(installation.environmentId, 'ssh:id-0');
      expect(installation.executable.path, startsWith('/'));
    }
    expect(
      found.map((i) => i.agentId),
      containsAll(<String>[AgentIds.claudeCode, AgentIds.codex]),
    );
    // And they are on screen, with their versions and their remote paths.
    for (final installation in found) {
      expect(find.textContaining(installation.executable.path), findsOneWidget);
    }
    expect(find.text('Connected'), findsOneWidget);
  });
}
