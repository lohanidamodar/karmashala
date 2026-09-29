import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'desktop_menu.dart';

/// A row's menu, built when it opens and not before: as a `List` a hundred-row
/// Explorer paid for eight hundred menu entries on every frame it rebuilt.
typedef RowMenuItemBuilder = List<PopupMenuEntry<String>> Function();

/// Shows a row's menu as a sheet titled [title]; resolves to the value picked.
typedef RowMenuSheetPresenter =
    Future<String?> Function(
      BuildContext context,
      String title,
      List<PopupMenuEntry<String>> items,
    );

/// Installed by an app that shows row menus as sheets under a thumb. Read only
/// at touch density, so a pointer surface keeps its popup.
class RowMenuSheetScope extends InheritedWidget {
  const RowMenuSheetScope({
    required this.present,
    required super.child,
    super.key,
  });

  final RowMenuSheetPresenter present;

  /// The presenter for [context], or null where menus stay popups.
  static RowMenuSheetPresenter? touchOf(BuildContext context) =>
      UiDensity.of(context).isTouch
      ? context.getInheritedWidgetOfExactType<RowMenuSheetScope>()?.present
      : null;

  @override
  bool updateShouldNotify(RowMenuSheetScope oldWidget) =>
      oldWidget.present != present;
}

/// Whether a pointer or the keyboard is on the row, as something to listen to
/// rather than `setState` — a row's builder is the entire card.
class RowInteraction extends ChangeNotifier {
  bool _hovered = false;
  bool _focused = false;

  bool get hovered => _hovered;
  bool get focused => _focused;

  /// Either — the two moments a row's menu should offer itself.
  bool get engaged => _hovered || _focused;

  set hovered(bool value) {
    if (_hovered == value) return;
    _hovered = value;
    notifyListeners();
  }

  set focused(bool value) {
    if (_focused == value) return;
    _focused = value;
    notifyListeners();
  }
}

/// Publishes one row's [RowInteraction] to the parts of it that care. An
/// `InheritedNotifier`, so a fire marks dependents and hands the child back.
class RowInteractionScope extends InheritedNotifier<RowInteraction> {
  const RowInteractionScope({
    required RowInteraction super.notifier,
    required super.child,
    super.key,
  });

  /// The row's state, subscribing [context] to it. Null outside a
  /// [RowContextMenu] — a button used on its own is simply always drawn.
  static RowInteraction? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<RowInteractionScope>()
      ?.notifier;
}

/// A row's actions are on the row: right-click, `Shift+F10`, the Menu key, a
/// named semantics action, and the `⋮`. Needs one focus stop inside the row.
class RowContextMenu extends StatefulWidget {
  const RowContextMenu({
    required this.menuLabel,
    required this.itemBuilder,
    required this.onSelected,
    required this.builder,
    super.key,
  });

  /// What the menu is called, in the same words [RowMenuButton]'s tooltip
  /// uses, so a screen reader and a pointer are told the same thing.
  final String menuLabel;

  /// Null for a row that has no menu — the hover state is still published, so
  /// a row can tint itself without owning a menu.
  final RowMenuItemBuilder? itemBuilder;

  final ValueChanged<String> onSelected;

  /// Builds the row. It is built once per real change and *not* on hover; see
  /// [RowInteraction].
  final WidgetBuilder builder;

  @override
  State<RowContextMenu> createState() => _RowContextMenuState();
}

class _RowContextMenuState extends State<RowContextMenu> {
  final _interaction = RowInteraction();

  @override
  void dispose() {
    _interaction.dispose();
    super.dispose();
  }

