// The state of [FileBrowserView].

part of '../file_browser_view.dart';

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
