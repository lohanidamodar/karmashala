/// The one file browser body every surface draws: the picker's dialog and
/// page, each side of the Files tab, and the phone's Files page. What differs
/// between them is the [FileBrowserController] they hand it and the few
/// slots below — never a second copy of the listing.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_icons.dart';
import 'design_tokens.dart';
import 'desktop_dialog.dart';
import 'desktop_menu.dart';
import 'file_browser.dart';
import 'file_browser_controller.dart';
import 'file_name_dialog.dart';
import 'hidden_files_chip.dart';
import 'inline_spinner.dart';
import 'quick_access.dart';
import 'row_menu.dart';

/// One entry a caller adds to a row's menu — the Files tab's Rename and
/// Delete. [onSelected] is told the row.
@immutable
class FileBrowserRowAction {
  const FileBrowserRowAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final bool destructive;
  final void Function(BrowsedEntry entry) onSelected;
}

/// The browser body: the machine, the path, New folder and New file, the
/// quick-access column (a chip row when narrow or under a thumb), the
/// listing, and the filter with the hidden toggle.
///
/// Right-click (or a long press under a thumb) on a folder pins it to quick
/// access; on a pin, unpins or renames it. The pins are the server's, so they
/// are the same in every browser on every client.
class FileBrowserView extends StatefulWidget {
  const FileBrowserView({
    required this.controller,
    this.touch = false,
    this.autofocusFilter = false,
    this.offerNewFolder = true,
    this.offerNewFile = true,
    this.actions,
    this.rowActions,
    this.onOpenFile,
    this.canOpenFile,
    this.showFooter = false,
    this.pins,
    this.openFileIcon = AppIcons.fileCode,
    this.openFileTooltip = 'Open in editor',
    this.subtitleOf,
    this.rowWrapper,
    this.upWrapper,
    this.footer,
    super.key,
  });

  /// The file open button's glyph and words: the editor in the Files tab,
  /// "Save to this computer" for a device's file.
  final IconData openFileIcon;
  final String openFileTooltip;

  /// A row's second line; a file's size in the Files tab when null.
  final String? Function(BrowsedEntry entry)? subtitleOf;

  /// Wraps a drawn row — a device's drag to move, and its folders' drops.
  final Widget Function(BrowsedEntry entry, Widget row)? rowWrapper;

  /// Wraps the Up button, as [rowWrapper] wraps a row.
  final Widget Function(Widget up)? upWrapper;

  /// Under everything: progress, or what the listing could not say.
  final WidgetBuilder? footer;

  final FileBrowserController controller;

  /// Touch-sized rows and the shortcuts as chips, whatever the density says —
  /// the picker's page, which is what a phone gets.
  final bool touch;

  final bool autofocusFilter;
  final bool offerNewFolder;
  final bool offerNewFile;

  /// More buttons on the toolbar, after New folder and New file.
  final WidgetBuilder? actions;

  /// More entries in a row's menu.
  final List<FileBrowserRowAction> Function(BrowsedEntry entry)? rowActions;

  /// What a file's open button does; none is drawn while null.
  final void Function(BrowsedEntry entry)? onOpenFile;
  final bool Function(BrowsedEntry entry)? canOpenFile;

  /// The count of rows and of the selection, under the listing.
  final bool showFooter;

  /// The pins to show; [QuickAccess.current] when null.
  final QuickAccessPins? pins;

  @override
  State<FileBrowserView> createState() => _FileBrowserViewState();
}

class _FileBrowserViewState extends State<FileBrowserView> {
  final _filter = TextEditingController();
  final _path = TextEditingController();
  final _listFocus = FocusNode();
  late String _shownDirectory = widget.controller.directory;
  QuickAccessPins? _pins;

  FileBrowserController get _browser => widget.controller;

  @override
  void initState() {
    super.initState();
    _path.text = _browser.directory;
    _browser.addListener(_changed);
    _pins = widget.pins ?? QuickAccess.current;
    _pins?.addListener(_pinsChanged);
  }

