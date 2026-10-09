// The on-screen marker and the tab's Resume and New session buttons.
part of '../overview_tab_view.dart';

/// Counts the dashboard as drawn while it is, for the chime to hold back:
/// what is in front of the person needs no sound.
class _OnScreen extends ConsumerStatefulWidget {
  const _OnScreen({required this.child});

  final Widget child;

  @override
  ConsumerState<_OnScreen> createState() => _OnScreenState();
}

class _OnScreenState extends ConsumerState<_OnScreen> {
  late final OverviewOnScreen _shown;
  var _counted = false;

  @override
  void initState() {
    super.initState();
    _shown = ref.read(overviewOnScreenProvider.notifier);
    // After the frame: a provider is not changed while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _shown.add();
      _counted = true;
    });
  }

  @override
  void dispose() {
    if (_counted) {
      final shown = _shown;
      Future.microtask(shown.remove);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// **Resume…**: a stopped or ended session brought back from here, kept on
/// the dashboard unless the person unticks it, which this device remembers.
class _ResumeButton extends ConsumerWidget {
  const _ResumeButton({required this.narrow});

  /// Whether the tab is too narrow for words beside the glyph.
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void resume() => unawaited(showOverviewResume(context, ref));
    return narrow
        ? IconButton(
            key: const ValueKey('overview-resume'),
            tooltip: 'Resume… (R)',
            onPressed: resume,
            icon: const Icon(AppIcons.clockCounterClockwise),
          )
        : Tooltip(
            message: 'Resume a stopped or ended session (R)',
            child: TextButton.icon(
              key: const ValueKey('overview-resume'),
              onPressed: resume,
              icon: const Icon(AppIcons.clockCounterClockwise),
              label: const Text('Resume…'),
            ),
          );
  }
}

/// **New session**, from here: the app's own dialog, in chat form where the
/// agent has one, kept here — started at the server, no tab, its card picked
/// and peeked — unless the person unticks it, which this device remembers.
class _NewSessionButton extends ConsumerWidget {
  const _NewSessionButton({required this.narrow});

  /// As [_ResumeButton.narrow].
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void start() {
      final prefs = ref.read(overviewPrefsProvider.notifier);
      final focus = ref.read(overviewFocusProvider.notifier);
      unawaited(
        NewSessionDialog.show(
          context,
          // Ticked as the background setting says; unticking is for this
          // start only.
          keepHere: ref.read(launchInBackgroundProvider),
          preferChat: true,
          // The session in view may be its parent, but only if the person
          // ticks it: from here a session starts on its own.
          parentSessionId: ref.read(overviewFocusProvider).peeked,
          linkToParent: false,
          onStarted: (session, {required keptHere}) {
            if (keptHere) {
              prefs.setView(OverviewView.board);
              focus.peek(session.id);
            }
          },
        ),
      );
    }

    return narrow
        ? IconButton(
            key: const ValueKey('overview-new-session'),
            tooltip: 'New session',
            onPressed: start,
            icon: const Icon(AppIcons.plus),
          )
        : TextButton.icon(
            key: const ValueKey('overview-new-session'),
            onPressed: start,
            icon: const Icon(AppIcons.plus),
            label: const Text('New session'),
          );
  }
}

/// **Run a pipeline**, beside New session where the header has room for it;
/// narrower, the window's + menu and the command palette offer it.
class _RunPipelineButton extends StatelessWidget {
  const _RunPipelineButton();

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('overview-run-pipeline'),
    tooltip: 'Run a pipeline…',
    onPressed: () => unawaited(showRunPipeline(context)),
    icon: const Icon(AppIcons.treeStructure),
  );
}

/// **Todos**, on the phone's Dashboard header: the open count on it, and the
/// todos a tap away as a page of their own.
class OverviewTodosButton extends ConsumerWidget {
  const OverviewTodosButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openTodoCountProvider);
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: const ValueKey('overview-todos'),
      tooltip: open == 0 ? 'Todos' : 'Todos · $open open',
      onPressed: () => openTodosPage(context, ref),
      icon: Badge.count(
        count: open,
        isLabelVisible: open > 0,
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        child: const Icon(AppIcons.listChecks),
      ),
    );
  }
}
