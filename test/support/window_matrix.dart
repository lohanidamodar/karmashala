/// The minimum-window and accessibility matrix.
///
/// Karmashala supports a 720x560 window, and several dialogs ask for far more
/// than that — the fan-out dialog asks for 1180x780. Flutter shrinks the outer
/// box silently, so nothing tells you the contents no longer fit; the pane just
/// clips, and the yellow-and-black stripes only appear if someone happens to
/// run at that size. Text scaling does the same thing to fixed-height rows.
///
/// [expectSurvivesWindowMatrix] pumps one widget in every cell of the matrix and
/// reports **all** of the findings together, rather than stopping at the first,
/// because the useful output is "which surface breaks where", not "the first
/// assertion that tripped".
///
/// Three things are checked in each cell:
///
/// - **Overflow.** Captured through `FlutterError.onError`, so the exact pixel
///   counts and directions come back rather than a bare pass/fail.
/// - **Focus traversal.** Tab must cycle through every stop and come back — no
///   dead end, nothing unreachable — and every stop must be inside the window.
///   A control you can focus but cannot see is the real bug at 720x560.
/// - **Semantics.** Every button must have a name. Icon-only controls are the
///   ones that lose theirs, and a tooltip is mouse-dependent: Narrator reads the
///   semantics tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One cell of the matrix.
class WindowCell {
  const WindowCell(this.label, this.size, {this.textScale = 1.0});

  final String label;
  final Size size;
  final double textScale;

  @override
  String toString() => label;
}

/// The smallest window the app supports.
const minimumWindow = WindowCell('720x560 (minimum window)', Size(720, 560));

/// An ordinary desktop window, as a control: a finding that appears here too is
/// not a small-window problem.
const desktopWindow = WindowCell('1440x900 (desktop)', Size(1440, 900));

/// The minimum window with Windows' "make text bigger" turned up. Fixed-height
/// rows and single-line labels break here first.
const minimumWindowLargeText = WindowCell(
  '720x560 @ 1.3x text',
  Size(720, 560),
  textScale: 1.3,
);

/// A desktop window at the settings screen's 125% UI text size — the scale
/// the in-app setting actually offers, at the size it will actually be used.
/// Not in the default matrix (opt in per surface) so adding it cannot silently
/// change what every existing test asserts.
const desktopLargeText = WindowCell(
  '1440x900 @ 1.25x text',
  Size(1440, 900),
  textScale: 1.25,
);

const windowMatrix = [minimumWindow, desktopWindow, minimumWindowLargeText];

/// A single thing wrong with one surface in one cell.
class MatrixFinding {
  MatrixFinding(this.cell, this.kind, this.detail);

  final WindowCell cell;
  final String kind;
  final String detail;

  @override
  String toString() => '  [$cell] $kind: $detail';
}

/// Pumps [build] in every cell of [matrix] and fails once, listing everything
/// found.
///
/// [build] is called fresh per cell and must return the whole tree to pump
/// (scope, `MaterialApp`, and the surface under test). [warmUp] runs after the
/// first pump — use it to drive the surface into the state worth measuring, such
/// as opening a dialog's second page.
///
/// Set [checkFocus] or [checkSemantics] to false only with a reason: a surface
/// with no focusable controls, or one whose buttons are deliberately unnamed
/// because a parent names them.
Future<void> expectSurvivesWindowMatrix(
  WidgetTester tester, {
  required Widget Function() build,
  Future<void> Function(WidgetTester tester)? warmUp,
  List<WindowCell> matrix = windowMatrix,
  bool checkFocus = true,
  bool checkSemantics = true,
  String? because,
}) async {
  final findings = <MatrixFinding>[];

  for (final cell in matrix) {
    findings.addAll(
      await _runCell(
        tester,
        cell,
        build: build,
        warmUp: warmUp,
        checkFocus: checkFocus,
        checkSemantics: checkSemantics,
      ),
    );
  }

  if (findings.isNotEmpty) {
    fail(
      '${findings.length} finding(s) across the window matrix'
      '${because == null ? '' : ' ($because)'}:\n'
      '${findings.join('\n')}',
    );
  }
}

