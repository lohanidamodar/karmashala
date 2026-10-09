import 'dart:io';
import 'dart:typed_data';

import 'package:agent_cli/process.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/data.dart';
import 'package:karmashala_automations/check_runner.dart'
    show CodeIdentityReader;
import 'package:karmashala_git/git.dart' show GitService;
import 'package:karmashala_verification/store.dart' show VerificationDao;
import 'package:karmashala_devices/devices.dart' show AndroidSdk;
import 'package:karmashala_host/src/browser/server_browser.dart';
import 'package:karmashala_host/src/devices/server_device_claims.dart';
import 'package:karmashala_host/src/devices/server_devices.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_context.dart';
import 'package:karmashala_host/src/mcp/tools/server_verification_runs.dart';
import 'package:karmashala_host/src/mcp/tools/verification_tool_set.dart';
import 'package:karmashala_session/events.dart';
import 'package:karmashala_session/session.dart';
import 'package:karmashala_session_engine/store.dart' show DecisionRecordDao;
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/tools.dart';
import 'package:karmashala_verification/verification.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/fake_browser.dart';
import '../../support/fake_command_runner.dart';

/// The blocks of an `_mcpContent` result.
List<Map<String, Object?>> blocks(Object? result) => [
  for (final block in (result! as Map)['_mcpContent']! as List)
    Map<String, Object?>.from(block as Map),
];

/// The text of the one text block.
String textOf(Object? result) =>
    blocks(result).firstWhere((b) => b['type'] == 'text')['text']! as String;