  /// The keyboard's way to the menu the mouse gets from a right-click, which is
  /// what makes revealing the button on hover honest rather than a regression.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || widget.itemBuilder == null) {
      return KeyEventResult.ignored;
    }
    final wanted =
        event.logicalKey == LogicalKeyboardKey.contextMenu ||
        (event.logicalKey == LogicalKeyboardKey.f10 &&
            HardwareKeyboard.instance.isShiftPressed);
    if (!wanted) return KeyEventResult.ignored;
    final context = node.context;
    if (context == null) return KeyEventResult.ignored;
    _openMenu(context);
    return KeyEventResult.handled;
  }

  /// Opens the menu against the row itself, anchored under its leading edge
  /// rather than at the pointer — on this path there is no pointer.
  Future<void> _openMenu(BuildContext context) async {
    final items = widget.itemBuilder?.call();
    if (items == null || items.isEmpty) return;
    if (RowMenuSheetScope.touchOf(context) case final present?) {
      final picked = await present(context, widget.menuLabel, items);
      if (picked != null && mounted) widget.onSelected(picked);
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final origin = box.localToGlobal(
      Offset(Insets.lg, box.size.height),
      ancestor: overlay,
    );
    final selected = await showDesktopMenuAt(context, origin, items);
    if (selected != null && mounted) widget.onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    Widget row = RowInteractionScope(
      notifier: _interaction,
      child: Builder(builder: widget.builder),
    );
    if (widget.itemBuilder case final itemBuilder?) {
      row = ContextMenuRegion(
        itemBuilder: itemBuilder,
        onSelected: widget.onSelected,
        child: row,
      );
      // The menu as a semantics action, not only a button under a pointer: a screen
      // reader's browse mode does not move focus, so that button is never there.
      final withMenu = row;
      row = Builder(
        builder: (context) => Semantics(
          customSemanticsActions: {
            CustomSemanticsAction(label: widget.menuLabel): () =>
                _openMenu(context),
          },
          child: withMenu,
        ),
      );
    }

    // No `setState` on either of these: they write to the notifier, which
    // rebuilds the two widgets that read it and nothing else.
    return MouseRegion(
      onEnter: (_) => _interaction.hovered = true,
      onExit: (_) => _interaction.hovered = false,
      // Not a focus stop of its own: it watches the row's *subtree*, so the row
      // still reads as focused while the keyboard is inside the menu button.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => _interaction.focused = focused,
        onKeyEvent: _onKey,
        child: row,
      ),
    );
  }
}

/// The `⋮` that teaches a row has a menu, in a slot the row always reserves.
/// It stays while its own menu is open — `showMenu` drops the result otherwise.
class RowMenuButton extends StatefulWidget {
  const RowMenuButton({
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
    super.key,
  });

  /// The button's accessible name. Say what the menu is *for* — Narrator reads
  /// this and nothing else about an icon-only control.
  final String tooltip;

  final RowMenuItemBuilder itemBuilder;
  final ValueChanged<String> onSelected;

  /// The square the button occupies, so it lands on the same centre-line
  /// whatever kind of row it is on.
  static double slotOf(UiDensity density) =>
      density.isTouch ? Touch.target : Chrome.icon + Insets.sm;

  /// The glyph inside that slot.
  static double glyphOf(UiDensity density) =>
      density.isTouch ? Touch.icon : Chrome.icon;

  @override
  State<RowMenuButton> createState() => _RowMenuButtonState();
}

class _RowMenuButtonState extends State<RowMenuButton> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    final slot = RowMenuButton.slotOf(density);
    // Density, never the window's width (CLAUDE.md §6): the companion runs
    // these rows on a tablet that is 1280px wide and still a thumb.
    final visible =
        density.isTouch ||
        _open ||
        (RowInteractionScope.maybeOf(context)?.engaged ?? true);
    if (RowMenuSheetScope.touchOf(context) case final present?) {
      return SizedBox(
        width: slot,
        height: slot,
        child: IconButton(
          tooltip: widget.tooltip,
          padding: EdgeInsets.zero,
          iconSize: RowMenuButton.glyphOf(density),
          icon: const Icon(AppIcons.dotsThreeVertical),
          onPressed: () async {
            final items = widget.itemBuilder();
            if (items.isEmpty) return;
            final picked = await present(context, widget.tooltip, items);
            if (picked != null && mounted) widget.onSelected(picked);
          },
        ),
      );
    }
    return SizedBox(
      width: slot,
      height: slot,
      child: visible
          ? PopupMenuButton<String>(
              tooltip: widget.tooltip,
              padding: EdgeInsets.zero,
              iconSize: RowMenuButton.glyphOf(density),
              icon: const Icon(AppIcons.dotsThreeVertical),
              constraints: const BoxConstraints(minWidth: 180),
              onOpened: () => setState(() => _open = true),
              onCanceled: () {
                if (mounted) setState(() => _open = false);
              },
              onSelected: (value) {
                if (mounted) setState(() => _open = false);
                widget.onSelected(value);
              },
              itemBuilder: (context) => widget.itemBuilder(),
            )
          : null,
    );
  }
}
