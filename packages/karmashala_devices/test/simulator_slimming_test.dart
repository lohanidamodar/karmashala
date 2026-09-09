import 'package:test/test.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/src/data/simulator_slimming_service.dart';
import 'package:karmashala_devices/src/domain/simulator_slimming.dart';

import './support/fake_command_runner.dart';

const _udid = '70592006-11CD-44A3-96BC-25EE8E72CA3D';
const _directory = '/private/var/tmp/com.apple.CoreSimulator.SimDevice.$_udid';
const _plist = '$_directory/disabled.plist';

/// Labels that must never appear in the table.
///
/// The first four were disabled by hand on a real device to see what happened:
/// the simulator came up a zombie that `simctl list` still called **Booted**,
/// `bootstatus -b` hung forever, `launch` failed with
/// `FBSOpenApplicationServiceErrorDomain code=5` and `io screenshot` timed out.
/// The rest were observed to be load-bearing for the simulator, for preferences
/// or for Xcode's own tooling.
const _neverDisable = [
  'com.apple.SpringBoard',
  'com.apple.backboardd',
  'com.apple.runningboardd',
  'com.apple.mobile.installd',
  'com.apple.CoreSimulator.bridge',
  'com.apple.lsd',
  'com.apple.pasteboard.pasted',
  'com.apple.containermanagerd',
  'com.apple.cfprefsd.xpc.daemon',
  'com.apple.distnoted.xpc.daemon',
  'com.apple.mobilegestalt.xpc',
  'com.apple.securityd',
  'com.apple.trustd',
  'com.apple.syslogd',
  'com.apple.logd_reporter',
  'com.apple.nsurlsessiond',
  'com.apple.dasd',
  'com.apple.UIKit.KeyboardManagement',
  'com.apple.dt.previewsd',
  'com.apple.dt.ViewHierarchyAgent',
  'com.apple.dt.AutomationModeUI',
  'com.apple.dt.automationmode-writer',
  'com.apple.sharingd',
];

/// Labels listed by two categories on purpose.
const _shared = [
  'com.apple.amsaccountsd',
  'com.apple.amsengagementd',
  'com.apple.amsondevicestoraged',
  'com.apple.passd',
  'com.apple.financed',
];

/// A device that has been booted once writes entries of its own into this
/// file. Seventeen of them, all explicit `false`, all launchd's business and
/// none of ours — this is the shape a read-modify-write has to survive.
const _launchdEntries = <String, bool>{
  'com.apple.NPKCompanionAgent': false,
  'com.apple.addressbooksyncd': false,
  'com.apple.appconduitd': false,
  'com.apple.brook.brookcompaniond': false,
  'com.apple.bulletindistributord': false,
  'com.apple.companionappd': false,
  'com.apple.companionfindlocallyd': false,
  'com.apple.companionmessagesd': false,
  'com.apple.eventkitsyncd': false,
  'com.apple.nanoappregistryd': false,
  'com.apple.nanomapscd': false,
  'com.apple.nanonewscd': false,
  'com.apple.nanosystemsettingsd': false,
  'com.apple.pairedsyncd': false,
  'com.apple.pairedunlockd': false,
  'com.apple.schooltimed': false,
  'com.apple.security.otpaird': false,
};

String _devicesJson(String state) =>
    '''
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      {
        "udid" : "$_udid",
        "isAvailable" : true,
        "deviceTypeIdentifier" : "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
        "state" : "$state",
        "name" : "iPhone 17"
      }
    ]
  }
}
''';

/// An in-memory [SlimmingFileStore]. Nothing in this file may reach
/// `/private/var/tmp`: a stray write there edits one of the developer's real
/// simulators, and the damage only shows up the next time they boot it.
class _FakeFileStore implements SlimmingFileStore {
  _FakeFileStore([Map<String, String>? seed]) : files = {...?seed};

  final Map<String, String> files;
  final List<String> operations = [];

  /// If set, [writeAsString] throws it.
  Object? writeError;

