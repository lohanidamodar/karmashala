import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/core/util/id_generator_provider.dart';
import 'package:chitragupta/src/features/environments/data/execution_environment_dao.dart';
import 'package:chitragupta/src/features/ssh/data/ssh_host_dao.dart';
import 'package:chitragupta/src/features/ssh/domain/ssh_host.dart';
import 'package:chitragupta/src/features/environments/presentation/environments_section.dart';
import 'package:chitragupta/src/features/ssh/presentation/ssh_hosts_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao environments;
  late SshHostDao hosts;

  setUp(() {
    db = AppDatabase.memory();
    environments = ExecutionEnvironmentDao(db);
    environments.upsert(windowsEnv());
    environments.upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));
    hosts = SshHostDao(db);
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FixedClock(testTime)),
          idGeneratorProvider.overrideWithValue(SequentialIdGenerator()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [SshHostsSection(), EnvironmentsSection()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fillHostForm(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'build-box');
    await tester.enterText(
      find.widgetWithText(TextField, 'Host'),
      'build.example.com',
    );
    await tester.enterText(find.widgetWithText(TextField, 'Port'), '2222');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'dev');
    await tester.enterText(
      find.widgetWithText(TextField, 'Private key path'),
      r'C:\Users\me\.ssh\id_ed25519',
    );
  }

  testWidgets('says what it stores when there is nothing yet', (tester) async {
    await pump(tester);
    expect(find.textContaining('No remote hosts yet'), findsOneWidget);
    expect(find.textContaining('passphrases never are'), findsOneWidget);
  });

  testWidgets('adding a host creates it and its execution environment', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();

    await fillHostForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    final saved = hosts.getAll().single;
    expect(saved.name, 'build-box');
    expect(saved.address, 'dev@build.example.com:2222');
    expect(saved.authMethod, SshAuthMethod.privateKey);
    // A remote host is configured, not discovered — adding one is what makes
    // its environment exist.
    expect(environments.getById(saved.environmentId), isNotNull);
    expect(find.text('dev@build.example.com:2222'), findsOneWidget);
  });

  testWidgets('the key path is stored with the environment that owns it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await fillHostForm(tester);

    final picker = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(picker);
    await tester.pumpAndSettle();
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ubuntu · wsl:Ubuntu').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Private key path'),
      '/home/me/.ssh/id_ed25519',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    final saved = hosts.getAll().single;
    expect(saved.privateKey!.environmentId, 'wsl:Ubuntu');
    expect(saved.privateKey!.path, '/home/me/.ssh/id_ed25519');
  });

  testWidgets('an incomplete form refuses to save and says why', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Name, host and username are all required'),
      findsOneWidget,
    );
    expect(hosts.getAll(), isEmpty);
  });

  testWidgets('key auth without a key path is rejected', (tester) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'box');
    await tester.enterText(find.widgetWithText(TextField, 'Host'), 'h');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'u');
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('needs the path to a private key'),
      findsOneWidget,
    );
  });

  testWidgets('a password host saves no key and says so', (tester) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'box');
    await tester.enterText(find.widgetWithText(TextField, 'Host'), 'h');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'u');
    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();
    expect(find.textContaining('never written to disk'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    final saved = hosts.getAll().single;
    expect(saved.authMethod, SshAuthMethod.password);
    expect(saved.privateKey, isNull);
  });

  testWidgets('editing a host rewrites it in place', (tester) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await fillHostForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Port'), '2022');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(hosts.getAll(), hasLength(1));
    expect(hosts.getAll().single.port, 2022);
  });

  testWidgets('removing a host asks first and keeps its pinned key', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await fillHostForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.textContaining('trusted host key is kept'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(hosts.getAll(), hasLength(1));

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(hosts.getAll(), isEmpty);
    expect(environments.getById('ssh:id-0'), isNull);
  });

  testWidgets('a new host appears in the environments list straight away', (
    tester,
  ) async {
    // A remote environment you have just created but cannot see is not created
    // as far as the user is concerned: both lists read the same table, and one
    // of them used to keep showing the world as it was.
    await pump(tester);
    expect(find.text('SSH'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Add host'));
    await tester.pumpAndSettle();
    await fillHostForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Add host'));
    await tester.pumpAndSettle();

    expect(find.text('SSH'), findsOneWidget);
    expect(find.text('ssh:id-0 · dev@build.example.com:2222'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('SSH'), findsNothing);
  });
}
