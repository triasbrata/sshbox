import 'package:flutter_test/flutter_test.dart';
import 'package:sshbox/src/git/git_diff.dart';

/// What a row shows on each side: its number and text, `·` for a filler.
List<String> _rows(DiffHunk hunk) => [
  for (final row in splitRows(hunk.lines))
    '${_side(row.left, old: true)} | ${_side(row.right, old: false)}',
];

String _side(DiffLine? line, {required bool old}) {
  if (line == null) return '·';
  final sign = switch (line.kind) {
    DiffLineKind.added => '+',
    DiffLineKind.removed => '-',
    DiffLineKind.context => ' ',
  };
  return '${old ? line.oldNo : line.newNo}$sign${line.text}';
}

void main() {
  test('a line replaced by three sits beside them, the old side padded so '
      'what follows lines up', () {
    // The screenshot the user drew it from: old 63 becomes new 63 to 65.
    final diff = parseDiff('''
diff --git a/MainActivity.kt b/MainActivity.kt
index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
--- a/MainActivity.kt
+++ b/MainActivity.kt
@@ -60,7 +60,9 @@ class MainActivity : FlutterActivity() {
     // A relaunch
     // instance
     override fun onCreate() {
-        val running = live
+        // MUTATION
+        // so every copy
+        val running: MainActivity? = null
         if (running == null) {
             live = WeakReference(this)
         } else {''');

    final file = diff.files.single;
    expect(file.path, 'MainActivity.kt');
    expect(file.oldBlob, '1111111111111111111111111111111111111111');
    expect(file.added, 3);
    expect(file.removed, 1);
    expect(file.expandable, isTrue);

    final hunk = file.hunks.single;
    expect(hunk.header, '@@ -60,7 +60,9 @@ class MainActivity : FlutterActivity() {');
    expect(_rows(hunk), [
      '60     // A relaunch | 60     // A relaunch',
      '61     // instance | 61     // instance',
      '62     override fun onCreate() { | 62     override fun onCreate() {',
      '63-        val running = live | 63+        // MUTATION',
      '· | 64+        // so every copy',
      '· | 65+        val running: MainActivity? = null',
      '64         if (running == null) { | 66         if (running == null) {',
      '65             live = WeakReference(this) | '
          '67             live = WeakReference(this)',
      '66         } else { | 68         } else {',
    ]);
    expect(hunk.oldEnd, 67);
    expect(hunk.newEnd, 69);
  });

  test('a new file is all additions, with nothing on the old side', () {
    final diff = parseDiff('''
diff --git a/notes.txt b/notes.txt
new file mode 100644
index 0000000000000000000000000000000000000000..3333333333333333333333333333333333333333
--- /dev/null
+++ b/notes.txt
@@ -0,0 +1,2 @@
+first
+second''');

    final file = diff.files.single;
    expect(file.isNew, isTrue);
    expect(file.oldPath, isNull);
    expect(file.newPath, 'notes.txt');
    expect(file.newMode, '100644');
    // Nothing old to read more lines from.
    expect(file.expandable, isFalse);
    expect(_rows(file.hunks.single), ['· | 1+first', '· | 2+second']);
    expect(file.hunks.single.oldFrom, 1);
  });

  test('a pure addition inside a file leaves the old side blank beside it', () {
    final diff = parseDiff('''
diff --git a/a.dart b/a.dart
index 4444444444444444444444444444444444444444..5555555555555555555555555555555555555555 100644
--- a/a.dart
+++ b/a.dart
@@ -3,0 +4,2 @@ void main() {
+  one();
+  two();''');

    final hunk = diff.files.single.hunks.single;
    // "-3,0" is after line 3, so the old side's next line is 4.
    expect(hunk.oldFrom, 4);
    expect(hunk.oldEnd, 4);
    expect(hunk.newFrom, 4);
    expect(_rows(hunk), ['· | 4+  one();', '· | 5+  two();']);
  });

  test('a deleted file is all removals, with nothing on the new side', () {
    final diff = parseDiff('''
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 6666666666666666666666666666666666666666..0000000000000000000000000000000000000000
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-was here
-and here''');

    final file = diff.files.single;
    expect(file.isDeleted, isTrue);
    expect(file.newPath, isNull);
    expect(file.path, 'gone.txt');
    expect(file.expandable, isFalse);
    expect(_rows(file.hunks.single), ['1-was here | ·', '2-and here | ·']);
  });

  test('a rename names both sides, and one with no change says so by having '
      'no hunks', () {
    final diff = parseDiff('''
diff --git a/old name.txt b/new name.txt
similarity index 100%
rename from old name.txt
rename to new name.txt
diff --git a/lib/a.dart b/lib/b.dart
similarity index 90%
rename from lib/a.dart
rename to lib/b.dart
index 7777777777777777777777777777777777777777..8888888888888888888888888888888888888888 100644
--- a/lib/a.dart
+++ b/lib/b.dart
@@ -1 +1 @@
-old
+new''');

    final [pure, edited] = diff.files;
    expect(pure.renamed, isTrue);
    expect(pure.oldPath, 'old name.txt');
    expect(pure.newPath, 'new name.txt');
    expect(pure.hunks, isEmpty);

    expect(edited.renamed, isTrue);
    expect(edited.oldPath, 'lib/a.dart');
    expect(edited.newPath, 'lib/b.dart');
    // A count left out is one.
    expect(_rows(edited.hunks.single), ['1-old | 1+new']);
  });

  test('a binary file is marked as one, with no lines', () {
    final diff = parseDiff('''
diff --git a/icon.png b/icon.png
index 9999999999999999999999999999999999999999..aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 100644
Binary files a/icon.png and b/icon.png differ
diff --git a/b.txt b/b.txt
index bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb..cccccccccccccccccccccccccccccccccccccccc 100644
--- a/b.txt
+++ b/b.txt
@@ -1 +1 @@
-x
+y''');

    final [icon, text] = diff.files;
    expect(icon.binary, isTrue);
    expect(icon.path, 'icon.png');
    expect(icon.hunks, isEmpty);
    expect(icon.expandable, isFalse);
    expect(icon.raw, contains('Binary files a/icon.png and b/icon.png differ'));
    // The file after it is read as usual.
    expect(text.path, 'b.txt');
    expect(_rows(text.hunks.single), ['1-x | 1+y']);
  });

  test('"No newline at end of file" marks the line it follows, wherever it '
      'falls', () {
    final diff = parseDiff(r'''
diff --git a/a.txt b/a.txt
index dddddddddddddddddddddddddddddddddddddddd..eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,3 @@
 one
-two
\ No newline at end of file
+two
+three
\ No newline at end of file''');

    final lines = diff.files.single.hunks.single.lines;
    expect(lines.map((line) => line.text), ['one', 'two', 'two', 'three']);
    expect(lines.map((line) => line.noNewline), [false, true, false, true]);
  });

  test('CRLF endings, a quoted name and a commit\'s preamble', () {
    final diff = parseDiff(
      'Fix the thing\r\n'
      '\r\n'
      'Ada, 2 days ago\r\n'
      '\r\n'
      ' "caf\\303\\251 \\"x\\".txt" | 2 +-\r\n'
      '\r\n'
      'diff --git "a/caf\\303\\251 \\"x\\".txt" "b/caf\\303\\251 \\"x\\".txt"\r\n'
      'index ffffffffffffffffffffffffffffffffffffffff..1212121212121212121212121212121212121212 100644\r\n'
      '--- "a/caf\\303\\251 \\"x\\".txt"\r\n'
      '+++ "b/caf\\303\\251 \\"x\\".txt"\r\n'
      '@@ -1 +1 @@\r\n'
      '-a\r\n'
      '+b\r\n',
    );

    expect(diff.preamble, startsWith('Fix the thing\n\nAda, 2 days ago'));
    final file = diff.files.single;
    expect(file.path, 'café "x".txt');
    expect(file.oldPath, 'café "x".txt');
    expect(_rows(file.hunks.single), ['1-a | 1+b']);
  });

  test('a mode change alone takes its name from the header', () {
    final diff = parseDiff('''
diff --git a/run me.sh b/run me.sh
old mode 100644
new mode 100755''');

    final file = diff.files.single;
    expect(file.path, 'run me.sh');
    expect(file.oldMode, '100644');
    expect(file.newMode, '100755');
    expect(file.hunks, isEmpty);
  });

  test('a line of the file that looks like a header is still a line of the '
      'file, the counts deciding', () {
    final diff = parseDiff('''
diff --git a/notes.md b/notes.md
index 1313131313131313131313131313131313131313..1414141414141414141414141414141414141414 100644
--- a/notes.md
+++ b/notes.md
@@ -1,2 +1,2 @@
-@@ -1 +1 @@
+--- a/x
 diff --git a/y b/y''');

    final file = diff.files.single;
    expect(diff.files, hasLength(1));
    expect(file.hunks.single.lines.map((line) => line.text), [
      '@@ -1 +1 @@',
      '--- a/x',
      'diff --git a/y b/y',
    ]);
  });

  test('blank context lines trimmed off the end of the output are put back', () {
    // What the runner hands over has its trailing whitespace trimmed, and a
    // blank context line at the very end is nothing but whitespace.
    final diff = parseDiff('''
diff --git a/a.txt b/a.txt
index 1515151515151515151515151515151515151515..1616161616161616161616161616161616161616 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,3 @@
-x
+y''');

    final lines = diff.files.single.hunks.single.lines;
    expect(lines.map((line) => (line.oldNo, line.newNo)), [
      (1, null),
      (null, 1),
      (2, 2),
      (3, 3),
    ]);
  });

  test('a merge\'s combined diff is kept as git printed it', () {
    final diff = parseDiff('''
diff --cc lib/a.dart
index 1717171,1818181..1919191
--- a/lib/a.dart
+++ b/lib/a.dart
@@@ -1,1 -1,1 +1,1 @@@
- one
 -two
++three''');

    final file = diff.files.single;
    expect(file.combined, isTrue);
    expect(file.path, 'lib/a.dart');
    expect(file.raw, contains('++three'));
    expect(file.expandable, isFalse);
  });

  test('no diff at all is no files and no preamble', () {
    final diff = parseDiff('');
    expect(diff.files, isEmpty);
    expect(diff.preamble, isEmpty);
  });
}
