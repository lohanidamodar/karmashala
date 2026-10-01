import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// **Opens every settled run of tool calls, and every call in it, down to its
/// card.** A finished turn's calls fold to one `Worked for …` line (board N2,
/// `transcriptRows`): the line opens into one line per call, and a call's line
/// into its full card. Tests about what a card says reach it the way a reader
/// does — two clicks — rather than pretending the turn is still running.
Future<void> openToolRuns(WidgetTester tester) async {
  // The fold lines, then the calls they opened onto. An owner's first InkWell
  // is its own line; any under it belong to what it opened.
  for (final type in ['_ToolBatchTile', '_ToolCallLine']) {
    final owners = find
        .byWidgetPredicate((w) => w.runtimeType.toString() == type)
        .evaluate()
        .toList();
    for (final owner in owners) {
      final line = find
          .descendant(
            of: find.byElementPredicate((e) => identical(e, owner)),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.ensureVisible(line);
      await tester.tap(line);
      await tester.pump();
    }
  }
  await tester.pump();
}
