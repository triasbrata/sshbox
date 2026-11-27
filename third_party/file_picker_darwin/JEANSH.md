# file_picker_darwin 1.1.0, one line changed

Copied from pub.dev's file_picker_darwin 1.1.0 (MIT) with one change, in
`MacOSFilePickerHandler.swift`: the window a dialog is a sheet of is the
registrar's view's window, or, when the registrar has none, the key window.

Why: the app's several windows share one engine with its views turned on, and
an engine in that mode has no first view for `registrar.view` to find, so
every dialog was answered with nothing. `example/` was left out as bulk.

To move to a newer version, copy it here the same way and make the change
again.
