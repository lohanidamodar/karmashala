import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:karmashala_session/transcript.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/transcript.dart';

import '../../environments/application/environment_values.dart'
    show EnvironmentKind, EnvironmentPath;
import '../../../core/clipboard/image_clipboard.dart';

/// Where a path the conversation wrote lands: resolved against the session's
/// [folder] in its environment's spelling, its `:line` dropped.
EnvironmentPath placeTranscriptPath(
  String token, {
  required EnvironmentPath folder,
  required EnvironmentKind? kind,
}) => EnvironmentPath(
  environmentId: folder.environmentId,
  path: resolveTranscriptPath(
    tokenForMatch(token).path,
    workingDirectory: folder.path,
    context: transcriptPathContext(kind),
  ),
);

/// [full] relative to [folder]; [full] itself when it is spelled for another
/// system than the session's.
String relativeTranscriptPath(
  EnvironmentPath full, {
  required EnvironmentPath folder,
  required EnvironmentKind? kind,
}) {
  final context = transcriptPathContext(kind);
  if (!context.isAbsolute(full.path)) return full.path;
  return context.relative(full.path, from: folder.path);
}

/// The ids of what a chat target's menu offers.
abstract final class ChatMenuIds {
  static const copySelection = 'copy-selection';
  static const open = 'open';
  static const reveal = 'reveal';
  static const copyLink = 'copy-link';
  static const copyLinkText = 'copy-link-text';
  static const copyPath = 'copy-path';
  static const copyFullPath = 'copy-full-path';
  static const copyRelativePath = 'copy-relative-path';
  static const copyImage = 'copy-image';
  static const saveImage = 'save-image';
  static const copyCode = 'copy-code';
}

/// The menu every link, path, picture and code span in a chat opens, and what
/// each of its items does. Built once per conversation: its callbacks read
/// the session as it is when an item runs.
class ChatTargetMenu {
  ChatTargetMenu({
    required this.folder,
    required this.kindOf,
    required this.openPath,
    required this.openLink,
    required this.canReveal,
    required this.reveal,
    required this.imageClipboard,
    this.saveImage,
  });

  /// The session's folder, or null when there is no record of it.
  final EnvironmentPath? Function() folder;
  final EnvironmentKind? Function(String environmentId) kindOf;
  final Future<void> Function(String token) openPath;
  final Future<void> Function(String href) openLink;
  final bool Function(EnvironmentPath path) canReveal;
  final Future<void> Function(EnvironmentPath path) reveal;
  final ImageClipboard Function() imageClipboard;

  /// Writes a picture where the person picks; null where there is no save
  /// dialog.
  final Future<void> Function(Uint8List bytes, String name)? saveImage;

  EnvironmentPath? _place(String token) {
    final base = folder();
    if (base == null) return null;
    return placeTranscriptPath(
      token,
      folder: base,
      kind: kindOf(base.environmentId),
    );
  }

  /// [target]'s items, with Copy selection first when [selection] is held.
  List<PopupMenuEntry<String>> itemsFor(
    TranscriptTarget target, {
    String? selection,
    bool touch = false,
  }) {
    DesktopMenuItem<String> item(String id, String label, IconData icon) =>
        DesktopMenuItem<String>(value: id, label: label, icon: icon);
    final items = <PopupMenuEntry<String>>[];
    switch (target) {
      case TranscriptWebLink(:final href, :final text):
        items.addAll([
          item(ChatMenuIds.open, 'Open link', AppIcons.arrowSquareOut),
          item(ChatMenuIds.copyLink, 'Copy link', AppIcons.linkSimple),
          if (text != null && text.isNotEmpty && text != href)
            item(ChatMenuIds.copyLinkText, 'Copy link text', AppIcons.copy),
        ]);
      case TranscriptPathLink(:final path):
        final full = _place(path);
        items.addAll([
          item(ChatMenuIds.open, 'Open', AppIcons.arrowSquareOut),
          if (full != null && canReveal(full))
            item(ChatMenuIds.reveal, 'Reveal in folder', AppIcons.folderOpen),
          item(ChatMenuIds.copyPath, 'Copy path as written', AppIcons.copy),
          if (full != null) ...[
            item(ChatMenuIds.copyFullPath, 'Copy full path', AppIcons.copy),
            item(
              ChatMenuIds.copyRelativePath,
              'Copy relative path',
              AppIcons.copy,
            ),
          ],
        ]);
      case TranscriptImageTarget(:final path, :final uri):
        items.addAll([
          if (imageClipboard().supported)
            item(ChatMenuIds.copyImage, 'Copy image', AppIcons.image),
          if (path != null)
            item(ChatMenuIds.copyPath, 'Copy path', AppIcons.copy)
          else if (uri != null && !uri.isScheme('data'))
            item(ChatMenuIds.copyLink, 'Copy link', AppIcons.linkSimple),
          if (!touch && saveImage != null)
            item(ChatMenuIds.saveImage, 'Save as…', AppIcons.floppyDisk),
          if (path != null || (uri != null && !uri.isScheme('data')))
            item(ChatMenuIds.open, 'Open', AppIcons.arrowSquareOut),
        ]);
      case TranscriptCodeSpan():
        items.add(item(ChatMenuIds.copyCode, 'Copy', AppIcons.copySimple));
    }
    if (selection == null) return items;
    return [
      item(ChatMenuIds.copySelection, 'Copy selection', AppIcons.copySimple),
      const DesktopMenuDivider(),
      ...items,
    ];
  }

