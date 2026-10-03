import 'package:flutter/material.dart';

import 'text_size.dart';
import 'tui.dart';

/// Home's quick way to the UI text size, for a touch screen with no keys and
/// no wheel: smaller, bigger and back to 100%, without going into Settings.
/// It moves the one setting the slider there moves, in the same steps.
Future<void> showTextSizeControl(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => TuiDialog(
    title: 'UI text size',
    maxWidth: 320,
    actions: [
      TuiButton(
        label: 'Reset',
        variant: TuiButtonVariant.ghost,
        onPressed: () => zoomUiText(context, 0),
      ),
      TuiButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
    ],
    child: ValueListenableBuilder(
      valueListenable: uiTextSize,
      builder: (context, scale, _) {
        final percent = (scale * 100).round();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TuiButton(
              label: '−',
              variant: TuiButtonVariant.ghost,
              onPressed: scale > UiTextSize.min + 0.001
                  ? () => zoomUiText(context, -1)
                  : null,
            ),
            Text('$percent%', semanticsLabel: 'UI text size $percent percent'),
            TuiButton(
              label: '+',
              variant: TuiButtonVariant.ghost,
              onPressed: scale < UiTextSize.max - 0.001
                  ? () => zoomUiText(context, 1)
                  : null,
            ),
          ],
        );
      },
    ),
  ),
);
