/// The host's file and directory dialogs, behind the announcement every
/// "Browse…" makes. One library because [PickerQuiet] is a singleton: a second
/// copy would leave the registrants of the first running under a live dialog.
library;

export 'src/file_picking.dart';