Future<List<MatrixFinding>> _runCell(
  WidgetTester tester,
  WindowCell cell, {
  required Widget Function() build,
  required Future<void> Function(WidgetTester tester)? warmUp,
  required bool checkFocus,
  required bool checkSemantics,
}) async {
  final findings = <MatrixFinding>[];
  final captured = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = cell.size;
  tester.platformDispatcher.textScaleFactorTestValue = cell.textScale;
  FlutterError.onError = captured.add;

  final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
  // A tap that "would not hit test" means the control is off-screen or covered.
  // That is the finding, so make it throw instead of printing a warning.
  WidgetController.hitTestWarningShouldBeFatal = true;

  SemanticsHandle? semantics;
  try {
    if (checkSemantics) semantics = tester.ensureSemantics();
    await tester.pumpWidget(build());
    await _settle(tester);
    if (warmUp != null) {
      try {
        await warmUp(tester);
        await _settle(tester);
      } on Object catch (error) {
        // Not being able to drive the surface is a finding, not a crash: a
        // control pushed out of the window is untappable for the user too.
        findings.add(MatrixFinding(cell, 'warm-up', _firstLine('$error')));
      }
    }

    // Overflow is reported during paint, so it is already in `captured`. Nudge
    // one more frame in case settling scheduled the offending layout late.
    await tester.pump();

    findings.addAll(_overflowFindings(cell, captured));
    if (checkFocus) findings.addAll(await _focusFindings(tester, cell));
    if (checkSemantics) findings.addAll(_semanticsFindings(tester, cell));

    // Anything captured that was not an overflow is a real error the surface
    // threw; surface it rather than swallowing it with the handler.
    for (final details in captured) {
      if (!_isOverflow(details)) {
        findings.add(
          MatrixFinding(cell, 'error', _firstLine('${details.exception}')),
        );
      }
    }
  } finally {
    FlutterError.onError = previousOnError;
    WidgetController.hitTestWarningShouldBeFatal = previousFatal;
    semantics?.dispose();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.view.reset();
    // Leave a clean tree so the next cell starts from nothing.
    await tester.pumpWidget(const SizedBox.shrink());
  }
  return findings;
}

bool _isOverflow(FlutterErrorDetails details) =>
    '${details.exception}'.contains('overflowed by');

final _overflowPattern = RegExp(
  r'A (\w+) overflowed by ([\d.]+) pixels on the (\w+)',
);

List<MatrixFinding> _overflowFindings(
  WindowCell cell,
  List<FlutterErrorDetails> captured,
) {
  final seen = <String>{};
  final findings = <MatrixFinding>[];
  for (final details in captured.where(_isOverflow)) {
    final message = '${details.exception}';
    final match = _overflowPattern.firstMatch(message);
    final detail = match == null
        ? _firstLine(message)
        : '${match.group(1)} overflowed by ${match.group(2)}px '
              'on the ${match.group(3)}';
    if (seen.add(detail)) findings.add(MatrixFinding(cell, 'overflow', detail));
  }
  return findings;
}

String _firstLine(String value) {
  final line = value.split('\n').first.trim();
  return line.length > 160 ? '${line.substring(0, 160)}…' : line;
}

