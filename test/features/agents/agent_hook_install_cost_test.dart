import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/features/agents/application/agent_hook_installation_service.dart';
import 'package:karmashala/src/features/agents/application/agent_status_providers.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/environments/application/local_environment_bootstrap.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';
import '../../support/temp_directory.dart';
import 'package:agent_cli/read.dart';

/// What installing the agents' status hooks costs the **isolate**, and what it
/// costs a store home that does not answer.
///
/// Measured on the owner's machine in profile mode on 2026-09-04, from the
/// app's own log:
///
/// ```txt
/// 17:15:29.946  MCP also on 172.18.240.1:47821, for WSL sessions
/// 17:15:30.999  Agent hooks: 6 installed, 0 skipped, 3 reporting by spool
/// ```
///
/// **1053 ms of a 1.91 s launch — 55% of it** — while the Dart isolate was at
/// ~4% of one core. It was not computation; it was `existsSync`,
/// `readAsStringSync` and `deleteSync` against six store homes, three of them
/// `\\wsl.localhost` UNC paths served by a plan9 daemon *inside* a
/// distribution. A synchronous Dart file operation has no timeout, so that wait
/// was the distribution's to set and the isolate's to serve — on the thread the
/// window is painted on, and the thread a native file dialog runs its modal
/// loop on (`karmashala_ui's picking.dart`: a picker created while the isolate is
/// busy is created and never shown, and the window goes Not Responding).
///
/// So this file asserts **counts**, never milliseconds:
///
///  * how many file operations one install performs, and that none of them is
///    synchronous;
///  * that the per-store work happens at once rather than in series;
///  * that a store home which never answers becomes one `unknown` row rather
///    than a sweep that never returns.
void main() {
  const endpoint = AgentHookEndpoint(port: 4242, token: 'tok');
  final claude = AgentRegistry.builtIn.byId('claudeCode')!;

  group('nothing on the install path holds the isolate', () {
    late Directory home;
    setUp(() {
      home = Directory.systemTemp.createTempSync('karmashala_hookcost_');
    });
    tearDown(() => removeTempDirectory(home));

    // The real `restrict` shells out to `icacls`/`chmod`. Faked so the count is
    // about file operations and nothing else — and faked as *granted*: where
    // this host can harden `localPosix` (macOS, Linux) a refusal is fatal and
    // the install stops before the operations being counted. On Windows the two
    // answers walk the same file operations, so the counts do not move.
    final installer = AgentHookInstaller(restrict: (_, _) async => true);

    Future<bool> install() => installer.install(
      descriptor: claude,
      storeHome: home.path,
      endpoint: endpoint,
      environment: EnvironmentKind.localPosix,
    );

    test('a first install is entirely asynchronous', () async {
      final io = _CountingIO();
      final installed = await io.run(install);

      expect(installed, isTrue, reason: 'the read-back still has to pass');
      expect(
        io.sync,
        isEmpty,
        reason:
            'every one of these is an unbounded wait on the UI isolate when '
            'the store home is a WSL share',
      );
      // The operations themselves, so a change that doubles them is visible.
      // Three files are written — the callback script, the endpoint file and
      // the config entry — and each one clears any staging file a killed quit
      // left, is staged, is renamed, has its own staging file removed and is
      // read back. 22 before that first clear, which the 2026-09-09 soak added
      // after finding `.karmashala-tmp` files accumulating in the store homes;
      // 25 before the config rewrite began stat-ing before its read and its
      // rename so a CLI save in between is re-spliced instead of overwritten.
      expect(io.async, hasLength(27));
      expect(
        io.async.where((op) => op.startsWith('File.readAsString')).length,
        3,
        reason:
            'the read-back of each of the two generated files, and the '
            'read-back of the config by `installedEvents` — the verification '
            'the 2026-09-01 incident put here, still reading disk. The two '
            '`_readConfigObject` calls do not appear because this config did '
            'not exist yet and an absent file reads as `{}`',
      );
    });

    test('the launch after it writes nothing and still reads back', () async {
      // The usual case, and the one that runs on every launch after the first:
      // the entry and the script are constants, and for `localPosix` so is the
      // endpoint file's `url=`/`token=` body for a given endpoint. Everything
      // is already byte-identical, so this is the shape of the cost the owner
      // actually pays six times a launch.
      expect(await install(), isTrue);

      final io = _CountingIO();
      expect(await io.run(install), isTrue);

      expect(io.sync, isEmpty);
      expect(
        io.async.where((op) => op.startsWith('File.writeAsString')),
        isEmpty,
        reason: 'a rewrite that changes nothing is still a write to somebody '
            'else\'s config',
      );
      // Nine, plus the one stat the config rewrite takes before its read; a
      // splice that changes nothing never reaches the stat before the rename.
      expect(io.async, hasLength(10));
    });

    test('uninstall and endpoint retirement are asynchronous too', () async {
      // `retireEndpoints` is what runs on the way *out*, inside a 150 ms
      // shutdown step — and a synchronous delete on a share could not be cut
      // off by that cap, because the cap can only stop an await.
      expect(await install(), isTrue);

      final retire = _CountingIO();
      expect(
        await retire.run(
          () => installer.retireEndpoint(descriptor: claude, storeHome: home.path),
        ),
        isTrue,
      );
      expect(retire.sync, isEmpty);

      final uninstall = _CountingIO();
      expect(
        await uninstall.run(
          () => installer.uninstall(descriptor: claude, storeHome: home.path),
        ),
        isTrue,
      );
      expect(uninstall.sync, isEmpty);
    });

    test('so is the "is this agent even here" question', () async {
      // Asked once per (agent, store home) by the service, and on a machine
      // where the agent is absent it is the *only* thing asked — so a
      // synchronous answer here was an unbounded wait bought for nothing.
      final io = _CountingIO();
      expect(await io.run(() => installer.storeIsPresent(home.path)), isTrue);
      expect(io.sync, isEmpty);
      expect(io.async, ['Directory.exists']);
    });
  });

  group('the sweep across environments', () {
    late AppDatabase db;
    late Directory root;

    setUp(() {
      db = AppDatabase.memory();
      ensureLocalEnvironment(ExecutionEnvironmentDao(db), FixedClock(testTime));
      root = Directory.systemTemp.createTempSync('karmashala_hooksweep_');
    });
    tearDown(() {
      db.close();
      removeTempDirectory(root);
    });

    /// Four store homes across two environments, and a service that installs
    /// through [installer] instead of touching anybody's real `~/.claude`.
    AgentHookInstallationService serviceWith(
      AgentHookInstaller installer, {
      Duration? storeBudget,
      int stores = 2,
    }) {
      final wsl = wslEnv();
      ExecutionEnvironmentDao(db).upsert(wsl);
      final local = ExecutionEnvironmentDao(
        db,
      ).getAll().firstWhere((e) => isLocalHost(e.kind)).id;
      final ids = [local, wsl.id].take(stores).toList();
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          cliStoreLocatorProvider.overrideWith(
            (ref) => _StubLocator([
              for (final id in ids)
                CliStore(
                  environmentId: id,
                  homesByAgentId: {
                    for (final descriptor in AgentRegistry.builtIn.descriptors)
                      if (descriptor.hooks != null)
                        descriptor.id: p.join(root.path, id, descriptor.id),
                  },
                ),
            ]),
          ),
          agentHookInstallerProvider.overrideWithValue(installer),
          agentHookInstallationServiceProvider.overrideWith(
            (ref) =>
                AgentHookInstallationService(ref, storeBudget: storeBudget),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container.read(agentHookInstallationServiceProvider);
    }

    test('every store home is swept at once, not one after another', () async {
      // Three hook-capable agents in each of two environments. In series the
      // most that is ever in flight is one, and one slow `\\wsl.localhost`
      // store home is the whole sweep's cost; concurrently it is its own.
      final installer = _ConcurrencyProbe();
      final results = await serviceWith(installer).installAll(endpoint);

      expect(results, hasLength(6));
      expect(installer.started, 6);
      expect(
        installer.peakInFlight,
        6,
        reason: 'serial execution can never have more than one in flight',
      );
    });

    test('a store home that never answers is one unknown row', () async {
      // The share is reachable for one agent and hung for the others. Before
      // the bound this sweep produced nothing at all — no report, no
      // "Agent hooks:" line, and no spool being drained for the whole run.
      final installer = _HangingInstaller(answersFor: 'claudeCode');
      final results = await serviceWith(
        installer,
        storeBudget: const Duration(milliseconds: 20),
        stores: 1,
      ).installAll(endpoint);

      expect(results, hasLength(3));
      final report = AgentHookInstallationReport(results);
      expect(report.installed, 1);
      expect(report.unknown, 2);

      final answered = results.singleWhere((r) => r.agentId == 'claudeCode');
      expect(answered.installed, isTrue);
      expect(answered.unknown, isFalse);

      for (final hung in results.where((r) => r.agentId != 'claudeCode')) {
        expect(hung.installed, isFalse);
        expect(
          hung.unknown,
          isTrue,
          reason: 'a false "not installed" sends someone looking for a config '
              'bug that may not be there',
        );
        expect(hung.skippedBecause, contains('unknown'));
        expect(
          hung.skippedBecause,
          contains('20 ms'),
          reason: 'a sub-second budget must not be reported as "within 0s"',
        );
        expect(
          hung.spoolDirectory,
          isNull,
          reason: 'nothing may be polled on the strength of a guess',
        );
      }
      // And the un-answered rows are kept out of the skipped list, which is
      // what the Tools panel words as a failure.
      expect(report.skippedByEnvironment, isEmpty);
      expect(report.unknownByEnvironment, hasLength(1));
    });
  });

  test('an un-swept report is not an empty one', () {
    // §19: an unobserved state is `unknown`, never `healthy`. The sweep runs
    // after the first frame now, so there is a real moment in every launch
    // when the honest answer is "not yet" — and `AgentHookInstallationReport`
    // has to be able to say it, or the Tools panel's silence would.
    expect(AgentHookInstallationReport.unswept.swept, isFalse);
    expect(AgentHookInstallationReport.none.swept, isTrue);
    expect(AgentHookInstallationReport.unswept.results, isEmpty);
    expect(AgentHookInstallationReport.none.results, isEmpty);
  });
}

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

/// How many installs are in flight at once.
///
/// Each one yields twice before answering, which is what makes the difference
/// between serial and concurrent observable as a **count** rather than as
/// elapsed time: in series `peakInFlight` can only ever reach one, however long
/// each call takes.
class _ConcurrencyProbe extends AgentHookInstaller {
  int started = 0;
  int _inFlight = 0;
  int peakInFlight = 0;

  @override
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) async {
    started++;
    _inFlight++;
    if (_inFlight > peakInFlight) peakInFlight = _inFlight;
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _inFlight--;
    return true;
  }

  @override
  Future<bool> storeIsPresent(String storeHome) async => true;
}

