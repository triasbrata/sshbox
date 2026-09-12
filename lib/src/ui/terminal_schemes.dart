import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

/// A named theme, as Settings offers it: the accent the app's colours grow
/// from, and the terminal's own colours for a dark app and for a light one.
class TerminalScheme {
  TerminalScheme(
    this.id,
    this.name,
    this.accent, {
    required String dark,
    required String light,
  }) : dark = _colors(dark),
       light = _colors(light);

  /// What Settings saves.
  final String id;
  final String name;

  /// The seed of the app's `ColorScheme`, light or dark.
  final Color accent;
  final TerminalTheme dark;
  final TerminalTheme light;

  /// Each built once, so a page that rebuilds hands xterm2 the same theme,
  /// and it re-shapes the glyphs on screen only when the colours change.
  TerminalTheme terminal(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The app's colours, light or dark. The accent itself is the primary
  /// container, the rest keep close to it, and every pair Material makes
  /// (text on its surface, a label on its button) is at its medium contrast.
  ColorScheme colorScheme(Brightness brightness) => ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
    contrastLevel: 0.5,
  );
}

/// Twenty colours in hex, in the order a terminal's settings list them:
/// background, foreground, cursor and selection, then the eight ANSI colours
/// black to white, then their bright ones. Eight digits carry an alpha first.
TerminalTheme _colors(String hex) {
  final c = [
    for (final h in hex.split(' ').where((h) => h.isNotEmpty))
      Color(int.parse(h.length == 6 ? 'ff$h' : h, radix: 16)),
  ];
  assert(c.length == 20, hex);
  const search = TerminalThemes.defaultTheme;
  return TerminalTheme(
    background: c[0],
    foreground: c[1],
    cursor: c[2],
    selection: c[3],
    black: c[4],
    red: c[5],
    green: c[6],
    yellow: c[7],
    blue: c[8],
    magenta: c[9],
    cyan: c[10],
    white: c[11],
    brightBlack: c[12],
    brightRed: c[13],
    brightGreen: c[14],
    brightYellow: c[15],
    brightBlue: c[16],
    brightMagenta: c[17],
    brightCyan: c[18],
    brightWhite: c[19],
    searchHitBackground: search.searchHitBackground,
    searchHitBackgroundCurrent: search.searchHitBackgroundCurrent,
    searchHitForeground: search.searchHitForeground,
  );
}

