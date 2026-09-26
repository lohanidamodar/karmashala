import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../application/companion_runtime.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_remote/remote.dart';
import '../application/companion_providers.dart';
import 'companion_chrome.dart';
import 'companion_machine.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'link_banner.dart';
import 'add_project_screen.dart';
import 'session_view_screen.dart';

/// Starting a session on the desktop, from the phone. Every label is what the
/// desktop reported; a mode its agent refuses is shown disabled, not hidden.
class StartSessionScreen extends ConsumerStatefulWidget {
  const StartSessionScreen({this.projectId, super.key});

  /// Preselect this project, when the screen is opened from inside one.
  final String? projectId;

  @override
  ConsumerState<StartSessionScreen> createState() => _StartSessionScreenState();
}

class _StartSessionScreenState extends ConsumerState<StartSessionScreen> {
  final _title = TextEditingController();
  final _message = TextEditingController();

  String? _projectId;
  String? _repositoryId;
  String? _installationId;
  String? _mode;

  /// Start in a worktree of its own, on a new branch, rather than the
  /// checkout itself.
  bool _worktree = false;

  /// The idempotency key for the request as it stands: kept across retries, so
  /// Start after "the desktop did not answer" costs one session; re-minted the
  /// moment any field changes, because that is a different intention.
  late String _key = _newKey();

  bool _starting = false;
  String? _failure;

