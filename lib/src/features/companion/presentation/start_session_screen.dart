import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/id_generator_provider.dart';
import '../../environments/domain/environment_label.dart';
import 'package:karmashala_remote/remote.dart';
import '../application/companion_providers.dart';
import 'companion_chrome.dart';
import 'companion_route.dart';
import 'companion_states.dart';
import 'link_banner.dart';
import 'add_project_screen.dart';
import 'session_view_screen.dart';

/// Starting a session on the desktop, from the phone.
///
/// The choice is made from what the desktop **reports** — its projects, the
/// checkouts inside them, and the agents actually installed where each
/// checkout lives — so nothing here is inferred from the sessions that happen
/// to exist. Every label, and every sentence about what a permission mode
/// does to an agent, is the desktop's own wording.
///
/// The permission mode is picked, never assumed: the row starts on the mode
/// the desktop's own settings would use for a new session with that agent,
/// and a mode the agent cannot be put into is shown, disabled, and explained
/// rather than quietly missing.
class StartSessionScreen extends ConsumerStatefulWidget {
  const StartSessionScreen({this.projectId, super.key});

  /// Preselect this project — set when the screen is opened from inside one,
  /// so the user does not re-answer a question they already answered.
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

  /// The idempotency key for the request as it currently stands.
  ///
  /// Minted once and **kept across retries**, which is what makes tapping
  /// Start again after "the desktop did not answer" cost one session rather
  /// than two. Re-minted the moment any field changes, because a different
  /// request is a different intention and must not be answered with the
  /// session the last one produced.
  late String _key = _newKey();

  bool _starting = false;
  String? _failure;

