import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/media/video_support_provider.dart';
import 'package:karmashala/src/features/terminal/application/terminal_recording_controller.dart';
import 'package:karmashala/src/features/terminal/presentation/recording_saved_dialog.dart';
import 'package:karmashala_media/media.dart';
import 'package:karmashala_terminal_core/cast.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/window_matrix.dart';

/// A recording that has just stopped, without taping a pane to get one.
class _Stopped extends TerminalRecordingController {
  @override
  TerminalRecordingState build() => TerminalRecordingState(
    saved: SavedRecording(
      paneId: 'pane-1',
      endedWithPane: false,
      file: File(
        r'C:\Users\someone\Videos\Karmashala\recordings'
        r'\pwsh-20260916-101500.cast',
      ),
      cast: TerminalCast(
        columns: 120,
        rows: 32,
        recordedAt: DateTime.utc(2026, 9, 16, 10, 15),
        title: 'pwsh',
        truncated: true,
        events: [
          CastEvent.output(Duration(milliseconds: 10), 'ok\r\n'),
          CastEvent.output(Duration(seconds: 12), 'done\r\n'),
        ],
      ),
    ),
  );
}

/// "Recording stopped" opens over the workbench, so it has to fit the
/// smallest window with or without an MP4 encoder on the host.
void main() {
  for (final support in const [
    VideoSupport.available('the test host writes MP4.'),
    VideoSupport.unavailable(
      'This Windows install has no H.264 encoder, so frames are offered '
      'instead of a finished video.',
    ),
  ]) {
    testWidgets('the stopped-recording dialog, '
        '${support.available ? 'with' : 'without'} an MP4 encoder', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          terminalRecordingProvider.overrideWith(_Stopped.new),
          videoSupportProvider.overrideWithValue(support),
        ],
      );
      addTearDown(container.dispose);

      await expectSurvivesWindowMatrix(
        tester,
        build: () => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.dark(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showRecordingSavedDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
        warmUp: (tester) async {
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
        },
        because: 'a finished recording over the workbench',
      );
    });
  }
}
