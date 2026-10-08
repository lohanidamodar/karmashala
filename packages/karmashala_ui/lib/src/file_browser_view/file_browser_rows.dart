// Source bar, filter field, entry and pin rows, header and messages.

part of '../file_browser_view.dart';

/// Which machine is being browsed. Drawn only when there is a choice, so a
/// workspace with nothing but this computer keeps the plain dialog.
class _SourceBar extends StatelessWidget {
  const _SourceBar({
    required this.sources,
    required this.current,
    required this.onChanged,
  });

  final List<BrowseSource> sources;
  final BrowseSource? current;
  final ValueChanged<BrowseSource>? onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    // Keyed by the machine, so a switch made in code redraws the field.
    key: ValueKey(current?.id),
    initialValue: current?.id ?? sources.first.id,
    isExpanded: true,
    decoration: const InputDecoration(isDense: true, labelText: 'Look in'),
    items: [
      for (final source in sources)
        DropdownMenuItem(
          value: source.id,
          child: Row(
            children: [
              Icon(
                source.local ? AppIcons.stack : AppIcons.globe,
                size: Chrome.icon,
              ),
              const SizedBox(width: Insets.sm),
              Flexible(
                child: Text(source.label, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
    ],
    onChanged: onChanged == null
        ? null
        : (id) {
            for (final source in sources) {
              if (source.id == id && source.id != current?.id) {
                onChanged!(source);
                return;
              }
            }
          },
  );
}

class _FilterField extends StatelessWidget {
  const _FilterField({
    required this.controller,
    required this.onChanged,
    required this.hint,
    required this.autofocus,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hint;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => SearchField(
    controller: controller,
    autofocus: autofocus,
    decoration: InputDecoration(
      isDense: true,
      prefixIcon: const Icon(AppIcons.magnifyingGlass, size: Chrome.icon),
      hintText: hint,
    ),
    onChanged: onChanged,
  );
}

/// One listed entry. Right-click, `Shift+F10` and the Menu key open its menu
/// ([RowContextMenu]); a long press does under a thumb.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    required this.touch,
    required this.manage,
    required this.pinned,
    required this.menuItems,
    required this.onMenuPicked,
    required this.onLongPress,
    required this.subtitle,
    required this.openFileIcon,
    required this.openFileTooltip,
    required this.menuButton,
    super.key,
  });

  final BrowsedEntry entry;
  final bool selected;
  final VoidCallback onTap;

  /// The trailing button: into a folder, or a file into the editor. In a
  /// picker the row itself opens a folder, so the caret is only a sign.
  final VoidCallback? onOpen;

  /// A thumb's row: [Touch.target] tall.
  final bool touch;

  /// The Files tab's row: a tap selects, the caret opens.
  final bool manage;
  final bool pinned;
  final RowMenuItemBuilder menuItems;
  final ValueChanged<String> onMenuPicked;
  final void Function(BuildContext context, Offset at) onLongPress;
  final String? subtitle;
  final IconData openFileIcon;
  final String openFileTooltip;

  /// A `⋮` that teaches the row has a menu: where the menu holds more than a
  /// picker's Open and Add to quick access.
  final bool menuButton;

  // No double-tap-to-open: a double-tap recognizer makes every *single* tap
  // wait out its timeout before it resolves, so selecting a file would lag by
  // 300 ms to save one click on Choose.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final compact = touch ? null : VisualDensity.compact;
    final trailing = <Widget>[
      if (entry.isDirectory && manage && onOpen != null)
        IconButton(
          tooltip: 'Open',
          visualDensity: compact,
          icon: const Icon(AppIcons.caretRight, size: Chrome.iconSmall),
          onPressed: onOpen,
        )
      else if (entry.isDirectory && !menuButton)
        Icon(
          AppIcons.caretRight,
          size: Chrome.icon,
          color: scheme.onSurfaceVariant,
        ),
      if (!entry.isDirectory && onOpen != null)
        IconButton(
          tooltip: openFileTooltip,
          visualDensity: compact,
          icon: Icon(openFileIcon, size: Chrome.iconSmall),
          onPressed: onOpen,
        ),
      if (menuButton && entry.readable)
        RowMenuButton(
          tooltip: 'More for ${entry.name}',
          itemBuilder: menuItems,
          onSelected: onMenuPicked,
        ),
    ];
    final iconColor = !entry.readable
        ? scheme.outline
        : entry.isDirectory
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return RowContextMenu(
      menuLabel: '${entry.name} actions',
      itemBuilder: menuItems,
      onSelected: onMenuPicked,
      builder: (rowContext) => GestureDetector(
        onLongPressStart: (details) =>
            onLongPress(rowContext, details.globalPosition),
        child: ListTile(
          dense: !touch,
          minTileHeight: touch ? Touch.target : null,
          selected: selected,
          selectedTileColor: StateLayers.selected(scheme),
          leading: Icon(
            entry.isDirectory
                ? (pinned ? AppIcons.pushPinFill : AppIcons.folder)
                : entry.isLink
                ? AppIcons.linkSimple
                : AppIcons.article,
            size: Chrome.icon,
            color: iconColor,
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle == null
              ? null
              : Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
          onTap: entry.readable ? onTap : null,
          trailing: trailing.isEmpty
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: trailing),
        ),
      ),
    );
  }
}

class _PinTile extends StatelessWidget {
  const _PinTile({
    required this.pin,
    required this.selected,
    required this.onTap,
    required this.menu,
    required this.menuItems,
    required this.onMenuPicked,
  });

  final PinnedFolder pin;
  final bool selected;
  final VoidCallback onTap;
  final void Function(Offset at) menu;
  final RowMenuItemBuilder menuItems;
  final ValueChanged<String> onMenuPicked;

  @override
  Widget build(BuildContext context) => RowContextMenu(
    menuLabel: '${pin.name} in quick access',
    itemBuilder: menuItems,
    onSelected: onMenuPicked,
    builder: (_) => GestureDetector(
      onLongPressStart: (details) => menu(details.globalPosition),
      child: Tooltip(
        message: pin.path,
        child: ListTile(
          dense: true,
          selected: selected,
          leading: const Icon(AppIcons.pushPinFill, size: Chrome.icon),
          title: Text(pin.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: onTap,
        ),
      ),
    ),
  );
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader(this.text, {this.minor = false});

  final String text;
  final bool minor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Insets.md,
        minor ? Insets.xs : Insets.sm,
        Insets.md,
        Insets.xs,
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: minor ? null : FontWeight.w600,
        ),
      ),
    );
  }
}

/// Pins this browser cannot open, said rather than dropped: a folder pinned
/// on a host this picker does not look at is still pinned.
class _ElsewhereNote extends StatelessWidget {
  const _ElsewhereNote({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.md,
        Insets.xs,
        Insets.md,
        Insets.sm,
      ),
      child: Text(
        count == 1
            ? '1 more on a machine this browser does not look at'
            : '$count more on machines this browser does not look at',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Insets.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: Chrome.iconHero,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: Insets.sm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
