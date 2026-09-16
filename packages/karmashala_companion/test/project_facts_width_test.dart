import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_companion/screens.dart';
import 'package:karmashala_remote/companion.dart';

import 'companion_test_support.dart';

/// The project screen's facts line: an environment badge beside the path must
/// give way on a narrow phone, as the project card's own path line does.
void main() {
  for (final scale in const [1.0, 1.3, 2.0]) {
    testWidgets('a long environment badge fits 320px at ${scale}x', (
      tester,
    ) async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      try {
        await pumpPhone(
          tester,
          size: const Size(320, 640),
          textScale: scale,
          gateway: FakeCompanionGateway.paired(
            sessions: [
              summary(
                's1',
                project: 'alpha',
                projectId: 'p1',
                projectPath: '/home/someone/work/alpha',
                environmentId: 'ssh:h1',
                environmentBadge: 'build-box.internal.example',
              ),
            ],
          ),
          home: const ProjectSessionsScreen(projectKey: 'p1'),
        );
      } finally {
        FlutterError.onError = previous;
      }

      expect(
        errors.map((e) => '${e.exception}'),
        isNot(contains(contains('overflowed'))),
      );
      expect(
        find.text('build-box.internal.example', skipOffstage: false),
        findsWidgets,
      );
    });
  }
}
