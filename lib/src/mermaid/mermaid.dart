/// Which Mermaid diagrams Jeansh draws itself, and how a source is read.
library;

import 'flowchart.dart';
import 'scene.dart';
import 'sequence.dart';

export 'scene.dart';

sealed class MermaidRead {
  const MermaidRead(this.kind);

  /// The diagram's first word: `flowchart`, `sequenceDiagram`, `pie`…
  final String kind;
}

/// A diagram read whole, laid out once its text can be measured.
class MermaidDrawable extends MermaidRead {
  const MermaidDrawable(super.kind, this.layout);

  final MermaidScene Function(MermaidMeasure measure) layout;
}

/// A diagram not drawn here: a kind there is no native layout for, or a
/// source this reader could not follow, which [reason] says.
class MermaidNotDrawn extends MermaidRead {
  const MermaidNotDrawn(super.kind, this.reason);

  final String reason;
}

/// The kinds laid out natively.
const nativeMermaidKinds = {'graph', 'flowchart', 'sequenceDiagram'};

MermaidRead readMermaid(String source) {
  final lines = source.split('\n');
  final i = skipMermaidPreamble(lines);
  final kind = i < lines.length
      ? lines[i].trim().split(RegExp(r'[\s;]')).first
      : '';
  if (!nativeMermaidKinds.contains(kind)) {
    return MermaidNotDrawn(
      kind,
      kind.isEmpty ? 'no diagram' : '$kind is not drawn natively',
    );
  }
  try {
    if (kind == 'sequenceDiagram') {
      final d = SequenceDiagram.parse(source);
      return MermaidDrawable(kind, d.layout);
    }
    final f = Flowchart.parse(source);
    return MermaidDrawable(kind, f.layout);
  } on MermaidError catch (e) {
    return MermaidNotDrawn(kind, 'not drawn natively: $e');
  }
}
