/// MCP tool definitions for verification runs, served to the bridge alongside
/// the browser and device tools.
///
/// Five tools, deliberately: start, note, finish, list, get. Everything a run
/// records comes from the browser and device tools the agent already has, so
/// there is nothing here for "click during a run" — driving is driving, and the
/// run is what remembers it.
const List<Map<String, dynamic>> verificationToolSchemas = [
  {
    'name': 'verification_start',
    'description':
        'Begin recording a verification run — a durable, inspectable record '
        'that a change actually works, which you can hand to the human. Give '
        'EITHER url (a browser run: attaches to the browser, goes there, and '
        'starts watching the console and network) OR serial (+ optional '
        'package: a device run, which brings that app to the front). While a '
        'run is recording, every browser_* and device_* call you make is '
        'captured as a step with its screenshots; console errors, failed '
        'requests and the log slice are collected for you at the end. Drive '
        'the change the way a user would, then call verification_finish with a '
        'verdict. One run at a time.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description':
              'The page to verify, e.g. "localhost:3000/settings". Makes this '
              'a browser run.',
        },
        'serial': {
          'type': 'string',
          'description':
              'Device serial from list_devices. Makes this a device run.',
        },
        'package': {
          'type': 'string',
          'description':
              'Android package to verify, e.g. "com.example.app". It is '
              'launched at the start of the run, and the closing logcat slice '
              'is filtered to it. Without it, the run records the device but '
              'collects no log.',
        },
        'title': {
          'type': 'string',
          'description':
              'What is being verified, in one line — "the settings page saves '
              'on Enter". Defaults to the target.',
        },
        'sessionId': {
          'type': 'string',
          'description':
              'Session this run belongs to, from list_sessions. Attaching it '
              'is what lets the human find the evidence from the conversation.',
        },
        'launch': {
          'type': 'boolean',
          'description':
              'Device runs only: set false to verify the app already on '
              'screen instead of relaunching it. Default true.',
        },
      },
    },
  },
  {
    'name': 'verification_note',
    'description':
        'Add your own step to the running verification — what you are about '
        'to check, or what you observed that the tools cannot see ("the '
        'spinner never stopped"). Notes are what turn a list of clicks into '
        'an argument.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'One line. Required.'},
        'detail': {
          'type': 'string',
          'description': 'Anything longer — an expected value, a stack trace.',
        },
      },
      'required': ['text'],
    },
  },
  {
    'name': 'verification_finish',
    'description':
        'Close the run with a verdict and the reason for it, collect the '
        'closing evidence (a screenshot, the console errors, the failed '
        'requests, the logcat slice, the UI tree) and write a markdown report '
        'next to the artifacts. Use "inconclusive" honestly — a run that '
        'could not reach the page is not a fail.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'verdict': {
          'type': 'string',
          'enum': ['pass', 'fail', 'inconclusive'],
          'description': 'Required.',
        },
        'reason': {
          'type': 'string',
          'description':
              'One or two sentences saying what you observed that justifies '
              'the verdict. This is the part a human reads first.',
        },
      },
      'required': ['verdict'],
    },
  },
  {
    'name': 'verification_list',
    'description':
        'List recorded verification runs, newest first — one line each with '
        'the verdict, the target and the step count.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Only runs attached to this session.',
        },
        'limit': {
          'type': 'number',
          'description': 'How many runs to show. Default 20.',
        },
      },
    },
  },
  {
    'name': 'verification_get',
    'description':
        'Read one run: its verdict, its steps and what it captured. Compact by '
        'default — step summaries and a list of artifacts, no images and no '
        'file contents. Pass full:true for step detail and the text of the '
        'evidence files, or images:true to attach the screenshots. Ask for '
        'images only when you need to look at one; they are the expensive part.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description':
              'Run id, or a unique prefix of one. Omit for the run that is '
              'recording now.',
        },
        'full': {
          'type': 'boolean',
          'description':
              'Include step detail and the contents of text artifacts.',
        },
        'images': {
          'type': 'boolean',
          'description': 'Attach the screenshots as images.',
        },
      },
    },
  },
];
