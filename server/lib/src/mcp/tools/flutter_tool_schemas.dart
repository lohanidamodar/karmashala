/// The `flutter_*` schemas, served alongside the rest.
const List<Map<String, Object?>> flutterAppToolSchemas = <Map<String, Object?>>[
  {
    'name': 'flutter_apps',
    'description':
        'Every running Flutter app Karmashala can reach, with an id to '
        'name it by, whether it can be hot reloaded and whether its build '
        'carries widget source locations. LOOK HERE FIRST: an app id lasts '
        'only as long as the "flutter run" that produced it. An empty list '
        'comes back with the exact flag to add so the next run is visible '
        '— Karmashala does not start the app and will never rewrite a '
        'command you typed. "We have not looked", "no app is running" and '
        '"an address nothing answers on" are three different answers here.',
    'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
  },
  {
    'name': 'flutter_attach',
    'description':
        'Attach to a running app by the address "flutter run" printed — '
        'the line "A Dart VM Service on … is available at: '
        'http://127.0.0.1:PORT/TOKEN=/". Use it when flutter_apps shows '
        'nothing because the run had no --vmservice-out-file. Attaching '
        'twice to the same app is the same as attaching once.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'vmServiceUri': {
          'type': 'string',
          'description':
              'The printed http:// address or the ws://…/ws one. Both are '
              'accepted.',
        },
      },
      'required': ['vmServiceUri'],
    },
  },
  {
    'name': 'flutter_reload',
    'description':
        'Hot reload the running app so an edit takes effect, or hot '
        'restart it. A SUCCESS HERE MEANS THE RELOAD REACHED THE VM AND '
        'NOTHING MORE: a widget that then failed to rebuild reports itself '
        'on flutter_logs, so read that next. Requires a "flutter run" '
        'still attached to the app — the recompile comes from the tool, '
        'not from the VM service, and an app nothing is driving says so '
        'instead of failing obscurely. fullRestart re-runs main() and '
        'the app loses the state it had.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'appId': {
          'type': 'string',
          'description':
              'From flutter_apps. Optional when exactly one app is '
              'attached; refused rather than guessed when two are.',
        },
        'fullRestart': {
          'type': 'boolean',
          'description':
              'Hot restart instead of hot reload. Re-runs main() and '
              'discards the app state. Default false.',
        },
      },
    },
  },
  {
    'name': 'flutter_logs',
    'description':
        'The running app\'s debug console: its stdout and stderr, its '
        'dart:developer log() records and every exception the framework '
        'caught, in one list oldest-first. This is where a runtime error '
        'lives — you do not need the developer to paste a stack trace. '
        'Lines marked "before attach" were replayed out of the VM service '
        'buffer and are history rather than now. An empty tail means the '
        'app has said nothing SINCE THE ATTACH, which is not the same as '
        'it having said nothing at all.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'appId': {
          'type': 'string',
          'description':
              'From flutter_apps. Optional when only one is attached.',
        },
        'limit': {
          'type': 'number',
          'description':
              'How many of the newest lines (default 100, max 1000).',
        },
        'errorsOnly': {
          'type': 'boolean',
          'description':
              'Only stderr and caught exceptions. Use it when hunting a '
              'failure in a chatty app.',
        },
      },
    },
  },
  {
    'name': 'flutter_pick_widget',
    'description':
        'Ask the developer to point at a widget in the running app: it '
        'goes into Flutter\'s own widget-select mode, they tap the thing '
        'they mean — on the desktop window or on the mirrored phone — and '
        'the widget and the file, line and column it was written at come '
        'back. Use it when they say "this button" or "that padding" and '
        'you cannot tell which one they mean. BLOCKS until they tap or the '
        'timeout passes. A build compiled without --track-widget-creation '
        '(profile, release) names the widget and cannot name a line, and '
        'says so rather than showing nothing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'appId': {
          'type': 'string',
          'description':
              'From flutter_apps. Optional when only one is attached.',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description': 'How long to wait for a tap (default 120, max 600).',
        },
      },
    },
  },
];

/// The `flutter_run` schema, served alongside the rest.
const List<Map<String, Object?>> flutterRunToolSchemas = <Map<String, Object?>>[
  {
    'name': 'flutter_run',
    'description':
        'THE FLUTTER LOOP: resolve a checkout\'s dependencies, launch it '
        'on a device, and run its gates — in visible panes, in that '
        'checkout\'s own environment, with the right SDK. A launch ATTACHES '
        'THE APP BY ITSELF, so flutter_apps, flutter_reload, flutter_logs '
        'and flutter_pick_widget are live the moment it starts and you '
        'never call flutter_attach. Actions: "pubGet" (a fresh worktree has '
        'no .dart_tool and nothing else will work until it does), "run" '
        '(needs deviceId), "status", "stop", "analyze", "test". Every '
        'answer carries a PREFLIGHT line naming the problem and the fix — '
        'no SDK in that environment, no .dart_tool, a device somebody else '
        'is driving. THE LOG COMES BACK ONLY WHEN SOMETHING FAILED OR IS '
        'STILL GOING; a gate that passed is a verdict, not a transcript. '
        'One run per device, refused by name. analyze and test record a '
        'verdict you can read back with verification_get.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['run', 'stop', 'status', 'pubGet', 'analyze', 'test'],
          'description':
              'What to do. "status" with no paneId lists everything this '
              'app started.',
        },
        'checkoutId': {
          'type': 'string',
          'description':
              'From list_checkouts. Required for run, pubGet, analyze and '
              'test — it is what says which environment the commands run '
              'in, which a bare path cannot.',
        },
        'projectDirectory': {
          'type': 'string',
          'description':
              'A sub-project inside the checkout, relative — "app" or '
              '"packages/mobile". Omit for a checkout that is itself the '
              'Flutter project.',
        },
        'deviceId': {
          'type': 'string',
          'description':
              'Required for "run": the id "flutter devices" prints — an '
              'adb serial for a phone, or "windows", "macos", "chrome". '
              'list_devices has the attached ones.',
        },
        'paneId': {
          'type': 'string',
          'description':
              'Which run to ask about or stop. From a previous answer. '
              'Optional for "stop" when exactly one thing is running.',
        },
        'arguments': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Extra flags for the command, after the ones Karmashala '
              'spells — "--profile", "--exclude-tags=live-ssh,live-wsl".',
        },
      },
      'required': ['action'],
    },
  },
];
