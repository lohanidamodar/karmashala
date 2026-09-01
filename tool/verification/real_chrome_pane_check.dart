// Manual verification — NOT part of `flutter test`'s default run (the file does
// not end in `_test.dart`). Run it explicitly, with a Chrome installed:
//
//   flutter test tool/verification/real_chrome_pane_check.dart
//
// The widget tests drive the pane against a scripted socket. This drives the
// pane's *controller* against a real Chrome instead: attach, navigate, list
// tabs, pick an element (with a synthetic click standing in for the hand), and
// check that what lands in the pane's state — description, selector, and the
// PNG it wrote to disk for the prompt — is the element that was clicked.
//
// It spawns its own Chrome on port 9335 with a throwaway profile, and kills it.
import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala/src/core/process/command_runner_providers.dart';
import 'package:karmashala/src/core/process/process_handle.dart';
import 'package:karmashala/src/core/process/windows_command_runner.dart';
import 'package:karmashala/src/features/browser/application/browser_pane_controller.dart';
import 'package:karmashala/src/features/browser/application/browser_providers.dart';
import 'package:karmashala/src/features/browser/data/browser_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'png_reader.dart';

const int kPort = 9335;
const String kTeal = '#0d9488';

void main() {
  test(
    'the pane drives a real browser, and captures what was picked',
    () async {
      final directory = await Directory.systemTemp.createTemp('cdp-pane-');
      final file = File('${directory.path}${Platform.pathSeparator}pane.html');
      await file.writeAsString(_testPage);

      final service = BrowserService(runner: const WindowsCommandRunner());
      final container = ProviderContainer(
        overrides: [
          hostCommandRunnerProvider.overrideWithValue(
            const WindowsCommandRunner(),
          ),
          browserDebugPortProvider.overrideWithValue(kPort),
          browserServiceProvider.overrideWithValue(service),
        ],
      );
      final controller = container.read(browserPaneControllerProvider.notifier);
      BrowserPaneState state() => container.read(browserPaneControllerProvider);
      ProcessHandle? chrome;
      String? profile;

      try {
        await controller.navigate(Uri.file(file.path).toString());
        chrome = service.session?.endpoint.process;
        profile = service.session?.endpoint.userDataDir;

        expect(state().status, BrowserPaneStatus.connected);
        expect(state().connection, contains('port $kPort'));
        expect(state().title, 'Pane check');
        expect(state().url, endsWith('pane.html'));
        expect(state().error, isNull);
        expect(state().tabs, isNotEmpty);
        expect(
          profile,
          contains('karmashala-cdp-profile'),
          reason: 'never the developer\'s own profile',
        );

        // Pick, then click the box for the user.
        final pick = controller.pickElement();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(state().status, BrowserPaneStatus.picking);
        await _clickCentreOf(service, '#teal-box');
        await pick;

        final capture = state().capture!;
        expect(capture.selector, '#teal-box');
        expect(capture.description, 'div#teal-box.box');
        expect(capture.outerHtml, contains('id="teal-box"'));
        expect(capture.computedStyles['background-color'], 'rgb(13, 148, 136)');
        expect(state().status, BrowserPaneStatus.connected);

        // The pane writes the crop to disk so the prompt can point at it.
        final written = File(state().captureFile!);
        expect(written.existsSync(), isTrue);
        final png = decodePng(Uint8List.fromList(await written.readAsBytes()));
        final dominant = png.dominantColour();
        expect(dominant.key, kTeal);
        expect(dominant.value, greaterThan(0.8));

        final prompt = controller.capturePrompt()!;
        expect(prompt, contains('### div#teal-box.box'));
        expect(prompt, contains('Selector: `#teal-box`'));
        expect(prompt, contains('background-color: rgb(13, 148, 136);'));
        expect(prompt, contains('Screenshot file: ${written.path}'));

        // The overlay must be gone from the real page, not just from our state.
        expect(
          await service.evaluate(
            "document.querySelectorAll('[data-karmashala-picker]').length",
          ),
          0,
        );

        await controller.disconnect();
        expect(state().status, BrowserPaneStatus.disconnected);
        expect(service.isConnected, isFalse);
      } finally {
        await service.disconnect();
        container.dispose();
        await chrome?.kill();
        for (final path in [profile, directory.path]) {
          await _remove(path);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Deletes a temp directory, retrying: Chrome holds handles open for a moment
/// after it exits, and a profile left behind in %TEMP% is a mess and a
/// security smell.
Future<void> _remove(String? path) async {
  if (path == null) return;
  final directory = Directory(path);
  for (var attempt = 0; attempt < 10; attempt++) {
    if (!directory.existsSync()) return;
    try {
      directory.deleteSync(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}

Future<void> _clickCentreOf(BrowserService service, String selector) async {
  final page = service.session!.page;
  final point =
      await service.evaluate(
            '(function(){var r=document.querySelector("$selector")'
            '.getBoundingClientRect();'
            'return {x:r.left+r.width/2,y:r.top+r.height/2};})()',
          )
          as Map<Object?, Object?>;
  final x = (point['x']! as num).toDouble();
  final y = (point['y']! as num).toDouble();
  for (final event in [
    {'type': 'mouseMoved', 'button': 'none', 'buttons': 0},
    {'type': 'mousePressed', 'button': 'left', 'buttons': 1, 'clickCount': 1},
    {'type': 'mouseReleased', 'button': 'left', 'buttons': 0, 'clickCount': 1},
  ]) {
    await page.connection.send(
      'Input.dispatchMouseEvent',
      params: {...event, 'x': x, 'y': y},
    );
  }
}

const String _testPage =
    '''
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Pane check</title>
<style>
  body { margin: 0; background: #fff; }
  .box { width: 260px; height: 150px; margin: 50px; }
  #teal-box { background: $kTeal; }
</style>
</head>
<body><div id="teal-box" class="box"></div></body>
</html>
''';
