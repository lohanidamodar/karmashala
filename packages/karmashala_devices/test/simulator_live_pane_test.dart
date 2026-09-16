import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/devices.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/widgets.dart';

const _udid = 'UDID-1';

class _Running extends SimulatorLiveViewController {
  _Running(this.view);

  final SimulatorLiveView view;

  @override
  SimulatorLiveViewState build() => SimulatorLiveViewRunning(view);
}

/// The simulator's picture while the backend has not said how big the screen
/// is — which it may never say.
void main() {
  late SimulatorLiveView view;

  setUp(() {
    view = SimulatorLiveView(
      udid: _udid,
      frames: SimulatorFrames(const Stream<Uint8List>.empty()),
      feed: SimulatorVideoFeed(
        url: Uri.parse('http://127.0.0.1:9100/'),
        stop: () async {},
      ),
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(900, 600),
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          simulatorLiveViewProvider.overrideWith(() => _Running(view)),
          iosSimulatorsProvider.overrideWith((ref) async => const []),
          simulatorBackendProvider.overrideWithValue(null),
          simctlServiceProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: Scaffold(body: SimulatorLivePane())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The box the picture is drawn in: whatever the frame widget ended up as.
  Size pictureSize(WidgetTester tester) {
    final raw = find.byType(RawImage);
    if (raw.evaluate().isNotEmpty) return tester.getSize(raw);
    return tester.getSize(
      find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == Colors.black,
      ),
    );
  }

  testWidgets('keeps a phone\'s shape before the first frame', (tester) async {
    // With no screen size the placeholder had no shape of its own: under a
    // loose width it was 0px wide, so nothing said a picture was coming.
    await pump(tester);

    final size = pictureSize(tester);
    expect(size.width, greaterThan(0));
    expect(size.width / size.height, closeTo(9 / 19.5, 0.01));
  });

  testWidgets('takes the frame\'s own shape once one arrives', (tester) async {
    // A landscape frame in a narrow side panel: drawn BoxFit.fill at the
    // pane's full height, it was squeezed to the panel's width.
    await pump(tester, size: const Size(300, 600));
    final image = await tester.runAsync(
      () => createTestImage(width: 400, height: 200),
    );
    view.frames.image.value = image as ui.Image;
    await tester.pumpAndSettle();

    final size = pictureSize(tester);
    expect(size.width / size.height, closeTo(2, 0.01));
  });
}
