import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/app_shell.dart';
import '../../../core/capabilities/capabilities.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import 'settings_layout.dart';
import 'settings_nav.dart';
import 'settings_page_body.dart';

/// Settings as a master-detail page, drilling down to one section at compact
/// widths. Mounted as a workbench tab ([SettingsTabView]), never pushed: a
/// route would cover the menu bar, the tab strip and the panes it configures.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({
    this.initialSection,
    this.initialAnchor,
    this.onSectionChanged,
    super.key,
  });

  /// The page to land on — how menu items and quick open deep-link. Changing
  /// it moves a Settings tab that is already open onto that page.
  final SettingsSectionId? initialSection;

  /// The section of [initialSection] to scroll to, or null for the page's top.
  final SettingsAnchor? initialAnchor;

  /// Told which section the user moved to, and `null` when a compact window
  /// backs out — how [SettingsTabView] keeps the page outside a dropped `State`.
  final ValueChanged<SettingsSectionId?>? onSectionChanged;

  /// The section list's width beside the page, in the two-column layout (the
  /// approved board's 224).
  static const navWidth = 224.0;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late SettingsSectionId _selected =
      widget.initialAnchor?.page ??
      widget.initialSection ??
      SettingsSectionId.values.first;

  /// Whether the compact layout shows a page, under its sticky picker (spec
  /// §6), rather than the searchable list the picker's Search opens.
  late bool _openOnCompact = true;

  /// One key per section of the page on screen, handed out by
  /// [SettingsAnchorScope]; replaced with the page.
  var _anchorKeys = <SettingsAnchor, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _revealAfterBuild(widget.initialAnchor);
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSection == oldWidget.initialSection &&
        widget.initialAnchor == oldWidget.initialAnchor) {
      return;
    }
    // A deep link at a screen already up; null is the compact list.
    final page = widget.initialAnchor?.page ?? widget.initialSection;
    if (page != _selected) _anchorKeys = {};
    _selected = page ?? _selected;
    _openOnCompact = page != null;
    _revealAfterBuild(widget.initialAnchor);
  }

  void _select(SettingsSectionId section) => _go(SettingsTarget(section));

  void _go(SettingsTarget target) {
    setState(() {
      if (target.page != _selected) _anchorKeys = {};
      _selected = target.page;
      _openOnCompact = true;
    });
    widget.onSectionChanged?.call(target.page);
    _revealAfterBuild(target.anchor);
  }

  SettingsAnchor? _pendingReveal;
  double? _lastRevealTop;
  int _revealFrames = 0;

  /// Scrolls [anchor]'s section to the top once the page holding it is built,
  /// and again on later frames until it stops moving: sections that load
  /// asynchronously grow above it after the first scroll. A scroll by the
  /// user ends it.
  void _revealAfterBuild(SettingsAnchor? anchor) {
    if (anchor == null) return;
    _pendingReveal = anchor;
    _lastRevealTop = null;
    _revealFrames = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(anchor));
  }

  void _reveal(SettingsAnchor anchor) {
    if (!mounted || _pendingReveal != anchor) return;
    final context = _anchorKeys[anchor]?.currentContext;
    final box = context?.findRenderObject();
    if (context == null || box is! RenderBox || !box.attached) {
      _pendingReveal = null;
      return;
    }
    Scrollable.ensureVisible(context);
    final top = box.localToGlobal(Offset.zero).dy;
    if (top == _lastRevealTop || ++_revealFrames >= _maxRevealFrames) {
      _pendingReveal = null;
      return;
    }
    _lastRevealTop = top;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(anchor));
  }

  static const _maxRevealFrames = 30;

  void _backToList() {
    setState(() => _openOnCompact = false);
    widget.onSectionChanged?.call(null);
  }

  @override
  Widget build(BuildContext context) {
    final tones = SurfaceTones.of(context);
    // A link to a page this client hides (Keyboard, on a phone) lands on the
    // first page it shows.
    final caps = ref.watch(capabilitiesProvider);
    final selected = _selected.shownWith(caps)
        ? _selected
        : SettingsSectionId.values.firstWhere(
            (page) => page.shownWith(caps),
            orElse: () => _selected,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = ShellWidth.of(constraints.maxWidth).isCompact;
        final showingSection = !compact || _openOnCompact;
        // No header of its own (board N5): the workbench tab already says
        // "Settings", and the page says which page it is. The page sits on
        // the terminal's surface, like any tab's content.
        return Scaffold(
          backgroundColor: tones.term,
          // Each scrolling column is its own traversal group: reading order
          // sorts on global position, so scrolled content outranks the app bar.
          body: compact
              ? FocusTraversalGroup(
                  child: showingSection
                      // The sticky picker over the page (spec §6): one
                      // column, the category always one tap away.
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SettingsCategoryPicker(
                              selected: selected,
                              onSelect: _select,
                              onSearch: _backToList,
                            ),
                            Expanded(child: _page(selected)),
                          ],
                        )
                      : SettingsNav(
                          selected: null,
                          onSelect: _select,
                          onOpen: _go,
                        ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Told apart from the page by tone (the board's `panel`
                    // column); the hairline beside it is transparent unless
                    // "Lines between regions" is on.
                    ColoredBox(
                      color: tones.panel,
                      child: SizedBox(
                        width: SettingsScreen.navWidth,
                        child: FocusTraversalGroup(
                          child: SettingsNav(
                            selected: selected,
                            onSelect: _select,
                            onOpen: _go,
                          ),
                        ),
                      ),
                    ),
                    Container(width: 1, color: tones.line),
                    Expanded(
                      child: FocusTraversalGroup(child: _page(selected)),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _page(SettingsSectionId section) =>
      NotificationListener<UserScrollNotification>(
        onNotification: (_) {
          _pendingReveal = null;
          return false;
        },
        child: SettingsAnchorScope(
          keys: _anchorKeys,
          child: _SectionContent(section: section),
        ),
      );
}

/// The selected section's page, held to a readable width — a wide window adds
/// margin, not 900px-long switch rows.
class _SectionContent extends StatelessWidget {
  const _SectionContent({required this.section});

  final SettingsSectionId section;

  @override
  Widget build(BuildContext context) {
    // A page is longer than the window, and Tab wrapping back to its first
    // control does not scroll up to it on Flutter's own policy.
    final scaler = MediaQuery.textScalerOf(context);
    return FocusRevealGroup(
      // The tab's own width, not the window's: a split pane is narrow too.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return SingleChildScrollView(
            // A fresh scroll position per section, not one shared offset.
            key: PageStorageKey('settings-${section.name}'),
            padding: SettingsLayout.pagePadding(width, scaler),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: SettingsLayout.contentMaxWidth,
                ),
                child: SettingsPageBody(page: section),
              ),
            ),
          );
        },
      ),
    );
  }

  /// A page's content that is not an anchored section yet: Notifications and
  /// About are new with spec §6's regrouping, and the anchor-to-widget table
  /// in `settings_page_body.dart` is held by the responsive work. The body
  /// still draws their title and description; this draws what follows. Search
  /// finds both pages by their label and [SettingsSectionId.aliases].
}

