import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/application/explorer_sections.dart';
import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:karmashala/src/features/explorer/presentation/section_membership_dialog.dart';
import 'package:karmashala_ui/theme.dart';

import '../../support/window_matrix.dart';

/// Fourteen hand-filled sections, one of which already holds the session.
class _ManySections extends ExplorerSectionsController {
  @override
  List<ExplorerSection> build() => [
    for (var i = 0; i < 14; i++)
      ExplorerSection(
        id: 'section-$i',
        name: 'Manual section $i',
        rule: const ManualRule(),
        position: i,
        members: i == 3 ? const {'s1'} : const {},
      ),
  ];
}

/// "Add to section" lists every manual section, so a long list has to scroll
/// inside the smallest window and Tab has to reach the last one.
void main() {
  testWidgets('the section membership dialog, with fourteen sections', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [explorerSectionsProvider.overrideWith(_ManySections.new)],
    );
    addTearDown(container.dispose);

    await expectSurvivesWindowMatrix(
      tester,
      build: () => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          debugShowCheckedModeBanner: false,
          home: const SectionMembershipDialog(sessionId: 's1'),
        ),
      ),
      because: 'a long list of hand-filled sections',
    );
  });
}
