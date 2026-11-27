import 'dart:collection' show Queue;
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:xterm2/src/core/buffer/cell_offset.dart';
import 'package:xterm2/src/core/cell.dart';
import 'package:xterm2/src/core/cursor.dart';
import 'package:xterm2/src/utils/circular_buffer.dart';
import 'package:xterm2/src/utils/unicode_v11.dart';

const _cellSize = 4;

const _cellForeground = 0;

const _cellBackground = 1;

const _cellAttributes = 2;

const _cellContent = 3;

const _maxCombiningCharactersPerCell = 16;

class BufferLine with IndexedItem {
  BufferLine(
    this._length, {
    this.isWrapped = false,
  }) : _cells = Uint32List(_calcCapacity(_length) * _cellSize);

  int _length;

  /// The cells, four words each. Empty while the line is [isPacked].
  Uint32List _cells;

  /// What every method reads and writes: the cells, unpacked first if they
  /// are packed.
  @pragma('vm:prefer-inline')
  Uint32List get _data {
    if (_packed != null) _unpack();
    return _cells;
  }

  set _data(Uint32List value) {
    _packed = null;
    _cells = value;
  }

  /// The line as [pack] left it, or null while its cells are in [_cells].
  Uint8List? _packed;

  /// Whether the cells are held packed, a line scrolled out of sight taking
  /// a twentieth of the memory it does unpacked.
  bool get isPacked => _packed != null;

  /// The bytes the cells take now, packed or not.
  int get heldBytes => _packed?.lengthInBytes ?? _cells.lengthInBytes;

  /// Lines unpacked to be read or changed, oldest first. A line that has
  /// fallen out of the back of it is packed again, so scrolling through the
  /// whole scrollback does not leave it all unpacked.
  static final _unpacked = Queue<BufferLine>();
  static const _maxUnpacked = 256;

  Uint32List get data => _data;

  var isWrapped = false;

  int get length => _length;

  final _anchors = <CellAnchor>[];

  Map<int, String>? _combiningCharacters;

  Map<int, int>? _underlineColors;

  List<CellAnchor> get anchors => _anchors;

  bool get hasCombiningCharacters => _combiningCharacters?.isNotEmpty ?? false;

  Map<int, String> get _mutableCombiningCharacters {
    return _combiningCharacters ??= <int, String>{};
  }

  Map<int, int> get _mutableUnderlineColors {
    return _underlineColors ??= <int, int>{};
  }

  int getForeground(int index) {
    return _data[index * _cellSize + _cellForeground];
  }

  int getBackground(int index) {
    return _data[index * _cellSize + _cellBackground];
  }

  int getAttributes(int index) {
    return _data[index * _cellSize + _cellAttributes];
  }

  int getHyperlinkId(int index) {
    return (getAttributes(index) & CellAttr.hyperlinkMask) >>
        CellAttr.hyperlinkShift;
  }

  bool isProtected(int index) {
    return getAttributes(index) & CellAttr.protected != 0;
  }

  int getContent(int index) {
    return _data[index * _cellSize + _cellContent];
  }

  int getCodePoint(int index) {
    return _data[index * _cellSize + _cellContent] & CellContent.codepointMask;
  }

  int getWidth(int index) {
    return _data[index * _cellSize + _cellContent] >> CellContent.widthShift;
  }

  String? getCombiningCharacters(int index) {
    return _combiningCharacters?[index];
  }

  int getUnderlineColor(int index) {
    return _underlineColors?[index] ?? 0;
  }

  void addCombiningCharacter(int index, int codePoint) {
    if (index < 0 ||
        index >= _length ||
        getCodePoint(index) == 0 ||
        codePoint < 0 ||
        codePoint > 0x10FFFF) {
      return;
    }

    final existing = _combiningCharacters?[index];
    if (existing == null) {
      _mutableCombiningCharacters[index] = String.fromCharCode(codePoint);
      return;
    }

    if (existing.runes.length >= _maxCombiningCharactersPerCell) return;
    _mutableCombiningCharacters[index] =
        existing + String.fromCharCode(codePoint);
  }

  void getCellData(
    int index,
    CellData cellData, {
    bool includeUnderlineColor = true,
  }) {
    final offset = index * _cellSize;
    cellData.foreground = _data[offset + _cellForeground];
    cellData.background = _data[offset + _cellBackground];
    cellData.underlineColor = switch (includeUnderlineColor) {
      true => _underlineColors?[index] ?? 0,
      false => 0,
    };
    cellData.flags = _data[offset + _cellAttributes];
    cellData.content = _data[offset + _cellContent];
  }

