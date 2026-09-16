import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala/src/features/verification/data/verification_artifact_store.dart';
import 'package:karmashala/src/features/verification/data/verification_dao.dart';

import '../../support/fake_command_runner.dart';
import '../browser/fake_browser.dart';

/// A 1×1 PNG, so an artifact written by a test is a real image.
final Uint8List tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
]);

const _sdkRoot = r'C:\sdk';
const _adbPath = r'C:\sdk\platform-tools\adb.exe';

final AndroidSdk fakeSdk = const AndroidSdk(
  root: EnvironmentPath(environmentId: 'windows', path: _sdkRoot),
  adb: EnvironmentPath(environmentId: 'windows', path: _adbPath),
);

/// The UI dump a fake device answers with.
const String fakeUiXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<hierarchy rotation="0">'
    '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" '
    'package="com.example.app" content-desc="" bounds="[0,0][1080,2340]">'
    '<node index="0" text="Settings" resource-id="com.example.app:id/title" '
    'class="android.widget.TextView" package="com.example.app" '
    'content-desc="" clickable="true" enabled="true" '
    'bounds="[40,200][600,280]" />'
    '</node></hierarchy>';

/// A scripted adb: every command a run makes has an answer, and the calls are
/// recorded so a test can assert on the actual argv.
class FakeAdb {
  FakeAdb({this.serial = 'FAKE123', this.packageRunning = true}) {
    runner = FakeCommandRunner(responder: _respond);
    service = AdbService(
      runner: runner,
      sdk: fakeSdk,
      readHostFile: (_) async => tinyPng,
      uiDumpRetryDelay: Duration.zero,
    );
  }

  final String serial;

  /// Whether `pidof` finds the package. False is the "app is not running" case
  /// that makes a logcat slice legitimately empty.
  bool packageRunning;

  /// Set to make `monkey` report that the package has no launcher activity.
  bool packageInstalled = true;

  late final FakeCommandRunner runner;
  late final AdbService service;

  /// The argv of every adb call, joined, in order.
  List<String> get calls => [
    for (final request in runner.requests) request.arguments.join(' '),
  ];

  bool called(String fragment) => calls.any((c) => c.contains(fragment));

  CommandResult _respond(CommandRequest request) {
    final argv = request.arguments.join(' ');
    if (argv.contains('devices')) {
      return CommandResult(
        exitCode: 0,
        stdout:
            'List of devices attached\n'
            '$serial\tdevice product:test model:Test transport_id:1\n',
        stderr: '',
      );
    }
    if (argv.contains('monkey')) {
      return CommandResult(
        exitCode: 0,
        stdout: packageInstalled
            ? 'Events injected: 1\n'
            : '** No activities found to run, monkey aborted.',
        stderr: '',
      );
    }
    if (argv.contains('wm size')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'Physical size: 1080x2340',
        stderr: '',
      );
    }
    if (argv.contains('uiautomator dump')) {
      return const CommandResult(
        exitCode: 0,
        stdout: 'UI hierchary dumped to: /data/local/tmp/x.xml',
        stderr: '',
      );
    }
    if (argv.contains('logcat')) {
      return const CommandResult(
        exitCode: 0,
        stdout:
            '08-30 12:00:00.100  4242  4242 I MainActivity: started\n'
            '08-30 12:00:00.200  4242  4242 E MainActivity: boom\n',
        stderr: '',
      );
    }
    // Checked after logcat on purpose: "logcat -d" contains "cat ".
    if (argv.contains('cat ')) {
      return const CommandResult(exitCode: 0, stdout: fakeUiXml, stderr: '');
    }
    if (argv.contains('pidof')) {
      return CommandResult(
        exitCode: 0,
        stdout: packageRunning ? '4242' : '',
        stderr: '',
      );
    }
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }
}

/// Everything a verification-service test needs, wired to fakes.
class VerificationHarness {
  VerificationHarness({DateTime Function()? now, String Function()? newId})
    : root = Directory.systemTemp.createTempSync('verify-run') {
    db = AppDatabase.memory();
    dao = VerificationDao(db);
    store = VerificationArtifactStore(root);
    service = VerificationService(
      dao,
      store,
      browserOf: () => browser.service,
      adbOf: () => adb.service,
      changes: changes,
      now: now,
      newId: newId ?? _sequentialId,
    );
  }

  final Directory root;
  late final AppDatabase db;
  late final VerificationDao dao;
  late final VerificationArtifactStore store;
  late final VerificationService service;

  /// The signal the service publishes into, held here so a widget test can
  /// override `verificationChangesProvider` with the same one. Without that the
  /// pane would watch a different signal from the service it is given and stop
  /// following a run live — which is the whole point of the stream.
  final changes = VerificationChangeSignal();

  final browser = FakeBrowser();
  final adb = FakeAdb();

  var _ids = 0;
  String _sequentialId() => 'run-${(++_ids).toString().padLeft(3, '0')}';

  Future<void> dispose() async {
    await service.dispose();
    await changes.dispose();
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