  @override
  Future<String?> readAsString(String path) async {
    operations.add('read $path');
    return files[path];
  }

  @override
  Future<void> writeAsString(String path, String contents) async {
    operations.add('write $path');
    if (writeError != null) throw writeError!;
    files[path] = contents;
  }

  @override
  Future<void> rename(String from, String to) async {
    operations.add('rename $from -> $to');
    final contents = files.remove(from);
    if (contents == null) throw StateError('no such file: $from');
    files[to] = contents;
  }

  @override
  Future<void> delete(String path) async {
    operations.add('delete $path');
    files.remove(path);
  }
}

/// A distinguishable failure, for the temporary-file cleanup test.
class _WriteFailed implements Exception {
  const _WriteFailed();
}

/// A runner that answers `simctl list` with [state], and reports `Shutdown`
/// after [pollsBeforeDown] further polls once `simctl shutdown` is issued.
FakeCommandRunner _simctl({
  String state = 'Shutdown',
  int pollsBeforeDown = 1,
  bool shutdownFails = false,
  bool bootFails = false,
}) {
  var current = state;
  var remaining = -1;
  return FakeCommandRunner(
    environmentId: 'macos',
    responder: (request) {
      if (request.executable != 'xcrun') {
        return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      }
      switch (request.arguments[1]) {
        case 'list':
          if (remaining > 0 && --remaining == 0) current = 'Shutdown';
          return CommandResult(
            exitCode: 0,
            stdout: _devicesJson(current),
            stderr: '',
          );
        case 'shutdown':
          remaining = pollsBeforeDown;
          return CommandResult(
            exitCode: shutdownFails ? 1 : 0,
            stdout: '',
            stderr: shutdownFails ? 'Unable to shutdown device' : '',
          );
        case 'boot':
          return CommandResult(
            exitCode: bootFails ? 1 : 0,
            stdout: '',
            stderr: bootFails ? 'Unable to boot device in current state' : '',
          );
        default:
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
      }
    },
  );
}

SimulatorSlimmingService _service(
  FakeCommandRunner runner,
  _FakeFileStore files, {
  Duration timeout = const Duration(seconds: 30),
}) => SimulatorSlimmingService(
  runner: runner,
  files: files,
  shutdownTimeout: timeout,
  pollInterval: const Duration(milliseconds: 1),
);

/// The `simctl` subcommands issued, in order. Ignores `mkdir`/`chmod`.
List<String> _simctlVerbs(FakeCommandRunner runner) => [
  for (final request in runner.requests)
    if (request.executable == 'xcrun') request.arguments[1],
];

