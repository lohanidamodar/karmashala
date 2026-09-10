/// What a drag in the terminal is carrying: a whole tab out of the strip along
/// the top, or one pane out of a region's own header. `Draggable<String>` could
/// not tell a tab id from a pane id, and the ids are opaque, so a drop target
/// that guessed would one day guess wrong, silently.
sealed class TerminalDrag {
  const TerminalDrag();
}

/// A whole tab, dragged from the workbench strip.
class TabDrag extends TerminalDrag {
  const TabDrag(this.tabId);

  final String tabId;
}

/// One pane, dragged from the header of the region it is in.
class PaneDrag extends TerminalDrag {
  const PaneDrag(this.paneId);

  final String paneId;
}
