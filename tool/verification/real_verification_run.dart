// Manual verification — NOT part of `flutter test`'s default run (the file does
// not end in `_test.dart`). Run it explicitly:
//
//   flutter test tool/verification/real_verification_run.dart
//
// It drives the *MCP tool handlers* — `VerificationTools.call(...)`, exactly
// what the control server invokes — against a real Chrome and a real Android
// device, and prints the run and the report it produced.
//
// What only this can catch: whether the console errors a real page throws
// actually reach the run, whether a real screenshot is of what it claims, and
// whether a real device's logcat slice comes back filtered to the app.
//
// It spawns its own Chrome on port 9336 with a throwaway profile and kills it.
// The device half needs a real device attached; it launches Settings, taps one
// element, and presses Home afterwards so the phone is left as it was found.
//
// Nothing here touches the app's real database: the run rows go to an in-memory
// database and the artifacts to a temp directory that is listed, reported on,
// and then deleted.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_browser/browser.dart';
import 'package:karmashala/src/features/verification/application/verification_service.dart';
import 'package:karmashala/src/features/verification/application/verification_tools.dart';
import 'package:karmashala_verification/store.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'png_reader.dart';

const int kPort = 9336;
const String kTeal = '#0d9488';

/// The text of an `_mcpContent` result.
String textOf(Object? result) {
  final blocks = (result! as Map)['_mcpContent']! as List;
  for (final block in blocks) {
    final map = block as Map;
    if (map['type'] == 'text') return map['text']! as String;
  }
  return '';
}

int imagesIn(Object? result) => ((result! as Map)['_mcpContent']! as List)
    .where((b) => (b as Map)['type'] == 'image')
    .length;

/// A rough token count. `chars / 4` — no tokenizer runs offline, and Loop 39
/// quoted its costs the same way, so the numbers are comparable.
int tokens(String text) => (text.length / 4).round();

void banner(String title) => stdout.writeln('\n== $title ==');