  @override
  void didUpdateWidget(FileBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _follow();
    }
    final pins = widget.pins ?? QuickAccess.current;
    if (!identical(pins, _pins)) {
      _pins?.removeListener(_pinsChanged);
      _pins = pins?..addListener(_pinsChanged);
    }
  }

  @override
  void dispose() {
    _browser.removeListener(_changed);
    _pins?.removeListener(_pinsChanged);
    _filter.dispose();
    _path.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _follow();
    setState(() {});
  }

  /// A new folder starts unfiltered, and the path field says where it is.
  void _follow() {
    if (_browser.directory == _shownDirectory) return;
    _shownDirectory = _browser.directory;
    _filter.clear();
    _path.text = _browser.directory;
  }

  void _pinsChanged() {
    if (mounted) setState(() {});
  }

  bool _touchOf(BuildContext context) =>
      widget.touch || UiDensity.of(context).isTouch;

  // ---- quick access -------------------------------------------------------

  /// The pin naming [path] here, or null.
  PinnedFolder? _pinOf(String path) {
    final environmentId = _browser.environmentId;
    if (environmentId == null) return null;
    for (final pin in _pins?.pins ?? const <PinnedFolder>[]) {
      if (pin.names(environmentId, path)) return pin;
    }
    return null;
  }

  /// Whether this browser can pin at all: it needs pins to keep them, and an
  /// environment to say where a folder is. A browser of this device's own
  /// disk, outside any server, has neither.
  bool get _canPin => _pins != null && _browser.environmentId != null;

  Future<void> _togglePin(String path) async {
    final pins = _pins;
    final environmentId = _browser.environmentId;
    if (pins == null || environmentId == null) return;
    if (pins.unavailable case final reason?) {
      _browser.showNotice(reason);
      return;
    }
    final pinned = _pinOf(path);
    try {
      if (pinned != null) {
        await pins.unpin(pinned);
      } else {
        await pins.pin(PinnedFolder(environmentId: environmentId, path: path));
      }
    } on Object catch (error) {
      _browser.showNotice(operationFailureSentence(error));
    }
  }

  Future<void> _renamePin(PinnedFolder pin) async {
    final pins = _pins;
    if (pins == null) return;
    final label = await FileNameDialog.ask(
      context,
      title: 'Rename in quick access',
      action: 'Rename',
      initial: pin.name,
      label: 'Shown as',
      refuse: (value) => value.trim().length > 200
          ? 'A name in quick access is at most 200 characters.'
          : null,
    );
    if (label == null) return;
    try {
      await pins.rename(pin, label.isEmpty ? null : label);
    } on Object catch (error) {
      _browser.showNotice(operationFailureSentence(error));
    }
  }

  Future<void> _unpin(PinnedFolder pin) async {
    try {
      await _pins?.unpin(pin);
    } on Object catch (error) {
      _browser.showNotice(operationFailureSentence(error));
    }
  }

  /// Opens [pin] — switching machine first when it is another's.
  void _openPin(PinnedFolder pin) {
    if (_browser.environmentId == pin.environmentId) {
      unawaited(_browser.open(pin.path));
      return;
    }
    for (final source in _browser.sources) {
      if (source.id == pin.environmentId) {
        unawaited(_browser.switchTo(source, at: pin.path));
        return;
      }
    }
  }

  /// Pins this browser can open, by machine, in list order; and how many
  /// name a machine it does not look at.
  ({List<(String, List<PinnedFolder>)> groups, int elsewhere}) _pinGroups() {
    final all = _pins?.pins ?? const <PinnedFolder>[];
    final labels = <String, String>{
      for (final source in _browser.sources) source.id: source.label,
    };
    final groups = <String, List<PinnedFolder>>{};
    var elsewhere = 0;
    for (final pin in all) {
      if (!labels.containsKey(pin.environmentId)) {
        elsewhere++;
        continue;
      }
      groups.putIfAbsent(pin.environmentId, () => []).add(pin);
    }
    return (
      groups: [
        for (final source in _browser.sources)
          if (groups[source.id] case final pins?) (source.label, pins),
      ],
      elsewhere: elsewhere,
    );
  }

  // ---- menus --------------------------------------------------------------

  Future<void> _showMenu(
    BuildContext context,
    String title,
    List<PopupMenuEntry<String>> items,
    ValueChanged<String> onSelected, {
    Offset? at,
  }) async {
    if (items.isEmpty) return;
    String? picked;
    if (RowMenuSheetScope.touchOf(context) case final present?) {
      picked = await present(context, title, items);
    } else if (at != null) {
      picked = await showDesktopMenuAt(context, at, items);
    } else {
      picked = await showDesktopMenuUnder(context, items);
    }
    if (picked != null && mounted) onSelected(picked);
  }

  List<PopupMenuEntry<String>> _rowItems(BrowsedEntry entry) {
    final extras = widget.rowActions?.call(entry) ?? const [];
    final pinned = entry.isDirectory ? _pinOf(entry.path) : null;
    return [
      if (entry.isDirectory)
        DesktopMenuItem(
          value: 'open',
          label: 'Open',
          icon: AppIcons.folderOpen,
        ),
      if (_browser.multiSelect)
        DesktopMenuItem(
          value: 'select',
          label: _browser.selected.contains(entry.path)
              ? 'Remove from selection'
              : 'Add to selection',
          icon: AppIcons.check,
        ),
      for (final (index, action) in extras.indexed)
        DesktopMenuItem(
          value: 'action:$index',
          label: action.label,
          icon: action.icon,
          destructive: action.destructive,
        ),
      if (entry.isDirectory && _canPin)
        DesktopMenuItem(
          value: 'pin',
          label: pinned == null
              ? 'Add to quick access'
              : 'Remove from quick access',
          icon: pinned == null ? AppIcons.pushPin : AppIcons.pushPinFill,
        ),
    ];
  }

  void _rowPicked(BrowsedEntry entry, String value) {
    switch (value) {
      case 'open':
        unawaited(_browser.open(entry.path));
      case 'select':
        _browser.select(entry, add: true);
      case 'pin':
        unawaited(_togglePin(entry.path));
      default:
        final index = int.tryParse(value.replaceFirst('action:', ''));
        final extras = widget.rowActions?.call(entry) ?? const [];
        if (index != null && index < extras.length) {
          extras[index].onSelected(entry);
        }
    }
  }

  List<PopupMenuEntry<String>> _pinItems(PinnedFolder pin) => [
    DesktopMenuItem(value: 'open', label: 'Open', icon: AppIcons.folderOpen),
    DesktopMenuItem(
      value: 'rename',
      label: 'Rename…',
      icon: AppIcons.pencilSimple,
    ),
    DesktopMenuItem(
      value: 'unpin',
      label: 'Remove from quick access',
      icon: AppIcons.x,
    ),
  ];

  void _pinPicked(PinnedFolder pin, String value) {
    switch (value) {
      case 'open':
        _openPin(pin);
      case 'rename':
        unawaited(_renamePin(pin));
      case 'unpin':
        unawaited(_unpin(pin));
    }
  }

  // ---- new ----------------------------------------------------------------

  Future<void> _create({required bool folder}) async {
    final name = await FileNameDialog.ask(
      context,
      title: folder ? 'New folder' : 'New file',
      action: 'Create',
    );
    if (name == null) return;
    await (folder ? _browser.createFolder(name) : _browser.createFile(name));
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final touch = _touchOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The shortcuts are the first thing to go: the listing is the browser.
        final column = !touch && constraints.maxWidth >= 560;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_browser.sources.length > 1) ...[
              _SourceBar(
                sources: _browser.sources,
                current: _browser.source,
                onChanged: _browser.busySwitching
                    ? null
                    : (source) => unawaited(_browser.switchTo(source)),
              ),
              const SizedBox(height: Insets.sm),
            ],
            _pathBar(context),
            _toolbar(context),
            if (_browser.notice case final notice?)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.xs),
                child: DesktopErrorBanner(
                  notice,
                  onDismiss: () => _browser.showNotice(null),
                ),
              ),
            if (!column) _chips(context, touch: touch),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (column) ...[
                    SizedBox(width: 168, child: _column(context)),
                    const SizedBox(width: Insets.sm),
                  ],
                  Expanded(child: _listing(context, touch: touch)),
                ],
              ),
            ),
            const SizedBox(height: Insets.sm),
            Row(
              children: [
                Expanded(
                  child: _FilterField(
                    controller: _filter,
                    onChanged: (_) => setState(() {}),
                    hint: _browser.directoriesOnly
                        ? 'Filter folders'
                        : 'Filter this folder',
                    autofocus: widget.autofocusFilter,
                  ),
                ),
                const SizedBox(width: Insets.sm),
                HiddenFilesChip(
                  hiddenCount: _browser.hiddenCount,
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
            if (widget.showFooter) _footer(context),
            ?widget.footer?.call(context),
          ],
        );
      },
    );
  }

  Widget _pathBar(BuildContext context) {
    final here = _pinOf(_browser.directory);
    return Row(
      children: [
        IconButton(
          onPressed: _browser.canGoBack ? _browser.back : null,
          icon: const Icon(AppIcons.caretLeft, size: Chrome.icon),
          tooltip: 'Back',
        ),
        IconButton(
          onPressed: _browser.canGoForward ? _browser.forward : null,
          icon: const Icon(AppIcons.caretRight, size: Chrome.icon),
          tooltip: 'Forward',
        ),
        (widget.upWrapper ?? (up) => up)(
          IconButton(
            onPressed: _browser.canGoUp ? _browser.up : null,
            icon: const Icon(AppIcons.arrowUp, size: Chrome.icon),
            tooltip: 'Up one folder',
          ),
        ),
        Expanded(
          child: TextField(
            controller: _path,
            decoration: InputDecoration(
              isDense: true,
              hintText: Platform.isWindows
                  ? r'C:\ or \\wsl.localhost\distro\home\you'
                  : '/ or ~/projects',
            ),
            onSubmitted: (value) => unawaited(_browser.openTyped(value)),
          ),
        ),
        if (_canPin)
          IconButton(
            onPressed: _browser.error != null || _browser.loading
                ? null
                : () => unawaited(_togglePin(_browser.directory)),
            icon: Icon(
              here == null ? AppIcons.pushPin : AppIcons.pushPinFill,
              size: Chrome.icon,
            ),
            tooltip: here == null
                ? 'Add this folder to quick access'
                : 'Remove this folder from quick access',
          ),
        IconButton(
          onPressed: _browser.refresh,
          icon: const Icon(AppIcons.arrowsClockwise, size: Chrome.icon),
          tooltip: 'Read this folder again',
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context) {
    final busy = _browser.loading || _browser.working;
    final creates = _browser.canCreate && _browser.error == null;
    final buttons = [
      if (widget.offerNewFolder)
        TextButton.icon(
          icon: const Icon(AppIcons.folderPlus, size: Chrome.iconSmall),
          label: const Text('New folder'),
          onPressed: busy || !creates
              ? null
              : () => unawaited(_create(folder: true)),
        ),
      if (widget.offerNewFile && !_browser.directoriesOnly)
        TextButton.icon(
          icon: const Icon(AppIcons.filePlus, size: Chrome.iconSmall),
          label: const Text('New file'),
          onPressed: busy || !creates
              ? null
              : () => unawaited(_create(folder: false)),
        ),
    ];
    final extra = widget.actions?.call(context);
    if (buttons.isEmpty && extra == null) {
      return const SizedBox(height: Insets.sm);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Wrap(
        spacing: Insets.xs,
        runSpacing: Insets.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [...buttons, ?extra],
      ),
    );
  }

  /// The quick-access column: pins first, grouped by machine when the browser
  /// sees several, then this computer's own folders and drives.
  Widget _column(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (:groups, :elsewhere) = _pinGroups();
    final several = _browser.sources.length > 1;
    final current = _browser.directory;
    final environmentId = _browser.environmentId;
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        primary: false,
        children: [
          if (groups.isNotEmpty) const _ColumnHeader('Quick access'),
          for (final (label, pins) in groups) ...[
            if (several) _ColumnHeader(label, minor: true),
            for (final pin in pins)
              _PinTile(
                pin: pin,
                selected:
                    environmentId == pin.environmentId &&
                    pinnedFolderKey(pin.path) == pinnedFolderKey(current),
                onTap: () => _openPin(pin),
                menu: (at) => _showMenu(
                  context,
                  pin.name,
                  _pinItems(pin),
                  (value) => _pinPicked(pin, value),
                  at: at,
                ),
                menuItems: () => _pinItems(pin),
                onMenuPicked: (value) => _pinPicked(pin, value),
              ),
          ],
          if (elsewhere > 0) _ElsewhereNote(count: elsewhere),
          if (_browser.places.isNotEmpty) ...[
            if (groups.isNotEmpty || elsewhere > 0) const Divider(height: 1),
            for (final place in _browser.places)
              ListTile(
                dense: true,
                selected: place.path.toLowerCase() == current.toLowerCase(),
                leading: Icon(place.icon, size: Chrome.icon),
                title: Text(
                  place.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => unawaited(_browser.open(place.path)),
              ),
          ],
        ],
      ),
    );
  }

  /// The same shortcuts as a row of chips, where a column would cost the
  /// listing its width: a phone, a narrow pane.
  Widget _chips(BuildContext context, {required bool touch}) {
    final (:groups, :elsewhere) = _pinGroups();
    final several = _browser.sources.length > 1;
    final chips = <Widget>[
      for (final (label, pins) in groups)
        for (final pin in pins)
          Builder(
            builder: (chipContext) => GestureDetector(
              onLongPressStart: (details) => _showMenu(
                chipContext,
                pin.name,
                _pinItems(pin),
                (value) => _pinPicked(pin, value),
                at: details.globalPosition,
              ),
              onSecondaryTapDown: (details) => _showMenu(
                chipContext,
                pin.name,
                _pinItems(pin),
                (value) => _pinPicked(pin, value),
                at: details.globalPosition,
              ),
              child: ActionChip(
                avatar: const Icon(
                  AppIcons.pushPinFill,
                  size: Chrome.iconSmall,
                ),
                label: Text(several ? '${pin.name} · $label' : pin.name),
                tooltip: pin.path,
                materialTapTargetSize: touch
                    ? MaterialTapTargetSize.padded
                    : MaterialTapTargetSize.shrinkWrap,
                onPressed: () => _openPin(pin),
              ),
            ),
          ),
      for (final place in _browser.places)
        ActionChip(
          avatar: Icon(place.icon, size: Chrome.iconSmall),
          label: Text(place.label),
          materialTapTargetSize: touch
              ? MaterialTapTargetSize.padded
              : MaterialTapTargetSize.shrinkWrap,
          onPressed: () => unawaited(_browser.open(place.path)),
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xs),
      child: SizedBox(
        height: touch ? Touch.target : 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          primary: false,
          itemCount: chips.length,
          separatorBuilder: (_, _) => const SizedBox(width: Insets.xs),
          itemBuilder: (_, index) => Center(child: chips[index]),
        ),
      ),
    );
  }

  Widget _listing(BuildContext context, {required bool touch}) {
    final scheme = Theme.of(context).colorScheme;
    final border = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      side: BorderSide(color: scheme.outlineVariant),
    );

    final Widget body;
    if (_browser.loading && _browser.entries.isEmpty) {
      body = const Center(child: InlineSpinner(size: InlineSpinnerSize.large));
    } else if (_browser.error case final error?) {
      body = _Message(icon: AppIcons.warningCircle, text: error);
    } else {
      final rows = _browser.visible(_filter.text);
      if (rows.isEmpty) {
        body = _Message(
          icon: AppIcons.folder,
          text: _browser.entries.isNotEmpty
              ? (_filter.text.trim().isEmpty
                    ? 'Everything in here is hidden.'
                    : 'Nothing matches “${_filter.text.trim()}”.')
              : _browser.multiSelect
              ? 'Nothing here.'
              : _browser.directoriesOnly
              ? 'No folders in here. You can still choose this one.'
              : 'Nothing in here matches what is being asked for.',
        );
      } else {
        body = Focus(
          focusNode: _listFocus,
          child: ListView.builder(
            primary: false,
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final entry = rows[index];
              final row = _EntryRow(
                key: ValueKey(entry.path),
                entry: entry,
                touch: touch,
                manage: _browser.multiSelect,
                subtitle: widget.subtitleOf != null
                    ? widget.subtitleOf!(entry)
                    : _browser.multiSelect &&
                          !entry.isDirectory &&
                          entry.sizeBytes != null
                    ? describeBrowsedSize(entry.sizeBytes)
                    : null,
                openFileIcon: widget.openFileIcon,
                openFileTooltip: widget.openFileTooltip,
                menuButton: widget.rowActions != null,
                pinned: entry.isDirectory && _pinOf(entry.path) != null,
                selected: _browser.selected.contains(entry.path),
                onTap: () => _browser.tap(
                  entry,
                  add:
                      HardwareKeyboard.instance.isControlPressed ||
                      HardwareKeyboard.instance.isMetaPressed,
                ),
                onOpen: !entry.readable
                    ? null
                    : entry.isDirectory
                    ? () => unawaited(_browser.open(entry.path))
                    : widget.onOpenFile != null &&
                          (widget.canOpenFile?.call(entry) ?? true)
                    ? () => widget.onOpenFile!(entry)
                    : null,
                menuItems: () => _rowItems(entry),
                onMenuPicked: (value) => _rowPicked(entry, value),
                onLongPress: (rowContext, at) => _showMenu(
                  rowContext,
                  entry.name,
                  _rowItems(entry),
                  (value) => _rowPicked(entry, value),
                  at: at,
                ),
              );
              return widget.rowWrapper?.call(entry, row) ?? row;
            },
          ),
        );
      }
    }

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: border,
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }

  Widget _footer(BuildContext context) {
    final theme = Theme.of(context);
    final count = _browser.visible(_filter.text).length;
    final selected = _browser.selected.length;
    final items = '$count item${count == 1 ? '' : 's'}';
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs, left: Insets.xs),
      child: Text(
        selected == 0 ? items : '$items · $selected selected',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

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
  Widget build(BuildContext context) => TextField(
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
        waitDuration: const Duration(milliseconds: 600),
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

/// A size a person can read. Null — the filesystem did not say — is a dash,
/// never a zero.
String describeBrowsedSize(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
