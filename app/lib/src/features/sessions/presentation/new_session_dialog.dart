import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../../app/widgets/full_screen_form.dart';
import '../../../core/capabilities/capabilities.dart';
import '../../agents/application/agent_installations_controller.dart';
import '../../agents/application/agent_providers.dart';
import '../../agents/application/folded_installations.dart';
import '../../settings/application/settings_controller.dart';
import '../../agents/presentation/acp_login_dialog.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused, DataRefusalCode;
import 'package:agent_cli/descriptors.dart' show AgentRunForm;
import 'package:agent_cli/discovery.dart';
import '../../environments/application/environment_values.dart'
    show EnvironmentPath;
import '../../environments/application/environments_controller.dart';
import 'package:karmashala_git/git.dart';
import '../../explorer/application/explorer_actions.dart';
import '../../git/application/changes_providers.dart';
import '../../git/application/git_providers.dart';
import 'package:karmashala_git/worktrees.dart';
import '../../git/presentation/worktree_creation_view.dart';
import '../../projects/application/projects_controller.dart';
import '../../projects/presentation/new_project_dialog.dart';
import '../../terminal/application/system_terminal_providers.dart';
import 'package:karmashala_terminal_runtime/system_terminals.dart';
import '../application/new_session_memory.dart';
import '../application/session_defaults.dart';
import '../application/session_launcher.dart';
import '../application/session_providers.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:karmashala_session/launch.dart';
import 'package:karmashala_session/lineage.dart' show SessionDepth, SessionLink;
import 'package:karmashala_session/session.dart' show Session;
import 'session_destination_picker.dart';
import 'slow_start_note.dart';
import 'filter_menu_field.dart';
import 'new_dialog_section.dart';
import 'new_session_agent_cards.dart';

part 'new_session_dialog/fields.dart';
part 'new_session_dialog/places.dart';
part 'new_session_dialog/start.dart';

/// Where a new session's work lands (spec §5, board N3). [existing] is an
/// existing branch — checked out in a new worktree — or an existing worktree,
/// joined.
enum _WorkPlace { checkout, newWorktree, existing }

/// The prefixes of an existing-place pick: one choice list holds both kinds.
const _pickWorktree = 'worktree:';
const _pickBranch = 'branch:';

/// Whether [name] could be a branch: the refusals of
/// `git check-ref-format --branch` a person is likely to type, caught before
/// the server is asked.
bool _isBranchName(String name) =>
    !name.startsWith('-') &&
    !name.startsWith('/') &&
    !name.endsWith('/') &&
    !name.endsWith('.') &&
    !name.endsWith('.lock') &&
    !name.contains('..') &&
    !name.contains('//') &&
    !name.contains('@{') &&
    !RegExp(r'[\s~^:?*\[\\\x00-\x1f\x7f]').hasMatch(name);

/// A session [NewSessionDialog] started, and whether it opened no tab.
typedef NewSessionStarted =
    void Function(Session session, {required bool keptHere});

/// Creates a session **where you say**. Browsing and cancelling leaves the
/// app's selection alone; pressing Start moves it, it being no longer a guess.
class NewSessionDialog extends ConsumerStatefulWidget {
  const NewSessionDialog({
    this.targetPaneId,
    this.destination,
    this.firstPrompt,
    this.title,
    this.keepHere = false,
    this.preferChat = false,
    this.onStarted,
    this.parentSessionId,
    this.linkToParent = true,
    super.key,
  });

