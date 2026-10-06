import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_automations/automations.dart';
import 'package:karmashala_automations/webhooks.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/automation_providers.dart';

/// One webhook as its owner sees it: where it is called, whether this server
/// is listening, its switch, its secret rotated, a call rehearsed without
/// starting anything, and every call it has had. A phone reads the same.
class WebhookPanel extends ConsumerStatefulWidget {
  const WebhookPanel({required this.automation, super.key});

  final Automation automation;

  static Future<void> show(BuildContext context, Automation automation) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: DesktopDialogTitle(
            icon: AppIcons.globe,
            title: 'Webhook "${automation.name}"',
          ),
          content: BoundedDialogContent(
            width: DialogWidth.wide,
            child: WebhookPanel(automation: automation),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );

  @override
  ConsumerState<WebhookPanel> createState() => _WebhookPanelState();
}

class _WebhookPanelState extends ConsumerState<WebhookPanel> {
  WebhookStatus? _status;
  String? _failure;
  StreamSubscription<WebhookCall>? _calls;
  var _rehearsing = false;
  late final TextEditingController _sample;

  @override
  void initState() {
    super.initState();
    final fields = webhookTemplateFields(widget.automation.prompt);
    _sample = TextEditingController(
      text: const JsonEncoder.withIndent(
        '  ',
      ).convert(webhookSampleBody(fields)),
    );
    final data = ref.read(automationsDataProvider);
    _calls = data.webhookCalls
        .where((call) => call.automationId == widget.automation.id)
        .listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    unawaited(_calls?.cancel());
    _sample.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final status = await ref
          .read(automationsDataProvider)
          .webhookStatus(widget.automation.id);
      if (mounted) setState(() => _status = status);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '$error');
    }
  }

  Future<void> _rotate() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Rotate the secret?',
      message:
          'A new secret is made and shown once. The old one stops working '
          'at once, so update whatever calls this webhook.',
      confirmLabel: 'Rotate',
    );
    if (!confirmed || !mounted) return;
    try {
      final issued = await ref
          .read(automationsDataProvider)
          .rotateWebhook(widget.automation.id);
      if (mounted) await WebhookSecretDialog.show(context, issued);
    } on Object catch (error) {
      if (mounted) setState(() => _failure = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final automation =
        ref
            .watch(automationsProvider)
            .where((a) => a.id == widget.automation.id)
            .firstOrNull ??
        widget.automation;
    final status = _status;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failure case final failure?) ...[
          DesktopErrorBanner(failure),
          const SizedBox(height: Insets.sm),
        ],
        Text(
          'A call to its URL starts one new session with its prompt, filled '
          'from the JSON body. ${automation.webhook?.requireSignature ?? true ? 'Calls must be signed with its secret.' : 'It takes unsigned calls: the URL alone is the key.'}',
          style: quiet,
        ),
        const SizedBox(height: Insets.sm),
        if (status == null)
          const LinearProgressIndicator()
        else ...[
          if (status.url case final url?)
            _CopyRow(label: 'URL', value: url, tooltip: 'Copy the URL'),
          Text(
            status.listening
                ? 'Listening for calls on the relay.'
                : status.problem ?? 'Not listening.',
            style: status.listening
                ? quiet
                : theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
          ),
        ],
        SwitchListTile(
          key: const ValueKey('webhook-enabled'),
          contentPadding: EdgeInsets.zero,
          value: automation.enabled,
          title: const Text('Enabled'),
          subtitle: Text(
            automation.enabled
                ? 'Calls start sessions.'
                : 'Every call is answered as if there were no webhook here.',
          ),
          onChanged: (enabled) => ref
              .read(automationControllerProvider)
              .setEnabled(automation.id, enabled: enabled),
        ),
        Wrap(
          spacing: Insets.sm,
          runSpacing: Insets.xs,
          children: [
            OutlinedButton(
              onPressed: _rotate,
              child: const Text('Rotate secret'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => _rehearsing = !_rehearsing),
              child: const Text('Send a test call'),
            ),
          ],
        ),
        if (_rehearsing) ...[
          const SizedBox(height: Insets.sm),
          _Rehearsal(template: automation.prompt, sample: _sample),
        ],
        const SizedBox(height: Insets.md),
        Text('CALLS', style: theme.textTheme.labelSmall),
        const SizedBox(height: Insets.xs),
        if (status != null && status.calls.isEmpty)
          Text('No calls yet.', style: quiet)
        else if (status != null)
          for (final call in status.calls) _CallLine(call: call),
      ],
    );
  }
}

