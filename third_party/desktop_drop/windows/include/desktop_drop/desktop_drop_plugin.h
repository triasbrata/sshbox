#ifndef FLUTTER_PLUGIN_DESKTOP_DROP_PLUGIN_H_
#define FLUTTER_PLUGIN_DESKTOP_DROP_PLUGIN_H_

#include <flutter_plugin_registrar.h>
#include <windows.h>
#include <stdint.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void DesktopDropPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

// Makes the view of a window the app opened after the first a place files
// can be dropped, its events naming [view_id]; and takes it away again before
// the window goes.
FLUTTER_PLUGIN_EXPORT void DesktopDropAttachWindow(HWND view, int64_t view_id);
FLUTTER_PLUGIN_EXPORT void DesktopDropDetachWindow(HWND view);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_DESKTOP_DROP_PLUGIN_H_
