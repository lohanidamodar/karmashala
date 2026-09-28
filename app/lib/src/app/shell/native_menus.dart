import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/notes/application/notes_providers.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'shell_menus.dart';
import 'shell_state.dart';
import 'shell_area.dart';
import 'side_panel_state.dart';

/// Whether the menus live in the system's menu bar rather than the window's.
/// macOS only: Flutter has no platform menu bar anywhere else. Read from the
/// target platform rather than the host, so a widget test — Android unless it
/// says otherwise — keeps the in-window bar and can opt in.
bool get useNativeMenus => defaultTargetPlatform == TargetPlatform.macOS;

/// The window's Workspace, View and Tools menus in the macOS menu bar, after
/// the app menu a Mac app carries and before its Window menu. The same
/// [ShellMenuActions] as the in-window bar, so the two cannot drift; a native
/// item takes no icon and no check mark, so a toggle says what it will do.
class NativeShellMenus extends ConsumerWidget {
  const NativeShellMenus({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!useNativeMenus) return child;
    final actions = ShellMenuActions(context, ref);
    return PlatformMenuBar(
      menus: [
        _appMenu(actions),
        _workspaceMenu(actions),
        _viewMenu(actions, ref),
        _toolsMenu(actions),
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
            onSelected: actions.about,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Settings…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.comma,
              meta: true,
            ),
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
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyN,
              meta: true,
              shift: true,
            ),
            onSelected: actions.newProject,
          ),
          PlatformMenuItem(
            label: 'New session',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyN,
              meta: true,
            ),
            onSelected: actions.newSession,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Go to…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyK,
              meta: true,
            ),
            onSelected: actions.goTo,
          ),
        ],
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Detect CLI sessions',
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

  PlatformMenu _viewMenu(ShellMenuActions actions, WidgetRef ref) {
    final explorer = ref.watch(
      shellControllerProvider.select((s) => s.explorerPaneVisible),
    );
    final panel = ref.watch(
      visibleSidePanelProvider.select((panel) => panel != null),
    );
    final hasRoom = ref.watch(sidePanelRoomProvider);
    final focus = ref.watch(terminalMaximizedProvider);
    final terminal = ref.watch(
      terminalSessionsControllerProvider.select((s) => s.tabs.isNotEmpty),
    );
    final surfaces = SidePanelSurface.offered(
      debugMode: ref.watch(
        settingsControllerProvider.select((s) => s.debugMode),
      ),
      notesEnabled: ref.watch(notesEnabledProvider),
    );
    final hidden = ref.watch(hiddenSidePanelSurfacesProvider);
    return PlatformMenu(
      label: 'View',
      menus: [
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: explorer ? 'Hide Explorer' : 'Show Explorer',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyB,
                meta: true,
                shift: true,
              ),
              onSelected: actions.toggleExplorer,
            ),
            PlatformMenuItem(
              label: hasRoom
                  ? (panel ? 'Hide Context Panel' : 'Show Context Panel')
                  : 'Context Panel  ·  $kSidePanelNoRoom',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.digit3,
                meta: true,
              ),
              onSelected: hasRoom ? actions.toggleSidePanel : null,
            ),
            PlatformMenu(
              label: 'Tools in More',
              menus: [
                PlatformMenuItemGroup(
                  members: [
                    for (final surface in surfaces)
                      PlatformMenuItem(
                        label: hidden.contains(surface)
                            ? 'Show ${surface.label}'
                            : 'Hide ${surface.label}',
                        onSelected: () => actions.setSurfaceHidden(
                          surface,
                          hidden: !hidden.contains(surface),
                        ),
                      ),
                  ],
                ),
                PlatformMenuItem(
                  label: 'Show all',
                  onSelected: hidden.isEmpty ? null : actions.showAllSurfaces,
                ),
              ],
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: 'Inbox',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyA,
                meta: true,
                shift: true,
              ),
              onSelected: () => showShellArea(ref, ShellArea.inbox),
            ),
            for (final surface in surfaces)
              PlatformMenuItem(
                label: surface.label,
                onSelected: hasRoom ? () => actions.showSurface(surface) : null,
              ),
          ],
        ),
        // The terminal's verbs, as in the in-window View menu.
        PlatformMenuItemGroup(
          members: [
            PlatformMenu(
              label: 'Terminal',
              menus: [
                PlatformMenuItem(
                  label: 'Find in Scrollback',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyF,
                    meta: true,
                    shift: true,
                  ),
                  onSelected: terminal ? actions.findInScrollback : null,
                ),
                PlatformMenuItem(
                  label: 'Command Snippets',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyS,
                    meta: true,
                    shift: true,
                  ),
                  onSelected: terminal ? actions.commandSnippets : null,
                ),
                PlatformMenuItem(
                  label: 'Commands Run Here…',
                  onSelected: terminal ? actions.commandsRun : null,
                ),
              ],
            ),
          ],
        ),
        PlatformMenuItemGroup(
          members: [
            PlatformMenuItem(
              label: focus ? 'Leave Zen' : 'Enter Zen',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.backslash,
                meta: true,
              ),
              onSelected: actions.toggleFocusMode,
            ),
          ],
        ),
      ],
    );
  }

  PlatformMenu _toolsMenu(ShellMenuActions actions) => PlatformMenu(
    label: 'Tools',
    menus: [
      PlatformMenuItem(label: 'Settings', onSelected: actions.openSettings),
    ],
  );
}
