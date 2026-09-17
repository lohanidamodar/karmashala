import 'package:flutter/material.dart';

import '../../../app/shell/app_shell.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
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

  /// The widest a section's page grows: a wide window adds margin, not
  /// 900px-long switch rows.
  static const contentMaxWidth = 720.0;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsSectionId _selected =
      widget.initialAnchor?.page ??
      widget.initialSection ??
      SettingsSectionId.values.first;

  /// Whether the compact layout shows a page; a deep link opens into one.
  late bool _openOnCompact =
      widget.initialSection != null || widget.initialAnchor != null;

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
            leading: compact && _openOnCompact
                ? BackButton(onPressed: _backToList)
                : null,
            title: Row(
              children: [
                Icon(AppIcons.gearSix, color: theme.colorScheme.tertiary),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    compact && showingSection
                        ? 'Settings · ${_selected.label}'
                        : 'Settings',
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
                      ? _page()
                      : SettingsNav(
                          selected: null,
                          onSelect: _select,
                          onOpen: _go,
                        ),
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: SettingsScreen.navWidth,
                      child: FocusTraversalGroup(
                        child: SettingsNav(
                          selected: _selected,
                          onSelect: _select,
                          onOpen: _go,
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
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
    return FocusRevealGroup(
      child: SingleChildScrollView(
        // A fresh scroll position per section, not one shared offset.
        key: PageStorageKey('settings-${section.name}'),
        padding: const EdgeInsets.symmetric(
          horizontal: Insets.xl,
          vertical: Insets.lg,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: SettingsScreen.contentMaxWidth,
            ),
            child: SettingsPageBody(page: section),
          ),
        ),
      ),
    );
  }
}