/// `verification_*` as the server runs them, all of them: a review of a
/// change, a page on its browser and a device on its machine (slice 4a),
/// over a real store and data service.
void main() {
  late AppDatabase db;
  late DataService data;
  late ServerToolContext context;
  late ServerVerificationRuns runs;
  late VerificationToolSet tools;
  late Directory dataDirectory;
  late List<DataChanges> told;
  final now = DateTime.utc(2026, 9, 27, 12);
  var ids = 0;

  setUp(() {
    db = AppDatabase.memory();
    data = DataService(db, clock: () => now);
    told = [];
    data.open(told.add).handle(const DataSubscribe());
    dataDirectory = Directory.systemTemp.createTempSync('verify-server');
    context = ServerToolContext(
      database: db,
      data: data,
      dataDirectory: dataDirectory.path,
      clock: () => now,
    );
    ids = 0;
    runs = ServerVerificationRuns(
      context,
      newId: () => 'run-${(++ids).toString().padLeft(3, '0')}',
    );
    tools = VerificationToolSet(runs);

    const at = '2026-01-01T00:00:00.000Z';
    db.execute(
      'INSERT INTO execution_environments (id, kind, name, created_at) '
      "VALUES ('windows', 'windowsNative', 'Windows', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO projects '
      '(id, name, root_environment_id, root_path, created_at) '
      "VALUES ('p1', 'Demo', 'windows', 'C:\\src', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO repositories '
      '(id, project_id, name, environment_id, path, created_at) '
      "VALUES ('r1', 'p1', 'r1', 'windows', 'C:\\src', ?);",
      [at],
    );
    db.execute(
      'INSERT INTO agent_installations '
      '(id, agent_kind, environment_id, executable_path, created_at) '
      "VALUES ('a1', 'claudeCode', 'windows', 'claude', ?);",
      [at],
    );
    for (final id in ['work-1', 'review-1']) {
      data
          .open((_) {})
          .handle(
            SessionCreate(
              Session(
                id: id,
                repositoryId: 'r1',
                agentInstallationId: 'a1',
                title: id,
                useWorktree: false,
                status: SessionStatus.created,
                createdAt: now,
              ),
            ),
          );
    }
  });
  tearDown(() {
    context.close();
    db.close();
    if (dataDirectory.existsSync()) dataDirectory.deleteSync(recursive: true);
  });

  Future<Object?> call(
    String tool, [
    Map<String, dynamic> arguments = const {},
    String? caller,
  ]) => tools.call(tool, arguments, caller)!;

  Matcher refusal(String words) => throwsA(
    isA<VerificationException>().having(
      (e) => e.message,
      'message',
      contains(words),
    ),
  );

  group('everything is answered here (slice 4a: nothing is the app\'s)', () {
    test('a server with no browser or no devices refuses those runs in '
        'words', () async {
      await expectLater(
        call('verification_start', {'url': 'https://a.test'}),
        refusal('This Karmashala server drives no browser'),
      );
      await expectLater(
        call('verification_start', {
          'serial': 'FAKE123',
          'package': 'com.example.app',
        }, 's'),
        refusal('This Karmashala server drives no devices'),
      );
      expect(runs.activeRun, isNull);
    });

    test('note, finish and a get with no id, with nothing recording, say '
        'what to do', () async {
      await expectLater(
        call('verification_note', {'text': 'x'}, 's'),
        refusal('verification_start'),
      );
      await expectLater(
        call('verification_finish', {'verdict': 'pass'}, 's'),
        refusal('verification_start'),
      );
      await expectLater(
        call('verification_get', const {}, 's'),
        refusal('verification_list'),
      );
    });

    test('an unknown tool in the namespace is named, not swallowed', () async {
      await expectLater(
        call('verification_teleport'),
        refusal('Unknown verification tool: verification_teleport'),
      );
    });

    test('a list and a get by id are read here', () async {
      expect(
        textOf(await call('verification_list')),
        contains('No verification'),
      );
      await expectLater(
        call('verification_get', {'id': 'nope'}),
        refusal('No verification run with id (or prefix) "nope".'),
      );
    });

    test('while the server records, every start is its refusal, and note, '
        'finish and get are its own', () async {
      await call('verification_start', {'change': true, 'title': 'A'});
      await expectLater(
        call('verification_start', {'url': 'https://a.test'}),
        refusal(
          'A verification run is already recording: "A" (run-001). '
          'Finish it before starting another.',
        ),
      );
      expect(tools.call('verification_note', {'text': 'x'}, null), isNotNull);
      expect(
        textOf(await call('verification_get')),
        contains('STILL RECORDING'),
      );
    });
  });

  group('the code a run was taken on', () {
    late _ScriptedIdentities identities;

    setUp(() {
      identities = _ScriptedIdentities();
      runs = ServerVerificationRuns(
        context,
        newId: () => 'run-${(++ids).toString().padLeft(3, '0')}',
        identities: identities,
      );
      tools = VerificationToolSet(runs);
    });

    test('is read from the subject session\'s checkout at the start', () async {
      identities.head = 'a';
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
      }, 'review-1');
      expect(identities.reads, [r'C:\src']);
      expect(runs.activeRun!.identity!.head, startsWith('a'));
      expect(runs.activeRun!.identity!.changedDuringRun, isFalse);
    });

    test('code that moved before the finish is recorded as such, and the '
        'get says it is stale', () async {
      identities.head = 'a';
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
      }, 'review-1');
      identities.head = 'b';
      await call('verification_finish', {'verdict': 'pass'}, 'review-1');
      final stored = VerificationDao(db).getRun('run-001')!;
      expect(stored.identity!.changedDuringRun, isTrue);
      final text = textOf(await call('verification_get', {'id': 'run-001'}));
      expect(text, contains('Code: aaaaaaa'));
      expect(text, contains('it changed while this ran'));
      expect(text, contains('Freshness: STALE'));
    });

    test('code that held still reads fresh', () async {
      identities.head = 'a';
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
      }, 'review-1');
      await call('verification_finish', {'verdict': 'pass'}, 'review-1');
      expect(
        VerificationDao(db).getRun('run-001')!.identity!.changedDuringRun,
        isFalse,
      );
      final text = textOf(await call('verification_get', {'id': 'run-001'}));
      expect(text, contains('Freshness: FRESH'));
    });

    test('a run with nothing recorded says so', () async {
      await call('verification_start', {'change': true}, null);
      await call('verification_finish', {'verdict': 'pass'}, null);
      final text = textOf(await call('verification_get', {'id': 'run-001'}));
      expect(text, contains('Code: not recorded'));
      expect(text, contains('Freshness: VERSION UNKNOWN'));
    });
  });

  group('verification_start', () {
    test('change:true records the caller as the verifier', () async {
      final result = await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the parser fix',
      }, 'review-1');
      final run = runs.activeRun!;
      expect(run.target.kind, VerificationTargetKind.change);
      expect(run.sessionId, 'work-1');
      expect(run.producedBySessionId, 'review-1');
      expect(textOf(result), contains('Recording run-001'));
      expect(textOf(result), contains('independent'));
      expect(textOf(result), contains('verification_note'));
      // Every client is told, and the evidence folder is the server's.
      expect(
        told.expand((t) => t.changes).whereType<VerificationRunChanged>(),
        isNotEmpty,
      );
      expect(
        run.artifactDirectory,
        p.join(dataDirectory.path, 'verification', 'run-001'),
      );
      expect(Directory(run.artifactDirectory).existsSync(), isTrue);
    });

    test('with no subject the caller graded itself, and says so', () async {
      await call('verification_start', {'change': true}, 'work-1');
      expect(runs.activeRun!.sessionId, 'work-1');
      expect(runs.activeRun!.attribution, VerdictAttribution.author);
      expect(runs.activeRun!.title, 'Review of the change');
    });

    test('a change run cannot also be a page run', () async {
      await expectLater(
        call('verification_start', {'change': true, 'url': 'localhost:3000'}),
        refusal(
          'A run verifies one thing: pass url, serial or change, not '
          'several.',
        ),
      );
      await expectLater(
        call('verification_start', {
          'url': 'https://a.test',
          'serial': 'FAKE123',
        }),
        refusal('A run verifies one thing'),
      );
    });

    test('naming nothing at all points at all three kinds', () async {
      await expectLater(
        call('verification_start'),
        refusal(
          'Give url (to verify a page), serial (to verify a device), or '
          'change:true (to record a review of the code itself). list_devices '
          'has the serials.',
        ),
      );
    });
  });

  group('verification_note and finish', () {
    test('a note needs something to say', () async {
      await call('verification_start', {'change': true});
      await expectLater(
        call('verification_note', {'text': '   '}),
        refusal('text is required.'),
      );
    });

    test('an unknown verdict lists the ones that exist', () async {
      await call('verification_start', {'change': true});
      await expectLater(
        call('verification_finish', {'verdict': 'maybe'}),
        refusal('verdict must be one of: pass, fail, inconclusive.'),
      );
    });

    test('finishing reports the verdict, writes the report and frees the '
        'slot', () async {
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the parser fix',
      }, 'review-1');
      await call('verification_note', {
        'text': 'The retry loop never resets the counter.',
      }, 'review-1');
      final text = textOf(
        await call('verification_finish', {
          'verdict': 'fail',
          'reason': 'The retry loop never resets its counter.',
        }, 'review-1'),
      );
      expect(text, startsWith('FAIL — Review of the parser fix'));
      expect(text, contains('by another session'));
      expect(text, contains('1 step'));
      final report = File(
        p.join(dataDirectory.path, 'verification', 'run-001', 'report.md'),
      );
      expect(text, contains('Report: ${report.path}'));
      expect(report.readAsStringSync(), contains('**Verdict: FAIL**'));
      expect(runs.activeRun, isNull);

      final stored = (await runs.get('run-001'))!;
      expect(stored.verdict, VerificationVerdict.fail);
      expect(stored.attribution, VerdictAttribution.independent);
      expect(stored.steps.single.kind, VerificationStepKind.note);
    });

    test('a pass the session gave itself says it is self-verified', () async {
      await call('verification_start', {'change': true}, 'work-1');
      final text = textOf(
        await call('verification_finish', {'verdict': 'pass'}, 'work-1'),
      );
      expect(text, contains('SELF-VERIFIED'));
      expect(text, contains('checks_run'));
    });

    test('a caller outside a session leaves the run unattributed', () async {
      await call('verification_start', {'change': true});
      await call('verification_finish', {'verdict': 'pass'});
      final run = (await runs.list()).single;
      expect(run.producedBySessionId, isNull);
      expect(run.attribution, VerdictAttribution.notRecorded);
    });
  });

  group('the verdict lands in the decision record', () {
    test('of the session whose work it judged, named by its agent', () async {
      await call('verification_start', {
        'change': true,
        'sessionId': 'work-1',
        'title': 'Review of the trailing-comma fix',
      }, 'review-1');
      await call('verification_finish', {
        'verdict': 'pass',
        'reason': 'Nothing wrong found.',
      }, 'review-1');

      final decision = DecisionRecordDao(db).forSession('work-1').single;
      expect(decision.kind, DecisionKind.verificationVerdict);
      expect(
        decision.summary,
        '${VerificationVerdict.pass.label} — Review of the trailing-comma '
        'fix. Nothing wrong found.',
      );
      expect(
        decision.detail,
        'Verdict ${VerdictAttribution.independent.phrase}.',
      );
      expect(decision.decidedBy, 'Claude Code');
      expect(decision.recordedBySessionId, 'review-1');
      expect(decision.origin, DecisionOrigin.verificationRun);
      expect(decision.originId, 'run-001');
      expect(DecisionRecordDao(db).forSession('review-1'), isEmpty);
      expect(
        told.expand((t) => t.changes).whereType<DecisionRecorded>(),
        isNotEmpty,
      );
    });

    test('an unattached run writes nothing, and a missing subject does not '
        'fail the finish', () async {
      await call('verification_start', {'change': true});
      await call('verification_finish', {'verdict': 'pass'});
      await call('verification_start', {'change': true, 'sessionId': 'gone'});
      final text = textOf(
        await call('verification_finish', {'verdict': 'fail'}),
      );
      expect(text, startsWith('FAIL'));
      expect(DecisionRecordDao(db).all(), isEmpty);
    });
  });

  group('reading', () {
    test('one line per run, newest first, and no JSON', () async {
      await call('verification_start', {'change': true, 'title': 'older run'});
      await call('verification_finish', {'verdict': 'pass'});
      await call('verification_start', {'change': true, 'title': 'newer run'});
      await call('verification_note', {'text': 'looked'});
      await call('verification_finish', {'verdict': 'fail'});

      final result = await call('verification_list');
      final text = textOf(result);
      expect(blocks(result), hasLength(1));
      expect(text, isNot(contains('{')));
      expect(text.indexOf('newer run'), lessThan(text.indexOf('older run')));
      expect(text, contains('FAIL'));
      expect(text, contains('1 step'));
    });

    test('a prefix works, and an ambiguous one lists the candidates', () async {
      await call('verification_start', {'change': true, 'title': 'one'});
      await call('verification_finish', {'verdict': 'pass'});
      await call('verification_start', {'change': true, 'title': 'two'});
      await call('verification_finish', {'verdict': 'pass'});

      expect(
        textOf(await call('verification_get', {'id': 'run-001'})),
        contains('one'),
      );
      await expectLater(
        call('verification_get', {'id': 'run-'}),
        refusal('matches 2 runs'),
      );
    });

    test('a run the app recorded is read here by id', () async {
      data
          .open((_) {})
          .handle(
            VerificationStart(
              VerificationRun(
                id: 'run-app',
                title: 'the page saves',
                target: const VerificationTarget.browser('https://a.test'),
                startedAt: now,
                artifactDirectory: p.join(dataDirectory.path, 'verification'),
              ),
            ),
          );
      expect(
        textOf(await call('verification_get', {'id': 'run-app'})),
        contains('STILL RECORDING — the page saves'),
      );
    });
  });

  group('a page on the server\'s browser', () {
    late FakeBrowser fake;
    late ServerBrowser browser;

    setUp(() {
      fake = FakeBrowser();
      browser = ServerBrowser(
        database: db,
        dataDirectory: dataDirectory.path,
        tell: data.announce,
        hostEnvironment: const {},
        operatingSystem: 'macos',
        service: fake.service,
      );
      runs = ServerVerificationRuns(
        context,
        newId: () => 'run-${(++ids).toString().padLeft(3, '0')}',
        browser: browser,
      );
      tools = VerificationToolSet(runs);
    });
    tearDown(() => browser.close());

    test('is started here, and every browser action is a step with its '
        'evidence', () async {
      final started = tools.call('verification_start', {
        'url': 'https://example.com/app',
        'sessionId': 'work-1',
      }, 'review-1');
      expect(started, isNotNull, reason: 'no longer handed to the app');
      expect(textOf(await started), contains('Every browser_* call'));
      expect(fake.service.actionSink, isNotNull);
      await fake.service.screenshot();

      final text = textOf(
        await call('verification_finish', {'verdict': 'pass'}, 'review-1'),
      );
      expect(text, startsWith('PASS'));
      expect(fake.service.actionSink, isNull, reason: 'the sink comes off');

      final run = (await runs.get('run-001'))!;
      expect(run.target.kind, VerificationTargetKind.browser);
      final kinds = run.steps.map((s) => s.kind).toList();
      expect(kinds, contains(VerificationStepKind.navigate));
      // The screenshot the agent took and the closing one.
      expect(
        kinds.where((k) => k == VerificationStepKind.screenshot),
        hasLength(2),
      );
      final shots = run.artifacts.where(
        (a) => a.kind == VerificationArtifactKind.screenshot,
      );
      expect(shots, hasLength(2));
      for (final shot in shots) {
        expect(await runs.readArtifact(shot), isNotEmpty);
      }
      // The pane followed what the run did.
      expect(browser.state.status, BrowserStatus.connected);
    });

    test(
      'an unreachable page keeps the run, finishable, and says why',
      () async {
        await browser.close();
        fake = FakeBrowser(targets: []);
        fake.endpoint.openTabError = Exception('no page will open');
        browser = ServerBrowser(
          database: db,
          dataDirectory: dataDirectory.path,
          tell: data.announce,
          hostEnvironment: const {},
          operatingSystem: 'macos',
          service: fake.service,
        );
        runs = ServerVerificationRuns(
          context,
          newId: () => 'run-x',
          browser: browser,
        );
        tools = VerificationToolSet(runs);
        await expectLater(
          call('verification_start', {'url': 'https://a.test'}),
          throwsA(anything),
        );
        expect(runs.activeRun, isNotNull);
        await call('verification_finish', {'verdict': 'inconclusive'});
        final run = (await runs.get('run-x'))!;
        expect(run.steps.first.summary, 'Could not reach the target');
      },
    );
  });

  group('a device on the server\'s machine (slice 4a)', () {
    late _FakeAdb adb;
    late ServerDeviceClaims claims;
    late ServerDevices devices;
    AndroidSdk? sdk;

    ServerVerificationRuns deviceRuns() => ServerVerificationRuns(
      context,
      newId: () => 'run-${(++ids).toString().padLeft(3, '0')}',
      devices: devices,
    );

    setUp(() {
      adb = _FakeAdb();
      sdk = _sdk;
      claims = ServerDeviceClaims(database: db, tell: data.announce);
      devices = ServerDevices(
        database: db,
        claims: claims,
        runners: FakeCommandRunnerFactory(fallback: adb.runner),
        canRunSimulators: false,
        findSdk: (_) async => sdk,
      );
      runs = deviceRuns();
      tools = VerificationToolSet(runs);
    });
    tearDown(() async {
      claims.close();
      await devices.close();
    });

    const device = {'serial': 'FAKE123', 'package': 'com.example.app'};

    test('a serial starts a run that launches the package as its first '
        'step', () async {
      final text = textOf(await call('verification_start', device));
      expect(text, contains('device_*'));
      expect(text, contains('com.example.app'));
      expect(adb.called('monkey -p com.example.app'), isTrue);
      final run = (await runs.get('run-001'))!;
      expect(run.target.kind, VerificationTargetKind.device);
      expect(run.title, 'Verify com.example.app');
      expect(run.steps.first.kind, VerificationStepKind.launch);
      expect(run.steps.first.summary, contains('com.example.app'));
    });

    test('launch:false verifies what is already on screen', () async {
      await call('verification_start', {...device, 'launch': false});
      expect(adb.called('monkey'), isFalse);
    });

    test('every adb call during the run is a step, and the UI tree a '
        'file', () async {
      await call('verification_start', {...device, 'launch': false});
      final service = (await devices.adb())!;
      await service.tap('FAKE123', 100, 200);
      await service.dumpUiHierarchy('FAKE123');
      await call('verification_note', {
        'text': 'the header is where it should be',
      });
      await call('verification_finish', {'verdict': 'pass'});

      final run = (await runs.get('run-001'))!;
      expect(
        run.steps.map((s) => s.summary),
        containsAll(['Tapped (100, 200)', 'the header is where it should be']),
      );
      final tree = run.artifacts.firstWhere(
        (a) => a.kind == VerificationArtifactKind.uiTree,
      );
      expect(
        File(
          p.join(run.artifactDirectory, tree.relativePath),
        ).readAsStringSync(),
        contains('Settings'),
      );
    });

    test('finishing collects a screenshot, the UI tree and the package\'s '
        'log, then takes the sink off', () async {
      await call('verification_start', device);
      final text = textOf(
        await call('verification_finish', {
          'verdict': 'pass',
          'reason': 'the screen shows Settings',
        }),
      );
      expect(text, startsWith('PASS'));
      final service = (await devices.adb())!;
      expect(service.actionSink, isNull, reason: 'the sink comes off');

      final run = (await runs.get('run-001'))!;
      expect(
        run.artifacts.map((a) => a.kind),
        containsAll([
          VerificationArtifactKind.logcat,
          VerificationArtifactKind.uiTree,
          VerificationArtifactKind.screenshot,
        ]),
      );
      final logcat = run.artifacts.firstWhere(
        (a) => a.kind == VerificationArtifactKind.logcat,
      );
      expect(
        String.fromCharCodes((await runs.readArtifact(logcat))!),
        contains('boom'),
      );
      expect(
        File(p.join(run.artifactDirectory, 'report.md')).readAsStringSync(),
        contains('**Verdict: PASS**'),
      );

      // Nothing is recorded once the run is finished.
      final before = run.steps.length;
      await service.tap('FAKE123', 1, 1);
      expect((await runs.get('run-001'))!.steps, hasLength(before));
    });

    test('an app that was not running says so instead of an empty '
        'file', () async {
      adb.packageRunning = false;
      await call('verification_start', device);
      await call('verification_finish', {'verdict': 'inconclusive'});
      expect(
        (await runs.get('run-001'))!.steps.map((s) => s.summary).join('\n'),
        contains('not running'),
      );
    });

    test('an unknown serial is named, and the run stays finishable', () async {
      await expectLater(
        call('verification_start', {'serial': 'NOT-HERE'}),
        refusal('NOT-HERE'),
      );
      expect(runs.activeRun, isNotNull);
      await call('verification_finish', {'verdict': 'inconclusive'});
      final run = (await runs.get('run-001'))!;
      expect(run.steps.first.summary, 'Could not reach the target');
    });

    test('a package with no launcher activity is reported, not guessed '
        'at', () async {
      adb.packageInstalled = false;
      await expectLater(
        call('verification_start', {'serial': 'FAKE123', 'package': 'x.y'}),
        throwsA(isA<StateError>()),
      );
      final run = (await runs.get(runs.activeRun!.id))!;
      expect(run.steps.last.summary, contains('Could not reach the target'));
    });

    test(
      'no Android SDK on the server\'s machine is refused in words',
      () async {
        sdk = null;
        await expectLater(
          call('verification_start', device),
          refusal('No Android SDK was found on the server\'s machine'),
        );
        expect(runs.activeRun, isNotNull, reason: 'finishable, as a page run');
      },
    );

    test('a second run is refused while the first is recording', () async {
      await call('verification_start', {...device, 'launch': false});
      await expectLater(
        call('verification_start', {...device, 'launch': false}),
        refusal('already recording'),
      );
    });

    group('verification_get of a device run', () {
      Future<String> finishedRun() async {
        await call('verification_start', {
          ...device,
          'title': 'a run with evidence',
        });
        await (await devices.adb())!.screenshot('FAKE123');
        await call('verification_finish', {
          'verdict': 'fail',
          'reason': 'save throws',
        });
        return (await runs.list()).first.id;
      }

      int imagesIn(Object? result) =>
          blocks(result).where((b) => b['type'] == 'image').length;

      test('is compact by default: no images, no file contents', () async {
        final id = await finishedRun();
        final result = await call('verification_get', {'id': id});
        expect(imagesIn(result), 0);
        final text = textOf(result);
        expect(text, contains('FAIL — a run with evidence'));
        expect(text, contains('Steps ('));
        expect(text, contains('Captured ('));
        expect(text, isNot(contains('boom')));
        expect(text, contains('images:true'));
        expect(text, contains('full:true'));
      });

      test('images:true attaches them as image blocks', () async {
        final id = await finishedRun();
        final result = await call('verification_get', {
          'id': id,
          'images': true,
        });
        expect(imagesIn(result), greaterThan(0));
        expect(blocks(result).first['mimeType'], 'image/png');
      });

      test('full:true brings the evidence text with it', () async {
        final id = await finishedRun();
        expect(
          textOf(await call('verification_get', {'id': id, 'full': true})),
          contains('boom'),
        );
      });

      test('with no id it reads the run that is recording now', () async {
        await call('verification_start', {...device, 'title': 'in progress'});
        final text = textOf(await call('verification_get'));
        expect(text, contains('STILL RECORDING'));
        expect(text, contains('in progress'));
      });
    });

    group('the caller is the producer of the verdict', () {
      test('verifying another session names both sides', () async {
        await call('verification_start', {
          ...device,
          'sessionId': 'work-1',
        }, 'review-1');
        final run = runs.activeRun!;
        expect(run.sessionId, 'work-1');
        expect(run.producedBySessionId, 'review-1');
        expect(run.attribution, VerdictAttribution.independent);
      });

      test('an independent pass carries no self-verified warning, and lands '
          'in the subject\'s decision record', () async {
        await call('verification_start', {
          ...device,
          'sessionId': 'work-1',
        }, 'review-1');
        final text = textOf(
          await call('verification_finish', {'verdict': 'pass'}, 'review-1'),
        );
        expect(text, isNot(contains('SELF-VERIFIED')));
        final decision = DecisionRecordDao(db).forSession('work-1').single;
        expect(decision.kind, DecisionKind.verificationVerdict);
        expect(decision.originId, 'run-001');
        expect(DecisionRecordDao(db).forSession('review-1'), isEmpty);
      });

      test('the list column says which runs graded themselves', () async {
        await call('verification_start', device, 'work-1');
        await call('verification_finish', {'verdict': 'pass'}, 'work-1');
        final text = textOf(
          await call('verification_list', const {}, 'work-1'),
        );
        expect(text, contains('verifier'));
        expect(text, contains('self'));
      });
    });
  });
}

