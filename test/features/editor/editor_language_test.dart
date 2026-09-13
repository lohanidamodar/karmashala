import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/languages/all.dart' show allLanguages;
import 'package:karmashala/src/features/editor/application/editor_language.dart';

void main() {
  group('the language a path names', () {
    test('reads the extension, whichever separator the host path uses', () {
      expect(highlightLanguageFor(r'C:\src\app\lib\main.dart'), 'dart');
      expect(
        highlightLanguageFor(r'\\wsl.localhost\arch\home\d\app\src\main.rs'),
        'rust',
      );
      expect(highlightLanguageFor('/home/d/app/src/main.py'), 'python');
      expect(highlightLanguageFor(r'D:\My Files\a b\notes.md'), 'markdown');
    });

    test('does not care about case', () {
      expect(highlightLanguageFor(r'C:\a\Main.DART'), 'dart');
      expect(highlightLanguageFor(r'C:\a\App.TSX'), 'typescript');
    });

    test('covers the spread the Files panel shows', () {
      const expected = <String, String>{
        'a.js': 'javascript',
        'a.mjs': 'javascript',
        'a.cjs': 'javascript',
        'a.jsx': 'javascript',
        'a.ts': 'typescript',
        'a.go': 'go',
        'a.java': 'java',
        'a.kt': 'kotlin',
        'a.kts': 'kotlin',
        'a.swift': 'swift',
        'a.c': 'cpp',
        'a.h': 'cpp',
        'a.cpp': 'cpp',
        'a.hpp': 'cpp',
        'a.cs': 'cs',
        'a.rb': 'ruby',
        'a.php': 'php',
        'a.sh': 'bash',
        'a.zsh': 'bash',
        'a.ps1': 'powershell',
        'a.sql': 'sql',
        'a.html': 'xml',
        'a.xml': 'xml',
        'a.css': 'css',
        'a.scss': 'scss',
        'a.less': 'less',
        'a.json': 'json',
        'a.yaml': 'yaml',
        'a.yml': 'yaml',
        'a.toml': 'ini',
        'a.ini': 'ini',
        'a.conf': 'ini',
        'build.gradle': 'gradle',
        'a.cmake': 'cmake',
        'a.lua': 'lua',
        'a.r': 'r',
        'a.scala': 'scala',
        'a.ex': 'elixir',
        'a.exs': 'elixir',
        'a.erl': 'erlang',
        'a.hs': 'haskell',
        'a.pl': 'perl',
        'a.vim': 'vim',
        'a.diff': 'diff',
        'a.patch': 'diff',
        'a.proto': 'protobuf',
        'a.graphql': 'graphql',
        'a.gql': 'graphql',
      };
      for (final entry in expected.entries) {
        expect(
          highlightLanguageFor('C:\\src\\${entry.key}'),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('answers for the names toolchains leave without an extension', () {
      expect(highlightLanguageFor(r'C:\src\Makefile'), 'makefile');
      expect(highlightLanguageFor(r'C:\src\Dockerfile'), 'dockerfile');
      expect(highlightLanguageFor(r'C:\src\CMakeLists.txt'), 'cmake');
      expect(highlightLanguageFor(r'C:\src\.env'), 'ini');
    });

    test('says nothing rather than guessing', () {
      expect(highlightLanguageFor(r'C:\src\.gitignore'), isNull);
      expect(highlightLanguageFor(r'C:\src\.gitattributes'), isNull);
      expect(highlightLanguageFor(r'C:\src\LICENSE'), isNull);
      expect(highlightLanguageFor(r'C:\src\notes.txt'), isNull);
      expect(highlightLanguageFor(r'C:\src\archive.zip'), isNull);
      expect(highlightLanguageFor(r'C:\src'), isNull);
    });

    test('every id it can answer with is one highlight registers', () {
      for (final id in highlightLanguageIds) {
        expect(allLanguages.containsKey(id), isTrue, reason: id);
      }
      expect(highlightLanguageIds, isNotEmpty);
    });
  });
}
