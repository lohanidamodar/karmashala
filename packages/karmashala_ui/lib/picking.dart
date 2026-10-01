/// The host's file and directory dialogs, behind the announcement every
/// "Browse…" makes. One library because [PickerQuiet] is a singleton: a second
/// copy would leave the registrants of the first running under a live dialog.
library;

export 'src/file_browser_controller.dart'
    show BrowsePlace, FileBrowserController;
export 'src/file_browser_view.dart'
    show FileBrowserRowAction, FileBrowserView, describeBrowsedSize;
export 'src/file_name_dialog.dart';
export 'src/file_picking.dart';
export 'src/file_sources_picking.dart';
export 'src/hidden_files.dart' show HiddenFilesPreference, isHiddenEntry;
export 'src/hidden_files_chip.dart';
export 'src/quick_access.dart';