void main() {
  test('a browser run, against a real Chrome', () async {
    final pageDir = await Directory.systemTemp.createTemp('verify-page-');
    final page = File(p.join(pageDir.path, 'page.html'));
    await page.writeAsString(_testPage);

    final artifacts = await Directory.systemTemp.createTemp('verify-runs-');
    final db = AppDatabase.memory();
    final browser = BrowserService(
      startProcess: browserProcessStarter(const LocalCommandRunner()),
    );
    final service = VerificationService(
      VerificationDao(db),
      VerificationArtifactStore(artifacts),
      browserOf: () => browser,
      adbOf: () => null,
    );
    final tools = VerificationTools(service);
    BrowserProcess? chrome;
    String? profileDir;

    try {
      // Attach to *our own* Chrome first, on a port nobody else is using: a run
      // started cold would take the default 9222 and drive whatever browser the
      // developer already had open there.
      await browser.connect(port: kPort, url: 'about:blank');
      chrome = browser.session!.endpoint.process;
      profileDir = browser.session!.endpoint.userDataDir;
      stdout.writeln(browser.session!.endpoint.description);

      banner('verification_start');
      final started = await tools.call('verification_start', {
        'url': Uri.file(page.path).toString(),
        'title': 'the teal panel renders and the page stays quiet',
        'sessionId': 'loop-51-demo-session',
      });
      stdout.writeln(textOf(started));
      stdout.writeln(
        '--- verification_start: ${textOf(started).length} chars ≈ '
        '${tokens(textOf(started))} tokens',
      );
      expect(browser.isConnected, isTrue);

      banner('driving it, the way an agent would');
      // Every one of these is a plain browser_* call. Nothing here knows a run
      // is being recorded — that is the whole point of the seam.
      final found = await browser.findElements(text: 'Save');
      stdout.writeln('browser_find → ${found.total} match(es)');
      await browser.click(text: 'Save');
      await browser.capture('#panel');
      await browser.screenshot();
      unawaited(
        tools.call('verification_note', const {
          'text': 'The panel is teal after Save, as the change intended.',
        }),
      );

      banner('now break it on purpose');
      // The button throws and fetches a URL that cannot resolve. Neither is
      // visible in a screenshot; both are what a run is for.
      await browser.click(text: 'Break it');
      await Future<void>.delayed(const Duration(seconds: 2));

      banner('verification_finish');
      final finished = await tools.call('verification_finish', const {
        'verdict': 'fail',
        'reason':
            'The panel renders, but clicking Break it throws '
            'TypeError and its POST never resolves.',
      });
      final finishText = textOf(finished);
      stdout.writeln(finishText);
      stdout.writeln(
        '--- verification_finish: ${finishText.length} chars ≈ '
        '${tokens(finishText)} tokens',
      );

      final run = service.list().single;
      expect(run.verdict.toString(), contains('fail'));

      banner('the run, as an agent reads it back');
      final compact = await tools.call('verification_get', {'id': run.id});
      final compactText = textOf(compact);
      stdout.writeln(compactText);
      stdout.writeln(
        '\n--- compact: ${compactText.length} chars ≈ '
        '${tokens(compactText)} tokens, ${imagesIn(compact)} image blocks',
      );

      final full = await tools.call('verification_get', {
        'id': run.id,
        'full': true,
      });
      stdout.writeln(
        '--- full:true: ${textOf(full).length} chars ≈ '
        '${tokens(textOf(full))} tokens, ${imagesIn(full)} image blocks',
      );
      final withImages = await tools.call('verification_get', {
        'id': run.id,
        'images': true,
      });
      stdout.writeln(
        '--- images:true: ${imagesIn(withImages)} image blocks '
        '(the text is the compact one)',
      );
      final listed = await tools.call('verification_list', const {});
      stdout.writeln(
        '--- verification_list: ${textOf(listed).length} chars ≈ '
        '${tokens(textOf(listed))} tokens',
      );

      banner('what landed on disk');
      final files = Directory(run.artifactDirectory).listSync().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final size = file is File ? file.lengthSync() : 0;
        stdout.writeln('  ${p.basename(file.path)}  $size B');
      }

      // The console and network files must actually contain the two faults.
      final console = File(
        p.join(
          run.artifactDirectory,
          run.artifacts
              .firstWhere((a) => a.kind.name == 'consoleErrors')
              .relativePath,
        ),
      ).readAsStringSync();
      stdout.writeln('\nconsole.txt:\n$console');
      expect(console, contains('TypeError'));

      final network = run.artifacts.where(
        (a) => a.kind.name == 'network' || a.kind.name == 'networkFailures',
      );
      if (network.isNotEmpty) {
        stdout.writeln(
          '\nnetwork.txt:\n'
          '${File(p.join(run.artifactDirectory, network.first.relativePath)).readAsStringSync()}',
        );
      }

      // A screenshot has to be of the thing it names.
      final crop = run.artifacts.firstWhere(
        (a) => a.kind.isImage && a.label.contains('#panel'),
      );
      final decoded = decodePng(
        File(
          p.join(run.artifactDirectory, crop.relativePath),
        ).readAsBytesSync(),
      );
      final dominant = decoded.dominantColour();
      stdout.writeln(
        '\nelement crop ${decoded.width}×${decoded.height}, dominant '
        '${dominant.key} at ${(dominant.value * 100).toStringAsFixed(1)}%',
      );
      expect(dominant.key, kTeal);

      banner('report.md');
      stdout.writeln(
        File(p.join(run.artifactDirectory, 'report.md')).readAsStringSync(),
      );
    } finally {
      await browser.disconnect();
      unawaited(chrome?.kill());
      await _deleteWithRetries(pageDir);
      if (profileDir != null) {
        await _deleteWithRetries(Directory(profileDir));
      }
      stdout.writeln('\nartifacts were in ${artifacts.path}');
      await _deleteWithRetries(artifacts);
      db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a device run, on a real device', () async {
    final runner = const LocalCommandRunner();
    final sdk = await AndroidSdkDiscoveryService(
      runner: runner,
      environment: localHostEnvironment(DateTime.now().toUtc()),
    ).discover();
    expect(sdk, isNotNull, reason: 'no Android SDK on this machine');

    final adb = AdbService(runner: runner, sdk: sdk!);
    final devices = await adb.listDevices();
    final device = devices.where((d) => d.isReady).firstOrNull;
    expect(device, isNotNull, reason: 'no ready device attached');
    stdout.writeln('device: ${device!.serial} (${device.displayName})');

    final artifacts = await Directory.systemTemp.createTemp('verify-device-');
    final db = AppDatabase.memory();
    final service = VerificationService(
      VerificationDao(db),
      VerificationArtifactStore(artifacts),
      browserOf: () =>
          BrowserService(startProcess: browserProcessStarter(runner)),
      adbOf: () => adb,
    );
    final tools = VerificationTools(service);

    try {
      banner('verification_start (launches the app)');
      stdout.writeln(
        textOf(
          await tools.call('verification_start', {
            'serial': device.serial,
            'package': 'com.android.settings',
            'title': 'Settings opens and its search field is reachable',
          }),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 3));

      banner('driving it, the way an agent would');
      // device_tap_element's own logic: read the tree, find the element, tap
      // its centre. Both the dump and the tap are recorded by the seam.
      final tree = await adb.dumpUiHierarchy(device.serial);
      stdout.writeln('UI tree: ${tree.nodeCount} nodes in ${tree.packageName}');
      const query = UiElementQuery(text: 'Search');
      final matches = tree.find(query);
      stdout.writeln('matches for "Search": ${matches.length}');
      if (matches.isNotEmpty && matches.first.tapBounds != null) {
        final point = matches.first.tapBounds!.center;
        await adb.tap(device.serial, point.x, point.y);
        stdout.writeln('tapped (${point.x}, ${point.y})');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await adb.screenshot(device.serial);
      unawaited(
        tools.call('verification_note', const {
          'text': 'Settings came to the front and the search field opened.',
        }),
      );

      banner('verification_finish');
      stdout.writeln(
        textOf(
          await tools.call('verification_finish', const {
            'verdict': 'pass',
            'reason':
                'Settings launched, the search field was reachable by query, '
                'and the log slice has no fatal lines.',
          }),
        ),
      );

      final run = service.list().single;
      banner('the run, as an agent reads it back');
      final compact = textOf(
        await tools.call('verification_get', {'id': run.id}),
      );
      stdout.writeln(compact);
      stdout.writeln(
        '\n--- compact: ${compact.length} chars ≈ ${tokens(compact)} tokens',
      );

      banner('what landed on disk');
      for (final file in Directory(run.artifactDirectory).listSync()) {
        stdout.writeln(
          '  ${p.basename(file.path)}  '
          '${file is File ? file.lengthSync() : 0} B',
        );
      }

      final logcat = run.artifacts.firstWhere(
        (a) => a.kind.name == 'logcat',
        orElse: () => throw StateError('no logcat artifact'),
      );
      final log = File(
        p.join(run.artifactDirectory, logcat.relativePath),
      ).readAsStringSync();
      stdout.writeln('\nlogcat slice (first 15 lines):');
      stdout.writeln(const LineSplitter().convert(log).take(15).join('\n'));

      final shot = run.artifacts.firstWhere((a) => a.kind.isImage);
      final decoded = decodePng(
        File(
          p.join(run.artifactDirectory, shot.relativePath),
        ).readAsBytesSync(),
      );
      stdout.writeln('\ndevice screenshot ${decoded.width}×${decoded.height}');

      banner('report.md');
      stdout.writeln(
        File(p.join(run.artifactDirectory, 'report.md')).readAsStringSync(),
      );
    } finally {
      // Leave the phone as it was found.
      await adb.pressKey(device.serial, DeviceKey.home);
      stdout.writeln('\nartifacts were in ${artifacts.path}');
      await _deleteWithRetries(artifacts);
      db.close();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Windows holds handles for a moment after a process exits.
Future<void> _deleteWithRetries(Directory directory) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

const String _testPage =
    '''
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Verification run fixture</title>
<style>
  body { margin: 0; font-family: sans-serif; background: #fff; padding: 24px; }
  #panel { width: 240px; height: 140px; background: $kTeal; }
</style>
</head>
<body>
  <h1>Settings</h1>
  <div id="panel"></div>
  <button id="save">Save</button>
  <button id="break">Break it</button>
  <script>
    document.getElementById('save').addEventListener('click', function () {
      document.getElementById('panel').style.background = '$kTeal';
    });
    document.getElementById('break').addEventListener('click', function () {
      fetch('https://this-host-does-not-exist.invalid/save', {method: 'POST'})
        .catch(function () {});
      window.somethingUndefined.save();
    });
  </script>
</body>
</html>
''';