/// **The sticky category picker** of a narrow Settings tab (spec §6, board N5
/// narrow): on the `panel` tone, one wide button naming the page's group (dim)
/// and the page (semibold) with a caret, opening every page by group; and a
/// square Search button beside it, which opens the full list with its search
/// field.
class SettingsCategoryPicker extends ConsumerWidget {
  const SettingsCategoryPicker({
    required this.selected,
    required this.onSelect,
    required this.onSearch,
    super.key,
  });

  final SettingsSectionId selected;
  final ValueChanged<SettingsSectionId> onSelect;
  final VoidCallback onSearch;

  /// The picker's buttons: the board's 34 px — a control and a step of air.
  static const buttonHeight = Chrome.control + Insets.sm;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    final radius = BorderRadius.circular(Radii.sm + 2);
    return ColoredBox(
      color: tones.panel,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.md,
          vertical: Insets.sm + 2,
        ),
        child: Row(
          children: [
            Expanded(
              child: Builder(
                builder: (anchor) => Material(
                  color: tones.raised,
                  borderRadius: radius,
                  child: InkWell(
                    borderRadius: radius,
                    hoverColor: tones.hover,
                    onTap: () async {
                      final caps = ref.read(capabilitiesProvider);
                      final groups = [
                        for (final group in SettingsGroup.values)
                          if (group.pages.any((p) => p.shownWith(caps))) group,
                      ];
                      final picked = await showDesktopMenuUnder<String>(
                        anchor,
                        [
                          for (final (index, group) in groups.indexed) ...[
                            if (index > 0) const DesktopMenuDivider(),
                            PopupMenuItem<String>(
                              enabled: false,
                              height: Chrome.menuRow,
                              child: Text(
                                group.label.toUpperCase(),
                                style: theme.textTheme.labelSmall?.merge(
                                  Chrome.groupLabel,
                                ),
                              ),
                            ),
                            for (final page in group.pages)
                              if (page.shownWith(caps))
                                DesktopMenuItem(
                                  value: page.name,
                                  label: page.label,
                                  icon: page.icon,
                                  selected: page == selected,
                                ),
                          ],
                        ],
                      );
                      if (picked == null) return;
                      onSelect(SettingsSectionId.values.byName(picked));
                    },
                    child: SizedBox(
                      height: buttonHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Insets.md,
                        ),
                        child: Row(
                          children: [
                            Text(
                              selected.group.label,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(width: Insets.sm),
                            Expanded(
                              child: Text(
                                selected.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              AppIcons.caretDown,
                              size: Chrome.iconSmall,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: Insets.sm),
            Material(
              color: tones.raised,
              borderRadius: radius,
              child: InkWell(
                borderRadius: radius,
                hoverColor: tones.hover,
                onTap: onSearch,
                child: Tooltip(
                  message: 'Search settings',
                  child: SizedBox.square(
                    dimension: buttonHeight,
                    child: Icon(
                      AppIcons.magnifyingGlass,
                      size: Chrome.icon,
                      color: theme.colorScheme.onSurfaceVariant,
                      semanticLabel: 'Search settings',
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
