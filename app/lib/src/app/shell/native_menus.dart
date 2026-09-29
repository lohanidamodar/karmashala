import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'keymap_controller.dart';
import 'shell_menus.dart';
import 'shell_shortcuts.dart';

/// Whether the menus live in the system's menu bar rather than the window's.
/// macOS only: Flutter has no platform menu bar anywhere else. Read from the
/// target platform rather than the host, so a widget test — Android unless it
/// says otherwise — keeps the in-window bar and can opt in.
bool get useNativeMenus => defaultTargetPlatform == TargetPlatform.macOS;

/// The window's Workspace and View menus in the macOS menu bar, after the app
/// menu a Mac app carries and before its Window menu. The in-window Tools
/// menu — Settings and About — *is* that app menu here, so it has no second
/// home. The same [ShellMenuActions] as the in-window bar, and View's rows are
/// the same list; a native item takes no icon and no check mark, so a toggle
/// says what it will do.
class NativeShellMenus extends ConsumerWidget {
  const NativeShellMenus({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!useNativeMenus) return child;
    // Every key equivalent below is the keymap's: rebuilt when it moves.
    ref.watch(keymapProvider.select((k) => k.revision));
    final actions = ShellMenuActions(context, ref);
    return PlatformMenuBar(
      menus: [
        _appMenu(actions),
        _workspaceMenu(actions),
        _viewMenu(actions, ref),
        const PlatformMenu(
          label: 'Window',
          menus: [
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.minimizeWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.zoomWindow,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.toggleFullScreen,
            ),
            PlatformProvidedMenuItem(
              type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
            ),
          ],
        ),
      ],
      child: child,
    );
  }

  PlatformMenu _appMenu(ShellMenuActions actions) => PlatformMenu(
    label: 'Karmashala',
    menus: [
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'About Karmashala',
            shortcut: shellCommandActivator('app.about'),
            onSelected: actions.about,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Settings…',
            shortcut: shellCommandActivator('settings.open'),
            onSelected: actions.openSettings,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.servicesSubmenu,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.hideOtherApplications,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.showAllApplications,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          // The app's own quit, not the system's terminate: the tray's Quit,
          // so shutdown runs in order.
          PlatformMenuItem(
            label: 'Quit Karmashala',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyQ,
              meta: true,
            ),
            onSelected: actions.quit,
          ),
        ],
      ),
    ],
  );

  PlatformMenu _workspaceMenu(ShellMenuActions actions) => PlatformMenu(
    label: 'Workspace',
    menus: [
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'New project',
            shortcut: shellCommandActivator('project.new'),
            onSelected: actions.newProject,
          ),
          PlatformMenuItem(
            label: 'New session',
            shortcut: shellCommandActivator('session.new'),
            onSelected: actions.newSession,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Go to…',
            shortcut: shellCommandActivator('quickOpen.show'),
            onSelected: actions.goTo,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Detect CLI sessions',
            shortcut: shellCommandActivator('workspace.detectCliSessions'),
            onSelected: actions.detectCliSessions,
          ),
          PlatformMenuItem(
            label: 'Clear projects and re-import…',
            onSelected: actions.clearAndReimport,
          ),
        ],
      ),
    ],
  );

  /// The same rows as the window's View menu ([viewMenuSections]), with the
  /// chords the keymap binds.
  PlatformMenu _viewMenu(ShellMenuActions actions, WidgetRef ref) =>
      PlatformMenu(
        label: 'View',
        menus: [
          for (final section in viewMenuSections(ref, actions))
            PlatformMenuItemGroup(
              members: [for (final entry in section) _viewRow(entry)],
            ),
        ],
      );

  static PlatformMenuItem _viewRow(ViewMenuEntry entry) => switch (entry) {
    ViewMenuCommand() => PlatformMenuItem(
      label: entry.nativeLabel ?? entry.label,
      shortcut: entry.command == null
          ? null
          : shellCommandActivator(entry.command!),
      onSelected: entry.onPressed,
    ),
    ViewMenuSubmenu() => PlatformMenu(
      label: entry.label,
      menus: [for (final child in entry.entries) _viewRow(child)],
    ),
  };
}