  String _newKey() => ref.read(idGeneratorProvider).newId();

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
    // A project supplied by the caller is an answer the user has already
    // given. Never silently replace it with the first project if the host's
    // workspace changed while this screen was open.
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
      // Do not start in another checkout after a workspace refresh removed
      // the selected one.
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
      title: 'Projects on this desktop',
      children: [
        for (final project in projects)
          ListTile(
            leading: const Icon(AppIcons.folder),
            title: Text(project.name, maxLines: 1),
            // Two projects of the same name — the same repository set up once
            // per environment — are told apart here and nowhere else, so the
            // environment is named in the picker even though the settled row
            // leaves it to the checkout beneath it.
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
      // last one cannot survive into this one.
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
      // Modes belong to an agent. Dropping the pick sends the row back to the
      // new agent's own default rather than carrying a choice made for
      // another CLI.
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
              // The desktop's own permission vocabulary: a warning for the
              // dangerous mode, a tick for one the agent honours.
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
          );
      if (!mounted) return;
      final hostAfter = ref.read(companionGatewayProvider).pairing?.hostId;
      if (hostBefore != hostAfter) {
        setState(() => _failure =
            'The active desktop changed while this session was starting. '
            'Try again.');
        return;
      }
      // Replace rather than push: coming back to a filled-in form for a
      // session that now exists would invite starting it twice.
      Navigator.of(context).pushReplacement(
        companionRoute<void>(
          context,
          (_) => SessionViewScreen(sessionId: started.sessionId),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      // The desktop's own sentence. It refused, or could not do it, and only
      // it knows why — "something went wrong" is nothing anyone can act on.
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
                  : const CompanionNotice(
                      icon: AppIcons.warningCircle,
                      title: 'Not granted',
                      tone: NoticeTone.attention,
                      body:
                          'This desktop did not grant this phone permission to '
                          'start sessions. Pair again and tick "Start new '
                          'sessions" to use it.',
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(List<RemoteWorkspaceProject> projects) {
    final project = _project(projects);
    if (project == null) {
      final staleSelection = _projectId != null || widget.projectId != null;
      return CompanionNotice(
        icon: AppIcons.folderPlus,
        title: staleSelection ? 'Project no longer available' : 'Nothing to start in',
        body: staleSelection
            ? 'The project selected for this session is no longer in the '
                'desktop workspace. Go back and choose another project.'
            : 'Your desktop lists no project with a checkout in it. Add one '
                'here and it will show up on the next refresh.',
        actionLabel: !staleSelection &&
                ref
                    .read(companionGatewayProvider)
                    .capabilities
                    .has(Capability.addProject)
            ? 'Add project'
            : null,
        onAction: !staleSelection &&
                ref
                    .read(companionGatewayProvider)
                    .capabilities
                    .has(Capability.addProject)
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
        body:
            _repositoryId == null
                ? '${project.name} has no repository your desktop can start '
                    'a session in.'
                : 'That checkout is no longer available on the desktop. '
                    'Go back and choose another checkout.',
      );
    }
    final agent = _agent(checkout);
    final mode = agent == null ? null : _selectedMode(agent);
    final theme = Theme.of(context);
    final muted = UiDensity.of(context).muted(theme);

    return ListView(
      // Capped at a phone's measure past the compact breakpoint: these rows
      // are a form, and a form set across a tablet is a form nobody can read
      // in one glance (CLAUDE.md §6).
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
          // Named here and not on the project row above: the environment a
          // session runs in is the checkout's, and a project root that lives
          // somewhere else would put two rows in disagreement about "the
          // environment" — worse than one row that answers.
          environment: checkout.environmentName,
          detail: _checkoutLine(checkout),
          alert: checkout.folderMissing,
          onTap: project.checkouts.length > 1
              ? () => _pickCheckout(project)
              : null,
        ),
        if (agent == null)
          const Padding(
            padding: EdgeInsets.all(Insets.lg),
            child: CompanionNotice(
              icon: AppIcons.robot,
              title: 'No agent installed here',
              tone: NoticeTone.attention,
              body:
                  'Your desktop has no agent installed in the environment this '
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.sm,
              Insets.lg,
              0,
            ),
            child: TextField(
              controller: _title,
              onChanged: (_) => _formChanged(),
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Title',
                helperText: 'Optional — your desktop names it if you do not.',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.md,
              Insets.lg,
              0,
            ),
            child: TextField(
              controller: _message,
              onChanged: (_) => _formChanged(),
              enabled: agent.acceptsOpeningMessage,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'First message',
                // Said before it is typed, not refused afterwards: the launch
                // itself would decline an opening message this CLI cannot be
                // handed, and finding that out after writing one is worse.
                helperText: agent.acceptsOpeningMessage
                    ? 'Optional — sent as soon as the session is up.'
                    : '${agent.name} takes no opening message on its command '
                          'line. Start it and say it in the session.',
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (_failure != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.lg,
                Insets.md,
                Insets.lg,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    AppIcons.warningCircle,
                    size: Touch.icon,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      _failure!,
                      style: muted?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.lg,
              Insets.lg,
              Insets.lg,
              0,
            ),
            child: FilledButton.icon(
              onPressed: _starting || mode == null
                  ? null
                  : () => _start(checkout, agent, mode),
              icon: _starting
                  ? const SizedBox.square(
                      dimension: Touch.iconSmall,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.play),
              label: Text(_starting ? 'Starting…' : 'Start session'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(Touch.target),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Which execution environment something lives in, in the desktop's own words
/// — "Windows", "WSL · Ubuntu", "SSH · build-box".
///
/// A line of its own rather than one more clause in a dot-joined run: this is
/// the answer people were reading the path to work out, and a fact buried
/// mid-sentence is a fact still being decoded. The kind prefix labels it for
/// the eye; the [Semantics] label does the same for a reader that never sees
/// the line break, and speaks the separator as the pause it looks like.
class _Environment extends StatelessWidget {
  const _Environment(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      // A node of its own, not an annotation folded into the tile's: the point
      // is that "which environment" is asked and answered separately from the
      // checkout's name, for a listener as much as for a reader.
      container: true,
      label: 'Environment: ${spokenEnvironmentLabel(name)}',
      excludeSemantics: true,
      // Two lines, not one: an ellipsised distribution name is exactly the
      // guess this row exists to remove, and a 200% text scale reaches the
      // edge of a phone in about eight characters.
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

/// A picker row's supporting lines: where it lives, then what else is known
/// about it. **Null when neither says anything**, so a tile with nothing to
/// add keeps a single-line height rather than an empty subtitle slot.
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

/// One answered question: what it is, what it says, and — when there is more
/// than one answer to give — that tapping it opens the rest.
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

  /// Where this lives, in the desktop's own words. Null when the desktop had
  /// nothing worth saying — [detail] still carries the path.
  final String? environment;

  final String? detail;

  /// Draw it in the error colour — a folder the desktop cannot see, or a mode
  /// the desktop marks dangerous.
  final bool alert;

  /// Null when there is nothing to choose between, which is drawn as a plain
  /// statement rather than a control that does nothing.
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
