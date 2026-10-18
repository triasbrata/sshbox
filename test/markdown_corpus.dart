import 'dart:io';

/// Documents of the kinds people keep on a host: a README, a CLAUDE.md, and
/// the corners of Markdown that are easiest to get wrong.
final _documents = <String, String>{
  'readme': '''
# Jeansh

Terminal buddy in your **pocket**. Built with _Flutter_ and `dartssh2`.

[![CI](https://img.shields.io/badge.svg)](https://example.com/ci)

## Install

* Download the build for your desktop.
* Unpack it, then run `./jeansh`.
* Read the [docs](https://example.com/docs "The docs").

1. One
2. Two
3) Three

```sh
flutter build apk --release
```

| Platform | Status |
|----------|:------:|
| Android  | ✅     |

<details>
<summary>More</summary>

Hidden *text*.

</details>

See [the guide][guide] and the footnote[^1].

[guide]: https://example.com/guide
[^1]: A footnote.

---

Line one
line two after a hard break.
Trailing paragraph with an escaped \\* star and a \\_ line.
''',
  'claude': '''
---
title: notes
tags: [a, b]
---

# How sessions work

Several sessions work this repo at the same time. These rules keep them
from colliding, and make sure *nothing* counts as done until the user
has tried it.

## Who runs the app

- One **coordinator** session holds the only `flutter run`.
  It answers the user itself.
- Every other session is a worker.
  - Workers never run `flutter install`.
  - [ ] a task
  - [x] a done task

> A quote
> over two lines.

    indented code
    more

Setext heading
==============

Another
-------

<!-- a comment
spanning lines -->

Closing paragraph with a [link](<https://example.com/a b>) and `` code ` span ``.
''',
  'edges': '''
Intra_word_underscores and snake_case_names stay text.

***bold italic*** and **bold *nested* bold** and *a **b** c*.

A line with &amp; an entity.

A raw <span>tag</span> inline.

A bare https://example.com link.

~~struck~~ text.

  Indented paragraph.

#Not a heading
# Heading with closing ##
###### Six

+ plus item
-
- after empty

```mermaid
flowchart LR
  A --> B
```

~~~
tilde fence
~~~

```
unclosed fence
''',
  'crlf-free tail without newline': 'Last line with no newline',
  'empty': '',
  'only blanks': '\n\n\n',
  'with a table at the very end': '| a | b |\n|---|---|\n| 1 | 2 |',
  'nested lists and quotes':
      '- a\n  - b\n    - c\n      1. d\n> q\n> > nested\n> - item in quote\n',
  'tasks': '- [ ] open\n- [x] done\n* [X] done too\n  - [ ] nested\n',
};

/// Every document the fidelity tests run over: the hand-made ones above and
/// the repository's own README.md and CLAUDE.md, which are real and long.
Map<String, String> get markdownCorpus => {
  ..._documents,
  'repo README.md': File('README.md').readAsStringSync(),
  'repo CLAUDE.md': File('CLAUDE.md').readAsStringSync(),
};
