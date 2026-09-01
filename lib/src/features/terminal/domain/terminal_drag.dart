/// What a drag in the terminal is carrying.
///
/// Two things can be picked up, and they land in the same places: a whole
/// workspace tab out of the strip along the top, and one pane out of a region's
/// own header. `Draggable<String>` could not tell a tab id from a pane id, and
/// a drop target that guesses is a drop target that will one day guess wrong —
/// the ids are opaque, so the mistake would be silent.
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