  String _newKey() => ref.read(companionIdGeneratorProvider).newId();

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
    super.dispose();
  }

  /// The request changed, so the last one's answer is no longer ours to reuse.
  void _formChanged() => _key = _newKey();

  RemoteWorkspaceProject? _project(List<RemoteWorkspaceProject> projects) {
    if (projects.isEmpty) return null;
    final requested = _projectId ?? widget.projectId;
    // A project supplied by the caller is an answer already given; a workspace
    // refresh must not replace it with the first project.
    if (requested != null) {
      for (final project in projects) {
        if (project.projectId == requested) return project;
      }
      return null;
    }
    return projects.first;
  }

  RemoteCheckoutOption? _checkout(RemoteWorkspaceProject project) {
    if (project.checkouts.isEmpty) return null;
    if (_repositoryId != null) {
      for (final checkout in project.checkouts) {
        if (checkout.repositoryId == _repositoryId) return checkout;
      }
      // Never start in another checkout because a refresh removed this one.
      return null;
    }
    return project.checkouts.first;
  }

  RemoteAgentOption? _agent(RemoteCheckoutOption checkout) {
    if (checkout.agents.isEmpty) return null;
    for (final agent in checkout.agents) {
      if (agent.installationId == _installationId) return agent;
    }
    return checkout.agents.first;
  }

  /// The mode the start will ask for: the user's pick when they made one and
  /// this agent can be put into it, else the desktop's own default.
  RemotePermissionOption? _selectedMode(RemoteAgentOption agent) {
    for (final option in agent.permissionModes) {
      if (option.mode == _mode && option.selectable) return option;
    }
    for (final option in agent.permissionModes) {
      if (option.mode == agent.defaultMode) return option;
    }
    return agent.permissionModes.isEmpty ? null : agent.permissionModes.first;
  }

  Future<void> _pickProject(List<RemoteWorkspaceProject> projects) async {
    final picked = await _sheet<String>(
      title: 'Projects on ${readCompanionMachineName(ref)}',
      children: [
        for (final project in projects)
          ListTile(
            leading: const Icon(AppIcons.folder),
            title: Text(project.name, maxLines: 1),
            // Two projects of the same name — one repository set up once per
            // environment — are told apart here and nowhere else.
            subtitle: _beneath(
              environment: project.environmentName,
              detail: project.path,
            ),
            isThreeLine:
                project.environmentName != null && project.path != null,
            selected: project.projectId == _project(projects)?.projectId,
            onTap: () => Navigator.of(context).pop(project.projectId),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _projectId = picked;
      // A project's checkouts and agents are its own; a pick made under the
      // last one cannot survive.
      _repositoryId = null;
      _installationId = null;
      _formChanged();
    });
  }

  Future<void> _pickCheckout(RemoteWorkspaceProject project) async {
    final picked = await _sheet<String>(
      title: 'Checkouts in ${project.name}',
      children: [
        for (final checkout in project.checkouts)
          ListTile(
            leading: Icon(
              AppIcons.folder,
              color: checkout.folderMissing
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            title: Text(checkout.name, maxLines: 1),
            subtitle: _beneath(
              environment: checkout.environmentName,
              detail: _checkoutLine(checkout),
            ),
            isThreeLine:
                checkout.environmentName != null &&
                _checkoutLine(checkout).isNotEmpty,
            selected: checkout.repositoryId == _repositoryId,
            onTap: () => Navigator.of(context).pop(checkout.repositoryId),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _repositoryId = picked;
      _installationId = null;
      _formChanged();
    });
  }

  Future<void> _pickAgent(RemoteCheckoutOption checkout) async {
    final picked = await _sheet<String>(
      title: 'Agents installed here',
      children: [
        for (final agent in checkout.agents)
          ListTile(
            leading: const Icon(AppIcons.robot),
            title: Text(agent.name, maxLines: 1),
            subtitle: agent.version == null ? null : Text(agent.version!),
            selected: agent.installationId == _installationId,
            onTap: () => Navigator.of(context).pop(agent.installationId),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _installationId = picked;
      // Modes belong to an agent, so the pick drops back to the new agent's
      // default rather than carrying a choice made for another CLI.
      _mode = null;
      _formChanged();
    });
  }

  Future<void> _pickMode(RemoteAgentOption agent) async {
    final selected = _selectedMode(agent);
    final picked = await _sheet<String>(
      title: 'How much ${agent.name} may do without asking',
      children: [
        for (final option in agent.permissionModes)
          ListTile(
            enabled: option.selectable,
            leading: Icon(
              // The desktop's own permission vocabulary.
              option.dangerous ? AppIcons.warning : AppIcons.check,
              color: option.dangerous && option.selectable
                  ? SemanticColors.of(context).attention
                  : null,
            ),
            title: Text(option.label),
            subtitle: Text(option.summary),
            isThreeLine: option.summary.length > 60,
            selected: option.mode == selected?.mode,
            trailing: option.mode == selected?.mode
                ? const Icon(AppIcons.check)
                : null,
            onTap: option.selectable
                ? () => Navigator.of(context).pop(option.mode)
                : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _mode = picked;
      _formChanged();
    });
  }

  Future<T?> _sheet<T>({
    required String title,
    required List<Widget> children,
  }) => companionSheet<T>(context, title: title, children: children);

  Future<void> _start(
    RemoteCheckoutOption checkout,
    RemoteAgentOption agent,
    RemotePermissionOption mode,
  ) async {
    if (_starting) return;
    final hostBefore = ref.read(companionGatewayProvider).pairing?.hostId;
    setState(() {
      _starting = true;
      _failure = null;
    });
    try {
      final started = await ref
          .read(companionGatewayProvider)
          .startSession(
            requestId: _key,
            repositoryId: checkout.repositoryId,
            installationId: agent.installationId,
            permissionMode: mode.mode,
            title: _title.text.trim().isEmpty ? null : _title.text.trim(),
            message: _message.text.trim().isEmpty ? null : _message.text.trim(),
            worktree: _worktree,
          );
      if (!mounted) return;
      final hostAfter = ref.read(companionGatewayProvider).pairing?.hostId;
      if (hostBefore != hostAfter) {
        setState(
          () => _failure =
              'The machine this phone is connected to changed while this '
              'session was starting. Try again.',
        );
        return;
      }
      // Replace rather than push: coming back to a filled-in form for a session
      // that now exists would invite starting it twice.
      Navigator.of(context).pushReplacement(
        companionRoute<void>(
          context,
          (_) => SessionViewScreen(sessionId: started.sessionId),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      // The desktop's own sentence: only it knows why it refused.
      setState(() => _failure = companionErrorText(error));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  static String _checkoutLine(RemoteCheckoutOption checkout) => [
    if (checkout.folderMissing) 'Folder not found',
    ?checkout.branch,
    ?(checkout.subPath ?? checkout.path),
  ].join('  ·  ');

  @override
  Widget build(BuildContext context) {
    final granted = ref
        .watch(companionGatewayProvider)
        .capabilities
        .has(Capability.startSession);
    final workspace = ref.watch(companionWorkspaceProvider);

    return Scaffold(
      appBar: companionAppBar(context, title: const Text('New session')),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinkBanner(),
            Expanded(
              child: granted
                  ? companionAsync(
                      workspace,
                      loading: () => const CompanionSkeletonList(lines: 2),
                      error: (error) => CompanionNotice.failure(
                        error: error,
                        onRetry: () =>
                            ref.invalidate(companionWorkspaceProvider),
                      ),
                      data: _form,
                    )
                  : CompanionNotice(
                      icon: AppIcons.warningCircle,
                      title: 'Not granted',
                      tone: NoticeTone.attention,
                      body:
                          'This phone was not granted permission to start '
                          'sessions on ${watchCompanionMachineName(ref)}. '
                          'Pair again and tick "Start new sessions" to use '
                          'it.',
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(List<RemoteWorkspaceProject> projects) {
    final machine = readCompanionMachineName(ref);
    final project = _project(projects);
    if (project == null) {
      final staleSelection = _projectId != null || widget.projectId != null;
      final canAdd =
          !staleSelection &&
          ref
              .read(companionGatewayProvider)
              .capabilities
              .has(Capability.addProject);
      return CompanionNotice(
        icon: AppIcons.folderPlus,
        title: staleSelection
            ? 'Project no longer available'
            : 'Nothing to start in',
        body: staleSelection
            ? 'The project selected for this session is no longer in the '
                  'workspace on $machine. Go back and choose another project.'
            : 'No project with a checkout in it is listed on $machine. Add '
                  'one here and it will show up on the next refresh.',
        actionLabel: canAdd ? 'Add project' : null,
        onAction: canAdd
            ? () async {
                await Navigator.of(context).push(
                  companionRoute<void>(
                    context,
                    (_) => const AddProjectScreen(),
                  ),
                );
                if (mounted) ref.invalidate(companionWorkspaceProvider);
              }
            : null,
      );
    }
    final checkout = _checkout(project);
    if (checkout == null) {
      return CompanionNotice(
        icon: AppIcons.folder,
        title: _repositoryId == null ? 'No checkout here' : 'Checkout changed',
        body: _repositoryId == null
            ? '${project.name} has no repository $machine can start a '
                  'session in.'
            : 'That checkout is no longer available on $machine. '
                  'Go back and choose another checkout.',
      );
    }
    final agent = _agent(checkout);
    final mode = agent == null ? null : _selectedMode(agent);

    return ListView(
      // Capped at a phone's measure past the compact breakpoint: a form set
      // across a tablet cannot be read in one glance (CLAUDE.md §6).
      padding: companionListInsets(
        context,
        const EdgeInsets.only(bottom: Insets.xl),
      ),
      children: [
        _Row(
          icon: AppIcons.folder,
          label: 'Project',
          value: project.name,
          detail: project.path,
          onTap: projects.length > 1 ? () => _pickProject(projects) : null,
        ),
        _Row(
          icon: AppIcons.folderOpen,
          label: 'Checkout',
          value: checkout.name,
          // Named here and not on the project row: the environment a session
          // runs in is the checkout's, and a project root elsewhere would put
          // the two rows in disagreement.
          environment: checkout.environmentName,
          detail: _checkoutLine(checkout),
          alert: checkout.folderMissing,
          onTap: project.checkouts.length > 1
              ? () => _pickCheckout(project)
              : null,
        ),
        if (agent == null)
          Padding(
            padding: const EdgeInsets.all(Insets.lg),
            child: CompanionNotice(
              icon: AppIcons.robot,
              title: 'No agent installed here',
              tone: NoticeTone.attention,
              body:
                  'No agent is installed on $machine in the environment this '
                  'checkout lives in, so there is nothing to start it with.',
            ),
          )
        else ...[
          _Row(
            icon: AppIcons.robot,
            label: 'Agent',
            value: agent.name,
            detail: agent.version,
            onTap: checkout.agents.length > 1
                ? () => _pickAgent(checkout)
                : null,
          ),
          _Row(
            icon: mode != null && mode.dangerous
                ? AppIcons.warning
                : AppIcons.check,
            label: 'Permissions',
            value: mode?.label ?? 'Not offered',
            detail: mode?.summary,
            alert: mode?.dangerous ?? false,
            onTap: () => _pickMode(agent),
          ),
          SwitchListTile(
            secondary: const Icon(AppIcons.gitBranch),
            title: const Text('Own worktree'),
            subtitle: const Text(
              'A new branch in a worktree of its own, so this session\'s '
              'changes stay apart from the checkout.',
            ),
            value: _worktree,
            onChanged: _starting
                ? null
                : (value) => setState(() {
                    _worktree = value;
                    _formChanged();
                  }),
          ),
          _StartFormFields(
            agent: agent,
            title: _title,
            message: _message,
            onChanged: _formChanged,
          ),
          if (_failure case final failure?)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.md,
                Insets.lg,
                0,
              ),
              child: CompanionInlineError(failure),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.lg,
              Insets.lg,
              0,
            ),
            child: CompanionPrimaryButton(
              busy: _starting,
              label: _starting ? 'Starting…' : 'Start session',
              icon: AppIcons.play,
              onPressed: mode == null
                  ? null
                  : () => _start(checkout, agent, mode),
            ),
          ),
        ],
      ],
    );
  }
}

/// The two things typed on the form: a title, and the first message when
/// [agent] can be handed one on its command line.
class _StartFormFields extends StatelessWidget {
  const _StartFormFields({
    required this.agent,
    required this.title,
    required this.message,
    required this.onChanged,
  });

  final RemoteAgentOption agent;
  final TextEditingController title;
  final TextEditingController message;

  /// Any edit: the request is a different one now.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.sm, Insets.lg, 0),
        child: TextField(
          controller: title,
          onChanged: (_) => onChanged(),
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Title',
            helperText: 'Optional — the machine names it if you do not.',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Insets.lg, Insets.md, Insets.lg, 0),
        child: TextField(
          controller: message,
          onChanged: (_) => onChanged(),
          enabled: agent.acceptsOpeningMessage,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: 'First message',
            // Said before it is typed: the launch would decline an opening
            // message this CLI cannot be handed.
            helperText: agent.acceptsOpeningMessage
                ? 'Optional — sent as soon as the session is up.'
                : '${agent.name} takes no opening message on its command '
                      'line. Start it and say it in the session.',
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    ],
  );
}

/// Which execution environment something lives in, in the desktop's own words
/// — "Windows", "WSL · Ubuntu", "SSH · build-box". A line of its own, because
/// this is the answer people were reading the path to work out.
class _Environment extends StatelessWidget {
  const _Environment(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      // A node of its own, so "which environment" is answered separately from
      // the checkout's name for a listener too.
      container: true,
      label: 'Environment: ${spokenEnvironmentLabel(name)}',
      excludeSemantics: true,
      // Two lines: an ellipsised distribution name is the guess this row exists
      // to remove, and 200% text reaches a phone's edge in eight characters.
      child: Text(
        name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: UiDensity.of(context)
            .muted(theme)
            ?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// A picker row's supporting lines. Null when neither says anything, so a tile
/// with nothing to add keeps its single-line height.
Widget? _beneath({String? environment, String? detail}) {
  final lines = [
    if (environment != null) _Environment(environment),
    if (detail != null && detail.isNotEmpty)
      Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
  ];
  if (lines.isEmpty) return null;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: lines,
  );
}

/// One answered question, which opens the rest when there is more than one
/// answer to give.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.value,
    this.environment,
    this.detail,
    this.alert = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;

  /// Where this lives, in the desktop's own words; null when it said nothing.
  final String? environment;

  final String? detail;

  /// Draw it in the error colour: an unreachable folder, or a dangerous mode.
  final bool alert;

  /// Null when there is nothing to choose between, drawn as a plain statement
  /// rather than a control that does nothing.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final semantic = SemanticColors.of(context);
    return ListTile(
      minVerticalPadding: Insets.sm,
      leading: Icon(icon, color: alert ? semantic.attention : null),
      title: Text(label, style: theme.textTheme.labelSmall),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: alert ? semantic.attention : scheme.onSurface,
            ),
          ),
          if (environment != null) _Environment(environment!),
          if (detail != null && detail!.isNotEmpty)
            Text(
              detail!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: UiDensity.of(context).muted(theme),
            ),
        ],
      ),
      trailing: onTap == null
          ? null
          : const Icon(AppIcons.caretDown, size: Touch.iconSmall),
      onTap: onTap,
    );
  }
}
