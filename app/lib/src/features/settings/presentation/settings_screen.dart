import 'package:flutter/material.dart';

import '../../../app/shell/app_shell.dart';
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
class SettingsScreen extends StatefulWidget {
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

  /// The section list's width beside the page, in the two-column layout.
  static const navWidth = 208.0;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
    final theme = Theme.of(context);
    final tones = SurfaceTones.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = ShellWidth.of(constraints.maxWidth).isCompact;
        final showingSection = !compact || _openOnCompact;
        return Scaffold(
          appBar: AppBar(
            // A page header, not a chrome row: `Chrome.titleBar` is 30px.
            toolbarHeight: 44,
            // A workbench tab: an implied leading button would pop the
            // app's own route.
            automaticallyImplyLeading: false,
            leading: null,
            title: Row(
              children: [
                Icon(AppIcons.gearSix, color: theme.colorScheme.tertiary),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    'Settings',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
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
                              selected: _selected,
                              onSelect: _select,
                              onSearch: _backToList,
                            ),
                            Expanded(child: _page()),
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
                    // Told apart from the page by tone, like the sidebar
                    // from the workbench; the hairline beside it is
                    // transparent unless "Lines between regions" is on.
                    ColoredBox(
                      color: tones.side,
                      child: SizedBox(
                        width: SettingsScreen.navWidth,
                        child: FocusTraversalGroup(
                          child: SettingsNav(
                            selected: _selected,
                            onSelect: _select,
                            onOpen: _go,
                          ),
                        ),
                      ),
                    ),
                    Container(width: 1, color: tones.line),
                    Expanded(child: FocusTraversalGroup(child: _page())),
                  ],
                ),
        );
      },
    );
  }

  Widget _page() => NotificationListener<UserScrollNotification>(
    onNotification: (_) {
      _pendingReveal = null;
      return false;
    },
    child: SettingsAnchorScope(
      keys: _anchorKeys,
      child: _SectionContent(section: _selected),
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

/// **The sticky category picker** of a narrow Settings tab (spec §6): the
/// page's name with a caret, opening every page by group, and Search, which
/// opens the full list with its search field.
class SettingsCategoryPicker extends StatelessWidget {
  const SettingsCategoryPicker({
    required this.selected,
    required this.onSelect,
    required this.onSearch,
    super.key,
  });

  final SettingsSectionId selected;
  final ValueChanged<SettingsSectionId> onSelect;
  final VoidCallback onSearch;

  static const _search = '\u0000search';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: SurfaceTones.of(context).chrome,
      child: Builder(
        builder: (anchor) => InkWell(
          onTap: () async {
            final picked = await showDesktopMenuUnder<String>(anchor, [
              DesktopMenuItem(
                value: _search,
                label: 'Search settings…',
                icon: AppIcons.magnifyingGlass,
              ),
              for (final group in SettingsGroup.values) ...[
                const DesktopMenuDivider(),
                PopupMenuItem<String>(
                  enabled: false,
                  height: Chrome.menuRow,
                  child: Text(
                    group.label.toUpperCase(),
                    style: theme.textTheme.labelSmall?.merge(Chrome.groupLabel),
                  ),
                ),
                for (final page in group.pages)
                  DesktopMenuItem(
                    value: page.name,
                    label: page.label,
                    icon: page.icon,
                    selected: page == selected,
                  ),
              ],
            ]);
            if (picked == null) return;
            if (picked == _search) {
              onSearch();
              return;
            }
            onSelect(SettingsSectionId.values.byName(picked));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.lg,
              vertical: Insets.sm,
            ),
            child: Row(
              children: [
                Icon(selected.icon, size: Chrome.iconAction),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    '${selected.group.label} · ${selected.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                const SizedBox(width: Insets.xs),
                const Icon(AppIcons.caretDown, size: Chrome.iconSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
