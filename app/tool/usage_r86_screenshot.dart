// Round 86's option B for the Usage tab's accounts — a grouped list card on
// the page, three rows and "Show all" — drawn over the same seven fake
// sign-ins as option A, which ships and which round 85's tool renders:
//
//   flutter test tool/responsive_r85_screenshot.dart \
//     --dart-define=R85_DIR=r86 --dart-define=R85_ONLY=usage-accounts
//   flutter test tool/responsive_r85_screenshot.dart \
//     --dart-define=R85_DIR=r86 --dart-define=R85_ONLY=more-usage
//   flutter test tool/usage_r86_screenshot.dart
//
// Example addresses only. Images land in build/r85-responsive/r86/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/agents/application/usage_accounts.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_account_selector.dart';
import 'package:karmashala/src/features/agents/presentation/usage_tab/usage_tab_state.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../test/app/responsive_surfaces.dart';

const _outDir = 'build/r85-responsive/r86';

Future<void> _loadBundledFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, Object?>>()) {
    final loader = FontLoader(family['family']! as String);
    for (final font
        in (family['fonts']! as List).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(font['asset']! as String));
    }
    await loader.load();
  }
}

/// Option B: the page's header row, then the accounts as a card.
class _OptionB extends ConsumerWidget {
  const _OptionB();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(usageAccountsProvider);
    final range = ref.watch(usageTabSelectionProvider.select((s) => s.range));
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeaderBar(
              title: 'Usage',
              onBack: () {},
              controls: [
                CompactSegmented(
                  segments: [
                    for (final r in UsageRange.values)
                      ButtonSegment(value: r, label: Text(r.label)),
                  ],
                  selected: range,
                  onChanged: (_) {},
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(Insets.lg),
              child: Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Insets.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      UsageAccountList(
                        accounts: accounts.take(3).toList(),
                        selectedId: null,
                        onSelected: (_) {},
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          onPressed: () {},
                          child: Text('Show all ${accounts.length}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUpAll(() async {
    Directory(_outDir).createSync(recursive: true);
    await _loadBundledFonts();
  });

  for (final width in const [360.0, 412.0]) {
    for (final scale in const [1.0, 1.6]) {
      for (final brightness in Brightness.values) {
        final label =
            '${width.toInt()}-x$scale-'
            '${brightness == Brightness.dark ? 'dark' : 'light'}';
        testWidgets('option B $label', (tester) async {
          tester.view
            ..physicalSize = Size(width, scale > 1 ? 1200 : 860)
            ..devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final c = (await tester.runAsync(manyUsageAccountsContainer))!;
          await tester.pumpWidget(
            responsiveApp(
              tester,
              c,
              brightness,
              desktop: const SizedBox(),
              phoneHome: const _OptionB(),
            ),
          );
          await settleSurface(tester);
          await tester.runAsync(() async {
            final render =
                responsiveBoundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            File(
              '$_outDir/option-b-$label.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
          });
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
        });
      }
    }
  }
}
