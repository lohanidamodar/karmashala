import 'package:flutter/material.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/capabilities/capabilities.dart';
import 'settings_catalog.dart';

export 'settings_catalog.dart'
    show SettingsAnchor, SettingsGroup, SettingsSectionId, SettingsTarget;

/// The settings page list: a search box over the pages, grouped. While the box holds
/// a query the list narrows to the pages it matches and lists the settings it
/// found under each. Up/Down move the page selection while a row has focus;
/// the search box keeps its own arrows.
class SettingsNav extends ConsumerStatefulWidget {
  const SettingsNav({
    required this.selected,
    required this.onSelect,
    this.onOpen,
    super.key,
  });

  /// The highlighted page, or null (the phone list before one is opened).
  final SettingsSectionId? selected;

  final ValueChanged<SettingsSectionId> onSelect;

  /// Opens a search hit at its section; without it a hit opens its page.
  final ValueChanged<SettingsTarget>? onOpen;

  @override
  ConsumerState<SettingsNav> createState() => _SettingsNavState();
}

class _SettingsNavState extends ConsumerState<SettingsNav> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<SettingsSectionId> get _visible => [
    for (final page in SettingsSectionId.values)
      if (page.matches(_filter.text, caps: ref.read(capabilitiesProvider)))
        page,
  ];

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final pages = _visible;
    if (pages.isEmpty) return KeyEventResult.ignored;
    final step = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (step == 0) return KeyEventResult.ignored;
    final index = widget.selected == null
        ? -1
        : pages.indexOf(widget.selected!);
    final next = index == -1
        ? (step > 0 ? 0 : pages.length - 1)
        : (index + step).clamp(0, pages.length - 1);
    if (next != index) widget.onSelect(pages[next]);
    return KeyEventResult.handled;
  }

  void _open(SettingsEntry entry) {
    final open = widget.onOpen;
    if (open == null) {
      widget.onSelect(entry.page);
    } else {
      open(SettingsTarget.anchor(entry.anchor));
    }
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(capabilitiesProvider);
    final pages = _visible;
    final hits = searchSettings(_filter.text, caps: caps);
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    const fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
      borderSide: BorderSide.none,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Board N5: a 28 px search box on the `raised` tone, no outline, over
        // the grouped list, all inside the column's 12 × 8 padding.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.sm,
            Insets.md,
            Insets.sm,
            Insets.xs,
          ),
          child: SearchField(
            controller: _filter,
            onChanged: (_) => setState(() {}),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: tones.raised,
              border: fieldBorder,
              enabledBorder: fieldBorder,
              focusedBorder: fieldBorder.copyWith(
                borderSide: BorderSide(color: theme.colorScheme.primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Insets.sm,
                vertical: Insets.xs + Insets.xxs,
              ),
              hintText: 'Search settings',
              hintStyle: theme.textTheme.bodySmall?.copyWith(color: muted),
              prefixIcon: Icon(
                AppIcons.magnifyingGlass,
                size: Chrome.iconSmall,
                color: muted,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: Chrome.row + 2,
              ),
            ),
          ),
        ),
        Expanded(
          child: Focus(
            // A key handler, not a focus stop: arrows bubble up to it.
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onListKey,
            // Widget order, not reading order: the page list scrolls in a short
            // window, and reading order re-sorts the rows as they move, so Tab
            // would come back to a row it had already visited.
            child: FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.sm,
                  0,
                  Insets.sm,
                  Insets.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final group in SettingsGroup.values)
                      if (pages.any((p) => p.group == group)) ...[
                        SettingsNavGroupHeader(group: group),
                        for (final page in pages)
                          if (page.group == group) ...[
                            _NavRow(
                              page: page,
                              selected: page == widget.selected,
                              onTap: () => widget.onSelect(page),
                            ),
                            for (final hit in hits)
                              // The page row already says what a same-named
                              // setting would.
                              if (hit.page == page && hit.label != page.label)
                                SettingsSearchHitRow(
                                  entry: hit,
                                  onTap: () => _open(hit),
                                ),
                          ],
                      ],
                    if (pages.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(Insets.md),
                        child: Text(
                          'Nothing matches.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A group's name above its pages in the page list.
class SettingsNavGroupHeader extends StatelessWidget {
  const SettingsNavGroupHeader({required this.group, super.key});

  final SettingsGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Board `.grp`: 10.5, semibold, tracked, uppercase, dim, 12 px above.
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Insets.md - Insets.xxs,
          Insets.md,
          Insets.md - Insets.xxs,
          Insets.xs,
        ),
        child: Text(
          group.label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall
              ?.merge(Chrome.groupLabel)
              .copyWith(
                fontSize: TypeSizes.micro,
                letterSpacing: 0.5,
                color: theme.colorScheme.outline,
              ),
        ),
      ),
    );
  }
}

/// One setting a search found: its label, and the section it lives in.
class SettingsSearchHitRow extends StatelessWidget {
  const SettingsSearchHitRow({
    required this.entry,
    required this.onTap,
    super.key,
  });

  final SettingsEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '${entry.label}, in ${entry.page.label}, ${entry.anchor.title}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: Insets.xxs),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.xl,
              Insets.xs,
              Insets.sm,
              Insets.xs,
            ),
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (entry.anchor.title != entry.label)
                    Text(
                      entry.anchor.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.page,
    required this.selected,
    required this.onTap,
  });

  final SettingsSectionId page;
  final bool selected;
  final VoidCallback onTap;

  /// Board `.nav`: a 28 px row, text only — no icon — muted until it is the
  /// page on screen, which takes the `selected` tone and the full ink; the
  /// `hover` tone under the pointer.
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: page.label,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Insets.hair),
        child: Material(
          color: selected ? tones.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            hoverColor: tones.hover,
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: Chrome.row + 2),
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md - Insets.xxs,
              ),
              alignment: Alignment.centerLeft,
              child: ExcludeSemantics(
                child: Text(
                  page.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: TypeSizes.field,
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