/// Tab through the surface. Every stop must be inside the window, and the ring
/// must close — if Tab never returns to where it started, something is a trap.
///
/// A lazy list is the exception the closure rule has to make room for: it
/// disposes the row the ring started at, and the honest verdict is then "closed
/// at the first row that still exists". See [_stopKey].
Future<List<MatrixFinding>> _focusFindings(
  WidgetTester tester,
  WindowCell cell,
) async {
  final findings = <MatrixFinding>[];
  final window = Offset.zero & cell.size;

  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await _settle(tester);
  final first = FocusManager.instance.primaryFocus;
  if (first == null || !first.hasPrimaryFocus) return findings;

  // The rect is recorded while the stop *has* focus. Measuring afterwards would
  // report every field of a scrolling form as off-screen, because tabbing on
  // scrolls the earlier ones away — a harness artefact, not a layout bug.
  // **The first stop is remembered twice, and neither way is redundant.** See
  // [_stopKey]: on a lazy list the node is gone by the end of a lap, and the
  // key is what recognises the row when it is rebuilt.
  final firstKey = _stopKey(first);
  final visited = <FocusNode>[first];
  final rects = <Rect?>[_rectOf(first)];
  const cap = 60;
  var closed = false;
  for (var i = 0; i < cap; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _settle(tester);
    final node = FocusManager.instance.primaryFocus;
    if (node == null) break;
    if (identical(node, first) || _stopKey(node) == firstKey) {
      closed = true;
      break;
    }
    if (visited.any((seen) => identical(seen, node))) {
      // **A lazy list is allowed to have thrown the first stop away.** Tabbing
      // down a `ListView` disposes the rows it scrolls past, the first one
      // included, and the traversal then wraps to the earliest row that still
      // exists. That is the ring closing, not a trap — and calling it a trap
      // made every long scrolling surface look broken. Measured on a 30-row
      // list at 720x560: the first stop's element unmounts at stop 15, and the
      // wrap lands back on stop 15 at stop 30.
      if (first.context?.mounted ?? false) {
        findings.add(
          MatrixFinding(
            cell,
            'focus',
            'tab revisits a stop before completing the ring — '
                '${visited.length} stops seen',
          ),
        );
      }
      closed = true;
      break;
    }
    visited.add(node);
    rects.add(_rectOf(node));
  }

  if (!closed) {
    findings.add(
      MatrixFinding(
        cell,
        'focus',
        'tab never returned to the first stop after ${visited.length} '
            'moves — the traversal ring does not close',
      ),
    );
  }

  for (final rect in rects) {
    if (rect == null) {
      // Not "skip it": a stop with nothing on screen to measure is a control
      // the user can tab to and cannot see, which is the bug this harness is
      // for. It used to disappear into a broad catch and produce no finding.
      findings.add(
        MatrixFinding(
          cell,
          'focus',
          'a focus stop has no laid-out render object to measure — it can be '
              'tabbed to but not seen',
        ),
      );
      continue;
    }
    if (rect.isEmpty) continue;
    if (!window.overlaps(rect)) {
      findings.add(
        MatrixFinding(
          cell,
          'focus',
          'a focus stop sits entirely outside the window at $rect',
        ),
      );
    } else if (rect.left < window.left - 0.01 ||
        rect.top < window.top - 0.01 ||
        rect.right > window.right + 0.01 ||
        rect.bottom > window.bottom + 0.01) {
      findings.add(
        MatrixFinding(
          cell,
          'focus',
          'a focus stop is clipped by the window edge at $rect',
        ),
      );
    }
  }
  return findings;
}

/// Every button needs a name. A tooltip counts — it lands in the semantics tree
/// — but a bare `Icon` inside an `IconButton` does not.
List<MatrixFinding> _semanticsFindings(WidgetTester tester, WindowCell cell) {
  final root = _rootSemantics(tester);
  if (root == null) return const [];

  final findings = <MatrixFinding>[];
  final unnamed = <Rect>[];

  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    final isButton =
        data.flagsCollection.isButton || data.flagsCollection.isLink;
    final named =
        data.label.trim().isNotEmpty || data.tooltip.trim().isNotEmpty;
    if (isButton && !named) unnamed.add(node.rect);
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);

  for (final rect in unnamed) {
    findings.add(
      MatrixFinding(
        cell,
        'semantics',
        'a button has no accessible name (rect ${rect.size.width.toInt()}x'
            '${rect.size.height.toInt()} at ${rect.left.toInt()},'
            '${rect.top.toInt()}) — Narrator will announce it as "button"',
      ),
    );
  }
  return findings;
}

