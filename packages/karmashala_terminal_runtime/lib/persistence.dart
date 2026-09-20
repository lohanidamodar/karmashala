/// What a workbench keeps between runs: the stored pane rows and the layout
/// they rebuild, and the named presets a shape can be saved as. Both take an
/// `AppDatabase`; their providers stay in the app.
library;

export 'src/terminal_layout_dao.dart';
export 'src/terminal_preset_dao.dart';
