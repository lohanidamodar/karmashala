@Tags(['live-agent'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'live_agent_screen.dart';

/// **A measuring tool, not a behaviour.** Starts an agent CLI in a real ConPTY
/// and xterm2 grid, waits for a screen, then presses key steps and writes the
/// grid after each one — how a prompt's keys were read off the real CLI rather
/// than assumed. Skips itself unless `KARMASHALA_PROBE` holds a JSON spec:
///
/// - `argv`: the command line;
/// - `cwd`: where to run it, or absent for a fresh temp folder seeded with
///   `files` (a map of relative path to content);
/// - `wait`: text to wait for before the first dump;
/// - `steps`: keys pressed one at a time (JSON string escapes, so the Down
///   arrow is ESC then `[B`), `type:` then text written in one go, or `wait:`
///   then text to wait for;
/// - `settle`: milliseconds to let the screen settle after each step;
/// - `env`: extra environment; `out`: the file the screens are written to.
///
/// Run it with `flutter test --tags=live-agent` and this file's path.
void main() {
  final raw = Platform.environment['KARMASHALA_PROBE'];
  test('probe', skip: raw == null ? 'set KARMASHALA_PROBE' : false, () async {
    final spec = jsonDecode(raw!) as Map<String, Object?>;
    final argv = (spec['argv']! as List).cast<String>();
    var cwd = spec['cwd'] as String?;
    if (cwd == null) {
      cwd = Directory.systemTemp.createTempSync('ks-probe-').path;
      final files = (spec['files'] as Map?)?.cast<String, String>() ?? {};
      for (final entry in files.entries) {
        File('$cwd${Platform.pathSeparator}${entry.key}')
          ..createSync(recursive: true)
          ..writeAsStringSync(entry.value);
      }
    }
    final settle = Duration(milliseconds: (spec['settle'] as int?) ?? 1500);
    final out = StringBuffer('cwd: $cwd\nargv: $argv\n');
    final screen = LiveAgentScreen.start(
      argv: argv,
      workingDirectory: cwd,
      environment: (spec['env'] as Map?)?.cast<String, String>() ?? const {},
    );
    void dump(String label) => out
      ..writeln('===== $label =====')
      ..writeln(screen.text.trimRight());
    try {
      final wait = spec['wait'] as String?;
      if (wait != null) {
        await screen.untilShows(wait, within: const Duration(seconds: 90));
      }
      await Future<void>.delayed(settle);
      dump('start');
      final steps = (spec['steps'] as List?)?.cast<String>() ?? const [];
      for (final step in steps) {
        if (step.startsWith('wait:')) {
          await screen.untilShows(
            step.substring(5),
            within: const Duration(seconds: 90),
          );
          await Future<void>.delayed(settle);
          dump(step);
          continue;
        }
        // `split:a|b|c` — each part its own write, back to back, the way three
        // `textInput` calls reach the pty.
        if (step.startsWith('split:')) {
          for (final part in step.substring(6).split('|')) {
            screen.send(part);
          }
          await Future<void>.delayed(settle);
          dump('split');
          continue;
        }
        if (step.startsWith('type:')) {
          await screen.write(step.substring(5));
          await Future<void>.delayed(settle);
          dump('typed');
          continue;
        }
        await screen.press(step);
        await Future<void>.delayed(settle);
        dump('after ${jsonEncode(step)}');
      }
    } on Object catch (error) {
      out.writeln('!!!!! $error');
    } finally {
      final exited = await screen.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -999,
      );
      out.writeln('exit: ${exited == -999 ? 'still running' : exited}');
      await screen.close();
      final path = spec['out'] as String?;
      if (path != null) File(path).writeAsStringSync(out.toString());
      // ignore: avoid_print
      print(out);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
