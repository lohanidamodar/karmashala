import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/overview/presentation/overview_title_block.dart';
import 'package:karmashala/src/features/sessions/application/host_lifecycle/host_lifecycle_providers.dart';

import 'mission_fixture.dart';

/// **A card's title stays readable** on a phone: never squeezed below its
/// first [kOverviewTitleKeeps] characters — the chip, End and ⋯ move to the
/// next line first — and the state chip never ends mid-word.
void main() {
  late Directory dir;

  // The app's own faces: the test font draws every glyph a full square, so
  // a title's width would say nothing about a real one.
  setUpAll(() async {
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
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ks-title-layout');
  });
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // The prefs file may still be held open on Windows; the OS sweeps temp.
    }
  });

  bool keyed(Widget w, String prefix) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix);

  /// The width the paragraph's first [kOverviewTitleKeeps] characters take.
  double floorOf(RenderParagraph paragraph) {
    final text = paragraph.text.toPlainText();
    final kept = text.characters.take(kOverviewTitleKeeps).toString();
    final painter = TextPainter(
      text: TextSpan(text: kept, style: paragraph.text.style),
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  for (final width in [360.0, 390.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('${width}px at ${scale}x: titles keep '
          '$kOverviewTitleKeeps characters, chips are whole', (tester) async {
        await pumpMission(
          tester,
          fixture: MissionFixture.full(),
          prefsDir: dir,
          size: Size(width, 800),
          phone: true,
          textScale: scale,
          // Every session runs, so every card carries its End too.
          overrides: [
            sessionRunningOnHostProvider.overrideWithValue((_) => true),
          ],
        );

        final titles = find.byWidgetPredicate(
          (w) => keyed(w, 'overview-card-title:'),
        );
        expect(titles, findsWidgets);
        for (final element in titles.evaluate()) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byWidget(element.widget),
              matching: find.byType(RichText),
            ),
          );
          final name = paragraph.text.toPlainText();
          // A title shorter than the floor shows whole; a longer one keeps
          // at least the floor, or the block's whole width where even that
          // is narrower.
          if (!paragraph.didExceedMaxLines) continue;
          final block = tester.renderObject<RenderOverviewTitleBlock>(
            find.ancestor(
              of: find.byWidget(element.widget),
              matching: find.byType(OverviewTitleBlock),
            ),
          );
          expect(
            paragraph.size.width,
            greaterThanOrEqualTo(
              math.min(floorOf(paragraph), block.size.width) - 0.5,
            ),
            reason: '"$name" squeezed to ${paragraph.size.width}',
          );
        }

        var chips = 0;
        for (final fit in tester.renderObjectList<RenderOverviewChipFit>(
          find.byType(OverviewChipFit),
        )) {
          chips++;
          final shown = fit.short ? fit.lastChild! : fit.firstChild!;
          final paragraphs = <RenderParagraph>[];
          void visit(RenderObject node) {
            if (node is RenderParagraph) paragraphs.add(node);
            node.visitChildren(visit);
          }

          visit(shown);
          for (final paragraph in paragraphs) {
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: '"${paragraph.text.toPlainText()}" is cut off',
            );
          }
        }
        expect(chips, greaterThan(0));
        expect(tester.takeException(), isNull);
        await unmountMission(tester);
      });
    }
  }

  testWidgets('a desktop keeps one row', (tester) async {
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      overrides: [sessionRunningOnHostProvider.overrideWithValue((_) => true)],
    );
    final blocks = tester.renderObjectList<RenderOverviewTitleBlock>(
      find.byType(OverviewTitleBlock),
    );
    expect(blocks, isNotEmpty);
    for (final block in blocks) {
      expect(block.arrangement, OverviewTitleLayout.oneRow);
    }
    await unmountMission(tester);
  });

  testWidgets('a narrow card moves the chip, End and ⋯ off the title row', (
    tester,
  ) async {
    await pumpMission(
      tester,
      fixture: MissionFixture.full(),
      prefsDir: dir,
      size: const Size(360, 800),
      phone: true,
      textScale: 1.6,
      overrides: [sessionRunningOnHostProvider.overrideWithValue((_) => true)],
    );
    final moved = tester
        .renderObjectList<RenderOverviewTitleBlock>(
          find.byType(OverviewTitleBlock),
        )
        .where((b) => b.arrangement != OverviewTitleLayout.oneRow);
    expect(moved, isNotEmpty);
    await unmountMission(tester);
  });
}
