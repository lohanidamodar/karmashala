import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_skill_installation_service.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import 'package:agent_cli/read.dart';

/// Every store the locator would have found, without touching a real home.
class _StubLocator implements CliStoreLocator {
  _StubLocator(this.stores);

  final List<CliStore> stores;

  @override
  Future<List<CliStore>> locate(List<ExecutionEnvironment> environments) async =>
      stores;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The sweep, against a temporary home. **Nothing here touches the owner's own
/// agent configuration**: the store locator is stubbed with a directory this
/// file created and deletes.
void main() {
  const skills = <KarmashalaSkill>[
    KarmashalaSkill(
      name: 'karmashala-one',
      description: 'A fixture skill. Use it when testing the sweep.',
      body: '# One',
    ),
  ];

  late AppDatabase db;
  late Directory home;

  setUp(() {
    db = AppDatabase.memory();
    ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
    home = Directory.systemTemp.createTempSync('karmashala_skillsvc_');
  });
  tearDown(() {
    db.close();
    removeTempDirectory(home);
  });

  String localEnvironmentId() => ExecutionEnvironmentDao(
    db,
  ).getAll().firstWhere((e) => isLocalHost(e.kind)).id;

  String claudeStore() => p.join(home.path, '.claude');
  File skillFile() => File(
    p.join(home.path, '.claude', 'skills', 'karmashala-one', 'SKILL.md'),
  );

  ProviderContainer containerWith(
    CliStoreLocator locator, {
    AgentRegistry? registry,
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        cliStoreLocatorProvider.overrideWithValue(locator),
        if (registry != null) agentRegistryProvider.overrideWithValue(registry),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  AgentSkillInstallationService serviceIn(ProviderContainer container) =>
      AgentSkillInstallationService(
        container.read(_refProvider),
        skills: skills,
      );

  _StubLocator localStore() => _StubLocator([
    CliStore(
      environmentId: localEnvironmentId(),
      homesByAgentId: {'claudeCode': claudeStore()},
    ),
  ]);

  test('the sweep writes the skills and publishes what it read', () async {
    Directory(claudeStore()).createSync(recursive: true);
    final container = containerWith(localStore());

    final report = await serviceIn(container).sweep();

    expect(skillFile().existsSync(), isTrue);
    expect(report.complete, hasLength(1));
    expect(report.complete.single.agentId, 'claudeCode');
    expect(report.complete.single.installed, 1);
    expect(report.complete.single.root, endsWith('skills'));
    // Published, not just returned: Settings reads the provider.
    expect(
      container.read(agentSkillInstallationReportProvider).complete,
      hasLength(1),
    );
  });

  test('the report carries the age of its reading', () async {
    Directory(claudeStore()).createSync(recursive: true);
    final container = containerWith(localStore());

    expect(AgentSkillInstallationReport.unswept.swept, isFalse);
    expect(AgentSkillInstallationReport.unswept.checkedAt, isNull);

    final report = await serviceIn(container).sweep();
    expect(report.swept, isTrue);
    expect(report.checkedAt, isNotNull);
  });

  test('removal takes back exactly what the sweep wrote', () async {
    Directory(claudeStore()).createSync(recursive: true);
    final container = containerWith(localStore());
    await serviceIn(container).sweep();

    final report = await serviceIn(container).sweepRemoval();

    expect(skillFile().existsSync(), isFalse);
    expect(report.results.single.installed, 0);
    expect(report.results.single.skippedBecause, isNull);
    // The skills root itself is a directory the CLI documents, so it stays.
    expect(
      Directory(p.join(home.path, '.claude', 'skills')).existsSync(),
      isTrue,
    );
  });

  test('a CLI with no skill support gets nothing, and says why', () async {
    // The three shipped CLIs all have skills, so this is the agent added
    // tomorrow: installed, with a store home right here, and nobody has
    // established where — if anywhere — it discovers one. It must get an empty
    // directory tree and a sentence, not a guess.
    const unchecked = AgentDescriptor(
      id: 'unchecked',
      displayName: 'Unchecked CLI',
      binaries: AgentBinaries(windows: ['unchecked'], posix: ['unchecked']),
      store: AgentStoreSpec(
        homeDirectoryName: '.unchecked',
        format: AgentStoreFormat.none,
      ),
      skills: AgentSkillSupport.none(
        refusal: 'nobody has read this CLI\'s documentation',
      ),
    );
    final store = p.join(home.path, '.unchecked');
    Directory(store).createSync(recursive: true);
    final container = containerWith(
      _StubLocator([
        CliStore(
          environmentId: localEnvironmentId(),
          homesByAgentId: {'unchecked': store},
        ),
      ]),
      registry: const AgentRegistry([unchecked]),
    );

    final report = await serviceIn(container).sweep();

    expect(report.complete, isEmpty);
    expect(report.results.single.declared, 0);
    expect(report.incompleteByAgent, {
      'unchecked': 'nobody has read this CLI\'s documentation',
    });
    // Nothing was written anywhere under the home, not even an empty root.
    expect(Directory(store).listSync(), isEmpty);
  });

  test('an agent that declares nothing and says nothing still says why', () async {
    const silent = AgentDescriptor(
      id: 'silent',
      displayName: 'Silent CLI',
      binaries: AgentBinaries(windows: ['silent'], posix: ['silent']),
      store: AgentStoreSpec(
        homeDirectoryName: '.silent',
        format: AgentStoreFormat.none,
      ),
    );
    final store = p.join(home.path, '.silent');
    Directory(store).createSync(recursive: true);
    final container = containerWith(
      _StubLocator([
        CliStore(
          environmentId: localEnvironmentId(),
          homesByAgentId: {'silent': store},
        ),
      ]),
      registry: const AgentRegistry([silent]),
    );

    final report = await serviceIn(container).sweep();

    expect(
      report.incompleteByAgent['silent'],
      contains('nobody has established where this CLI discovers a skill'),
    );
  });

  test('a store home that never answers is unknown, not failed', () async {
    Directory(claudeStore()).createSync(recursive: true);
    final container = containerWith(localStore());
    final service = AgentSkillInstallationService(
      container.read(_refProvider),
      skills: skills,
      storeBudget: Duration.zero,
    );

    final results = await service.installAll();

    expect(results.single.unknown, isTrue);
    expect(results.single.installed, 0);
    // §19: an unobserved state does not borrow an observed one's words.
    expect(results.single.skippedBecause, contains('unknown'));
    expect(
      AgentSkillInstallationReport(results).unknownByAgent.keys,
      ['claudeCode'],
    );

    // **And the work stopped with the wait.** The bound ends the wait; a Dart
    // future cannot be cancelled, so without `SkillSweepDeadline` the install
    // would go on creating directories under a home this row has already
    // reported as unknown — in a test, one whose `tearDown` is about to walk
    // it.
    //
    // The first drain lets whatever was already in flight finish, because that
    // is the honest guarantee: an abandoned sweep completes at most the
    // operation it had started and begins no new one. The snapshot is taken
    // after it, and the two drains that follow are what prove nothing else follows.
    // Counted, never waited out.
    await pumpEventQueue();
    final settled = _filesUnder(home);
    await pumpEventQueue();
    await pumpEventQueue();
    expect(
      _filesUnder(home),
      settled,
      reason: 'an abandoned sweep started new work after it was given up on',
    );
    // And it never leaves a staged file behind: the write and its rename are
    // one operation, so what survives is a skill or nothing.
    expect(
      settled.where((f) => f.endsWith('.tmp')),
      isEmpty,
      reason: 'a staged write outlived the sweep that started it',
    );
  });

  test('shutdown gives up on a sweep in flight', () async {
    Directory(claudeStore()).createSync(recursive: true);
    final container = containerWith(localStore());
    final service = serviceIn(container);

    // Nothing has been swept, so there is nothing to give up on and this must
    // still be safe to call — shutdown runs it unconditionally.
    service.abandon();

    await service.sweep();
    final settled = _filesUnder(home);
    service.abandon();
    await pumpEventQueue();

    expect(_filesUnder(home), settled);
  });
}

/// A `Ref` from inside the container, which is what the service takes.
final _refProvider = Provider<Ref>((ref) => ref);

/// Every file under [root], relative and sorted — a count of what a sweep put
/// on disk, so "it wrote nothing more" is a comparison rather than a wait.
List<String> _filesUnder(Directory root) =>
    root
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((f) => p.relative(f.path, from: root.path).replaceAll(r'\', '/'))
        .toList()
      ..sort();
