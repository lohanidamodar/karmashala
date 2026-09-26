import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/explorer/domain/explorer_section.dart';
import 'package:karmashala_projects/karmashala_projects.dart';

/// The sections the store seeds (migration v29, tested in
/// `packages/karmashala_store/test/explorer_sections_migration_test.dart`),
/// as this build reads them.
void main() {
  StoredSection seeded(String id, String name, String kind, int position) =>
      StoredSection(
        id: id,
        name: name,
        kind: kind,
        position: position,
        collapsed: true,
      );

  test('every seeded section is one this build reads', () {
    final sections = [
      seeded('section-pinned', 'Pinned', 'pinned', 0),
      seeded('section-checks-failing', 'Checks failing', 'checksFailing', 1),
      seeded('section-awaiting-input', 'Awaiting input', 'awaitingInput', 2),
      seeded(
        'section-ended-in-failure',
        'Ended in failure',
        'endedInFailure',
        3,
      ),
    ].map(ExplorerSection.fromStored).toList();

    expect(sections, everyElement(isNotNull));
    expect(sections.first!.id, kPinnedSectionId);
    expect(sections.first!.rule, isA<PinnedRule>());
    expect(sections.first!.isEditable, isFalse);
  });

  test(
    'a section whose rule this build cannot read is skipped, not guessed',
    () {
      // What a downgrade looks like: a newer build wrote a rule kind this one
      // has no code for. Drawing it as a manual group would silently strip the
      // rule the moment the user renamed it.
      const future = StoredSection(
        id: 'future',
        name: 'From tomorrow',
        kind: 'blocksMerge',
        position: 99,
      );
      expect(ExplorerSection.fromStored(future), isNull);
    },
  );
}
