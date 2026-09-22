import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show Layer;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_terminal_runtime/ingest.dart';
import 'package:karmashala_terminal_runtime/instances.dart';
import 'package:xterm2/xterm.dart';

/// A minimized window's terminals: written to, but neither repainted nor asking
/// for frames until the window is shown, when they repaint once.
void main() {
  RenderTerminal renderOf(WidgetTester tester) {
    RenderTerminal? found;
    void walk(RenderObject node) {
      if (node is RenderTerminal) found ??= node;
      node.visitChildren(walk);
    }

    walk(tester.renderObject(find.byType(TerminalView)));
    return found!;
  }

  /// What the terminal last painted. A repaint replaces it.
  Layer? paintedLayer(WidgetTester tester) =>
      renderOf(tester).debugLayer?.firstChild;

  String screenText(Terminal terminal) => [
    for (var y = 0; y < terminal.buffer.lines.length; y++)
      terminal.buffer.lines[y].getText(),
  ].join('\n');

  testWidgets('output while suspended reaches the buffer, paints nothing and '
      'asks for no frame; resuming repaints once', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 600);
    addTearDown(tester.view.reset);

    final gate = TerminalViewGate();
    final terminal = PaneTerminal(maxLines: 2000, viewGate: gate);
    var now = Duration.zero;
    final frameCallbacks = <VoidCallback>[];
    final coalescer = PtyOutputCoalescer(
      onData: terminal.write,
      viewGate: gate,
      budget: TerminalIngestBudget(clock: () => now),
      monotonicClock: () => now,
      scheduleFrameCallback: (callback) {
        frameCallbacks.add(callback);
        SchedulerBinding.instance.addPostFrameCallback((_) => callback());
      },
    );
    addTearDown(coalescer.dispose);

    await tester.pumpWidget(
      MaterialApp(home: TerminalView(terminal, padding: EdgeInsets.zero)),
    );
    await tester.pumpAndSettle();
    final before = paintedLayer(tester);
    expect(before, isNotNull, reason: 'the first frame paints the terminal');

    gate.suspend();
    var framesAsked = 0;
    for (var i = 0; i < 300; i++) {
      coalescer.add(utf8.encode('line $i\r\n'));
      now += const Duration(milliseconds: 5);
      await tester.binding.delayed(const Duration(milliseconds: 5));
      if (tester.binding.hasScheduledFrame) framesAsked++;
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));

    expect(framesAsked, 0, reason: 'no write may ask for a frame');
    expect(
      identical(paintedLayer(tester), before),
      isTrue,
      reason: 'nothing was painted',
    );

    expect(coalescer.pendingBytes, 0, reason: 'the watchdog drained it all');
    expect(screenText(terminal), contains('line 299'));
    expect(
      frameCallbacks,
      isEmpty,
      reason: 'no frame is coming, so no post-frame callback may wait on one',
    );
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'a write to a suspended terminal must not ask for a frame',
    );
    expect(renderOf(tester).debugNeedsPaint, isFalse);
    expect(renderOf(tester).debugNeedsLayout, isFalse);

    // Something else in the window draws a frame; the terminal stays put.
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(identical(paintedLayer(tester), before), isTrue);

    gate.resume();
    expect(tester.binding.hasScheduledFrame, isTrue);
    // A visible write of this many lines takes two frames too: the second
    // scrolls to the bottom without repainting.
    var frames = 0;
    var paints = 0;
    var last = before;
    while (tester.binding.hasScheduledFrame && frames < 10) {
      await tester.pump();
      frames++;
      final layer = paintedLayer(tester);
      if (!identical(layer, last)) paints++;
      last = layer;
    }
    expect(paints, 1, reason: 'resuming repaints once');
    expect(frames, lessThanOrEqualTo(2));

    tester.binding.scheduleFrame();
    await tester.pump();
    expect(identical(paintedLayer(tester), last), isTrue);
  });

  test('output listeners hear every write; views hear once, on resume', () {
    final gate = TerminalViewGate();
    final terminal = PaneTerminal(viewGate: gate);
    var output = 0;
    var views = 0;
    terminal.addOutputListener(() => output++);
    terminal.addListener(() => views++);

    terminal.write('visible');
    expect((output, views), (1, 1));

    gate.suspend();
    for (var i = 0; i < 10; i++) {
      terminal.write('hidden $i');
    }
    expect((output, views), (11, 1));

    gate.resume();
    expect((output, views), (11, 2));
    gate.resume();
    expect(views, 2, reason: 'nothing is owed twice');
  });

  test('a terminal disposed while owed is not told on resume', () {
    final gate = TerminalViewGate();
    final terminal = PaneTerminal(viewGate: gate);
    var views = 0;
    terminal.addListener(() => views++);

    gate.suspend();
    terminal.write('x');
    terminal.dispose();
    gate.resume();
    expect(views, 0);
  });

  test('a plain Terminal takes output listeners as ordinary listeners', () {
    final terminal = Terminal();
    var heard = 0;
    void listener() => heard++;
    terminal.addOutputListener(listener);
    terminal.write('a');
    terminal.removeOutputListener(listener);
    terminal.write('b');
    expect(heard, 1);
  });
}
