import 'package:agent_cli/read.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/cli_detection/application/cli_detection_providers.dart';
import 'package:karmashala/src/features/cli_detection/presentation/detected_projects_view.dart';

/// The one way into the detected-sessions view: it starts a scan and opens the
/// view in a dialog no larger than [DetectedProjectsView.dialogMaxSize].
void main() {
  testWidgets('show starts a scan and opens the view, bounded', (tester) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scans = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          detectedProjectsControllerProvider.overrideWith(
            () => _CountingDetection(scans),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => DetectedProjectsView.show(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(scans, hasLength(1));
    expect(find.byType(DetectedProjectsView), findsOneWidget);
    final size = tester.getSize(find.byType(DetectedProjectsView));
    expect(
      size.width,
      lessThanOrEqualTo(DetectedProjectsView.dialogMaxSize.width),
    );
    expect(
      size.height,
      lessThanOrEqualTo(DetectedProjectsView.dialogMaxSize.height),
    );
  });
}

class _CountingDetection extends DetectedProjectsController {
  _CountingDetection(this._scans);

  final List<int> _scans;

  @override
  Future<List<DetectedProject>> build() async => const [];

  @override
  Future<void> detect() async => _scans.add(_scans.length);
}