/// A share that answers for one agent and never for the rest.
class _HangingInstaller extends AgentHookInstaller {
  _HangingInstaller({required this.answersFor});

  final String answersFor;

  @override
  Future<bool> install({
    required AgentDescriptor descriptor,
    required String storeHome,
    required AgentHookEndpoint endpoint,
    required EnvironmentKind environment,
  }) => descriptor.id == answersFor
      ? Future.value(true)
      : Completer<bool>().future;

  @override
  Future<bool> storeIsPresent(String storeHome) async => true;
}

/// Every `File` and `Directory` operation a body performs, sorted into the ones
/// that can be waited on and the ones that cannot.
///
/// [IOOverrides.createFile] and `createDirectory` are the single funnel every
/// `File(path)` and `Directory(path)` goes through, so nothing the installer
/// touches can escape the count — the same instrument
/// `cli_detection/subagent_transcript_cost_test.dart` uses for a different
/// question.
final class _CountingIO extends IOOverrides {
  final sync = <String>[];
  final async = <String>[];

  Future<T> run<T>(Future<T> Function() body) =>
      IOOverrides.runWithIOOverrides(body, this);

  void record(String op) => op.endsWith('Sync') ? sync.add(op) : async.add(op);

  @override
  File createFile(String path) => _CountingFile(super.createFile(path), this);

