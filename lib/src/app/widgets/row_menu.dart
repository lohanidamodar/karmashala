import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../theme/app_icons.dart';
import '../theme/design_tokens.dart';
import 'desktop_menu.dart';

/// The one rule every list row in the app follows:
///
/// > **A row's actions are on the row.** Right-click opens them, `Shift+F10`
/// > and the Menu key open them from the keyboard, a screen reader finds them
/// > as a named action, and the `⋮` that duplicates all four is drawn when a
/// > pointer or the keyboard is on the row — or always, on a touch surface,
/// > where there is no right-click and no hover to reveal it with.
///
/// The Explorer arrived at this first and this is that contract, lifted out so
/// the Todos, Notes and Inbox panes cannot answer the question differently.
/// Those panes each drew a permanent button per row and nothing else: the
/// owner's report was that "it's difficult and not good UX to have only an
/// action button", and the answer is not to delete the button but to stop it
/// being the *only* way in.
///
/// ## What a call site still owes
///
/// **A focusable descendant.** This wraps the row in a `Focus` that watches
/// the subtree rather than taking a stop of its own — a hundred rows must not
/// cost a hundred extra tab stops — so `Shift+F10` reaches it only while
/// something *inside* the row has focus. Every row that uses this therefore
/// needs at least one focus stop: a checkbox, a tappable body, a button that
/// is not disabled. A card whose only control is a disabled button is
/// unreachable, and the menu on it would be a menu no keyboard can open.
///
/// See [RowMenuButton] for the button half, and for the bug that makes hiding
/// it harder than it looks.
class RowContextMenu extends StatefulWidget {
  const RowContextMenu({
    required this.menuLabel,
    required this.menuItems,
    required this.onSelected,
    required this.builder,
    super.key,
  });

  /// What the menu is called, in the same words [RowMenuButton]'s tooltip
  /// uses, so a screen reader and a pointer are told the same thing.
  final String menuLabel;

  final List<PopupMenuEntry<String>> menuItems;
  final ValueChanged<String> onSelected;

  /// Builds the row. `menuVisible` says whether this is a moment the `⋮`
  /// should be drawn — pass it straight to [RowMenuButton.visible].
  final Widget Function(BuildContext context, bool menuVisible) builder;

  @override
  State<RowContextMenu> createState() => _RowContextMenuState();
}

class _RowContextMenuState extends State<RowContextMenu> {
  bool _hovered = false;
  bool _focused = false;

  /// The keyboard's way to the menu the mouse gets from a right-click.
  ///
  /// `Shift+F10` and the Menu key are the platform convention, and they are
  /// what makes revealing the button on hover honest rather than an
  /// accessibility regression (CLAUDE.md §5: *preserve keyboard navigation*).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || widget.menuItems.isEmpty) {
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

  /// Opens the menu against the row itself.
  ///
  /// Anchored under the row's leading edge rather than at the pointer, because
  /// on this path there is no pointer.
  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) return;
    final origin = box.localToGlobal(
      Offset(Insets.lg, box.size.height),
      ancestor: overlay,
    );
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(origin.dx, origin.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: widget.menuItems,
    );
    if (selected != null && mounted) widget.onSelected(selected);
  }

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    // A thumb has neither a hover nor a right-click, so on a touch surface the
    // button is the only way to the menu and is always drawn. A pointer has
    // both. Density, never the window's width (CLAUDE.md §6) — the companion
    // runs these panes on a tablet that is 1280px wide and still a thumb.
    final menuVisible = density.isTouch || _hovered || _focused;

    Widget row = widget.builder(context, menuVisible);
    if (widget.menuItems.isNotEmpty) {
      row = ContextMenuRegion(
        menuItems: widget.menuItems,
        onSelected: widget.onSelected,
        child: row,
      );
      // The menu as a semantics action on the row, not only as a button that
      // appears under a pointer. A screen reader's browse mode does not move
      // Flutter's focus, so a hover-revealed button is a button that, for a
      // screen reader, is never there at all.
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

    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      // Not a focus stop of its own: it watches the row's *subtree*, so the
      // row still reads as focused while the keyboard is inside the menu
      // button it just revealed — otherwise tabbing to that button would hide
      // it out from under the keyboard.
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (_focused != focused) setState(() => _focused = focused);
        },
        onKeyEvent: _onKey,
        child: row,
      ),
    );
  }
}

/// The `⋮` that teaches a row has a menu, in a slot the row always reserves.
///
/// [visible] false keeps the slot and draws nothing in it. That is deliberate
/// twice over: the row's text must not reflow when a pointer arrives, and an
/// absent button is absent from the focus ring too.
///
/// **It stays while its own menu is open, and that is not a nicety.** Opening
/// the menu pushes a route whose modal barrier takes both the hover and the
/// focus off the row in the same frame, so a button drawn only for a hovering
/// pointer unmounts itself underneath its own menu — and `showMenu` drops the
/// result when the button that opened it is gone. In the Explorer this
/// silently discarded every choice on every row for mouse users; right-click
/// and `Shift+F10` kept working, which is exactly why the tests did not see
/// it. `_open` is the guard, and it is why this is a `StatefulWidget` for what
/// looks like a one-line build.
class RowMenuButton extends StatefulWidget {
  const RowMenuButton({
    required this.visible,
    required this.tooltip,
    required this.items,
    required this.onSelected,
    super.key,
  });

  final bool visible;

  /// The button's accessible name. Say what the menu is *for* — Narrator reads
  /// this and nothing else about an icon-only control.
  final String tooltip;

  final List<PopupMenuEntry<String>> items;
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
    return SizedBox(
      width: slot,
      height: slot,
      child: widget.visible || _open
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
              itemBuilder: (context) => widget.items,
            )
          : null,
    );
  }
}
