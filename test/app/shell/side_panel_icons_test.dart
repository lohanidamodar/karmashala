import 'package:chitragupta/src/app/shell/side_panel.dart';
import 'package:chitragupta/src/app/shell/side_panel_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rail is seven unlabelled glyphs in a 34px column, so two that look alike
/// are two surfaces the user cannot tell apart.
///
/// The owner reported exactly that: "I still don't see the worktree viewer".
/// Inbox was `warning-circle` and Info was `info` — a circle with a `!` above a
/// circle with an `i`, indistinguishable at 16px. A codepoint check cannot see
/// that two glyphs *look* alike, but it can see the case that actually happens:
/// two entries reaching for the same constant.
void main() {
  test('every rail surface has its own glyph', () {
    final byIcon = <int, List<String>>{};
    for (final surface in SidePanelSurface.values) {
      byIcon
          .putIfAbsent(SidePanel.iconFor(surface).codePoint, () => [])
          .add(surface.label);
    }
    final shared = [
      for (final entry in byIcon.entries)
        if (entry.value.length > 1) entry.value,
    ];
    expect(shared, isEmpty, reason: 'these surfaces share a glyph: $shared');
  });

  test('every rail glyph is a Phosphor glyph from picons', () {
    // One Material `Icons.smartphone` had been sitting in the rail since the
    // device pane was added; at 16px beside six Phosphor strokes it is the one
    // that looks wrong.
    for (final surface in SidePanelSurface.values) {
      final icon = SidePanel.iconFor(surface);
      expect(
        icon.fontPackage,
        'picons',
        reason: '${surface.label} is not a Phosphor glyph',
      );
    }
  });

  test('the surface that holds branches and worktrees says so', () {
    // "Info" named nothing, so nobody opened it.
    expect(SidePanelSurface.repository.label, 'Repository');
  });
}
