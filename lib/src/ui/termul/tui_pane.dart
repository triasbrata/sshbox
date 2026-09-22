// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_pane.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// As upstream.

import 'package:flutter/material.dart';

import 'termul_theme.dart';
import 'tui_text.dart';

class TuiLogLine {
  const TuiLogLine({
    required this.text,
    this.tone = TuiTextTone.normal,
    this.prefix,
  });

  final String text;
  final TuiTextTone tone;
  final String? prefix;
}

class TuiPane extends StatelessWidget {
  const TuiPane({
    super.key,
    required this.title,
    required this.lines,
    this.subtitle,
    this.footer,
    this.child,
  });

  final String title;
  final String? subtitle;
  final String? footer;
  final List<TuiLogLine> lines;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;

    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: p.sidebar,
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                TuiText(title, bold: true, size: 12),
                if (subtitle != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: TuiText(
                      subtitle!,
                      tone: TuiTextTone.dim,
                      size: 11,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ] else
                  const Spacer(),
              ],
            ),
          ),
          Expanded(
            child:
                child ??
                ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: lines.length,
                  itemBuilder: (context, i) {
                    final line = lines[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (line.prefix != null) ...[
                            SizedBox(
                              width: 28,
                              child: TuiText(
                                line.prefix!,
                                tone: TuiTextTone.dim,
                                size: 12,
                              ),
                            ),
                          ],
                          Expanded(
                            child: TuiText(
                              line.text,
                              tone: line.tone,
                              size: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
          ),
          if (footer != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.border)),
              ),
              child: TuiText(footer!, tone: TuiTextTone.dim, size: 10),
            ),
        ],
      ),
    );
  }
}

class TuiAsciiLogo extends StatelessWidget {
  const TuiAsciiLogo({super.key});

  static const mark = '''
 ▐▛███▜▌
▝▜█████▛▘
  ▘▘ ▝▝''';

  @override
  Widget build(BuildContext context) {
    return const TuiText(mark, tone: TuiTextTone.accent, size: 11);
  }
}
