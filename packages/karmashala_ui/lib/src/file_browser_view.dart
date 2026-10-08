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
import 'search_field.dart';
import 'desktop_dialog.dart';
import 'desktop_menu.dart';
import 'file_browser.dart';
import 'file_browser_controller.dart';
import 'file_name_dialog.dart';
import 'hidden_files_chip.dart';
import 'inline_spinner.dart';
import 'quick_access.dart';
import 'row_menu.dart';

part 'file_browser_view/file_browser_view_state.dart';
part 'file_browser_view/file_browser_rows.dart';

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