const _adbPath = '/sdk/platform-tools/adb';

const _sdk = AndroidSdk(
  root: EnvironmentPath(environmentId: 'localPosix', path: '/sdk'),
  adb: EnvironmentPath(environmentId: 'localPosix', path: _adbPath),
);

/// The UI dump a fake device answers with.
const String _uiXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" '
    'package="com.example.app" content-desc="" bounds="[0,0][1080,2340]">'
    '<node index="0" text="Settings" resource-id="com.example.app:id/title" '
    'class="android.widget.TextView" package="com.example.app" '
    'content-desc="" clickable="true" enabled="true" '
    'bounds="[40,200][600,280]" />'
    '</node></hierarchy>';

/// A 1×1 PNG's first bytes, so a pulled screenshot is an image.
final Uint8List _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

/// A scripted adb on the server's machine: every command a run makes has an
/// answer, and the argv of each is kept. Nothing reaches a real device.
class _FakeAdb {
  _FakeAdb() {
    runner = FakeCommandRunner(
      environmentId: 'localPosix',
      responder: _respond,
    );
  }

  final String serial = 'FAKE123';

  /// Whether `pidof` finds the package.
  bool packageRunning = true;

  /// False makes `monkey` report that the package has no launcher activity.
  bool packageInstalled = true;