  @override
  Directory createDirectory(String path) =>
      _CountingDirectory(super.createDirectory(path), this);

  @override
  FileStat statSync(String path) {
    record('statSync');
    return super.statSync(path);
  }

  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) {
    record('fseGetTypeSync');
    return super.fseGetTypeSync(path, followLinks);
  }
}

/// A `File` that reports what was asked of it and then does it.
///
/// Only the members this feature uses are implemented; anything else lands in
/// [noSuchMethod] and throws, so a new operation on the install path cannot be
/// added without this test noticing.
class _CountingFile implements File {
  _CountingFile(this._inner, this._io);

  final File _inner;
  final _CountingIO _io;

  @override
  String get path => _inner.path;

  @override
  Directory get parent => _inner.parent;

  @override
  bool existsSync() {
    _io.record('File.existsSync');
    return _inner.existsSync();
  }

  @override
  Future<FileStat> stat() {
    _io.record('File.stat');
    return _inner.stat();
  }

  @override
  Future<bool> exists() {
    _io.record('File.exists');
    return _inner.exists();
  }

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    _io.record('File.readAsStringSync');
    return _inner.readAsStringSync(encoding: encoding);
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    _io.record('File.readAsString');
    return _inner.readAsString(encoding: encoding);
  }

  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _io.record('File.writeAsStringSync');
    _inner.writeAsStringSync(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    _io.record('File.writeAsString');
    return _inner.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  void deleteSync({bool recursive = false}) {
    _io.record('File.deleteSync');
    _inner.deleteSync(recursive: recursive);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) {
    _io.record('File.delete');
    return _inner.delete(recursive: recursive);
  }

  @override
  void createSync({bool recursive = false, bool exclusive = false}) {
    _io.record('File.createSync');
    _inner.createSync(recursive: recursive, exclusive: exclusive);
  }

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) {
    _io.record('File.create');
    return _inner.create(recursive: recursive, exclusive: exclusive);
  }

  @override
  File renameSync(String newPath) {
    _io.record('File.renameSync');
    return _inner.renameSync(newPath);
  }

  @override
  Future<File> rename(String newPath) {
    _io.record('File.rename');
    return _inner.rename(newPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _io.record('File.${_nameOf(invocation)}');
    return super.noSuchMethod(invocation);
  }
}

