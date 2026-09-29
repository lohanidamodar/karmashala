import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/session_context.dart';
import 'package:karmashala/src/features/media/application/session_media_providers.dart';
import 'package:karmashala/src/features/media/domain/session_media_item.dart';
import 'package:karmashala/src/features/media/presentation/session_media_panel.dart';
import 'package:karmashala_ui/primitives.dart';

void main() {
  testWidgets('a session still being read waits on the house spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          panelSessionIdProvider.overrideWithValue('s1'),
          sessionMediaProvider.overrideWith(
            (ref, id) => const Stream<List<SessionMediaItem>>.empty(),
          ),
          sessionMediaHostPathProvider.overrideWith((ref, id) => null),
        ],
        child: const MaterialApp(home: Scaffold(body: SessionMediaPanel())),
      ),
    );
    await tester.pump();
    expect(find.byType(InlineSpinner), findsOneWidget);
  });
}