/// The themes Settings offers, Jeansh's own first: the one in use until
/// another is picked.
///
/// Each scheme's published colours, light variants included, except where a
/// comment says otherwise. A published colour too faint on its own background
/// is lightened on a dark one and darkened on a light one, hue and saturation
/// kept, just until it reaches 7:1 for the text; 4.5:1 for red, green,
/// yellow, blue, magenta and cyan, bright ones included; and 3:1 for bright
/// black, the grey of comments and zsh's autosuggestions. Each comment lists
/// those as published → used. Black on a dark background and white on a light
/// one stay as published: programs paint bars and highlights with them, which
/// should sit close to the terminal's own background.
///
/// Dracula and Nord publish no light variant; theirs are the scheme's own
/// colours on a light background, darkened the same way.
final terminalSchemes = [
  // The green Jeansh always had. Background, text, cursor and selection are
  // the Material surface, on-surface and primary it had before there were
  // themes; the ANSI colours are VS Code's: xterm2's default on dark, after
  // Light+ on light.
  TerminalScheme(
    'clode',
    'Jeansh',
    const Color(0xFF4CC38A),
    // red cd3131 → d85a5a, blue 2472c8 → 3685db, magenta bc3fbc → c656c6,
    // bright black 666666 → 676767.
    dark:
        '171d19 dfe4dd 91d5ad 5991d5ad '
        '000000 d85a5a 0dbc79 e5e510 3685db c656c6 11a8cd e5e5e5 '
        '676767 f14c4c 23d18b f5f543 3b8eea d670d6 29b8db ffffff',
    // yellow 946f00 → 8e6a00, cyan 0a7f9e → 0a7997; bright red e04848 →
    // d82525, green 148f14 → 128112, yellow a88400 → 896c00, blue 2a6fd6 →
    // 286dd2, magenta c837c8 → b833b8, cyan 0a93b3 → 087a94.
    light:
        'f0f5ee 171d19 266a4a 59266a4a '
        '000000 cd3131 107c10 8e6a00 0451a5 bc05bc 0a7997 555555 '
        '666666 d82525 128112 896c00 286dd2 b833b8 087a94 8c8c8c',
  ),
  // spec.draculatheme.com, as dracula/alacritty sets it.
  TerminalScheme(
    'dracula',
    'Dracula',
    const Color(0xFFBD93F9),
    dark:
        '282a36 f8f8f2 f8f8f2 44475a '
        '21222c ff5555 50fa7b f1fa8c bd93f9 ff79c6 8be9fd f8f8f2 '
        '6272a4 ff6e6e 69ff94 ffffa5 d6acff ff92df a4ffff ffffff',
    // Unofficial: dark's text and background swapped, its selection at 30%,
    // black and white mirrored, comment grey kept. The bright ones, at 3:1
    // until now: red ff4f4f → e60000, green 00a630 → 008426, yellow 939300 →
    // 767600, blue b56aff → 9b36ff, magenta ff34c3 → d80098, cyan 009f9f →
    // 007f7f.
    light:
        'f8f8f2 282a36 282a36 4d44475a '
        'ffffff e60000 048424 6e7805 8e46f5 dc007f 037c96 282a36 '
        '6272a4 e60000 008426 767600 9b36ff d80098 007f7f 21222c',
  ),
  // nordtheme/alacritty.
  TerminalScheme(
    'nord',
    'Nord',
    const Color(0xFF88C0D0),
    // red bf616a → cf888f, magenta b48ead → b590af, both bright ones too;
    // bright black 4c566a → 6f7d98.
    dark:
        '2e3440 d8dee9 d8dee9 4c566a '
        '3b4252 cf888f a3be8c ebcb8b 81a1c1 b590af 88c0d0 e5e9f0 '
        '6f7d98 cf888f a3be8c ebcb8b 81a1c1 b590af 8fbcbb eceff4',
    // Unofficial: Nord's own "bright ambiance", Snow Storm under Polar Night.
    // The bright ones, at 3:1 until now: red bf616a → b54954, green 719353 →
    // 597442, yellow b2811f → 8d6619, blue 668db4 → 497096, magenta a87ca0 →
    // 8d5d84, cyan 589291 → 467474.
    light:
        'eceff4 2e3440 2e3440 d8dee9 '
        'e5e9f0 b54954 597442 8d6618 496f95 8c5d83 357587 3b4252 '
        '4c566a b54954 597442 8d6619 497096 8d5d84 467474 2e3440',
  ),
  // morhetz/gruvbox, as alacritty-theme sets it; selection is bg2.
  TerminalScheme(
    'gruvbox',
    'Gruvbox',
    const Color(0xFFFE8019),
    // red cc241d → e8645e, blue 458588 → 509a9d, magenta b16286 → bd7b99;
    // bright red fb4934 → fb533f.
    dark:
        '282828 ebdbb2 ebdbb2 504945 '
        '282828 e8645e 98971a d79921 509a9d bd7b99 689d6a a89984 '
        '928374 fb533f b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2',
    // green 98971a → 727114, yellow d79921 → 906616, blue 458588 → 3d7679,
    // magenta b16286 → a65279, cyan 689d6a → 4d774f; bright green 79740e →
    // 75700e, yellow b57614 → 976311, cyan 427b58 → 417957.
    light:
        'fbf1c7 3c3836 3c3836 d5c4a1 '
        'fbf1c7 cc241d 727114 906616 3d7679 a65279 4d774f 7c6f64 '
        '928374 9d0006 75700e 976311 076678 8f3f71 417957 3c3836',
  ),
  // Ethan Schoonover's, as alacritty-theme sets it; cursor base1 or base01,
  // selection base02 or base2.
  TerminalScheme(
    'solarized',
    'Solarized',
    const Color(0xFFB58900),
    // text 839496 → a8b4b5; red dc322f → e56462, blue 268bd2 → 2f93d9,
    // magenta d33682 → dd629d; bright red cb4b16 → e8652e, green 586e75 →
    // 789199, yellow 657b83 → 7a9199, magenta 6c71c4 → 8387cd. Bright black
    // was 002b36, the background itself; it is base01, the scheme's comment
    // grey, lightened: 586e75 → 5d747b.
    dark:
        '002b36 a8b4b5 93a1a1 073642 '
        '073642 e56462 859900 b58900 2f93d9 dd629d 2aa198 eee8d5 '
        '5d747b e8652e 789199 7a9199 839496 8387cd 93a1a1 fdf6e3',
    // text 586e75 → 45575c; red dc322f → da2925, green 859900 → 697800,
    // yellow b58900 → 8f6c00, blue 268bd2 → 2076b3, magenta d33682 → cf2d7c,
    // cyan 2aa198 → 217e77; bright red cb4b16 → c44815, yellow 657b83 →
    // 5f747c, blue 839496 → 647476, magenta 6c71c4 → 6369c0, cyan 93a1a1 →
    // 657474.
    light:
        'fdf6e3 45575c 586e75 eee8d5 '
        '073642 da2925 697800 8f6c00 2076b3 cf2d7c 217e77 eee8d5 '
        '002b36 c44815 586e75 5f747c 647476 6369c0 657474 fdf6e3',
  ),
  // Mocha and Latte, from catppuccin/palette's ANSI colours; the cursor is
  // Rosewater, the selection Overlay 2 at 30%, as its style guide has them.
  TerminalScheme(
    'catppuccin',
    'Catppuccin',
    const Color(0xFFCBA6F7),
    // bright black 585b70 → 656880.
    dark:
        '1e1e2e cdd6f4 f5e0dc 4d9399b2 '
        '45475a f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 a6adc8 '
        '656880 f37799 89d88b ebd391 74a8fc f2aede 6bd7ca bac2de',
    // green 40a02b → 327d22, yellow df8e1d → 996214, blue 1e66f5 → 1962f5,
    // magenta ea76cb → c81f9b, cyan 179299 → 137a80; bright red de293e →
    // d52136, green 49af3d → 347d2c, yellow eea02d → 9b610d, blue 456eff →
    // 2e5cff, magenta fe85d8 → d10290, cyan 2d9fa8 → 227980.
    light:
        'eff1f5 4c4f69 dc8a78 4d7c7f93 '
        '5c5f77 d20f39 327d22 996214 1962f5 c81f9b 137a80 acb0be '
        '6c6f85 d52136 347d2c 9b610d 2e5cff d10290 227980 bcc0cc',
  ),
  // Night and Day, from folke/tokyonight.nvim's terminal extras.
  TerminalScheme(
    'tokyo-night',
    'Tokyo Night',
    const Color(0xFF7AA2F7),
    // bright black 414868 → 5b6591.
    dark:
        '1a1b26 c0caf5 c0caf5 283457 '
        '15161e f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff a9b1d6 '
        '5b6591 ff899d 9fe044 faba4a 8db0ff c7a9ff a4daff c0caf5',
    // text 3760bf → 28458a; red f52a65 → c90941, green 587539 → 526d35,
    // yellow 8c6c3e → 7d6037, blue 2e7de9 → 1561ca, magenta 9854f1 → 8230ee,
    // cyan 007197 → 006d92; bright black a1a6c5 → 777fab, red ff4774 →
    // cb0032, green 5c8524 → 4c6f1e, yellow a27629 → 815e21, blue 358aff →
    // 005ddc, magenta a463ff → 7f24ff, cyan 007ea8 → 006d92.
    light:
        'e1e2e7 28458a 3760bf b7c1e3 '
        'b4b5b9 c90941 526d35 7d6037 1561ca 8230ee 006d92 6172b0 '
        '777fab cb0032 4c6f1e 815e21 005ddc 7f24ff 006d92 3760bf',
  ),
  // Atom's One Dark as alacritty-theme sets it, and One Light's colours from
  // atom/one-light-syntax in the same places (no terminal publishes them
  // faithfully); the cursor and selection are Atom's.
  TerminalScheme(
    'one-dark',
    'One Dark',
    const Color(0xFF61AFEF),
    // text abb2bf → b1b8c4; red e06c75 → e17079, bright red too; bright
    // black 5c6370 → 6c7584.
    dark:
        '282c34 b1b8c4 528bff 3e4451 '
        '1e2127 e17079 98c379 d19a66 61afef c678dd 56b6c2 abb2bf '
        '6c7584 e17079 98c379 d19a66 61afef c678dd 56b6c2 ffffff',
    // red e45649 → db3021, green 50a14f → 40813f, blue 4078f2 → 2c6af1,
    // cyan 0184bc → 017bb0, the bright ones too; bright black a0a1a7 →
    // 909198.
    light:
        'fafafa 383a42 526fff e5e5e6 '
        'ffffff db3021 40813f 986801 2c6af1 a626a4 017bb0 383a42 '
        '909198 db3021 40813f 986801 2c6af1 a626a4 017bb0 000000',
  ),
];
