import 'package:flutter/widgets.dart';
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

/// The themes Settings offers, Clode's own first: the one in use until
/// another is picked.
///
/// Each scheme's published colours, light variants included, except where a
/// comment says otherwise. Dracula and Nord publish no light variant; theirs
/// are the scheme's own colours on a light background, each accent darkened
/// (hue and saturation kept) until it reaches 4.5:1 there, and 3:1 for the
/// bright ones.
final terminalSchemes = [
  // The green Clode always had. Background, text, cursor and selection are
  // its Material surface, on-surface and primary; the ANSI colours are VS
  // Code's: xterm2's default on dark, after Light+ on light.
  TerminalScheme(
    'clode',
    'Clode',
    const Color(0xFF4CC38A),
    dark:
        '171d19 dfe4dd 91d5ad 5991d5ad '
        '000000 cd3131 0dbc79 e5e510 2472c8 bc3fbc 11a8cd e5e5e5 '
        '666666 f14c4c 23d18b f5f543 3b8eea d670d6 29b8db ffffff',
    light:
        'f0f5ee 171d19 266a4a 59266a4a '
        '000000 cd3131 107c10 946f00 0451a5 bc05bc 0a7f9e 555555 '
        '666666 e04848 148f14 a88400 2a6fd6 c837c8 0a93b3 8c8c8c',
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
    // black and white mirrored, comment grey kept.
    light:
        'f8f8f2 282a36 282a36 4d44475a '
        'ffffff e60000 048424 6e7805 8e46f5 dc007f 037c96 282a36 '
        '6272a4 ff4f4f 00a630 939300 b56aff ff34c3 009f9f 21222c',
  ),
  // nordtheme/alacritty.
  TerminalScheme(
    'nord',
    'Nord',
    const Color(0xFF88C0D0),
    dark:
        '2e3440 d8dee9 d8dee9 4c566a '
        '3b4252 bf616a a3be8c ebcb8b 81a1c1 b48ead 88c0d0 e5e9f0 '
        '4c566a bf616a a3be8c ebcb8b 81a1c1 b48ead 8fbcbb eceff4',
    // Unofficial: Nord's own "bright ambiance", Snow Storm under Polar Night.
    light:
        'eceff4 2e3440 2e3440 d8dee9 '
        'e5e9f0 b54954 597442 8d6618 496f95 8c5d83 357587 3b4252 '
        '4c566a bf616a 719353 b2811f 668db4 a87ca0 589291 2e3440',
  ),
  // morhetz/gruvbox, as alacritty-theme sets it; selection is bg2.
  TerminalScheme(
    'gruvbox',
    'Gruvbox',
    const Color(0xFFFE8019),
    dark:
        '282828 ebdbb2 ebdbb2 504945 '
        '282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 '
        '928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2',
    light:
        'fbf1c7 3c3836 3c3836 d5c4a1 '
        'fbf1c7 cc241d 98971a d79921 458588 b16286 689d6a 7c6f64 '
        '928374 9d0006 79740e b57614 076678 8f3f71 427b58 3c3836',
  ),
  // Ethan Schoonover's, as alacritty-theme sets it; cursor base1 or base01,
  // selection base02 or base2.
  TerminalScheme(
    'solarized',
    'Solarized',
    const Color(0xFFB58900),
    dark:
        '002b36 839496 93a1a1 073642 '
        '073642 dc322f 859900 b58900 268bd2 d33682 2aa198 eee8d5 '
        '002b36 cb4b16 586e75 657b83 839496 6c71c4 93a1a1 fdf6e3',
    light:
        'fdf6e3 586e75 586e75 eee8d5 '
        '073642 dc322f 859900 b58900 268bd2 d33682 2aa198 eee8d5 '
        '002b36 cb4b16 586e75 657b83 839496 6c71c4 93a1a1 fdf6e3',
  ),
  // Mocha and Latte, from catppuccin/palette's ANSI colours; the cursor is
  // Rosewater, the selection Overlay 2 at 30%, as its style guide has them.
  TerminalScheme(
    'catppuccin',
    'Catppuccin',
    const Color(0xFFCBA6F7),
    dark:
        '1e1e2e cdd6f4 f5e0dc 4d9399b2 '
        '45475a f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 a6adc8 '
        '585b70 f37799 89d88b ebd391 74a8fc f2aede 6bd7ca bac2de',
    light:
        'eff1f5 4c4f69 dc8a78 4d7c7f93 '
        '5c5f77 d20f39 40a02b df8e1d 1e66f5 ea76cb 179299 acb0be '
        '6c6f85 de293e 49af3d eea02d 456eff fe85d8 2d9fa8 bcc0cc',
  ),
  // Night and Day, from folke/tokyonight.nvim's terminal extras.
  TerminalScheme(
    'tokyo-night',
    'Tokyo Night',
    const Color(0xFF7AA2F7),
    dark:
        '1a1b26 c0caf5 c0caf5 283457 '
        '15161e f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff a9b1d6 '
        '414868 ff899d 9fe044 faba4a 8db0ff c7a9ff a4daff c0caf5',
    light:
        'e1e2e7 3760bf 3760bf b7c1e3 '
        'b4b5b9 f52a65 587539 8c6c3e 2e7de9 9854f1 007197 6172b0 '
        'a1a6c5 ff4774 5c8524 a27629 358aff a463ff 007ea8 3760bf',
  ),
  // Atom's One Dark as alacritty-theme sets it, and One Light's colours from
  // atom/one-light-syntax in the same places (no terminal publishes them
  // faithfully); the cursor and selection are Atom's.
  TerminalScheme(
    'one-dark',
    'One Dark',
    const Color(0xFF61AFEF),
    dark:
        '282c34 abb2bf 528bff 3e4451 '
        '1e2127 e06c75 98c379 d19a66 61afef c678dd 56b6c2 abb2bf '
        '5c6370 e06c75 98c379 d19a66 61afef c678dd 56b6c2 ffffff',
    light:
        'fafafa 383a42 526fff e5e5e6 '
        'ffffff e45649 50a14f 986801 4078f2 a626a4 0184bc 383a42 '
        'a0a1a7 e45649 50a14f 986801 4078f2 a626a4 0184bc 000000',
  ),
];