  /// Opens [target]'s menu: a popup at [position] under a pointer, a sheet
  /// under a thumb.
  Future<void> open(
    BuildContext context,
    TranscriptTarget target, {
    Offset? position,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final selection = TranscriptSelectionArea.selectedTextOf(context);
    final sheet = RowMenuSheetScope.touchOf(context);
    final items = itemsFor(
      target,
      selection: selection,
      touch: UiDensity.of(context).isTouch,
    );
    if (items.isEmpty) return;
    final String? picked;
    if (sheet != null) {
      picked = await sheet(context, _titleOf(target), items);
    } else if (position != null) {
      picked = await showDesktopMenuAt(context, position, items);
    } else {
      picked = await showDesktopMenuUnder(context, items);
    }
    if (picked == null) return;
    if (picked == ChatMenuIds.copySelection && selection != null) {
      return _copyText(messenger, selection, 'Selection');
    }
    await _pick(messenger, target, picked);
  }

  /// A hover button or Ctrl+C: Copy and Open without the menu.
  Future<void> run(
    BuildContext context,
    TranscriptTarget target,
    TranscriptTargetAction action,
  ) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final id = switch ((action, target)) {
      (TranscriptTargetAction.open, _) => ChatMenuIds.open,
      (_, TranscriptWebLink()) => ChatMenuIds.copyLink,
      (_, TranscriptPathLink()) => ChatMenuIds.copyPath,
      (_, TranscriptCodeSpan()) => ChatMenuIds.copyCode,
      (_, TranscriptImageTarget(:final path)) =>
        imageClipboard().supported || path == null
            ? ChatMenuIds.copyImage
            : ChatMenuIds.copyPath,
    };
    return _pick(messenger, target, id);
  }

  Future<void> _pick(
    ScaffoldMessengerState? messenger,
    TranscriptTarget target,
    String id,
  ) async {
    switch (target) {
      case TranscriptWebLink(:final href, :final text):
        switch (id) {
          case ChatMenuIds.open:
            await openLink(href);
          case ChatMenuIds.copyLink:
            await _copyText(messenger, href, 'Link');
          case ChatMenuIds.copyLinkText:
            await _copyText(messenger, text ?? href, 'Link text');
        }
      case TranscriptPathLink(:final path):
        final base = folder();
        final full = _place(path);
        switch (id) {
          case ChatMenuIds.open:
            await openPath(path);
          case ChatMenuIds.reveal when full != null:
            await reveal(full);
          case ChatMenuIds.copyPath:
            await _copyText(messenger, path, 'Path');
          case ChatMenuIds.copyFullPath when full != null:
            await _copyText(messenger, full.path, 'Full path');
          case ChatMenuIds.copyRelativePath when full != null && base != null:
            await _copyText(
              messenger,
              relativeTranscriptPath(
                full,
                folder: base,
                kind: kindOf(base.environmentId),
              ),
              'Relative path',
            );
        }
      case TranscriptImageTarget(:final path, :final uri):
        switch (id) {
          case ChatMenuIds.copyImage:
            final bytes = await target.bytes();
            final said = bytes == null
                ? "Couldn't copy: the image is not loaded."
                : await writeImageToClipboard(bytes, imageClipboard());
            _say(messenger, said);
          case ChatMenuIds.copyPath when path != null:
            await _copyText(messenger, path, 'Path');
          case ChatMenuIds.copyLink when uri != null:
            await _copyText(messenger, uri.toString(), 'Link');
          case ChatMenuIds.saveImage:
            final bytes = await target.bytes();
            if (bytes == null) {
              _say(messenger, "Couldn't save: the image is not loaded.");
            } else {
              await saveImage?.call(bytes, target.name);
            }
          case ChatMenuIds.open:
            if (path != null) {
              await openPath(path);
            } else if (uri != null) {
              await openLink(uri.toString());
            }
        }
      case TranscriptCodeSpan(:final code):
        await _copyText(messenger, code, 'Code');
    }
  }

  static String _titleOf(TranscriptTarget target) => switch (target) {
    TranscriptWebLink(:final href) => href,
    TranscriptPathLink(:final path) => path,
    TranscriptImageTarget() => target.name,
    TranscriptCodeSpan(:final code) => code,
  };

  static Future<void> _copyText(
    ScaffoldMessengerState? messenger,
    String text,
    String what,
  ) async {
    await Clipboard.setData(ClipboardData(text: text));
    _say(messenger, '$what copied to clipboard');
  }

  static void _say(ScaffoldMessengerState? messenger, String message) =>
      messenger?.showSnackBar(SnackBar(content: Text(message)));
}

/// Installs [menu] as the chat's target menu. Its tear-offs are stable, so a
/// rebuild of the view does not redraw every message.
class ChatTargetMenuScope extends StatelessWidget {
  const ChatTargetMenuScope({
    required this.menu,
    required this.child,
    super.key,
  });

  final ChatTargetMenu menu;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      TranscriptTargetMenuScope(open: menu.open, run: menu.run, child: child);
}

/// The menu [context] is under, re-installed over a dialog's route.
Widget keepTranscriptTargetMenu(BuildContext context, Widget child) {
  final scope = TranscriptTargetMenuScope.maybeScopeOf(context);
  if (scope == null) return child;
  return TranscriptTargetMenuScope(
    open: scope.open,
    run: scope.run,
    child: child,
  );
}