  CellData createCellData(int index) {
    final cellData = CellData.empty();
    getCellData(index, cellData);
    return cellData;
  }

  void setForeground(int index, int value) {
    _data[index * _cellSize + _cellForeground] = value;
  }

  void setBackground(int index, int value) {
    _data[index * _cellSize + _cellBackground] = value;
  }

  void setAttributes(int index, int value) {
    _data[index * _cellSize + _cellAttributes] = value;
  }

  void setContent(int index, int value) {
    _data[index * _cellSize + _cellContent] = value;
    _combiningCharacters?.remove(index);
  }

  void setWidth(int index, int width) {
    final offset = index * _cellSize + _cellContent;
    _data[offset] = (_data[offset] & CellContent.codepointMask) |
        (width << CellContent.widthShift);
  }

  void setCodePoint(int index, int char) {
    final width = unicodeV11.wcwidth(char);
    setContent(index, char | (width << CellContent.widthShift));
  }

  void setCell(int index, int char, int witdh, CursorStyle style) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = style.foreground;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] =
        style.attrs | (style.hyperlinkId << CellAttr.hyperlinkShift);
    _data[offset + _cellContent] = char | (witdh << CellContent.widthShift);
    _setUnderlineColor(index, style.underlineColor);
    _combiningCharacters?.remove(index);
  }

  void setAsciiCells(
    int start,
    String text,
    int textStart,
    int count,
    CursorStyle style,
  ) {
    assert(start >= 0 && start + count <= _length);
    assert(textStart >= 0 && textStart + count <= text.length);
    if (count <= 0) return;

    clearWideCellAt(start, style);
    clearWideCellAt(start + count - 1, style);

    final foreground = style.foreground;
    final background = style.background;
    final attributes =
        style.attrs | (style.hyperlinkId << CellAttr.hyperlinkShift);
    for (var offset = 0; offset < count; offset++) {
      final cellOffset = (start + offset) * _cellSize;
      final codeUnit = text.codeUnitAt(textStart + offset);
      assert(codeUnit >= 0x20 && codeUnit <= 0x7e);
      _data[cellOffset + _cellForeground] = foreground;
      _data[cellOffset + _cellBackground] = background;
      _data[cellOffset + _cellAttributes] = attributes;
      _data[cellOffset + _cellContent] =
          codeUnit | (1 << CellContent.widthShift);
    }

    final end = start + count;
    if (_combiningCharacters case final combiningCharacters?
        when combiningCharacters.isNotEmpty) {
      combiningCharacters.removeWhere(
        (index, _) => index >= start && index < end,
      );
    }
    if (style.underlineColor == 0) {
      if (_underlineColors case final underlineColors?
          when underlineColors.isNotEmpty) {
        underlineColors.removeWhere(
          (index, _) => index >= start && index < end,
        );
      }
      return;
    }
    for (var index = start; index < end; index++) {
      _mutableUnderlineColors[index] = style.underlineColor;
    }
  }

  void clearWideCellAt(int index, CursorStyle style) {
    if (index < 0 || index >= _length) return;

    if (getWidth(index) == 2) {
      eraseCell(index, style);
      if (index + 1 < _length) {
        eraseCell(index + 1, style);
      }
      return;
    }

    if (index > 0 && getWidth(index - 1) == 2) {
      eraseCell(index - 1, style);
      eraseCell(index, style);
    }
  }

  void setCellData(int index, CellData cellData) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = cellData.foreground;
    _data[offset + _cellBackground] = cellData.background;
    _data[offset + _cellAttributes] = cellData.flags;
    _data[offset + _cellContent] = cellData.content;
    _setUnderlineColor(index, cellData.underlineColor);
    _combiningCharacters?.remove(index);
  }

  void eraseCell(int index, CursorStyle style) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = CellColor.normal;
    _data[offset + _cellBackground] = style.background;
    _data[offset + _cellAttributes] = 0;
    _data[offset + _cellContent] = 0;
    _underlineColors?.remove(index);
    _combiningCharacters?.remove(index);
  }

  void resetCell(int index) {
    final offset = index * _cellSize;
    _data[offset + _cellForeground] = 0;
    _data[offset + _cellBackground] = 0;
    _data[offset + _cellAttributes] = 0;
    _data[offset + _cellContent] = 0;
    _underlineColors?.remove(index);
    _combiningCharacters?.remove(index);
  }

  void _setUnderlineColor(int index, int value) {
    if (value == 0) {
      _underlineColors?.remove(index);
      return;
    }
    _mutableUnderlineColors[index] = value;
  }

  /// Erase cells whose index satisfies [start] <= index < [end]. Erased cells
  /// are filled with [style].
  void eraseRange(
    int start,
    int end,
    CursorStyle style, {
    bool respectProtected = false,
  }) {
    // reset cell one to the left if start is second cell of a wide char
    if (start > 0 &&
        getWidth(start - 1) == 2 &&
        _canErase(start - 1, respectProtected)) {
      eraseCell(start - 1, style);
    }

    // reset cell one to the right if end is second cell of a wide char
    if (end < _length &&
        getWidth(end - 1) == 2 &&
        _canErase(end - 1, respectProtected)) {
      eraseCell(end - 1, style);
    }

    end = min(end, _length);
    for (var i = start; i < end; i++) {
      if (!_canErase(i, respectProtected)) continue;
      eraseCell(i, style);
    }
  }

  bool _canErase(int index, bool respectProtected) {
    if (!respectProtected) return true;
    return !isProtected(index);
  }

  /// Remove [count] cells starting at [start]. Cells that are empty after the
  /// removal are filled with [style].
  void removeCells(int start, int count, [CursorStyle? style, int? end]) {
    end ??= _length;
    assert(start >= 0 && start < _length);
    assert(end >= start && end <= _length);
    assert(count >= 0 && start + count <= end);

    if (count == 0) return;

    style ??= CursorStyle.empty;
    final combiningCharacters = switch (_combiningCharacters) {
      final values? when values.isNotEmpty => Map<int, String>.of(values),
      _ => const <int, String>{},
    };
    final underlineColors = switch (_underlineColors) {
      final values? when values.isNotEmpty => Map<int, int>.of(values),
      _ => const <int, int>{},
    };
    final rightBoundarySplitsWideCell =
        end < _length && end > 0 && getWidth(end - 1) == 2;

    if (start + count < end) {
      final moveStart = start * _cellSize;
      final moveEnd = (end - count) * _cellSize;
      final moveOffset = count * _cellSize;
      _data.setRange(moveStart, moveEnd, _data, moveStart + moveOffset);
    }

    for (var i = end - count; i < end; i++) {
      eraseCell(i, style);
    }

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }
    if (rightBoundarySplitsWideCell) {
      final shiftedHead = end - count - 1;
      if (shiftedHead >= start && shiftedHead < _length) {
        eraseCell(shiftedHead, style);
      }
      eraseCell(end, style);
    }

    _combiningCharacters = null;
    _underlineColors = null;
    for (final entry in combiningCharacters.entries) {
      if (entry.key < start) {
        if (getCodePoint(entry.key) != 0) {
          _mutableCombiningCharacters[entry.key] = entry.value;
        }
        continue;
      }

      if (entry.key < start + count) continue;
      final newIndex = entry.key - count;
      if (entry.key < end &&
          newIndex < _length &&
          getCodePoint(newIndex) != 0) {
        _mutableCombiningCharacters[newIndex] = entry.value;
        continue;
      }

      if (entry.key >= end && getCodePoint(entry.key) != 0) {
        _mutableCombiningCharacters[entry.key] = entry.value;
      }
    }
    for (final entry in underlineColors.entries) {
      if (entry.key < start) {
        if (getCodePoint(entry.key) != 0) {
          _mutableUnderlineColors[entry.key] = entry.value;
        }
        continue;
      }

      if (entry.key < start + count) continue;
      final newIndex = entry.key - count;
      if (entry.key < end &&
          newIndex < _length &&
          getCodePoint(newIndex) != 0) {
        _mutableUnderlineColors[newIndex] = entry.value;
        continue;
      }

      if (entry.key >= end && getCodePoint(entry.key) != 0) {
        _mutableUnderlineColors[entry.key] = entry.value;
      }
    }

    // Update anchors, remove anchors that are inside the removed range.
    if (_anchors.isNotEmpty) {
      for (final anchor in _anchors.toList()) {
        if (anchor.x >= start) {
          if (anchor.x < start + count) {
            anchor.dispose();
          } else if (anchor.x < end) {
            anchor.reposition(anchor.x - count);
          }
        }
      }
    }
  }

  /// Inserts [count] cells at [start]. New cells are initialized with [style].
  void insertCells(int start, int count, [CursorStyle? style, int? end]) {
    end ??= _length;
    assert(start >= 0 && start < _length);
    assert(end >= start && end <= _length);
    assert(count >= 0 && start + count <= end);

    if (count == 0) return;

    style ??= CursorStyle.empty;
    final combiningCharacters = switch (_combiningCharacters) {
      final values? when values.isNotEmpty => Map<int, String>.of(values),
      _ => const <int, String>{},
    };
    final underlineColors = switch (_underlineColors) {
      final values? when values.isNotEmpty => Map<int, int>.of(values),
      _ => const <int, int>{},
    };
    final rightBoundarySplitsWideCell =
        end < _length && end > 0 && getWidth(end - 1) == 2;

    if (start > 0 && getWidth(start - 1) == 2) {
      eraseCell(start - 1, style);
    }

    if (start + count < end) {
      final moveStart = start * _cellSize;
      final moveEnd = (end - count) * _cellSize;
      final moveOffset = count * _cellSize;
      _data.setRange(
        moveStart + moveOffset,
        moveEnd + moveOffset,
        _data,
        moveStart,
      );
    }

    final eraseEnd = min(start + count, end);
    for (var i = start; i < eraseEnd; i++) {
      eraseCell(i, style);
    }

    if (end > 0 && getWidth(end - 1) == 2) {
      eraseCell(end - 1, style);
    }
    if (rightBoundarySplitsWideCell) {
      eraseCell(end, style);
    }

    _combiningCharacters = null;
    _underlineColors = null;
    for (final entry in combiningCharacters.entries) {
      if (entry.key < start) {
        if (getCodePoint(entry.key) != 0) {
          _mutableCombiningCharacters[entry.key] = entry.value;
        }
        continue;
      }

      final newIndex = entry.key + count;
      if (entry.key < end && newIndex < end && getCodePoint(newIndex) != 0) {
        _mutableCombiningCharacters[newIndex] = entry.value;
        continue;
      }

      if (entry.key >= end && getCodePoint(entry.key) != 0) {
        _mutableCombiningCharacters[entry.key] = entry.value;
      }
    }
    for (final entry in underlineColors.entries) {
      if (entry.key < start) {
        if (getCodePoint(entry.key) != 0) {
          _mutableUnderlineColors[entry.key] = entry.value;
        }
        continue;
      }

      final newIndex = entry.key + count;
      if (entry.key < end && newIndex < end && getCodePoint(newIndex) != 0) {
        _mutableUnderlineColors[newIndex] = entry.value;
        continue;
      }

      if (entry.key >= end && getCodePoint(entry.key) != 0) {
        _mutableUnderlineColors[entry.key] = entry.value;
      }
    }

    // Update anchors, move anchors that are after the inserted range.
    if (_anchors.isNotEmpty) {
      for (final anchor in _anchors.toList()) {
        if (anchor.x >= end - count && anchor.x < end) {
          anchor.dispose();
          continue;
        }

        if (anchor.x >= start && anchor.x < end - count) {
          anchor.reposition(anchor.x + count);
        }
      }
    }
  }

  void resize(int length) {
    assert(length >= 0);

    if (length == _length) {
      return;
    }

    // The packed cells are a run of exactly the old length.
    if (_packed != null) _unpack();

    if (length > _length) {
      final newBufferSize = _calcCapacity(length) * _cellSize;

      if (newBufferSize > _data.length) {
        final newBuffer = Uint32List(newBufferSize);
        newBuffer.setRange(0, _data.length, _data);
        _data = newBuffer;
      }
    }

    _length = length;

    for (var i = 0; i < _anchors.length; i++) {
      final anchor = _anchors[i];
      if (anchor.x > _length) {
        anchor.reposition(_length);
      }
    }
  }

  /// Holds the cells in a form that takes about 1 to 2 bytes for each one
  /// written, instead of 16 for each one in the line's width: the text as
  /// bytes (a printable ASCII character is one byte, anything else a marker
  /// and a number), the trailing blanks left out, and the colours and
  /// attributes as runs. Nothing is lost: every method of the line unpacks it
  /// again, as it was, when it is used. Cells past [length] are not kept.
  void pack() {
    if (_packed != null) return;
    final cells = _cells;
    final length = _length;
    var contentLength = 0;
    for (var i = length - 1; i >= 0; i--) {
      if (cells[i * _cellSize + _cellContent] != 0) {
        contentLength = i + 1;
        break;
      }
    }

    final out = <int>[];
    _writeVarint(out, contentLength);
    final runs = <int>[];
    var runCount = 0;
    var runStart = 0;
    for (var i = 1; i <= length; i++) {
      if (i < length &&
          cells[i * _cellSize + _cellForeground] ==
              cells[runStart * _cellSize + _cellForeground] &&
          cells[i * _cellSize + _cellBackground] ==
              cells[runStart * _cellSize + _cellBackground] &&
          cells[i * _cellSize + _cellAttributes] ==
              cells[runStart * _cellSize + _cellAttributes]) {
        continue;
      }
      if (length == 0) break;
      _writeVarint(runs, i - runStart);
      _writeVarint(runs, cells[runStart * _cellSize + _cellForeground]);
      _writeVarint(runs, cells[runStart * _cellSize + _cellBackground]);
      _writeVarint(runs, cells[runStart * _cellSize + _cellAttributes]);
      runCount++;
      runStart = i;
    }
    _writeVarint(out, runCount);
    out.addAll(runs);
    for (var i = 0; i < contentLength; i++) {
      final word = cells[i * _cellSize + _cellContent];
      final codePoint = word & CellContent.codepointMask;
      if (word == 0) {
        out.add(0);
      } else if (word == (codePoint | (1 << CellContent.widthShift)) &&
          codePoint >= 0x20 &&
          codePoint <= 0x7e) {
        out.add(codePoint);
      } else {
        out.add(1);
        _writeVarint(out, word);
      }
    }
    _packed = Uint8List.fromList(out);
    _cells = _emptyCells;
  }

  static final _emptyCells = Uint32List(0);

  void _unpack() {
    final packed = _packed!;
    final cells = Uint32List(_calcCapacity(_length) * _cellSize);
    var at = 0;
    int readVarint() {
      var value = 0;
      var shift = 0;
      while (true) {
        final byte = packed[at++];
        value |= (byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        shift += 7;
      }
    }

    final contentLength = readVarint();
    final runCount = readVarint();
    var cell = 0;
    for (var run = 0; run < runCount; run++) {
      final count = readVarint();
      final foreground = readVarint();
      final background = readVarint();
      final attributes = readVarint();
      for (var i = 0; i < count; i++, cell++) {
        final offset = cell * _cellSize;
        cells[offset + _cellForeground] = foreground;
        cells[offset + _cellBackground] = background;
        cells[offset + _cellAttributes] = attributes;
      }
    }
    for (var i = 0; i < contentLength; i++) {
      final byte = packed[at++];
      final offset = i * _cellSize + _cellContent;
      if (byte == 0) continue;
      cells[offset] =
          byte == 1 ? readVarint() : byte | (1 << CellContent.widthShift);
    }
    _cells = cells;
    _packed = null;

    _unpacked.add(this);
    if (_unpacked.length > _maxUnpacked) _unpacked.removeFirst().pack();
  }

  static void _writeVarint(List<int> out, int value) {
    while (value >= 0x80) {
      out.add((value & 0x7f) | 0x80);
      value >>= 7;
    }
    out.add(value);
  }

  /// Returns the offset of the last cell that has content from the start of
  /// the line.
  int getTrimmedLength([int? cols]) {
    final maxCols = _data.length ~/ _cellSize;

    if (cols == null || cols > maxCols) {
      cols = maxCols;
    }

    if (cols <= 0) {
      return 0;
    }

    for (var i = cols - 1; i >= 0; i--) {
      var codePoint = getCodePoint(i);

      if (codePoint != 0) {
        // we are at the last cell in this line that has content.
        // the length of this line is the index of this cell + 1
        // the only exception is that if that last cell is wider
        // than 1 then we have to add the diff
        final lastCellWidth = getWidth(i);
        return i + lastCellWidth;
      }
    }
    return 0;
  }

  /// Copies [len] cells from [src] starting at [srcCol] to [dstCol] at this
  /// line.
  void copyFrom(BufferLine src, int srcCol, int dstCol, int len) {
    final requiredLength = dstCol + len;
    if (requiredLength > _length) {
      resize(requiredLength);
    }
    final dstEnd = dstCol + len;
    final srcEnd = srcCol + len;
    final leftBoundarySplitsWideCell = dstCol > 0 && srcCol > 0;
    final rightBoundarySplitsWideCell = dstEnd < _length && srcEnd > 0;
    Map<int, String>? copiedCombiningCharacters;
    Map<int, int>? copiedUnderlineColors;
    if (src._combiningCharacters case final combiningCharacters?) {
      for (final entry in combiningCharacters.entries) {
        if (entry.key < srcCol || entry.key >= srcCol + len) continue;
        final destination = dstCol + entry.key - srcCol;
        (copiedCombiningCharacters ??= <int, String>{})[destination] =
            entry.value;
      }
    }
    if (src._underlineColors case final underlineColors?) {
      for (final entry in underlineColors.entries) {
        if (entry.key < srcCol || entry.key >= srcCol + len) continue;
        final destination = dstCol + entry.key - srcCol;
        (copiedUnderlineColors ??= <int, int>{})[destination] = entry.value;
      }
    }

    // data.setRange(
    //   dstCol * _cellSize,
    //   (dstCol + len) * _cellSize,
    //   Uint32List.sublistView(src.data, srcCol * _cellSize, len * _cellSize),
    // );

    final srcOffset = srcCol * _cellSize;
    final dstOffset = dstCol * _cellSize;
    _data.setRange(
      dstOffset,
      dstOffset + len * _cellSize,
      src._data,
      srcOffset,
    );

    if (_combiningCharacters case final combiningCharacters?) {
      combiningCharacters.removeWhere(
        (index, _) => index >= dstCol && index < dstCol + len,
      );
      if (combiningCharacters.isEmpty) _combiningCharacters = null;
    }
    if (copiedCombiningCharacters case final copied?) {
      _mutableCombiningCharacters.addAll(copied);
    }
    if (_underlineColors case final underlineColors?) {
      underlineColors.removeWhere(
        (index, _) => index >= dstCol && index < dstCol + len,
      );
      if (underlineColors.isEmpty) _underlineColors = null;
    }
    if (copiedUnderlineColors case final copied?) {
      _mutableUnderlineColors.addAll(copied);
    }

    if (leftBoundarySplitsWideCell && getWidth(dstCol) == 0) {
      resetCell(dstCol);
    }
    if (rightBoundarySplitsWideCell && getWidth(dstEnd - 1) == 2) {
      resetCell(dstEnd - 1);
    }
  }

  static int _calcCapacity(int length) {
    assert(length >= 0);

    var capacity = 64;

    if (length < 256) {
      while (capacity < length) {
        capacity *= 2;
      }
    } else {
      capacity = 256;
      while (capacity < length) {
        capacity += 32;
      }
    }

    return capacity;
  }

  String getText([int? from, int? to]) {
    if (from == null || from < 0) {
      from = 0;
    }

    if (to == null || to > _length) {
      to = _length;
    }

    if (from > 0 &&
        from < _length &&
        getWidth(from) == 0 &&
        getWidth(from - 1) == 2) {
      from--;
    }
    if (to > 0 && to < _length && getWidth(to) == 0 && getWidth(to - 1) == 2) {
      to++;
    }

    final builder = StringBuffer();
    for (var i = from; i < to; i++) {
      final codePoint = getCodePoint(i);
      final width = getWidth(i);
      if (codePoint != 0 && i + width <= to) {
        builder.writeCharCode(codePoint);
        final combining = _combiningCharacters?[i];
        if (combining != null) {
          builder.write(combining);
        }
      }
    }

    return builder.toString();
  }

  CellAnchor createAnchor(int offset) {
    final anchor = CellAnchor(offset, owner: this);
    _anchors.add(anchor);
    return anchor;
  }

  void dispose() {
    for (final anchor in _anchors.toList()) {
      anchor.dispose();
    }
  }

  @override
  String toString() {
    return getText();
  }
}

/// A handle to a cell in a [BufferLine] that can be used to track the location
/// of the cell. Anchors are guaranteed to be stable, retaining their relative
/// position to each other after mutations to the buffer.
class CellAnchor {
  CellAnchor(int offset, {BufferLine? owner})
      : _offset = offset,
        _owner = owner;

  int _offset;

  int get x {
    return _offset;
  }

  int get y {
    assert(attached);
    return _owner!.index;
  }

  CellOffset get offset {
    assert(attached);
    return CellOffset(_offset, _owner!.index);
  }

  BufferLine? _owner;

  BufferLine? get line => _owner;

  bool get attached => _owner?.attached ?? false;

  void reparent(BufferLine owner, int offset) {
    _owner?._anchors.remove(this);
    _owner = owner;
    _owner?._anchors.add(this);
    _offset = offset;
  }

  void reposition(int offset) {
    _offset = offset;
  }

  void dispose() {
    _owner?._anchors.remove(this);
    _owner = null;
  }

  @override
  String toString() {
    if (attached) {
      return 'CellAnchor($x, $y)';
    } else {
      return 'CellAnchor($x, detached)';
    }
  }
}
