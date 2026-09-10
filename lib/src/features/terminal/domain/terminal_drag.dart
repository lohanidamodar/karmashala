/// What a drag in the terminal is carrying: a whole tab, or one pane.
/// `Draggable<String>` could not tell their opaque ids apart.
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