void main() {
  group('the category table', () {
    test('holds 170 distinct labels across 175 entries', () {
      final entries = SlimmingCategory.values.fold<int>(
        0,
        (total, category) => total + category.labels.length,
      );

      expect(allManagedLabels, hasLength(170));
      // The five deliberate duplicates account for the difference. A sixth
      // would mean somebody added a label to a second category without
      // thinking about the any-excepted-category rule.
      expect(entries, 175);
    });

    test('every label is a fully qualified com.apple. launchd label', () {
      for (final label in allManagedLabels) {
        expect(label, startsWith('com.apple.'), reason: label);
        expect(label.length, greaterThan('com.apple.'.length), reason: label);
        expect(label.trim(), label, reason: label);
        expect(label.contains(' '), isFalse, reason: label);
      }
    });

    test('names exactly the five labels that live in two categories', () {
      for (final label in allManagedLabels) {
        expect(
          categoriesFor(label),
          hasLength(_shared.contains(label) ? 2 : 1),
          reason: label,
        );
      }
      for (final label in _shared) {
        expect(allManagedLabels, contains(label));
      }
    });

    test('cannot reach a label that bricks the device', () {
      // The allowlist bounds this already, but the table is what the allowlist
      // *is* — a bad entry here is the one way a fatal label becomes writable.
      for (final label in _neverDisable) {
        expect(allManagedLabels, isNot(contains(label)), reason: label);
      }
    });

    test('has stable, unique ids that byId round-trips', () {
      final ids = SlimmingCategory.values.map((c) => c.id).toList();

      expect(ids.toSet(), hasLength(SlimmingCategory.values.length));
      for (final category in SlimmingCategory.values) {
        expect(SlimmingCategory.byId(category.id), category);
        expect(category.labels, isNotEmpty);
        expect(category.approxSavingMb, greaterThan(0));
        expect(category.displayName, isNotEmpty);
        expect(category.description, isNotEmpty);
      }
      expect(SlimmingCategory.byId('nope'), isNull);
    });

    test('only ever attributes feature loss to labels it manages', () {
      for (final category in SlimmingCategory.values) {
        for (final label in category.featureLoss.keys) {
          expect(category.labels, contains(label), reason: label);
        }
      }
    });
  });

  group('desiredDisabled', () {
    test('disables everything managed by default', () {
      expect(desiredDisabled(), allManagedLabels);
    });

    test('spares an excepted category', () {
      final disabled = desiredDisabled(except: {SlimmingCategory.widgets});

      expect(disabled, isNot(contains('com.apple.chronod')));
      expect(disabled, contains('com.apple.siriknowledged'));
      expect(
        disabled.length,
        allManagedLabels.length - SlimmingCategory.widgets.labels.length,
      );
    });

    test('keeps a shared label enabled when ANY excepted category lists it', () {
      // `passd` and `financed` are also listed by `other`, and the AMS trio by
      // `icloud`. Sparing "store" has to actually leave StoreKit working: if
      // the other category were still free to disable them, the checkbox the
      // user ticked would be a lie.
      final disabled = desiredDisabled(except: {SlimmingCategory.store});

      for (final label in _shared) {
        expect(disabled, isNot(contains(label)), reason: label);
      }
      expect(disabled, isNot(contains('com.apple.apsd')));
      // The rest of `other` and `icloud` still go.
      expect(disabled, contains('com.apple.merchantd'));
      expect(disabled, contains('com.apple.cloudd'));
    });

    test('keep spares individual labels regardless of category', () {
      final disabled = desiredDisabled(keep: {'com.apple.apsd'});

      expect(disabled, isNot(contains('com.apple.apsd')));
      expect(disabled, contains('com.apple.storekitd'));
      expect(disabled.length, allManagedLabels.length - 1);
    });

    test('never names a label outside the allowlist', () {
      expect(
        desiredDisabled(
          keep: {'com.apple.SpringBoard'},
        ).difference(allManagedLabels),
        isEmpty,
      );
      expect(desiredDisabled(except: SlimmingCategory.values.toSet()), isEmpty);
    });
  });

  group('featureLossFor', () {
    test('warns about the consequences a developer will actually hit', () {
      final warnings = featureLossFor();

      expect(warnings.keys, contains('com.apple.apsd'));
      expect(warnings.keys, contains('com.apple.storekitd'));
      expect(warnings.keys, contains('com.apple.swcd'));
      expect(warnings.keys, contains('com.apple.assetsd'));
      expect(warnings.keys, contains('com.apple.photoanalysisd'));
      expect(warnings.keys, contains('com.apple.contactsd'));
      expect(warnings.keys, contains('com.apple.calaccessd'));
      expect(warnings.keys, contains('com.apple.searchd'));
      for (final warning in warnings.values) {
        expect(warning, isNotEmpty);
      }
    });

    test('drops the warnings for a category that is being spared', () {
      final warnings = featureLossFor(except: {SlimmingCategory.photos});

      expect(warnings.keys, isNot(contains('com.apple.assetsd')));
      expect(warnings.keys, contains('com.apple.apsd'));
    });
  });

  group('applyDelta', () {
    test('disables what was asked for and leaves foreign keys alone', () {
      final next = applyDelta(_launchdEntries, desiredDisabled());

      for (final entry in _launchdEntries.entries) {
        expect(next[entry.key], entry.value, reason: entry.key);
      }
      for (final label in allManagedLabels) {
        expect(next[label], isTrue, reason: label);
      }
      expect(next, hasLength(_launchdEntries.length + 170));
    });

    test('ignores anything outside the allowlist — including fatal labels', () {
      // The allowlist is the safety mechanism: a typo, a stale saved category
      // id, or a caller that built its own set cannot reach SpringBoard.
      final next = applyDelta(const {}, {
        'com.apple.SpringBoard',
        'com.apple.runningboardd',
        'com.apple.chronod',
        'com.apple.not-a-real-daemon',
      });

      expect(next, {'com.apple.chronod': true});
    });

    test('removes only the managed keys it had disabled', () {
      final slimmed = applyDelta(_launchdEntries, desiredDisabled());

      final restored = applyDelta(slimmed, const {});

      // Exactly what launchd had before anyone touched it. This is the
      // recovery path, and the reason `simctl erase` is not needed.
      expect(restored, _launchdEntries);
    });

    test('leaves a managed label that is explicitly enabled as found', () {
      // launchd writes `false` entries of its own, and some are for labels
      // this table also owns. "Enabled" is already what that says, so
      // rewriting it would be churn in a file another process manages.
      const existing = {'com.apple.chronod': false, 'com.apple.searchd': false};

      final next = applyDelta(existing, {'com.apple.searchd'});

      expect(next, {'com.apple.chronod': false, 'com.apple.searchd': true});
    });

    test('does not mutate the map it was given', () {
      final existing = <String, bool>{..._launchdEntries};

      applyDelta(existing, desiredDisabled());

      expect(existing, _launchdEntries);
    });
  });

  group('the plist codec', () {
    test('round-trips a device that launchd has already written to', () {
      final entries = applyDelta(_launchdEntries, desiredDisabled());

      expect(parseDisabledPlist(encodeDisabledPlist(entries)), entries);
    });

    test('reads the real file shape', () {
      final xml = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        '<dict>',
        '\t<key>com.apple.chronod</key>',
        '\t<true/>',
        '\t<key>com.apple.pairedsyncd</key>',
        '\t<false/>',
        '</dict>',
        '</plist>',
      ].join('\n');

      expect(parseDisabledPlist(xml), {
        'com.apple.chronod': true,
        'com.apple.pairedsyncd': false,
      });
    });

    test('treats an empty dictionary as empty, not as unreadable', () {
      expect(
        parseDisabledPlist('<plist version="1.0">\n<dict/>\n</plist>'),
        isEmpty,
      );
      expect(
        parseDisabledPlist('<plist version="1.0">\n<dict>\n</dict>\n</plist>'),
        isEmpty,
      );
    });

    test('refuses a document it cannot round-trip', () {
      // Null means "refuse to touch it", never "empty" — rewriting a file this
      // parser did not understand would silently drop launchd's own entries.
      expect(parseDisabledPlist(''), isNull);
      expect(parseDisabledPlist('bplist00 rubbish'), isNull);
      expect(
        parseDisabledPlist('<dict><key>a</key><string>b</string></dict>'),
        isNull,
      );
      expect(
        parseDisabledPlist(
          '<dict><key>a</key><dict><key>b</key><true/></dict></dict>',
        ),
        isNull,
      );
      expect(parseDisabledPlist('<dict><true/></dict>'), isNull);
      expect(parseDisabledPlist('<dict><key>a</key></dict>'), isNull);
    });

    test('sorts keys so an unchanged selection produces an unchanged file', () {
      final xml = encodeDisabledPlist({
        'com.apple.zzz': true,
        'com.apple.aaa': false,
      });

      expect(
        xml.indexOf('com.apple.aaa'),
        lessThan(xml.indexOf('com.apple.zzz')),
      );
      expect(
        xml,
        encodeDisabledPlist({'com.apple.aaa': false, 'com.apple.zzz': true}),
      );
    });

    test('escapes markup in a key', () {
      expect(parseDisabledPlist(encodeDisabledPlist({'a&<b>': true})), {
        'a&<b>': true,
      });
    });
  });

  group('SimulatorSlimmingService.status', () {
    test('reports a stock device with no plist at all', () async {
      final files = _FakeFileStore();

      final status = await _service(_simctl(), files).status(_udid);

      expect(status.exists, isFalse);
      expect(status.readable, isTrue);
      expect(status.isSlimmed, isFalse);
      expect(status.disabled, isEmpty);
      expect(status.plistPath, _plist);
    });

    test('needs no simctl call, so it answers for a shut-down device', () async {
      final runner = _simctl();
      final files = _FakeFileStore({
        _plist: encodeDisabledPlist(
          applyDelta(_launchdEntries, desiredDisabled()),
        ),
      });

      final status = await _service(runner, files).status(_udid);

      expect(runner.requests, isEmpty);
      expect(status.isSlimmed, isTrue);
      expect(status.disabledManaged, hasLength(170));
      expect(status.disabledUnmanaged, isEmpty);
      expect(status.fullyDisabledCategories, SlimmingCategory.values.toSet());
      expect(status.partlyDisabledCategories, isEmpty);
      expect(status.featureLoss.keys, contains('com.apple.apsd'));
    });

    test('separates labels somebody else disabled from ours', () async {
      final files = _FakeFileStore({
        _plist: encodeDisabledPlist({
          'com.apple.chronod': true,
          'com.apple.some.future.daemon': true,
          ..._launchdEntries,
        }),
      });

      final status = await _service(_simctl(), files).status(_udid);

      expect(status.disabledManaged, {'com.apple.chronod'});
      expect(status.disabledUnmanaged, {'com.apple.some.future.daemon'});
      expect(status.partlyDisabledCategories, {SlimmingCategory.widgets});
      expect(status.fullyDisabledCategories, isEmpty);
    });

    test('flags a plist it cannot parse instead of guessing', () async {
      final files = _FakeFileStore({_plist: 'bplist00 not xml'});

      final status = await _service(_simctl(), files).status(_udid);

      expect(status.exists, isTrue);
      expect(status.readable, isFalse);
      expect(status.entries, isNull);
    });

    test('uses the upper-case UDID CoreSimulator names the directory with', () async {
      final files = _FakeFileStore({
        _plist: encodeDisabledPlist({'com.apple.chronod': true}),
      });

      final status = await _service(
        _simctl(),
        files,
      ).status(_udid.toLowerCase());

      // A lower-case udid is accepted by simctl on the command line, so a
      // caller can easily be holding one; reading the wrong path would report
      // every device as un-slimmed.
      expect(status.plistPath, _plist);
      expect(status.isSlimmed, isTrue);
    });
  });

  group('SimulatorSlimmingService.slim', () {
    test('writes to a temporary file and renames it into place', () async {
      final runner = _simctl();
      final files = _FakeFileStore();

      await _service(runner, files).slim(_udid);

      expect(files.operations, [
        'read $_plist',
        'write $_plist.tmp',
        'rename $_plist.tmp -> $_plist',
      ]);
      final written = parseDisabledPlist(files.files[_plist]!)!;
      expect(written.keys.toSet(), allManagedLabels);
      expect(written.values.every((disabled) => disabled), isTrue);
    });

    test('creates the directory 0700 before writing into it', () async {
      // A device that has never been booted has no directory at all, so this
      // is the common case. chmod is a process because Dart has no chmod.
      final runner = _simctl();

      await _service(runner, _FakeFileStore()).slim(_udid);

      final mkdir = runner.requests.firstWhere(
        (request) => request.executable == '/bin/mkdir',
      );
      final chmod = runner.requests.firstWhere(
        (request) => request.executable == '/bin/chmod',
      );
      expect(mkdir.arguments, ['-p', _directory]);
      expect(chmod.arguments, ['0700', _directory]);
    });

    test('shuts a booted device down first, then boots it again', () async {
      // launchd holds the disabled set in memory while it is up, so an edit
      // underneath it is racy — it may be serialised away or half-applied.
      final runner = _simctl(state: 'Booted', pollsBeforeDown: 2);
      final files = _FakeFileStore();

      await _service(runner, files).slim(_udid);

      expect(_simctlVerbs(runner), [
        'list', // Booted
        'shutdown',
        'list', // still Booted
        'list', // Shutdown
        'boot',
      ]);
      expect(files.files[_plist], isNotNull);
    });

    test('does not shut down a device that is already down', () async {
      final runner = _simctl();

      await _service(runner, _FakeFileStore()).slim(_udid);

      expect(_simctlVerbs(runner), ['list', 'boot']);
    });

    test('leaves the device down when the caller says not to boot', () async {
      final runner = _simctl();

      await _service(runner, _FakeFileStore()).slim(_udid, boot: false);

      expect(_simctlVerbs(runner), isNot(contains('boot')));
    });

    test('honours except and keep all the way to the file', () async {
      final files = _FakeFileStore();

      await _service(_simctl(), files).slim(
        _udid,
        except: {SlimmingCategory.store},
        keep: {'com.apple.chronod'},
      );

      final written = parseDisabledPlist(files.files[_plist]!)!;
      expect(written.keys, isNot(contains('com.apple.chronod')));
      expect(written.keys, isNot(contains('com.apple.storekitd')));
      // Shared with `other`, but spared because `store` was excepted.
      expect(written.keys, isNot(contains('com.apple.passd')));
      expect(written.keys, contains('com.apple.liveactivitiesd'));
    });

    test('merges into launchd own entries rather than replacing them', () async {
      final files = _FakeFileStore({
        _plist: encodeDisabledPlist(_launchdEntries),
      });

      await _service(_simctl(), files).slim(_udid);

      final written = parseDisabledPlist(files.files[_plist]!)!;
      for (final entry in _launchdEntries.entries) {
        expect(written[entry.key], entry.value, reason: entry.key);
      }
    });

    test('never writes a label outside the allowlist', () async {
      final files = _FakeFileStore();

      await _service(_simctl(), files).slim(_udid);

      final written = parseDisabledPlist(files.files[_plist]!)!;
      expect(written.keys.toSet().difference(allManagedLabels), isEmpty);
      for (final label in _neverDisable) {
        expect(written.keys, isNot(contains(label)), reason: label);
      }
    });

    test('refuses a plist it could not parse', () async {
      final files = _FakeFileStore({_plist: 'bplist00 not xml'});

      await expectLater(
        _service(_simctl(), files).slim(_udid),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('will not rewrite it'),
          ),
        ),
      );
      expect(files.files[_plist], 'bplist00 not xml');
    });

    test('refuses a UDID that is not a simulator', () async {
      await expectLater(
        _service(
          _simctl(),
          _FakeFileStore(),
        ).slim('11111111-2222-3333-4444-555555555555'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('No simulator'),
          ),
        ),
      );
    });

    test('gives up rather than editing a device that will not shut down', () async {
      // Writing while booted is the one thing that must not happen, so a
      // shutdown that never lands has to stop the whole operation.
      final runner = _simctl(state: 'Booted', pollsBeforeDown: 1 << 30);
      final files = _FakeFileStore();

      await expectLater(
        _service(
          runner,
          files,
          timeout: const Duration(milliseconds: 30),
        ).slim(_udid),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Could not shut'),
          ),
        ),
      );
      expect(files.files, isEmpty);
      expect(_simctlVerbs(runner), isNot(contains('boot')));
    });

    test('reports a boot that fails', () async {
      final runner = _simctl(bootFails: true);

      await expectLater(
        _service(runner, _FakeFileStore()).slim(_udid),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Could not boot'),
          ),
        ),
      );
    });

    test('does not leave a half-written temporary file behind', () async {
      final files = _FakeFileStore()..writeError = const _WriteFailed();

      await expectLater(
        _service(_simctl(), files).slim(_udid),
        throwsA(isA<_WriteFailed>()),
      );
      expect(files.files, isEmpty);
      expect(files.operations, contains('delete $_plist.tmp'));
    });
  });

  group('SimulatorSlimmingService.unslim', () {
    test('removes our keys and leaves everybody elses', () async {
      final files = _FakeFileStore();
      final service = _service(_simctl(), files);
      await service.slim(_udid);
      // Stand in for what launchd writes back during the boot in between.
      files.files[_plist] = encodeDisabledPlist({
        ...parseDisabledPlist(files.files[_plist]!)!,
        ..._launchdEntries,
        'com.apple.some.future.daemon': true,
      });

      await service.unslim(_udid);

      final written = parseDisabledPlist(files.files[_plist]!)!;
      expect(written, {
        ..._launchdEntries,
        'com.apple.some.future.daemon': true,
      });
      expect((await service.status(_udid)).isSlimmed, isFalse);
    });

    test('is a no-op on a device that was never slimmed', () async {
      final files = _FakeFileStore({
        _plist: encodeDisabledPlist(_launchdEntries),
      });

      await _service(_simctl(), files).unslim(_udid);

      expect(parseDisabledPlist(files.files[_plist]!), _launchdEntries);
    });
  });

  group('SimulatorSlimmingService.staleLabels', () {
    test('reports nothing missing when every managed label is loaded', () async {
      final runner = FakeCommandRunner(
        environmentId: 'macos',
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: _launchctlListOutput(allManagedLabels),
          stderr: '',
        ),
      );

      final stale = await _service(
        runner,
        _FakeFileStore(),
      ).staleLabels(_udid);

      expect(stale, isEmpty);
      final spawn = runner.requests.single;
      expect(spawn.executable, 'xcrun');
      expect(spawn.arguments, ['simctl', 'spawn', _udid, 'launchctl', 'list']);
    });

    test('names the labels a booted device does not know about', () async {
      // Stands in for Apple renaming a label between iOS releases: the
      // category table still lists the old name, but the device's own
      // launchd answers with something else entirely. Disabling — or
      // un-disabling — a name it has never heard of is a silent no-op, which
      // is exactly the failure mode this check exists to surface.
      final present = allManagedLabels.difference({
        'com.apple.chronod',
        'com.apple.searchd',
      });
      final runner = FakeCommandRunner(
        environmentId: 'macos',
        responder: (request) => CommandResult(
          exitCode: 0,
          stdout: _launchctlListOutput(present),
          stderr: '',
        ),
      );

      final stale = await _service(
        runner,
        _FakeFileStore(),
      ).staleLabels(_udid);

      expect(stale, {'com.apple.chronod', 'com.apple.searchd'});
    });

    test('refuses to guess when the device cannot be reached', () async {
      // `simctl spawn` fails outright on a device that is not booted — this
      // check needs the real launchd, so it must say so rather than reporting
      // every managed label as missing.
      final runner = FakeCommandRunner(
        environmentId: 'macos',
        responder: (request) => const CommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'Unable to lookup in current state: Shutdown',
        ),
      );

      await expectLater(
        _service(runner, _FakeFileStore()).staleLabels(_udid),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('must be booted'),
          ),
        ),
      );
    });
  });

  group('parseLaunchctlLabels', () {
    test('reads the label column and skips the header', () {
      const output =
          'PID\tStatus\tLabel\n'
          '123\t0\tcom.apple.chronod\n'
          '-\t0\tcom.apple.searchd\n';

      expect(parseLaunchctlLabels(output), {
        'com.apple.chronod',
        'com.apple.searchd',
      });
    });

    test('skips a row that does not have three tab-separated fields', () {
      const output =
          'PID\tStatus\tLabel\n'
          'garbage line with no tabs\n'
          '123\t0\tcom.apple.chronod\n';

      expect(parseLaunchctlLabels(output), {'com.apple.chronod'});
    });
  });
}

/// A `launchctl list` table naming exactly [labels], header included.
String _launchctlListOutput(Iterable<String> labels) {
  final buffer = StringBuffer('PID\tStatus\tLabel\n');
  for (final label in labels) {
    buffer.writeln('-\t0\t$label');
  }
  return buffer.toString();
}
