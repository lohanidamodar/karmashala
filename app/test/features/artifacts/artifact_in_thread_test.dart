import 'package:agent_cli/read.dart' show TranscriptMessage;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/artifacts/application/artifact_providers.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

import '../sessions/chat_cards_support.dart';
import 'artifacts_data_test.dart' show sampleArtifact;

/// A card at the turn that made it — in a terminal session's chat view as in
/// an ACP session's — and the ones with no row to hang on above the composer.
void main() {
  final t0 = DateTime.utc(2026, 10, 6, 9);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  final messages = [
    TranscriptMessage(role: 'user', text: 'Chart the coverage', at: at(0)),
    TranscriptMessage(role: 'agent', text: 'Here is the chart.', at: at(10)),
    TranscriptMessage(role: 'user', text: 'Thanks', at: at(20)),
    TranscriptMessage(role: 'agent', text: 'Anytime.', at: at(25)),
  ];

  for (final kind in ChatCardSession.values) {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets('${kind.name}: the card sits under the reply of its turn '
          'at $size', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final shown = sampleArtifact(at: at(5));
        final early = sampleArtifact(id: 'old', at: t0.subtract(
          const Duration(days: 1),
        ));
        final harness = await ChatCardHarness.open(
          kind,
          messages: messages,
          overrides: [
            sessionArtifactsProvider.overrideWith(
              (ref, id) async => <Artifact>[early, shown],
            ),
          ],
        );
        addTearDown(harness.dispose);
        await harness.pump(tester);

        final card = find.byKey(const ValueKey('artifact-card-a1'));
        expect(card, findsOneWidget);
        final reply = tester.getTopLeft(find.text('Here is the chart.'));
        final later = tester.getTopLeft(find.text('Thanks'));
        final placed = tester.getTopLeft(card);
        expect(placed.dy, greaterThan(reply.dy));
        expect(placed.dy, lessThan(later.dy));

        expect(find.byKey(const ValueKey('artifact-chip-old')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
