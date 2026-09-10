// **The isolate is asked to be still while a picker is up.**
//
// `karmashala_ui's picking.dart` records the measurement this is built from: on
// 2026-09-04, occupying the isolate for 25 s starting 50 ms after `openFile()`
// left the `#32770` "Open" window at `visible=0` and both it and the app's own
// window answering `IsHungAppWindow` — the picker created and never shown, and
// the app "Not Responding". Nothing in a widget test has a platform thread to
// block, so what is reachable from here is the other half of that sentence:
// whether everything working on this isolate is told to stop **before** the
// call and to carry on **after** it, whichever way the dialog answered.
//
// The occupation below is the same shape as the one that was measured — a
// synchronous burst inside `show`, with no yield in it — so a hook that was
// only told to be quiet *asynchronously* would never have been told at all by
// the time the dialog needed the thread.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_devices/devices.dart';

const _device = AndroidDevice(
  serial: 'emulator-5554',
  environmentId: 'windows',
  state: DeviceConnectionState.device,
  model: 'Pixel',
);

/// Stands where `DeviceStreamSession.setQuiet` stands: something that works on
/// this isolate whether or not anybody is looking at it.
class _FakeLiveStream {
  final List<bool> told = [];
  bool quiet = false;

  /// Frames it would have taken off the socket. A paused stream takes none —
  /// which is the whole of what "quiet" buys.
  int framesTaken = 0;

  void setQuiet(bool value) {
    told.add(value);
    quiet = value;
  }

  void arrive() {
    if (quiet) return;
    framesTaken += 1;
  }
}

void main() {
  late PickerQuiet quiet;
  late _FakeLiveStream stream;

  setUp(() {
    // Its own registry, never `PickerQuiet.instance`: a test that quieted the
    // singleton would reach every other suite in the run.
    quiet = PickerQuiet();
    stream = _FakeLiveStream();
    addTearDown(quiet.register(stream.setQuiet));
  });

  /// A dialog that takes the thread and does not give it back for [busy], the
  /// way the measured one did. [onBusy] runs while it is held.
  ShowFileDialog occupying(
    Duration busy, {
    void Function()? onBusy,
    Object? throwing,
  }) =>
      ({
        List<XTypeGroup> acceptedTypeGroups = const [],
        String? confirmButtonText,
        String? initialDirectory,
      }) async {
        final held = Stopwatch()..start();
        // A spin, not a `delay`: an `await` here would hand the isolate back,
        // which is exactly what the real call cannot do.
        while (held.elapsed < busy) {
          stream.arrive();
        }
        onBusy?.call();
        if (throwing != null) throw throwing;
        return null;
      };

  Future<void> pump(
    WidgetTester tester, {
    required ShowFileDialog show,
  }) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DeviceAppControls(
              device: _device,
              // The widget's own `_browse` with the host dialog swapped out:
              // the announcement, the flush and the quieting are all live code.
              pickFile: () => pickOneFile(
                what: 'a build to install',
                show: show,
                quiet: quiet,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the live stream is quiet for as long as the dialog is up', (
    tester,
  ) async {
    var quietWhileShown = false;
    var takenWhileShown = -1;
    await pump(
      tester,
      show: occupying(
        const Duration(milliseconds: 250),
        onBusy: () {
          quietWhileShown = stream.quiet;
          takenWhileShown = stream.framesTaken;
        },
      ),
    );

    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();

    expect(quietWhileShown, isTrue, reason: 'told before the dialog was asked');
    expect(
      takenWhileShown,
      0,
      reason: 'a quiet stream takes nothing off its socket',
    );
    expect(stream.quiet, isFalse, reason: 'and carries on afterwards');
    // Told once each way, never twice: a hook that heard "quiet" twice would
    // have to count, and one that never heard the second would stay stopped.
    expect(stream.told, [true, false]);
  });

  testWidgets('a dialog the host refuses still resumes the stream', (
    tester,
  ) async {
    await pump(
      tester,
      show: occupying(
        const Duration(milliseconds: 50),
        throwing: MissingPluginException('no file_selector here'),
      ),
    );

    await tester.tap(find.text('Install…'));
    await tester.pumpAndSettle();

    // The failure is already swallowed by `pickOneFile`; what must not be
    // swallowed with it is the resume. A live view left stopped by a picker
    // that never opened is the freeze made permanent.
    expect(stream.told, [true, false]);
    expect(stream.quiet, isFalse);
  });

  testWidgets('a typed path never quiets anything, because nothing opens', (
    tester,
  ) async {
    await pump(
      tester,
      show: occupying(const Duration(milliseconds: 250)),
    );

    await tester.enterText(
      find.byKey(const Key('device-install-path')),
      r'C:\builds\app.apk',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(stream.told, isEmpty);
    expect(stream.quiet, isFalse);
  });
}
