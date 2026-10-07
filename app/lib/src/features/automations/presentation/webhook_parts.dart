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
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../core/util/clock_provider.dart';
import '../../terminal/presentation/session_status.dart' show describeAge;
import '../application/automation_providers.dart';

/// A saved webhook's URL with Copy, whether the server is listening for it,
/// and Rotate for its secret.
class WebhookUrlRow extends ConsumerStatefulWidget {
  const WebhookUrlRow({required this.automation, super.key});

  final Automation automation;

  @override
  ConsumerState<WebhookUrlRow> createState() => _WebhookUrlRowState();
}

class _WebhookUrlRowState extends ConsumerState<WebhookUrlRow> {
  WebhookStatus? _status;
  String? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
          'A new secret is made and shown once. The old one stops working at '
          'once, so update it wherever calls come from, such as GitHub\'s '
          'webhook settings.',
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
    final status = _status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failure case final failure?) DesktopErrorBanner(failure),
        if (status == null && _failure == null)
          const LinearProgressIndicator()
        else if (status != null) ...[
          if (status.url case final url?)
            CopyRow(label: 'URL', value: url, tooltip: 'Copy the URL')
          else
            Text(
              'This server has no relay to take calls on yet, so there is no '
              'URL. Turn on hosted pairing in Settings.',
              style: theme.textTheme.bodySmall,
            ),
          Text(
            status.listening
                ? 'Listening. Anyone with this URL can start a run.'
                : status.problem ?? 'Not listening.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: status.listening
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.error,
            ),
          ),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('webhook-rotate'),
            onPressed: _rotate,
            child: const Text('Rotate the secret…'),
          ),
        ),
      ],
    );
  }
}

/// **Deliveries**: the calls a webhook had, what each came to and the prompt
/// it sent; and a sample body filled here, sending nothing.
class WebhookDeliveriesDialog extends ConsumerStatefulWidget {
  const WebhookDeliveriesDialog({required this.automation, super.key});

  final Automation automation;

  static Future<void> show(BuildContext context, Automation automation) =>
      showDialog<void>(
        context: context,
        builder: (_) => WebhookDeliveriesDialog(automation: automation),
      );

  @override
  ConsumerState<WebhookDeliveriesDialog> createState() =>
      _WebhookDeliveriesDialogState();
}