  late final FakeCommandRunner runner;

  List<String> get calls => [
    for (final request in runner.requests) request.arguments.join(' '),
  ];

  bool called(String fragment) => calls.any((c) => c.contains(fragment));

  CommandResult _respond(CommandRequest request) {
    final argv = request.arguments.join(' ');
    CommandResult ok(String stdout) =>
        CommandResult(exitCode: 0, stdout: stdout, stderr: '');
    if (argv.contains('devices')) {
      return ok(
        'List of devices attached\n'
        '$serial\tdevice product:test model:Test transport_id:1\n',
      );
    }
    if (argv.contains('monkey')) {
      return ok(
        packageInstalled
            ? 'Events injected: 1\n'
            : '** No activities found to run, monkey aborted.',
      );
    }
    if (argv.contains('wm size')) return ok('Physical size: 1080x2340');
    if (argv.contains('uiautomator dump')) {
      return ok('UI hierchary dumped to: /data/local/tmp/x.xml');
    }
    if (argv.contains('logcat')) {
      return ok(
        '08-30 12:00:00.100  4242  4242 I MainActivity: started\n'
        '08-30 12:00:00.200  4242  4242 E MainActivity: boom\n',
      );
    }
    if (request.arguments.contains('pull')) {
      // `screenshot` is device file → `adb pull` → host file, read back.
      File(request.arguments.last).writeAsBytesSync(_png);
      return ok('');
    }
    // After logcat on purpose: "logcat -d" contains "cat ".
    if (argv.contains('cat ')) return ok(_uiXml);
    if (argv.contains('pidof')) return ok(packageRunning ? '4242' : '');
    return ok('');
  }
}

/// Answers whatever [head] is now, and remembers which directories it read.
class _ScriptedIdentities extends CodeIdentityReader {
  _ScriptedIdentities() : super(_noGit);

  static Future<T> _noGit<T>(
    EnvironmentPath at,
    Future<T> Function(GitService git, EnvironmentPath at) question,
  ) => throw UnimplementedError();

  String head = 'a';
  final reads = <String>[];

  CodeIdentity _now(EnvironmentPath directory) => CodeIdentity(
    environmentId: directory.environmentId,
    path: directory.path,
    head: head.padRight(40, head),
    tree: '',
    dirty: const {},
  );

  @override
  Future<CodeIdentity?> read(EnvironmentPath directory) async {
    reads.add(directory.path);
    return _now(directory);
  }

  @override
  Future<CodeFreshness> freshnessOf(CodeIdentity? recorded) async =>
      compareCodeIdentity(
        recorded,
        recorded == null
            ? null
            : _now(
                EnvironmentPath(
                  environmentId: recorded.environmentId,
                  path: recorded.path,
                ),
              ),
      );
}
