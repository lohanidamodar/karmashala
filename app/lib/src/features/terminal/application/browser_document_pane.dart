import 'package:karmashala_terminal_core/geometry.dart'
    show kDocumentPanePrefix;

/// **The browser preview as a workbench pane** — the context panel's Browser
/// surface, opened beside a terminal from **Split ▾** (spec §4). One id, not
/// one per page: there is one attached Chrome and one controller driving it,
/// so a second pane would be a second view of the same browser, not another.
///
/// Here rather than beside the other document ids in `karmashala_terminal_core`
/// because the page it draws belongs to the app; the id is still a document
/// id, so persistence and restore carry it like any other.
const String kBrowserPaneId = '${kDocumentPanePrefix}browser';

/// Whether [paneId] is the browser preview.
bool isBrowserPane(String paneId) => paneId == kBrowserPaneId;