class _WebhookDeliveriesDialogState
    extends ConsumerState<WebhookDeliveriesDialog> {
  WebhookStatus? _status;
  String? _failure;
  StreamSubscription<WebhookCall>? _calls;
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
    _calls = ref
        .read(automationsDataProvider)
        .webhookCalls
        .where((call) => call.automationId == widget.automation.id)
        .listen((_) => _load());
    unawaited(_load());
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = ref.watch(clockProvider).nowUtc();
    ref.watch(automationsRevisionProvider);
    final data = ref.read(automationsDataProvider);
    final status = _status;
    return AlertDialog(
      scrollable: true,
      title: DesktopDialogTitle(
        icon: AppIcons.webhooksLogo,
        title: 'Deliveries · ${widget.automation.name}',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.wide,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'The last calls to its URL, and the exact prompt each one sent.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Insets.sm),
            if (_failure case final failure?) DesktopErrorBanner(failure),
            if (status == null && _failure == null)
              const LinearProgressIndicator()
            else if (status != null && status.calls.isEmpty)
              Text('No calls yet.', style: theme.textTheme.bodySmall)
            else if (status != null)
              for (final call in status.calls)
                _Delivery(
                  key: ValueKey(call.id),
                  call: call,
                  now: now,
                  prompt: switch (call.runId) {
                    final id? => data.runById(id)?.prompt,
                    null => null,
                  },
                ),
            const SizedBox(height: Insets.md),
            const EyebrowLabel('Try a sample body'),
            const SizedBox(height: Insets.xs),
            WebhookRehearsal(
              template: widget.automation.prompt,
              sample: _sample,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// A call's outcome in a few plain words.
String deliveryWords(WebhookCall call) => switch (call.outcome) {
  'accepted' => 'Ran',
  'bad signature' => 'Bad signature',
  'replay' => 'Already delivered',
  'slow down' => 'Too many calls',
  'busy' => 'Checkout busy',
  'paused' => 'Paused',
  'bad payload' => 'Body not usable',
  'not started' || 'failed' => 'Did not start',
  final other when other.isEmpty => 'Unknown',
  final other => '${other[0].toUpperCase()}${other.substring(1)}',
};

class _Delivery extends StatelessWidget {
  const _Delivery({
    required this.call,
    required this.now,
    required this.prompt,
    super.key,
  });

  final WebhookCall call;
  final DateTime now;

  /// What its run told the agent, while that run is still held.
  final String? prompt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final prompt = this.prompt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${deliveryWords(call)} · ${describeAge(call.receivedAt, now: now)}'
            '${call.ip.isEmpty ? '' : ' · from ${call.ip}'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: call.accepted ? null : theme.colorScheme.error,
            ),
          ),
          if (call.reason case final reason?) Text(reason, style: quiet),
          if (!call.accepted)
            Text('No run was started.', style: quiet)
          else if (prompt != null) ...[
            Text('Prompt sent to the agent:', style: quiet),
            SelectableText(
              prompt,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
                fontFamilyFallback: kMonoFallback,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The prompt a body would make — filled here, sent nowhere.
class WebhookRehearsal extends StatefulWidget {
  const WebhookRehearsal({
    required this.template,
    required this.sample,
    super.key,
  });

  final String template;
  final TextEditingController sample;

  @override
  State<WebhookRehearsal> createState() => _WebhookRehearsalState();
}

class _WebhookRehearsalState extends State<WebhookRehearsal> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String? prompt;
    String? problem;
    try {
      prompt = fillWebhookTemplate(
        widget.template,
        jsonDecode(widget.sample.text),
        nonce: 'preview',
      ).prompt;
    } on FormatException {
      problem = 'The body is not JSON.';
    } on WebhookTemplateException catch (error) {
      problem = error.message;
    }
    final mono = theme.textTheme.bodySmall?.copyWith(
      fontFamily: kMonoFamily,
      fontFamilyFallback: kMonoFallback,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('webhook-sample-body'),
          controller: widget.sample,
          minLines: 3,
          maxLines: 8,
          style: mono,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'A sample body',
            helperText:
                'Fills the prompt here only. Nothing is sent and no session '
                'starts.',
          ),
        ),
        const SizedBox(height: Insets.sm),
        if (problem != null)
          Text(
            problem,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          )
        else ...[
          Text('The prompt it would send', style: theme.textTheme.labelSmall),
          const SizedBox(height: Insets.xs),
          SelectableText(
            prompt!,
            key: const ValueKey('webhook-preview'),
            style: mono,
          ),
        ],
      ],
    );
  }
}

/// A label, a value to copy, and Copy.
class CopyRow extends StatelessWidget {
  const CopyRow({
    required this.label,
    required this.value,
    required this.tooltip,
    super.key,
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
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: kMonoFamily,
              fontFamilyFallback: kMonoFallback,
            ),
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
        icon: AppIcons.webhooksLogo,
        title: 'Its URL and secret',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (issued.url case final url?)
              CopyRow(label: 'URL', value: url, tooltip: 'Copy the URL')
            else
              Text(
                'This server has no relay to take calls on yet, so there is '
                'no URL. Turn on hosted pairing in Settings.',
                style: quiet,
              ),
            CopyRow(
              label: 'Secret',
              value: issued.secret,
              tooltip: 'Copy the secret',
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Copy both now. The secret is shown only once; you can rotate '
              'it later.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'In GitHub: Settings → Webhooks → Add webhook. Paste the URL, '
              'choose application/json, and paste the secret. Anything else '
              'signs each call with X-Karmashala-Timestamp (unix seconds) and '
              'X-Karmashala-Signature: sha256=<hex HMAC-SHA256 of '
              '"<timestamp>.<body>">, and sends X-Karmashala-Delivery so a '
              'retry is not run twice.',
              style: quiet,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I have copied both'),
        ),
      ],
    );
  }
}