  /// Opens the session flow, optionally placing an in-app session in an empty
  /// split instead of creating another workbench tab.
  /// A phone not granted `start_session` is told so instead: every way in
  /// comes through here.
  static Future<void> show(
    BuildContext context, {
    String? targetPaneId,
    SessionDestination? destination,
    String? firstPrompt,
    String? title,
    bool keepHere = false,
    bool preferChat = false,
    NewSessionStarted? onStarted,
    String? parentSessionId,
    bool linkToParent = true,
  }) {
    final container = ProviderScope.containerOf(context, listen: false);
    if (!container.read(capabilitiesProvider).mayStart) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(kStartNotGranted)));
      return Future.value();
    }
    return showFormDialog<void>(
      context: context,
      builder: (_) => NewSessionDialog(
        targetPaneId: targetPaneId,
        destination: destination,
        firstPrompt: firstPrompt,
        title: title,
        keepHere: keepHere,
        preferChat: preferChat,
        onStarted: onStarted,
        parentSessionId: parentSessionId,
        linkToParent: linkToParent,
      ),
    );
  }

  /// The session this one may be started under. Null offers no link.
  final String? parentSessionId;

  /// Whether "Link to …" starts ticked: on from a session's own ⋯, off from
  /// the dashboard, where the session in view is only a suggestion.
  final bool linkToParent;

  final String? targetPaneId;

  /// Whether "Keep working here (don't open a tab)" starts ticked: the
  /// session then starts at the server and no tab opens or takes focus.
  final bool keepHere;

  /// Whether an agent with a chat form starts in it unless the person picks.
  final bool preferChat;

  /// Told of the session once it started, and whether it was kept here.
  final NewSessionStarted? onStarted;

  /// Filled into the first prompt for the person to read, edit and start:
  /// a review, a crash or a failed run handed over is never sent unseen.
  final String? firstPrompt;

  /// The session title the dialog opens with, in place of the default.
  final String? title;

  /// Where the dialog opens pointed, when the caller already named a project
  /// or a checkout — quick open's project step. Null is whatever the app is
  /// pointed at ([defaultSessionDestinationProvider]). Either way the
  /// selection is left alone until Start.
  final SessionDestination? destination;

  @override
  ConsumerState<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends ConsumerState<NewSessionDialog> {
  final _titleController = TextEditingController(text: defaultSessionTitle);

  /// What the agent is told first, if anything: the session starts with it
  /// rather than at an empty prompt.
  final _promptController = TextEditingController();
  AgentInstallation? _installation;

  /// The agent the person picked, whichever machine it was on: a change
  /// of project keeps it wherever it is installed there too.
  String? _pickedAgentId;

  /// Null only while the workspace has no projects at all.
  SessionDestination? _destination;

  /// Whether [_destination]'s checkout is under git, as far as the filesystem
  /// could say. Starts — and stays, for an SSH checkout — at
  /// [GitPresence.unknown], which offers a worktree: not having looked is not
  /// the same as having found a plain folder.
  GitPresence _presence = GitPresence.unknown;
  _WorkPlace _place = _WorkPlace.checkout;

  /// The new worktree's branch; blank lets the server name it after the session.
  final _branchController = TextEditingController();

  /// What the new branch starts from; null is the checkout's HEAD.
  String? _base;

  /// The destination's worktrees, read once per destination; null until read.
  List<GitWorktree>? _worktrees;

  /// The destination's branches, local and remote-tracking, read once per
  /// destination; null until read, or when the server could not list them —
  /// then the bases fall back to the branches the worktrees name.
  List<GitBranchRef>? _branches;
  bool _branchesRead = false;

  /// The existing branch or worktree picked: [_pickBranch] or [_pickWorktree]
  /// and its name or path.
  String? _existingPick;
  bool _external = false;
  late bool _keepHere = widget.keepHere;
  late bool _linkParent = widget.parentSessionId != null && widget.linkToParent;
  SystemTerminal? _terminal;
  bool _busy = false;
  String? _error;

  /// The installation whose agent asked to be logged in before it would
  /// start, which the error then offers to log in.
  AgentInstallation? _loginFor;

  /// What the last login said, shown until the next start.
  String? _loginNotice;

  /// Set once a start has been busy for a while: an agent run through npx
  /// is downloaded on its first start, and a silent spinner looked hung.
  bool _slowStart = false;
  Timer? _slowStartTimer;

  /// The worktree this launch is creating; kept after it ends, so a failed
  /// stage's output stays on screen beside the error.
  WorktreeCreationTracker? _creation;

  /// Holds focus whenever no control inside the dialog does — after a click on
  /// a card or the background — so the dialog's keys keep working.
  final _keys = FocusNode(debugLabel: 'New session dialog');

  /// The agent cards and the installation picked, as last built: what the
  /// keys pick among.
  List<FoldedInstallations> _cards = const [];
  AgentInstallation? _shownInstallation;

  final _promptFocus = FocusNode(debugLabel: 'First message');

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_keepFocusInDialog);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keepFocusInDialog();
      _focusPromptIfInView();
    });
    if (widget.firstPrompt case final prompt?) _promptController.text = prompt;
    if (widget.title case final title?) _titleController.text = title;
    // Taken once, never overwriting the picker's own choice — but still
    // listened to, so a project added from the empty state below is picked up.
    _destination =
        widget.destination ?? ref.read(defaultSessionDestinationProvider);
    _afterDestinationChanged();
    ref.listenManual(defaultSessionDestinationProvider, (_, next) {
      if (_destination == null && next != null) {
        setState(() => _destination = next);
        _afterDestinationChanged();
      }
    });
  }

  /// The first message is what the person came to type, so it takes focus —
  /// but only when it is already on screen: focusing it would scroll the
  /// project and the agents out of view. Never on a phone, whose keyboard
  /// would cover them.
  void _focusPromptIfInView() {
    if (!mounted || opensFullScreen(context)) return;
    final box = _promptFocus.context?.findRenderObject();
    if (box == null || !box.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    final position = _promptFocus.context == null
        ? null
        : Scrollable.maybeOf(_promptFocus.context!)?.position;
    final inView =
        viewport == null ||
        position == null ||
        viewport.getOffsetToReveal(box, 1.0).offset <= position.pixels;
    if (inView) _promptFocus.requestFocus();
  }

  /// Focus that fell back to a scope around the dialog — its route's — comes
  /// to [_keys] instead.
  void _keepFocusInDialog() {
    final primary = FocusManager.instance.primaryFocus;
    if (!mounted || primary == null || primary == _keys) return;
    if (primary is FocusScopeNode && _keys.ancestors.contains(primary)) {
      _keys.requestFocus();
    }
  }

  /// Whether the key would be typed into a text field rather than act.
  static bool _typingInField() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText ||
            context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  static const _digitKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  /// 1–9 and the arrows pick a card, T and C its form — plain keys, so never
  /// while a field is taking text. The arrows only while nothing else has
  /// focus: on a control they move focus, as everywhere.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (_busy ||
        _typingInField() ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final current = _cards.indexWhere((g) => g.contains(_shownInstallation));
    final bool acted;
    if (_digitKeys.indexOf(key) case final digit when digit >= 0) {
      acted = _pickCard(digit);
    } else if (key == LogicalKeyboardKey.keyT) {
      acted = _pickForm(current, AgentRunForm.terminal);
    } else if (key == LogicalKeyboardKey.keyC) {
      acted = _pickForm(current, AgentRunForm.chat);
    } else if (_keys.hasPrimaryFocus) {
      // Two cards to a row.
      final step = switch (key) {
        LogicalKeyboardKey.arrowRight => 1,
        LogicalKeyboardKey.arrowLeft => -1,
        LogicalKeyboardKey.arrowDown => 2,
        LogicalKeyboardKey.arrowUp => -2,
        _ => 0,
      };
      acted = step != 0 && _pickCard(current < 0 ? 0 : current + step);
    } else {
      acted = false;
    }
    return acted ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _pickCard(int index) {
    if (index < 0 || index >= _cards.length) return false;
    _pick(pickAgentCard(ref, _cards[index]));
    return true;
  }

  bool _pickForm(int card, AgentRunForm form) {
    if (card < 0 || !_cards[card].offersChoice) return false;
    _pick(pickAgentCard(ref, _cards[card], form: form));
    return true;
  }

  void _pick(AgentInstallation installation) => setState(() {
    _installation = installation;
    _pickedAgentId = installation.agentId;
  });

  @override
  void dispose() {
    FocusManager.instance.removeListener(_keepFocusInDialog);
    _keys.dispose();
    _promptFocus.dispose();
    _slowStartTimer?.cancel();
    _titleController.dispose();
    _promptController.dispose();
    _branchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Never null since a workspace with no projects opens on "No project";
    // kept nullable for the moment before the first frame reads the default.
    final destination = _destination ?? const SessionDestination.scratch();
    final checkout = destination.checkout;
    final scratch = destination.isScratch;

    // Only the agents installed **where the session will run**: one discovered
    // on Windows is a Windows path, unresolvable inside a WSL checkout. A
    // session without a project runs wherever its agent is, so every agent.
    // An installation of an agent the registry no longer knows (a removed ACP
    // agent's leftover row) is not offered.
    final registry = ref.watch(agentRegistryProvider);
    final installations = [
      for (final i in ref.watch(agentInstallationsControllerProvider))
        if (registry.adapterFor(i.agentId) != null &&
            (scratch ||
                (checkout != null &&
                    i.environmentId == checkout.path.environmentId)))
          i,
    ];
    final found = scratch
        ? _agentForScratch(installations)
        : _agentFor(checkout, installations);
    _cards = foldInstallations(registry, installations);
    // Chat where the agent has one, until the person picks: a chat's asks
    // can all be answered from the Overview.
    final installation = widget.preferChat && _installation == null
        ? _cards
                  .where((c) => c.contains(found))
                  .firstOrNull
                  ?.installationFor(AgentRunForm.chat) ??
              found
        : found;
    _shownInstallation = installation;

    // A worktree is git's, so it is offered only where there is a repository to
    // take one from. Only a positive [GitPresence.notARepository] withdraws it.
    final worktreeOffered =
        checkout != null && _presence != GitPresence.notARepository;
    final externalOffered = ref.watch(
      capabilitiesProvider.select((c) => c.externalTerminalSessions),
    );

    final canStart =
        !_busy && (checkout != null || scratch) && installation != null;
    void start() => _create(
      installation,
      place: worktreeOffered ? _place : _WorkPlace.checkout,
    );
    // While a worktree is being made, Cancel stops that — and cleans up —
    // rather than closing a dialog whose launch would carry on unseen.
    final VoidCallback? cancel = !_busy
        ? () => Navigator.of(context).pop()
        : (_creation?.canCancel ?? false)
        ? () {
            _creation!.cancel();
            setState(() {});
          }
        : null;
    final fullScreen = opensFullScreen(context);
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One dialog, two tabs (spec §5): Project swaps this dialog for
        // the new-project one in the same place. In the body, not the
        // title, so it scrolls into view with the rest.
        NewKindSwitch(
          current: NewKind.session,
          onChanged: (_) {
            final navigator = Navigator.of(context);
            final host = navigator.context;
            navigator.pop();
            NewProjectDialog.show(host);
          },
        ),
        // Four labelled parts in the order the choice is made: where it
        // runs (which decides the agents offered), who runs it, where the
        // work lands, what it is told.
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.parentSessionId case final parent?)
              NewDialogSection(
                label: 'Sub-session',
                first: true,
                child: _parentChoice(parent),
              ),
            NewDialogSection(
              label: 'Project & machine',
              first: widget.parentSessionId == null,
              child: SessionDestinationPicker(
                destination: destination,
                enabled: !_busy,
                onChanged: (picked) {
                  setState(() {
                    _error = null;
                    _destination = picked;
                    // The installation picked is kept: still offered
                    // there, it stays; else `_agentFor` finds the same
                    // agent on the new machine, else the default.
                  });
                  _afterDestinationChanged();
                },
              ),
            ),
            NewDialogSection(
              label: 'Agent',
              child: installations.isEmpty
                  ? _noAgents(checkout)
                  : NewSessionAgentCards(
                      installations: installations,
                      selected: installation,
                      enabled: !_busy,
                      onSelected: _pick,
                    ),
            ),
            if (externalOffered || worktreeOffered)
              NewDialogSection(
                label: 'Where it works',
                child: _whereItWorks(
                  worktreeOffered,
                  checkout,
                  externalOffered: externalOffered,
                ),
              ),
            NewDialogSection(
              label: 'First prompt',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _promptController,
                    focusNode: _promptFocus,
                    minLines: 2,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'First message (optional)',
                      hintText: 'What should the agent start on?',
                    ),
                  ),
                ],
              ),
            ),
            if (!fullScreen) ...[
              const SizedBox(height: Insets.sm),
              Text(
                'Ctrl+Enter start · Esc cancel · 1–9 or arrows pick an agent '
                '· T / C terminal or chat',
                key: const ValueKey('new-session-key-hints'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_creation != null) ...[
              const SizedBox(height: Insets.md),
              WorktreeCreationLiveView(tracker: _creation!),
            ],
            if (_error != null) ...[
              const SizedBox(height: Insets.md),
              DesktopErrorBanner(_error!),
            ],
            if (_loginFor case final login?)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: _busy ? null : () => _logIn(login),
                  child: const Text('Log in…'),
                ),
              ),
            if (_loginNotice case final notice?) ...[
              const SizedBox(height: Insets.md),
              Text(notice, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_busy && _slowStart) ...[
              const SizedBox(height: Insets.md),
              const SlowStartNote(),
            ],
          ],
        ),
      ],
    );
    // The keys are the dialog's, not a field's: [_keys] wraps everything and
    // holds focus when nothing inside does, and these sit above it.
    Widget owningKeys(Widget dialog) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (canStart) start();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () => cancel?.call(),
      },
      child: Focus(focusNode: _keys, onKeyEvent: _onKey, child: dialog),
    );
    if (fullScreen) {
      return owningKeys(
        FullScreenForm(
          title: 'New session',
          body: body,
          onClose: cancel,
          primary: FilledButton(
            onPressed: canStart ? start : null,
            child: _busy
                ? const InlineSpinner(size: InlineSpinnerSize.medium)
                : const Text('Start'),
          ),
        ),
      );
    }
    return owningKeys(
      // Tab walks the title, then the body, then the actions — three groups
      // in that order, each in reading order inside. One reading order over
      // the whole dialog measured the body as it scrolled under the pinned
      // actions: at the minimum window Tab put the last fields after Start
      // and circled the bottom four stops without returning to the top.
      FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: AlertDialog(
          title: FocusTraversalOrder(
            order: const NumericFocusOrder(0),
            child: FocusTraversalGroup(
              child: const DesktopDialogTitle(
                icon: AppIcons.chatCircleDots,
                title: 'New session',
                subtitle: 'Choose where and how the coding agent should run.',
              ),
            ),
          ),
          // The whole dialog scrolls, title included: with only the body scrolling,
          // Tab left the title field above the window at 1.3x text.
          scrollable: true,
          // One width whatever the agent cards hold, so the dialog does not
          // resize as they load; it still gives way to a narrower window.
          // AlertDialog sizes its body by intrinsics, so nothing in it may be
          // a LayoutBuilder.
          content: FocusTraversalOrder(
            order: const NumericFocusOrder(1),
            child: FocusTraversalGroup(
              child: SizedBox(width: DialogWidth.narrow, child: body),
            ),
          ),
          actions: [
            FocusTraversalOrder(
              order: const NumericFocusOrder(2),
              child: TextButton(onPressed: cancel, child: const Text('Cancel')),
            ),
            FocusTraversalOrder(
              order: const NumericFocusOrder(3),
              child: Tooltip(
                message: 'Start the session (Ctrl+Enter)',
                child: FilledButton(
                  onPressed: canStart ? start : null,
                  child: _busy
                      ? const InlineSpinner(size: InlineSpinnerSize.medium)
                      : const LabelWithChord(
                          label: 'Start',
                          chord: 'Ctrl+Enter',
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
