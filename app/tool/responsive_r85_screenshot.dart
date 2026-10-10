// Round 85's responsive sweep: every surface in test/app/responsive_surfaces
// at 360, 390, 412, 768, 1100 and 1440 px, text 1.0 and 1.6, light and dark,
// over fakes. Besides the PNGs it writes findings.txt: overflow and errors,
// sideways scrolling, text cut short, and on a phone taps under Touch.target.
// Under tool/ so `flutter test` never picks it up; run it from app/:
//
//   flutter test tool/responsive_r85_screenshot.dart --dart-define=R85_DIR=after
//
// R85_ONLY=<prefix> renders only the surfaces whose name starts with it.
// Images land in build/r85-responsive/<R85_DIR>/.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/app/responsive_surfaces.dart';

const _dir = String.fromEnvironment('R85_DIR', defaultValue: 'after');
const _only = String.fromEnvironment('R85_ONLY');
const _outDir = 'build/r85-responsive/$_dir';

const _widths = [360.0, 390.0, 412.0, 768.0, 1100.0, 1440.0];

/// Taller than the device, so a render shows more than one screen's worth.
Size _sizeFor(double width, double scale) {
  final base = switch (width) {
    < 600 => 860.0,
    < 1000 => 1024.0,
    _ => 900.0,
  };
  return Size(width, scale > 1 ? base * 1.4 : base);
}

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

final _findings = StringBuffer();

String _keyNear(Element element) {
  String? found;
  element.visitAncestorElements((e) {
    if (e.widget.key case final ValueKey<Object?> key) {
      found = '${key.value}';
      return false;
    }
    return true;
  });
  return found ?? element.widget.runtimeType.toString();
}

/// What a person would object to in the render in front of [tester].
Future<List<String>> _look(
  WidgetTester tester,
  List<FlutterErrorDetails> errors, {
  required bool tapTargets,
}) async {
  final lines = <String>[];
  for (final e in errors) {
    final message = '${e.exception}'.split('\n').first;
    final where = RegExp(r'(lib/\S+?\.dart:\d+)').firstMatch('$e')?.group(1);
    lines.add('error: $message${where == null ? '' : ' at $where'}');
  }
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state;
    if (state is! ScrollableState) continue;
    final p = state.position;
    if (p.axis == Axis.horizontal &&
        p.hasContentDimensions &&
        p.maxScrollExtent > 0.5) {
      lines.add(
        'sideways: ${_keyNear(element)} scrolls '
        '${p.maxScrollExtent.toStringAsFixed(0)}px',
      );
    }
  }
  void walk(RenderObject node) {
    if (node is RenderParagraph && node.didExceedMaxLines) {
      final text = node.text.toPlainText().replaceAll('\n', ' ');
      lines.add(
        'truncated: '
        '"${text.length > 60 ? '${text.substring(0, 60)}…' : text}"',
      );
    }
    node.visitChildren(walk);
  }

  walk(responsiveBoundary.currentContext!.findRenderObject()!);
  if (tapTargets) {
    final verdict = await androidTapTargetGuideline.evaluate(tester);
    if (!verdict.passed) {
      for (final reason in verdict.reason!.split('\n')) {
        if (reason.startsWith('SemanticsNode')) lines.add('tap: $reason');
      }
    }
  }
  return lines;
}

void main() {
  setUpAll(() async {
    Directory(_outDir).createSync(recursive: true);
    await _loadBundledFonts();
  });
  tearDownAll(() {
    File('$_outDir/findings.txt').writeAsStringSync(_findings.toString());
  });

  for (final surface in responsiveSurfaces) {
    if (_only.isNotEmpty && !surface.name.startsWith(_only)) continue;
    for (final width in _widths) {
      final phone = width < 600;
      if (surface.phoneOnly && !phone) continue;
      if (surface.desktopOnly && phone) continue;
      for (final scale in const [1.0, 1.6]) {
        for (final brightness in Brightness.values) {
          final label =
              '${width.toInt()}-x$scale-'
              '${brightness == Brightness.dark ? 'dark' : 'light'}';
          testWidgets('${surface.name} $label', (tester) async {
            tester.view
              ..physicalSize = _sizeFor(width, scale)
              ..devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.view.reset);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final errors = <FlutterErrorDetails>[];
            final previous = FlutterError.onError;
            FlutterError.onError = errors.add;
            final semantics = phone ? tester.ensureSemantics() : null;
            final lines = <String>[];
            try {
              final build = await surface.prepare(tester, brightness);
              await tester.pumpWidget(build());
              await settleSurface(tester);
              await surface.warmUp?.call(tester);
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
                  '$_outDir/${surface.name}-$label.png',
                ).writeAsBytesSync(bytes!.buffer.asUint8List());
              });
              lines.addAll(
                await _look(
                  tester,
                  errors,
                  tapTargets:
                      phone && scale == 1.0 && brightness == Brightness.light,
                ),
              );
            } on Object catch (error) {
              lines.add('harness: ${'$error'.split('\n').first}');
            } finally {
              FlutterError.onError = previous;
              semantics?.dispose();
              for (final line in lines) {
                _findings.writeln('${surface.name} $label: $line');
              }
              await tester.pumpWidget(const SizedBox());
              await tester.pump(const Duration(seconds: 1));
            }
          });
        }
      }
    }
  }
}
