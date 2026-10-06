import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/code.dart'
    show CodeEditorKeys, SaveDocumentIntent;
import 'package:karmashala_ui/tokens.dart';

import '../../features/cli_detection/presentation/detected_projects_view.dart';
import '../../features/environments/presentation/environment_health_dialog.dart';
import '../../features/files/application/files_tab_actions.dart';
import '../../features/settings/presentation/settings_catalog.dart'
    show SettingsAnchor;

import '../../features/projects/presentation/new_project_dialog.dart';
import '../../features/sessions/presentation/new_session_dialog.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/terminal/application/terminal_sessions_controller.dart';
import 'package:karmashala_terminal_core/geometry.dart';
import '../../features/terminal/presentation/terminal_panel.dart';
import 'keymap.dart';
import 'keymap_controller.dart';
import 'karmashala_about_dialog.dart';
import 'quick_open/quick_open.dart';
import 'tab_picker.dart';
import 'workbench.dart' show terminalTabEntries;
import 'workbench_tabs.dart';
import 'shell_state.dart';
import 'side_panel_state.dart';
import 'shell_area.dart';
import '../../features/notifications/application/attention_inbox.dart';

part 'shell_shortcuts/intents.dart';
part 'shell_shortcuts/chord_table.dart';
part 'shell_shortcuts/chord_lookup.dart';

