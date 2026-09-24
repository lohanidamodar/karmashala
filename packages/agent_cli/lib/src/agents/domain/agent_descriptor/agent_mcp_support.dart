part of '../agent_descriptor.dart';

/// How an agent CLI is told, at launch, where Karmashala's own tools are.
enum AgentMcpStyle {
  /// A flag naming a config file the agent reads — Claude Code's
  /// `--mcp-config`.
  configFile,

  /// A flag setting one config value inline, with no file — Codex's
  /// `-c <dotted.key>=<value>`.
  inlineUrl,

  /// No convention we have verified. Nothing is passed. **The default.**
  unsupported,
}

/// Whether one agent can be pointed at an MCP server on its command line, and
/// how.
///
/// Modelled exactly like [AgentForkSupport] — declared data on the descriptor,
/// [evidence] required, defaulting to the conservative answer — and for the
/// same reason. Antigravity's descriptor was wrong for months because a flag
/// nobody had run was written down as if it were known; `agy --help` (1.1.22)
/// names an `mcp` *subcommand* for editing its own config and no launch option
/// at all, so Antigravity is given nothing here rather than something plausible.
///
/// Note what this is not: it is not "does the agent support MCP". All three
/// support it. It is "can this launch, without touching the user's own files,
/// add one more server for one session" — and that is a narrower question with
/// a different answer per CLI.
class AgentMcpSupport {
  /// The agent reads a config file named by [flag].
  ///
  /// Emitted as a **single `--flag=value` token**, not as two arguments, and
  /// that is load-bearing rather than cosmetic. Claude Code declares
  /// `--mcp-config <configs...>` — variadic, "space-separated" — so a
  /// space-separated value swallows every following non-flag argument,
  /// including the opening prompt this launcher passes as a positional:
  ///
  ///   $ claude --mcp-config /tmp/c.json mcp list
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: …/mcp
  ///   MCP config file not found: …/list
  ///   $ claude --mcp-config=/tmp/c.json mcp list
  ///   claude.ai Google Drive: … ✔ Connected      # ran the subcommand
  ///
  /// Verified against 2.1.251.
  const AgentMcpSupport.configFile({required this.flag, required this.evidence})
    : style = AgentMcpStyle.configFile,
      urlKey = '';

  /// The agent takes the URL on its command line, as `[flag] <urlKey>=<url>`.
  ///
  /// No file is written, so nothing has to be readable from the agent's
  /// filesystem — which is why this is the shape Codex gets even though it also
  /// has a config file: `~/.codex/config.toml` is the *user's*, holds one
  /// `[mcp_servers.karmashala]` block for the whole machine, and so could
  /// never carry a **per-session** URL. Identity is the point of the URL, so a
  /// convention that cannot be per-session is not a weaker version of this one,
  /// it is a different and wrong thing.
  const AgentMcpSupport.inlineUrl({
    required this.flag,
    required this.urlKey,
    required this.evidence,
  }) : style = AgentMcpStyle.inlineUrl;

  /// Nothing is known to work. The default.
  const AgentMcpSupport.unsupported()
    : style = AgentMcpStyle.unsupported,
      flag = '',
      urlKey = '',
      evidence = '';

  final AgentMcpStyle style;

  /// The option itself, e.g. `--mcp-config` or `-c`.
  final String flag;

  /// For [AgentMcpStyle.inlineUrl], the dotted config key the URL is assigned
  /// to. Empty otherwise.
  final String urlKey;

  /// Where this was verified — the `--help` line or the transcript it was read
  /// off, so a future CLI version can be re-checked rather than trusted.
  final String evidence;

  bool get isSupported => style != AgentMcpStyle.unsupported;

  /// Whether a config file has to exist before [argumentsFor] can say anything.
  bool get needsConfigFile => style == AgentMcpStyle.configFile;

  /// The arguments that point this agent at [url], or nothing when it cannot be
  /// told.
  ///
  /// A [AgentMcpStyle.configFile] agent with no [configPath] gets **nothing**,
  /// not a flag with an empty value: the file could not be written, and a flag
  /// naming a file that is not there is a launch that fails where the launch
  /// without it would have succeeded.
  ///
  /// [url] is nullable for the same reason, one environment further along. A
  /// config-file agent inside a WSL distribution is pointed at a *file* that
  /// spawns the stdio bridge, because no address this app binds is reachable
  /// from there — so there is no URL to hand it, and that is a working launch
  /// rather than a missing value. An [AgentMcpStyle.inlineUrl] agent has
  /// nothing but the URL and gets nothing without one.
  List<String> argumentsFor({String? url, String? configPath}) =>
      switch (style) {
        AgentMcpStyle.configFile =>
          configPath == null ? const [] : ['$flag=$configPath'],
        AgentMcpStyle.inlineUrl =>
          url == null || url.isEmpty ? const [] : [flag, '$urlKey=$url'],
        AgentMcpStyle.unsupported => const [],
      };

  /// [arguments] with anything [argumentsFor] wrote taken back out.
  ///
  /// For reading back a launch recorded before these flags were understood to
  /// be volatile, when they were stored alongside the durable ones. Every value
  /// in such a flag is dead by the next start — the config file is deleted by
  /// `SessionMcpConfigs.prepare`, the port is rebound, the credential is
  /// re-minted — and replaying one does not weaken the launch, it fails it:
  ///
  ///   Error: Invalid MCP configuration:
  ///   MCP config file not found: `…/karmashala/mcp/session-<uuid>.json`
  ///
  /// So a layout stored by the old code has to be repaired on the way in, or
  /// installing the fix leaves every pane the user already had just as broken.
  /// Matched on **our own** value and never on the flag alone: Codex's `-c`
  /// takes any config override, and a user's `-c model=…` is not ours to drop.
  List<String> withoutArgumentsIn(List<String> arguments) {
    switch (style) {
      case AgentMcpStyle.unsupported:
        return arguments;
      case AgentMcpStyle.configFile:
        return [
          for (final argument in arguments)
            if (!argument.startsWith('$flag=')) argument,
        ];
      case AgentMcpStyle.inlineUrl:
        final kept = <String>[];
        for (var i = 0; i < arguments.length; i++) {
          // Two tokens, dropped as two: a dangling `-c` left behind would take
          // whatever argument came next as its value.
          if (arguments[i] == flag &&
              i + 1 < arguments.length &&
              arguments[i + 1].startsWith('$urlKey=')) {
            i++;
            continue;
          }
          kept.add(arguments[i]);
        }
        return kept;
    }
  }
}
