import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_devices/pane.dart';
import 'package:karmashala_devices/providers.dart';
import 'package:karmashala_devices/widgets.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/tokens.dart';

const _udid = 'UDID-1';

class _Fixed extends SimulatorLiveViewController {
  _Fixed(this.initial);

  final SimulatorLiveViewState initial;
  int stops = 0;

  @override
  SimulatorLiveViewState build() => initial;

  @override
  Future<void> stop() async {
    stops++;
  }
}

/// The pane's empty and in-between states, drawn by the house placeholder:
/// one glyph size, one muted voice, and a way out that scrolls into reach
/// rather than being clipped off a short side panel.
void main() {
  Future<_Fixed> pumpSimulator(
    WidgetTester tester,
    SimulatorLiveViewState state, {
    required Size size,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fake = _Fixed(state);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          simulatorLiveViewProvider.overrideWith(() => fake),
          iosSimulatorsProvider.overrideWith((ref) async => const []),
          simulatorBackendProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SimulatorLivePane()),
        ),
      ),
    );
    // A starting state spins forever; a few frames are enough to lay out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return fake;
  }

  testWidgets('a failed simulator start keeps Dismiss in reach', (
    tester,
  ) async {
    final fake = await pumpSimulator(
      tester,
      const SimulatorLiveViewFailed(
        _udid,
        'WebDriverAgent did not answer on :8100 within 60 seconds. The '
        'simulator may still be booting, or another runner holds the port.',
      ),
      size: const Size(240, 220),
    );

    expect(find.byType(PanePlaceholder), findsOneWidget);
    final dismiss = find.text('Dismiss');
    await tester.ensureVisible(dismiss);
    await tester.pump();
    await tester.tap(dismiss);
    expect(fake.stops, 1);
  });

  testWidgets('a starting simulator says so without overflowing', (
    tester,
  ) async {
    await pumpSimulator(
      tester,
      const SimulatorLiveViewStarting(_udid),
      size: const Size(240, 160),
    );

    expect(find.byType(PanePlaceholder), findsOneWidget);
    expect(find.textContaining('Starting the live view'), findsOneWidget);
  });

  testWidgets('the device pane\'s empty state is the house placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          androidSdkProvider.overrideWith((ref) async => null),
          devicesProvider.overrideWith((ref) async => const []),
          avdsProvider.overrideWith((ref) async => const []),
          hostCanRunSimulatorsProvider.overrideWithValue(false),
          iosSimulatorsProvider.overrideWith((ref) async => const []),
          simulatorBackendProvider.overrideWithValue(null),
        ],
        child: const MaterialApp(home: Scaffold(body: DevicePane())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PanePlaceholder), findsOneWidget);
    // Its glyph at the one empty-state size, where a 40px copy had drifted.
    expect(
      tester.widget<Icon>(find.byIcon(AppIcons.deviceMobile)).size,
      Chrome.iconHero,
    );
  });
}