/// The semantics root, without going through the deprecated
/// `binding.pipelineOwner`: semantics now hang off a child of the root owner.
SemanticsNode? _rootSemantics(WidgetTester tester) {
  SemanticsNode? found;
  void visit(PipelineOwner owner) {
    found ??= owner.semanticsOwner?.rootSemanticsNode;
    owner.visitChildren(visit);
  }

  visit(tester.binding.rootPipelineOwner);
  return found;
}

/// Settle, but do not require the tree to go quiet: a surface showing a
/// progress indicator animates forever, and `pumpAndSettle` would time the
/// whole matrix out rather than measure the layout in front of it.
///
/// Only that timeout is tolerated. Catching every [FlutterError] also swallowed
/// whatever a widget threw while settling, which is exactly the kind of finding
/// the matrix is supposed to report.
Future<void> _settle(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  } on FlutterError catch (error) {
    if (!error.message.contains('pumpAndSettle timed out')) rethrow;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// What names the stop the ring started at, so it can be recognised again.
///
/// **Identity is not enough for a lazy list, and that is not a detail.** A
/// `ListView` builds a row when it scrolls into the cache and disposes it when
/// it scrolls out, so the [FocusNode] recorded as "the first stop" does not
/// survive one lap of a long list: `identical` misses the return, the traversal
/// runs on until it meets a row it has already had, and the harness reports a
/// *revisit* — a focus trap — against a surface that has none. Any matrix
/// failure on a scrolling surface needs that ruled out before it is believed.
///
/// So the stop is named by something the **row** owns rather than by the widget
/// that happens to be holding it: a `ValueKey` at or above it, else the first
/// label under it that a person would read. Identity is the last resort, and
/// for an unlabelled stop it is exactly as good as before.
///
/// The cost of the fallback is that two stops sharing one label read as the
/// same stop. That is only ever an under-report — the ring closes early, and no
/// finding is invented — and a surface with two identically named buttons on it
/// has a semantics problem this harness already reports.
String _stopKey(FocusNode node) {
  final context = node.context;
  if (context != null && context.mounted) {
    final key = _valueKeyAt(context);
    if (key != null) return 'key:$key';
    final label = _labelUnder(context);
    if (label != null) return 'label:$label';
  }
  return 'node:${identityHashCode(node)}';
}

/// The nearest `ValueKey` at or above [context].
///
/// The walk stops at the [Scrollable] the stop lives in: a list's own key names
/// the list, and letting it stand in for every row would make every row the
/// same stop.
String? _valueKeyAt(BuildContext context) {
  if (context.widget.key case final ValueKey<Object?> key) return '${key.value}';
  String? found;
  context.visitAncestorElements((element) {
    if (element.widget is Scrollable) return false;
    if (element.widget.key case final ValueKey<Object?> key) {
      found = '${key.value}';
      return false;
    }
    return true;
  });
  return found;
}

/// The first label under [context] that a person would read.
///
/// Read off the widget tree rather than the semantics tree on purpose: a cell
/// running with `checkSemantics: false` never turns semantics on, and the ring
/// still has to close there.
String? _labelUnder(BuildContext context) {
  String? found;
  void walk(Element element) {
    if (found != null) return;
    switch (element.widget) {
      case Text(:final data?) when data.trim().isNotEmpty:
        found = data.trim();
      case Tooltip(:final message?) when message.trim().isNotEmpty:
        found = message.trim();
      case Semantics(:final properties)
          when (properties.label ?? '').trim().isNotEmpty:
        found = properties.label!.trim();
      default:
        element.visitChildren(walk);
    }
  }

  context.visitChildElements(walk);
  return found;
}

/// A focus stop's global rect, or null when there is nothing to measure.
///
/// Null is a finding, not a skip — see [_focusFindings]. Two things produce it:
/// a node focused without ever being built (no render object), and one whose
/// render object has not been laid out (the framework asserts on
/// `semanticBounds`). The catch covers only the second; anything else the
/// widget threw is a real error and is allowed out.
Rect? _rectOf(FocusNode node) {
  if (node.context?.findRenderObject() == null) return null;
  try {
    return node.rect;
  } on AssertionError {
    return null;
  }
}
