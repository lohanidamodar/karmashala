import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/theme.dart';

/// What a list that moves focus by key needs of a row: a stop it can be handed,
/// and a row that says whether it is open.
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(body: child),
  );

  Widget row(String title, {bool? expanded, VoidCallback? onTap}) =>
      ExplorerRow(
        kind: ExplorerRowKind.project,
        depth: 0,
        selected: false,
        expanded: expanded,
        onTap: onTap ?? () {},
        builder: (context) => Text(title),
      );

  testWidgets('a row takes the focus node handed down to it', (tester) async {
    final stop = FocusNode();
    addTearDown(stop.dispose);
    await tester.pumpWidget(
      host(
        Column(
          children: [
            row('first'),
            ExplorerRowFocus(node: stop, child: row('second')),
          ],
        ),
      ),
    );

    stop.requestFocus();
    await tester.pump();

    expect(stop.hasPrimaryFocus, isTrue);
    expect(Focus.of(tester.element(find.text('second'))), stop);
    expect(
      Focus.of(tester.element(find.text('first'))),
      isNot(stop),
      reason: 'a row handed nothing makes its own, as ever',
    );
  });

  testWidgets('a row with no verb is not a stop, handed a node or not', (
    tester,
  ) async {
    final stop = FocusNode();
    addTearDown(stop.dispose);
    await tester.pumpWidget(
      host(
        ExplorerRowFocus(
          node: stop,
          child: ExplorerRow(
            kind: ExplorerRowKind.terminal,
            depth: 0,
            selected: false,
            builder: (context) => const Text('ended'),
          ),
        ),
      ),
    );

    stop.requestFocus();
    await tester.pump();

    expect(stop.hasFocus, isFalse);
  });

  testWidgets('a row that folds says which way it is, and one that does not '
      'says nothing', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        Column(
          children: [
            row('open', expanded: true),
            row('folded', expanded: false),
            row('leaf'),
          ],
        ),
      ),
    );

    Tristate said(String title) =>
        tester.getSemantics(find.text(title)).flagsCollection.isExpanded;
    expect(said('open'), Tristate.isTrue);
    expect(said('folded'), Tristate.isFalse);
    expect(said('leaf'), Tristate.none);
    handle.dispose();
  });
}
