/// The `project_build` schema, served alongside the rest.
const List<Map<String, Object?>> projectBuildToolSchemas =
    <Map<String, Object?>>[
      {
        'name': 'project_build',
        'description':
            'WHAT A CHECKOUT IS, AND THE ARTIFACT ITS TOOLCHAIN BUILDS. '
            '"detect" names the kind — Flutter, native Android, native iOS, '
            'React Native — with the files that said so and what Karmashala '
            'can do with it; a kind it can only spot says exactly that. '
            '"build" runs that kind\'s own build in a VISIBLE PANE in the '
            'checkout\'s own environment (flutter build apk for Flutter, the '
            'project\'s own gradlew for native Android — never a gradle on '
            'PATH) and does not wait. "status" carries the ARTIFACT PATH and '
            'the APPLICATION ID once the build has written them, read out of '
            'the build\'s own output-metadata.json. IT DOES NOT INSTALL OR '
            'LAUNCH: hand those two strings to device_install_app and '
            'device_launch_app, which is the whole device surface already. '
            'iOS and React Native are DETECTED ONLY and refuse to build, in '
            'one sentence naming why.',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['detect', 'build', 'status', 'stop'],
              'description':
                  'What to do. "status" with no paneId lists everything this '
                  'app built.',
            },
            'checkoutId': {
              'type': 'string',
              'description':
                  'From list_checkouts. Required for detect and build — it is '
                  'what says which environment the commands run in, which a '
                  'bare path cannot.',
            },
            'projectDirectory': {
              'type': 'string',
              'description':
                  'A sub-project inside the checkout, relative — "android" or '
                  '"packages/mobile". Omit for a checkout that is itself the '
                  'project.',
            },
            'target': {
              'type': 'string',
              'enum': ['android', 'ios'],
              'description':
                  'Which device family to build for. Android by '
                  'default; iOS refuses and says why.',
            },
            'paneId': {
              'type': 'string',
              'description':
                  'Which build to ask about or stop. From a previous answer.',
            },
            'arguments': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Extra flags after the ones Karmashala spells — '
                  '"--offline", "--stacktrace".',
            },
          },
          'required': ['action'],
        },
      },
    ];
