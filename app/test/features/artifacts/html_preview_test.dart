import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/presentation/html_preview.dart';
import 'package:karmashala_ui/theme.dart';
import 'package:karmashala_ui/transcript.dart';

/// An HTML page shown in the app: drawn natively with no script run, its
/// source a toggle away, sized to the page up to a limit, and the browser —
/// where scripts do run, sandboxed — one tap away.
void main() {
  const scripted =
      '<h1>Report</h1><p>All green.</p>'
      '<script>document.body.innerHTML = "hijacked"</script>'
      '<img src="https://example.com/chart.png">';

  Future<void> show(
    WidgetTester tester,
    String html, {
    double? maxHeight = 264,
    double width = 1440,
    double textScale = 1,
    Brightness brightness = Brightness.dark,
    List<Override> overrides = const [],
    Future<void> Function()? onOpenInBrowser,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: HtmlPreview(
                  key: const ValueKey('preview'),
                  html: html,
                  maxHeight: maxHeight,
                  onOpenInBrowser: onOpenInBrowser ?? () async {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The native engine lays a page out over a few frames.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('drawn natively; scripts never run, and it says where they do', (
    tester,
  ) async {
    await show(tester, scripted);
    expect(
      find.textContaining('All green.', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('hijacked', findRichText: true), findsNothing);
    expect(find.byKey(const ValueKey('artifact-html-scripts')), findsOneWidget);
    expect(
      find.textContaining('only when you open the page in your browser'),
      findsOneWidget,
    );
  });

  testWidgets('the network is off: a web image is refused and that is said', (
    tester,
  ) async {
    await show(tester, scripted);
    expect(
      find.byKey(const ValueKey('artifact-html-blocked-network')),
      findsOneWidget,
    );
    expect(find.textContaining('Network off'), findsOneWidget);
  });

  testWidgets('Source shows the markup, Preview the page again', (
    tester,
  ) async {
    await show(tester, scripted);
    await tester.tap(find.text('Source'));
    await tester.pumpAndSettle();
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(
      find.textContaining('<h1>Report</h1>', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.byType(CodeBlock), findsNothing);
  });

  testWidgets('Copy puts down the markup', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await show(tester, scripted);
    await tester.tap(find.byTooltip('Copy HTML'));
    await tester.pumpAndSettle();
    expect(copied, scripted);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a long page grows to the limit, then scrolls inside itself', (
    tester,
  ) async {
    // Past 10 KB the engine parses off the frame, so real time has to pass.
    await show(tester, '<p>${'Line of text. ' * 40}</p>' * 60);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.getSize(find.byKey(const ValueKey('preview'))).height, 264);
    await show(tester, '<p>short</p>');
    expect(
      tester.getSize(find.byKey(const ValueKey('preview'))).height,
      lessThan(200),
    );
  });

  testWidgets('full screen opens the same page with nothing more to open', (
    tester,
  ) async {
    await show(tester, scripted);
    await tester.tap(find.byKey(const ValueKey('html-preview-full')));
    await tester.pumpAndSettle();
    expect(find.text('HTML preview'), findsOneWidget);
    expect(find.byKey(const ValueKey('html-preview-full')), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('HTML preview'), findsNothing);
  });

  testWidgets('Open in browser is handed on', (tester) async {
    var opened = 0;
    await show(tester, scripted, onOpenInBrowser: () async => opened++);
    await tester.tap(find.byKey(const ValueKey('html-preview-browser')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('the engine is one provider: a web view would slot in there', (
    tester,
  ) async {
    await show(
      tester,
      scripted,
      overrides: [
        htmlEngineProvider.overrideWithValue(
          (context, html, {required allowNetwork, required openUrl}) =>
              const Text('another engine'),
        ),
        htmlEngineRunsScriptsProvider.overrideWithValue(true),
      ],
    );
    expect(find.text('another engine'), findsOneWidget);
    expect(find.byKey(const ValueKey('artifact-html-scripts')), findsNothing);
  });

  for (final width in const [360.0, 390.0, 1440.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('no overflow at $width px, text ×1.6, ${brightness.name}', (
        tester,
      ) async {
        await show(
          tester,
          scripted,
          width: width,
          textScale: 1.6,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
