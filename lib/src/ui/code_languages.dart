import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../files/file_browser.dart';

/// Syntax colouring for the file at [path], or null to leave it plain, in
/// Atom's colours for a page of [brightness]: the dark set's pastels are
/// unreadable on a light page.
///
/// Picked by name, never guessed from content: a guess is wrong often enough
/// on config files to be worse than no colour at all.
CodeHighlightTheme? codeThemeFor(
  String path, [
  Brightness brightness = Brightness.dark,
]) {
  final mode = _modeFor(path);
  if (mode == null) return null;
  return CodeHighlightTheme(
    languages: {'file': CodeHighlightThemeMode(mode: mode)},
    theme: codeStyles(brightness),
  );
}

/// The editor's colours, by highlight scope, for a page of [brightness]:
/// among them `addition` and `deletion`, what a diff's lines are drawn in.
Map<String, TextStyle> codeStyles(Brightness brightness) =>
    brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;

/// [code] coloured as the editor colours the file at [path], over [base], or
/// null where the editor would leave it plain.
TextSpan? highlightCode(
  String path,
  String code,
  TextStyle base,
  Brightness brightness,
) {
  final mode = _modeFor(path);
  if (mode == null) return null;
  final result = (Highlight()..registerLanguage('file', mode)).highlight(
    code: code,
    language: 'file',
  );
  final renderer = TextSpanRenderer(base, codeStyles(brightness));
  result.render(renderer);
  return renderer.span;
}

Mode? _modeFor(String path) {
  final name = RemotePath.basename(path).toLowerCase();
  switch (name) {
    case 'dockerfile' || 'containerfile':
      return langDockerfile;
    case 'makefile' || 'gnumakefile':
      return langMakefile;
    case '.bashrc' || '.bash_profile' || '.profile' || '.zshrc' || '.zprofile':
      return langBash;
  }
  // Sites and snippets under nginx carry no telling extension of their own.
  if (path.contains('/nginx/')) return langNginx;

  final dot = name.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (name.substring(dot + 1)) {
    'sh' || 'bash' || 'zsh' => langBash,
    'yaml' || 'yml' => langYaml,
    'json' => langJson,
    'dart' => langDart,
    'py' => langPython,
    'js' || 'mjs' || 'cjs' => langJavascript,
    'ts' => langTypescript,
    'go' => langGo,
    'rs' => langRust,
    // Close enough for all of them: sections, keys, values and comments.
    'ini' || 'cfg' || 'conf' || 'toml' || 'env' || 'service' || 'timer' =>
      langIni,
    'properties' => langProperties,
    'md' || 'markdown' => langMarkdown,
    'xml' || 'html' || 'htm' || 'svg' || 'plist' => langXml,
    'css' => langCss,
    'sql' => langSql,
    'diff' || 'patch' => langDiff,
    _ => null,
  };
}