/// The `Directory` counterpart. See [_CountingFile].
class _CountingDirectory implements Directory {
  _CountingDirectory(this._inner, this._io);

  final Directory _inner;
  final _CountingIO _io;

  @override
  String get path => _inner.path;

  @override
  Directory get parent => _inner.parent;

  @override
  bool existsSync() {
    _io.record('Directory.existsSync');
    return _inner.existsSync();
  }

  @override
  Future<bool> exists() {
    _io.record('Directory.exists');
    return _inner.exists();
  }

  @override
  void createSync({bool recursive = false}) {
    _io.record('Directory.createSync');
    _inner.createSync(recursive: recursive);
  }

  @override
  Future<Directory> create({bool recursive = false}) {
    _io.record('Directory.create');
    return _inner.create(recursive: recursive);
  }

  @override
  void deleteSync({bool recursive = false}) {
    _io.record('Directory.deleteSync');
    _inner.deleteSync(recursive: recursive);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) {
    _io.record('Directory.delete');
    return _inner.delete(recursive: recursive);
  }

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    _io.record('Directory.listSync');
    return _inner.listSync(recursive: recursive, followLinks: followLinks);
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) {
    _io.record('Directory.list');
    return _inner.list(recursive: recursive, followLinks: followLinks);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _io.record('Directory.${_nameOf(invocation)}');
    return super.noSuchMethod(invocation);
  }
}

/// `Symbol("existsSync")` → `existsSync`, so an unimplemented member is still
/// classified by the one rule that matters: whether its name ends in `Sync`.
String _nameOf(Invocation invocation) {
  final raw = invocation.memberName.toString();
  final open = raw.indexOf('"');
  final close = raw.lastIndexOf('"');
  return open < 0 || close <= open ? raw : raw.substring(open + 1, close);
}
