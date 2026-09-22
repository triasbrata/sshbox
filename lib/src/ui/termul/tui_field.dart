// Ported from TUI-Termul/termul at df2cacf9d140f8c74220f2879bc7ee53b2b6a758,
// lib/components/tui_field.dart. MIT License, Copyright (c) 2026 TUI-Termul: see
// LICENSE beside this file.
//
// Changed for Jeansh:
// Takes what Jeansh's forms need: a validator with its error drawn under
// the box in termul's error ink, helper text, several lines, a suffix
// (a secret's eye), a focus node, the keyboard's learning switches, an
// error found outside a form, and a switch to turn it off.
// The caption drawn in capitals is left out of accessibility; the field
// is named by its label as written.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'termul_theme.dart';

/// Form field — paper surface, hairline border, mono label.
class TuiField extends StatelessWidget {
  const TuiField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.autofocus = false,
    this.onSubmitted,
    this.validator,
    this.helper,
    this.maxLines = 1,
    this.minLines,
    this.suffix,
    this.focusNode,
    this.onChanged,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.enableIMEPersonalizedLearning = true,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  /// Jeansh: a [Form]'s check, its message drawn under the box.
  final FormFieldValidator<String>? validator;

  /// Jeansh: a line or two under the box saying what the field is for.
  final String? helper;
  final int? maxLines;
  final int? minLines;

  /// Jeansh: drawn at the box's right, as a secret's show/hide eye.
  final Widget? suffix;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool enableIMEPersonalizedLearning;

  /// Jeansh: an error found outside a [Form], drawn as [validator]'s is.
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final p = TermulThemeData.of(context).palette;
    final hairline = OutlineInputBorder(
      borderRadius: BorderRadius.zero,
      borderSide: BorderSide(color: p.border),
    );
    return Semantics(
      textField: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExcludeSemantics(
            child: Text(
              label.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall!.copyWith(
                color: p.accent,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            focusNode: focusNode,
            obscureText: obscure,
            autofocus: autofocus,
            keyboardType: keyboardType,
            textInputAction: textInputAction,
            inputFormatters: inputFormatters,
            maxLines: obscure ? 1 : maxLines,
            minLines: minLines,
            autocorrect: autocorrect,
            enableSuggestions: enableSuggestions,
            enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
            validator: validator,
            onChanged: onChanged,
            enabled: enabled,
            cursorColor: p.accent,
            style: TextStyle(
              fontFamily: TermulFonts.mono,
              fontSize: 14,
              color: p.text,
              height: 1.4,
            ),
            // termul's box: a panel fill with a hairline edge, 12 across.
            decoration: InputDecoration(
              filled: true,
              fillColor: p.panel,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 14,
              ),
              border: hairline,
              enabledBorder: hairline,
              focusedBorder: hairline,
              disabledBorder: hairline,
              errorBorder: hairline.copyWith(
                borderSide: BorderSide(color: p.deep),
              ),
              focusedErrorBorder: hairline.copyWith(
                borderSide: BorderSide(color: p.deep),
              ),
              hintText: hint,
              hintStyle: TextStyle(
                fontFamily: TermulFonts.mono,
                fontSize: 14,
                color: p.dim,
              ),
              helperText: helper,
              helperMaxLines: 6,
              helperStyle: Theme.of(context).textTheme.bodySmall!
                  .copyWith(color: p.muted, height: 1.45),
              errorStyle: Theme.of(context).textTheme.bodySmall!
                  .copyWith(color: p.deep),
              errorMaxLines: 3,
              errorText: errorText,
              suffixIcon: suffix,
            ),
            onFieldSubmitted: onSubmitted,
          ),
        ],
      ),
    );
  }
}