/// The prompt a body would make — filled here, sent nowhere.
class _Rehearsal extends StatefulWidget {
  const _Rehearsal({required this.template, required this.sample});

  final String template;
  final TextEditingController sample;

  @override
  State<_Rehearsal> createState() => _RehearsalState();
}

class _RehearsalState extends State<_Rehearsal> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? prompt;
    String? refusal;
    try {
      prompt = fillWebhookTemplate(
        widget.template,
        jsonDecode(widget.sample.text),
        nonce: 'preview',
      ).prompt;
    } on FormatException {
      refusal = 'The body is not JSON.';
    } on WebhookTemplateException catch (error) {
      refusal = error.message;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('webhook-sample-body'),
          controller: widget.sample,
          minLines: 3,
          maxLines: 8,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'A sample body',
            helperText: 'Nothing is sent and no session starts.',
          ),
        ),
        const SizedBox(height: Insets.sm),
        if (refusal != null)
          Text(
            refusal,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else ...[
          Text(
            'The prompt that would be sent',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: Insets.xs),
          SelectableText(
            prompt!,
            key: const ValueKey('webhook-preview'),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ],
      ],
    );
  }
}

/// One call: when, its answer, and enough to match it to a delivery — never
/// its body, which was not kept.
class _CallLine extends StatelessWidget {
  const _CallLine({required this.call});

  final WebhookCall call;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = call.receivedAt.toLocal();
    final when =
        '${at.year}-${_two(at.month)}-${_two(at.day)} '
        '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}';
    final details = [
      if (call.ip.isNotEmpty) 'from ${call.ip}',
      if (call.deliveryId case final id?) 'delivery $id',
      if (call.sessionId case final id?) 'session $id',
      'body ${call.bodyHash.length > 12 ? call.bodyHash.substring(0, 12) : call.bodyHash}… '
          '(${call.bodyBytes} bytes)',
      ?call.reason,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$when · ${call.status} · ${call.outcome}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: call.accepted ? null : theme.colorScheme.error,
            ),
          ),
          Text(
            details,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.tooltip,
  });

  final String label;
  final String value;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: theme.textTheme.labelSmall),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
        IconButton(
          tooltip: tooltip,
          icon: const Icon(AppIcons.copy),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: value));
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(SnackBar(content: Text('$label copied')));
          },
        ),
      ],
    );
  }
}

/// A webhook's secret, just made: shown here once, with how to sign.
class WebhookSecretDialog extends StatelessWidget {
  const WebhookSecretDialog({required this.issued, super.key});

  final WebhookIssued issued;

  static Future<void> show(BuildContext context, WebhookIssued issued) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => WebhookSecretDialog(issued: issued),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      scrollable: true,
      title: const DesktopDialogTitle(
        icon: AppIcons.globe,
        title: 'Your webhook\'s URL and secret',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (issued.url case final url?)
              _CopyRow(label: 'URL', value: url, tooltip: 'Copy the URL')
            else
              Text(
                'This server has no relay to take calls on yet, so there is '
                'no URL. Turn on hosted pairing in Settings.',
                style: quiet,
              ),
            _CopyRow(
              label: 'Secret',
              value: issued.secret,
              tooltip: 'Copy the secret',
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'The secret is shown only now and never again — copy it before '
              'closing. Rotate it to make a new one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Sign each call: GitHub does it when this is the webhook\'s '
              'secret (X-Hub-Signature-256). Anything else sends '
              'X-Karmashala-Timestamp (unix seconds) and '
              'X-Karmashala-Signature: sha256=<hex HMAC-SHA256 of '
              '"<timestamp>.<body>">. Send a delivery id '
              '(X-Karmashala-Delivery) so a retry is not run twice.',
              style: quiet,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I have copied it'),
        ),
      ],
    );
  }
}
