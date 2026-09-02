export 'src/terminal_view.dart';
export 'src/ui/controller.dart';
export 'src/ui/cursor_type.dart';
// Exported (upstream does not) so the app's perf/pixel-equivalence harness can
// drive the painter directly. See VENDORED.md.
export 'src/ui/painter.dart';
// Likewise: `test/terminal/perf/paint_layout_cost_test.dart` reaches the
// render object to prove `paint` refills the painter's per-frame layout budget.
export 'src/ui/render.dart';
export 'src/ui/keyboard_visibility.dart';
export 'src/ui/pointer_input.dart';
export 'src/ui/selection_mode.dart';
export 'src/ui/shortcut/shortcuts.dart';
export 'src/ui/terminal_text_style.dart';
export 'src/ui/terminal_theme.dart';
export 'src/ui/themes.dart';