/// Wraps [child] with the application's desktop keyboard shortcuts, declared
/// once in [shellChords] — see that list for the map and the skip-list.
class ShellShortcuts extends ConsumerStatefulWidget {
  const ShellShortcuts({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<ShellShortcuts> createState() => _ShellShortcutsState();
}

class _ShellShortcutsState extends ConsumerState<ShellShortcuts> {
  /// Where macOS hands back the Cmd chords the Flutter view would have eaten —
  /// its text-input plugin answers key equivalents for the whole window.
  static const MethodChannel _chords = MethodChannel(
    'karmashala/command_chords',
  );

  /// A context below [Actions], since that is where an intent is invoked.
  BuildContext? _actionsContext;

  /// Holds the keyboard between the strokes of a chord of several, so the
  /// next key reaches the keymap rather than the terminal or a text field.
  final FocusNode _sequenceFocus = FocusNode(
    debugLabel: 'keymap chord',
    skipTraversal: true,
  );

  /// The shell's own place for the keyboard, under every chord. Taken back
  /// whenever focus is left parked above the shell — nothing open in the
  /// workspace, a pane that held it closed, a page with no field — or no
  /// chord (Ctrl+K, Ctrl+P, Ctrl+W) reaches [Shortcuts] at all (owner,
  /// 2026-10-02).
  final FocusNode _shellFocus = FocusNode(
    debugLabel: 'shell',
    skipTraversal: true,
  );
  bool _reclaimScheduled = false;

  /// The strokes typed so far, while a chord of several is waiting.
  List<SingleActivator>? _pending;
  List<ShellChord> _candidates = const [];
  FocusNode? _returnFocus;

  @override
  void initState() {
    super.initState();
    _sequenceFocus.addListener(_onSequenceFocus);
    FocusManager.instance.addListener(_onFocusMoved);
    // A bad edit keeps the last good keymap; this says so without a dialog.
    ref.listenManual(
      keymapProvider.select((k) => k.problems),
      (previous, next) => _noticeProblems(previous ?? const [], next),
    );
    if (!Platform.isMacOS) return;
    _chords.setMethodCallHandler(_onChord);
    unawaited(_registerChords());
    // A keymap edit moves Cmd chords, and AppKit forwards only what it was told.
    ref.listenManual(
      keymapProvider.select((k) => k.revision),
      (_, _) => unawaited(_registerChords()),
    );
  }

  /// Whether [node] is a scope above the shell — the route's, the root — where
  /// focus parks when whatever held it inside went away.
  bool _parkedAbove(FocusNode? node) =>
      node == null ||
      (node is FocusScopeNode && _shellFocus.ancestors.contains(node));

  void _onFocusMoved() {
    if (_reclaimScheduled ||
        !_parkedAbove(FocusManager.instance.primaryFocus)) {
      return;
    }
    _reclaimScheduled = true;
    // After the frame: a pane closing hands focus on in the same frame, and
    // only focus still parked then is lost.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reclaimScheduled = false;
      if (!mounted) return;
      if (!_parkedAbove(FocusManager.instance.primaryFocus)) return;
      // Not while the window is in the background: Flutter parks focus then
      // on purpose, and gives it back to the node that had it on return
      // (and [KeyboardFocusKeeper] does if it does not).
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      // Not from under a dialog or another route on top.
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _shellFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    if (Platform.isMacOS) _chords.setMethodCallHandler(null);
    FocusManager.instance.removeListener(_onFocusMoved);
    _shellFocus.dispose();
    _sequenceFocus
      ..removeListener(_onSequenceFocus)
      ..dispose();
    super.dispose();
  }

  void _noticeProblems(List<String> previous, List<String> next) {
    if (next.isEmpty || listEquals(previous, next) || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(
          'keymap.json not applied — the last good keymap is still in use. '
          '${next.first}'
          '${next.length > 1 ? ' (and ${next.length - 1} more)' : ''}',
        ),
        action: SnackBarAction(
          label: 'Keyboard settings',
          onPressed: () =>
              openSettingsTab(ref, anchor: SettingsAnchor.keyboard),
        ),
      ),
    );
  }

  /// The first stroke of a chord of several: wait, holding the keyboard, for
  /// the rest.
  void _beginSequence(KeySequenceIntent intent) {
    final typed = intent.typed;
    final candidates = [
      for (final chord in shellChords)
        if (chord.isSequence &&
            !chord.paneOnly &&
            (intent.inTerminal ? !chord.outsideTerminal : !chord.paneLocal) &&
            _startsWith(chord.strokes, typed))
          chord,
    ];
    if (candidates.isEmpty) return;
    final current = FocusManager.instance.primaryFocus;
    _returnFocus = current == _sequenceFocus ? _returnFocus : current;
    _candidates = candidates;
    setState(() => _pending = typed);
    _sequenceFocus.requestFocus();
  }

  KeyEventResult _onSequenceKey(FocusNode node, KeyEvent event) {
    if (_pending == null || !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    // The first stroke's key-up and repeats, and modifiers pressed on the way
    // to the next stroke, are all part of the wait.
    if (event is! KeyDownEvent || _isModifier(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _endSequence();
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    _advanceSequence(
      SingleActivator(
        event.logicalKey,
        control: keyboard.isControlPressed,
        shift: keyboard.isShiftPressed,
        alt: keyboard.isAltPressed,
        meta: keyboard.isMetaPressed,
      ),
    );
    return KeyEventResult.handled;
  }

  void _advanceSequence(SingleActivator stroke) {
    final typed = [...?_pending, stroke];
    final matches = [
      for (final chord in _candidates)
        if (_startsWith(chord.strokes, typed)) chord,
    ];
    final exact = matches
        .where((c) => c.strokes.length == typed.length)
        .firstOrNull;
    if (exact != null) {
      _endSequence(run: exact.intent);
    } else if (matches.isNotEmpty) {
      setState(() => _pending = typed);
    } else {
      _endSequence();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text('${keymapSequenceLabel(typed)} is not a shortcut.'),
        ),
      );
    }
  }

  /// Gives the keyboard back to whoever had it, then runs [run] from there —
  /// a pane's own verbs are found above the pane.
  void _endSequence({Intent? run}) {
    final back = _returnFocus;
    final backContext = back?.context;
    _returnFocus = null;
    _candidates = const [];
    if (_pending != null && mounted) setState(() => _pending = null);
    if (backContext != null) back?.requestFocus();
    if (run == null) return;
    final context = backContext ?? _actionsContext;
    if (context != null && context.mounted) Actions.maybeInvoke(context, run);
  }

  /// Clicking away abandons a chord half typed.
  void _onSequenceFocus() {
    if (_pending != null && !_sequenceFocus.hasPrimaryFocus) {
      _returnFocus = null;
      _candidates = const [];
      setState(() => _pending = null);
    }
  }

  static bool _startsWith(
    List<SingleActivator> strokes,
    List<SingleActivator> typed,
  ) {
    if (typed.length > strokes.length) return false;
    for (var i = 0; i < typed.length; i++) {
      if (!sameKeys(strokes[i], typed[i])) return false;
    }
    return true;
  }

  static bool _isModifier(LogicalKeyboardKey key) =>
      LogicalKeyboardKey.expandSynonyms({
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.shift,
        LogicalKeyboardKey.alt,
        LogicalKeyboardKey.meta,
      }).contains(key) ||
      key == LogicalKeyboardKey.capsLock ||
      key == LogicalKeyboardKey.fn;

  /// The character each Cmd chord is reached by, as AppKit reports it; pane-only
  /// chords are left out, having no shell-level action to invoke.
  Future<void> _registerChords() async {
    final plain = <String>[];
    final shifted = <String>[];
    for (final chord in shellChords) {
      if (chord.paneOnly || !chord.activator.meta) continue;
      final key = chord.activator.trigger.keyLabel.toLowerCase();
      if (key.isEmpty || key.length > 1) continue;
      (chord.activator.shift ? shifted : plain).add(key);
    }
    plain.addAll(focusedCommandChords.keys);
    try {
      await _chords.invokeMethod('register', {
        'plain': plain,
        'shifted': shifted,
      });
    } on PlatformException {
      // A host without the channel simply keeps the old behaviour.
    } on MissingPluginException {
      // Same.
    }
  }

  Future<void> _onChord(MethodCall call) async {
    if (call.method != 'chord') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final key = arguments['key'];
    final shift = arguments['shift'] == true;
    // Mid-chord, a forwarded Cmd key is the next stroke, not a command.
    if (key is String && key.length == 1 && _pending != null) {
      _advanceSequence(
        SingleActivator(
          LogicalKeyboardKey(key.codeUnitAt(0)),
          meta: true,
          shift: shift,
        ),
      );
      return;
    }
    if (key is String && invokeFocusedCommandChord(key, shift: shift)) return;
    final context = _actionsContext;
    if (key is! String || context == null || !context.mounted) return;
    for (final chord in shellChords) {
      if (chord.paneOnly || !chord.activator.meta) continue;
      if (chord.activator.shift != shift) continue;
      if (chord.activator.trigger.keyLabel.toLowerCase() != key) continue;
      Actions.maybeInvoke(context, chord.firstStrokeIntent);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final child = widget.child;
    final controller = ref.read(shellControllerProvider.notifier);
    // Rebuilt when a keymap is applied, so [shellShortcutMap] is read afresh.
    ref.watch(keymapProvider.select((k) => k.revision));
    return Shortcuts(
      shortcuts: shellShortcutMap,
      child: Actions(
        actions: {
          OpenQuickOpenIntent: CallbackAction<OpenQuickOpenIntent>(
            onInvoke: (intent) {
              QuickOpen.show(context, initialQuery: intent.query);
              return null;
            },
          ),
          OpenAttentionInboxIntent: CallbackAction<OpenAttentionInboxIntent>(
            onInvoke: (intent) {
              // The Inbox is an area of the activity strip: the same chord
              // shows it in the sidebar, and hides the sidebar again.
              toggleShellArea(ref, ShellArea.inbox);
              return null;
            },
          ),
          // The same calls the Workspace and Tools menus make.
          NewSessionIntent: CallbackAction<NewSessionIntent>(
            onInvoke: (intent) {
              NewSessionDialog.show(context);
              return null;
            },
          ),
          NewProjectIntent: CallbackAction<NewProjectIntent>(
            onInvoke: (intent) {
              NewProjectDialog.show(context);
              return null;
            },
          ),
          OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
            onInvoke: (intent) {
              openSettingsTab(ref);
              return null;
            },
          ),
          OpenUsageIntent: CallbackAction<OpenUsageIntent>(
            onInvoke: (intent) {
              openUsageTab(ref);
              return null;
            },
          ),
          OpenLogsIntent: CallbackAction<OpenLogsIntent>(
            onInvoke: (intent) {
              openLogsTab(ref);
              return null;
            },
          ),
          OpenOverviewIntent: CallbackAction<OpenOverviewIntent>(
            onInvoke: (intent) {
              openOverviewTab(ref);
              return null;
            },
          ),
          ShowShellAreaIntent: CallbackAction<ShowShellAreaIntent>(
            onInvoke: (intent) {
              // Ctrl+4 on a client with no Devices area does nothing.
              if (!shellAreaShown(ref, intent.area)) return null;
              final shell = ref.read(shellControllerProvider);
              final showing =
                  shell.explorerPaneVisible &&
                  ref.read(shellAreaProvider) == intent.area;
              if (showing && shell.focusedPane == ShellPane.explorer) {
                controller.focusPane(ShellPane.detail);
              } else {
                showShellArea(ref, intent.area);
                controller.focusPane(ShellPane.explorer);
              }
              return null;
            },
          ),
          FocusPaneIntent: CallbackAction<FocusPaneIntent>(
            onInvoke: (intent) {
              controller.focusPane(intent.pane);
              return null;
            },
          ),
          ToggleExplorerPaneIntent: CallbackAction<ToggleExplorerPaneIntent>(
            onInvoke: (intent) {
              controller.toggleExplorerPane();
              return null;
            },
          ),
          OpenNextWaitingIntent: CallbackAction<OpenNextWaitingIntent>(
            onInvoke: (intent) {
              // Says nothing when nobody is waiting rather than moving the
              // window somewhere arbitrary: an empty inbox is an answer.
              ref.read(attentionInboxProvider.notifier).openNext();
              return null;
            },
          ),
          ToggleSidePanelIntent: CallbackAction<ToggleSidePanelIntent>(
            onInvoke: (intent) {
              ref.read(sidePanelProvider.notifier).toggle();
              return null;
            },
          ),
          ToggleTerminalIntent: CallbackAction<ToggleTerminalIntent>(
            onInvoke: (intent) {
              ref
                  .read(terminalSessionsControllerProvider.notifier)
                  .toggleFaceHere();
              return null;
            },
          ),
          ToggleFocusModeIntent: CallbackAction<ToggleFocusModeIntent>(
            onInvoke: (intent) {
              ref.read(terminalMaximizedProvider.notifier).toggle();
              return null;
            },
          ),
          NewTerminalTabIntent: CallbackAction<NewTerminalTabIntent>(
            onInvoke: (intent) {
              final terminal = TerminalActions(ref);
              terminal.open(terminal.defaultProfile());
              return null;
            },
          ),
          CloseTerminalTabIntent: CallbackAction<CloseTerminalTabIntent>(
            // The pane's verb, which closes the tab with its last pane.
            onInvoke: (intent) {
              TerminalActions(ref).closeFocusedPane();
              return null;
            },
          ),
          StepTerminalTabIntent: CallbackAction<StepTerminalTabIntent>(
            onInvoke: (intent) {
              final sessions = ref.read(
                terminalSessionsControllerProvider.notifier,
              );
              intent.forward ? sessions.nextTab() : sessions.previousTab();
              return null;
            },
          ),
          TerminalFontSizeIntent: CallbackAction<TerminalFontSizeIntent>(
            onInvoke: (intent) {
              final settings = ref.read(settingsControllerProvider.notifier);
              intent.delta == 0
                  ? settings.resetTerminalFontSize()
                  : settings.adjustTerminalFontSize(intent.delta);
              return null;
            },
          ),
          // Here rather than in the pane so a chord and the toolbar button
          // beside it run the same code.
          SplitTerminalPaneIntent: CallbackAction<SplitTerminalPaneIntent>(
            onInvoke: (intent) {
              TerminalActions(ref).split(intent.axis);
              return null;
            },
          ),
          FindInScrollbackIntent: CallbackAction<FindInScrollbackIntent>(
            onInvoke: (intent) {
              TerminalActions(ref).openSearch();
              return null;
            },
          ),
          JumpCommandIntent: CallbackAction<JumpCommandIntent>(
            onInvoke: (intent) {
              TerminalActions(ref).jumpCommand(forward: intent.forward);
              return null;
            },
          ),
          StepPaneInRegionIntent: CallbackAction<StepPaneInRegionIntent>(
            onInvoke: (intent) {
              final sessions = ref.read(
                terminalSessionsControllerProvider.notifier,
              );
              intent.forward
                  ? sessions.nextPaneInRegion()
                  : sessions.previousPaneInRegion();
              return null;
            },
          ),
          MovePaneFocusIntent: CallbackAction<MovePaneFocusIntent>(
            onInvoke: (intent) {
              ref
                  .read(terminalSessionsControllerProvider.notifier)
                  .movePaneFocus(intent.direction);
              return null;
            },
          ),
          KeySequenceIntent: CallbackAction<KeySequenceIntent>(
            onInvoke: (intent) {
              _beginSequence(intent);
              return null;
            },
          ),
          DetectCliSessionsIntent: CallbackAction<DetectCliSessionsIntent>(
            onInvoke: (intent) {
              DetectedProjectsView.show(context);
              return null;
            },
          ),
          ShowCommandsRunIntent: CallbackAction<ShowCommandsRunIntent>(
            onInvoke: (intent) {
              if (ref.read(terminalSessionsControllerProvider).tabs.isEmpty) {
                return null;
              }
              TerminalActions(ref).showCommands(context);
              return null;
            },
          ),
          SwitchTerminalTabIntent: CallbackAction<SwitchTerminalTabIntent>(
            onInvoke: (intent) {
              TabPicker.show(context, terminalTabEntries);
              return null;
            },
          ),
          CheckSystemHealthIntent: CallbackAction<CheckSystemHealthIntent>(
            onInvoke: (intent) {
              EnvironmentHealthDialog.show(context);
              return null;
            },
          ),
          BrowseFilesIntent: CallbackAction<BrowseFilesIntent>(
            onInvoke: (intent) {
              openFilesTabHere(ref);
              return null;
            },
          ),
          OpenAboutIntent: CallbackAction<OpenAboutIntent>(
            onInvoke: (intent) {
              KarmashalaAboutDialog.show(context);
              return null;
            },
          ),
        },
        // A context beneath [Actions], so a chord arriving from the window
        // has somewhere to be invoked.
        child: Builder(
          builder: (context) {
            _actionsContext = context;
            final pending = _pending;
            return Focus(
              focusNode: _sequenceFocus,
              onKeyEvent: _onSequenceKey,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  Focus(focusNode: _shellFocus, autofocus: true, child: child),
                  if (pending != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: Insets.xl,
                      child: Center(
                        child: _SequenceHint(keymapSequenceLabel(pending)),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// What a chord of several has so far, while it waits for the next stroke.
class _SequenceHint extends StatelessWidget {
  const _SequenceHint(this.typed);

  final String typed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(Radii.sm),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.sm,
          ),
          child: Text(
            '$typed was pressed. Waiting for the next key — Esc cancels.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onInverseSurface,
            ),
          ),
        ),
      ),
    );
  }
}
