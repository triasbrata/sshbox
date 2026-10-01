#include "my_application.h"

#include <cerrno>
#include <cstring>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // sshbox/window: the buttons and the tab strip the app draws in place of a
  // title bar ask the window to move, minimize, maximize and close on it,
  // and hear on it when the window is maximized or restored.
  FlMethodChannel* window_channel;
  GtkWindow* window;
  // Where the window was and how big, while neither maximized nor full
  // screen: what comes back at the next start (see restore_geometry).
  gint x, y, width, height;
  guint save_source;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The last primary-button press, and the widget it went to: a move needs
// the press it starts from, and the widget is told it was let go.
static GdkEvent* last_press = nullptr;
static GtkWidget* last_press_widget = nullptr;

// Sees every button press before any handler, Flutter's view's included,
// which would stop it at itself.
static gboolean remember_press(GSignalInvocationHint* hint, guint count,
                               const GValue* values, gpointer data) {
  GdkEvent* event = static_cast<GdkEvent*>(g_value_get_boxed(&values[1]));
  if (event->type != GDK_BUTTON_PRESS || event->button.button != 1) {
    return TRUE;
  }
  // The same press passed up to the widgets around the first: the first is
  // the one that took it.
  if (last_press != nullptr && last_press->button.time == event->button.time) {
    return TRUE;
  }
  g_clear_pointer(&last_press, gdk_event_free);
  g_clear_object(&last_press_widget);
  last_press = gdk_event_copy(event);
  last_press_widget = GTK_WIDGET(g_object_ref(g_value_get_object(&values[0])));
  return TRUE;
}

// Moves the window from the press the strip heard. The window manager then
// has the pointer, and Flutter would never see the button come up, holding
// the press for ever: it is told, as the Mac's window tells it.
static void begin_move(GtkWindow* window) {
  if (last_press == nullptr) return;
  // A click already let go leaves nothing to move, and the window manager
  // would take the next press as the end of a move nobody made.
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  GdkDevice* pointer = gdk_seat_get_pointer(
      gdk_display_get_default_seat(gdk_window_get_display(gdk_window)));
  GdkModifierType buttons;
  gdk_window_get_device_position(gdk_window, pointer, nullptr, nullptr,
                                 &buttons);
  if (!(buttons & GDK_BUTTON1_MASK)) return;
  GdkEventButton* press = &last_press->button;
  gtk_window_begin_move_drag(window, press->button,
                             static_cast<gint>(press->x_root),
                             static_cast<gint>(press->y_root), press->time);
  GdkEvent* release = gdk_event_copy(last_press);
  release->type = GDK_BUTTON_RELEASE;
  release->button.state |= GDK_BUTTON1_MASK;
  gboolean handled = FALSE;
  g_signal_emit_by_name(last_press_widget, "button-release-event", release,
                        &handled);
  gdk_event_free(release);
  g_clear_pointer(&last_press, gdk_event_free);
  g_clear_object(&last_press_widget);
}

static void window_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GtkWindow* window = self->window;
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "drag") == 0) {
    begin_move(window);
  } else if (strcmp(method, "minimize") == 0) {
    gtk_window_iconify(window);
  } else if (strcmp(method, "maximize") == 0) {
    if (gtk_window_is_maximized(window)) {
      gtk_window_unmaximize(window);
    } else {
      gtk_window_maximize(window);
    }
  } else if (strcmp(method, "close") == 0) {
    gtk_window_close(window);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

// The window's place, size and state, in the app's own data folder — the
// one path_provider names for Dart — as one line: x y width height
// maximized fullscreen. Minimized is never kept.
static gchar* geometry_path() {
  return g_build_filename(g_get_user_data_dir(), APPLICATION_ID, "window.txt",
                          nullptr);
}

static gboolean save_geometry(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->save_source = 0;
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
  if (gdk_window == nullptr || self->width <= 0) return G_SOURCE_REMOVE;
  GdkWindowState state = gdk_window_get_state(gdk_window);
  g_autofree gchar* path = geometry_path();
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_mkdir_with_parents(dir, 0700);
  g_autofree gchar* line = g_strdup_printf(
      "%d %d %d %d %d %d\n", self->x, self->y, self->width, self->height,
      (state & GDK_WINDOW_STATE_MAXIMIZED) != 0,
      (state & GDK_WINDOW_STATE_FULLSCREEN) != 0);
  g_file_set_contents(path, line, -1, nullptr);
  return G_SOURCE_REMOVE;
}

// Kept as it changes rather than at close: an update restarts the app with
// exit(), which closes nothing. Half a second after the last change, so a
// drag writes once.
static void schedule_save(MyApplication* self) {
  if (self->save_source != 0) g_source_remove(self->save_source);
  self->save_source = g_timeout_add(500, save_geometry, self);
}

static gboolean configure_cb(GtkWidget* widget, GdkEventConfigure* event,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GdkWindowState state = gdk_window_get_state(gtk_widget_get_window(widget));
  if (!(state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                 GDK_WINDOW_STATE_ICONIFIED))) {
    gtk_window_get_position(self->window, &self->x, &self->y);
    gtk_window_get_size(self->window, &self->width, &self->height);
  }
  schedule_save(self);
  return FALSE;
}

static gboolean delete_cb(GtkWidget* widget, GdkEvent* event,
                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->save_source != 0) {
    g_source_remove(self->save_source);
    save_geometry(self);
  }
  return FALSE;
}

// The numbers in window.txt, each within ±100000 — anything else, a file
// cut short or written by hand included, and nothing is restored.
static gboolean read_numbers(const gchar* text, gint* out, int count) {
  const gchar* at = text;
  for (int i = 0; i < count; i++) {
    gchar* end = nullptr;
    errno = 0;
    gint64 value = g_ascii_strtoll(at, &end, 10);
    if (end == at || errno != 0 || value < -100000 || value > 100000) {
      return FALSE;
    }
    out[i] = static_cast<gint>(value);
    at = end;
  }
  return TRUE;
}

// The window as it was last time, set before it is first shown so it never
// jumps. Under Wayland a client cannot place its own window, so there the
// size and the state come back and the compositor picks where.
static void restore_geometry(MyApplication* self) {
  g_autofree gchar* path = geometry_path();
  g_autofree gchar* text = nullptr;
  if (!g_file_get_contents(path, &text, nullptr, nullptr)) return;
  gint n[6];
  if (!read_numbers(text, n, 6) || n[2] < 200 || n[3] < 150) return;
  gint x = n[0], y = n[1], width = n[2], height = n[3];
  gboolean maximized = n[4] != 0, fullscreen = n[5] != 0;

  // The monitor its top strip, the part that moves it, is on; when that is
  // on none — a laptop undocked, a screen unplugged — the main one, centred.
  // Either way it comes back no bigger than that monitor and wholly on it,
  // so a window sized for a bigger screen keeps its buttons in reach.
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(self->window));
  GdkRectangle strip = {x, y, width, MIN(height, 40)};
  GdkMonitor* monitor = nullptr;
  for (int i = 0; i < gdk_display_get_n_monitors(display) && !monitor; i++) {
    GdkRectangle area;
    gdk_monitor_get_workarea(gdk_display_get_monitor(display, i), &area);
    if (gdk_rectangle_intersect(&strip, &area, nullptr)) {
      monitor = gdk_display_get_monitor(display, i);
    }
  }
  gboolean seen = monitor != nullptr;
  if (!seen) monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr) monitor = gdk_display_get_monitor(display, 0);
  if (monitor != nullptr) {
    GdkRectangle area;
    gdk_monitor_get_workarea(monitor, &area);
    width = MIN(width, area.width);
    height = MIN(height, area.height);
    if (seen) {
      x = CLAMP(x, area.x, area.x + area.width - width);
      y = CLAMP(y, area.y, area.y + area.height - height);
    } else {
      x = area.x + (area.width - width) / 2;
      y = area.y + (area.height - height) / 2;
    }
  }
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display)) gtk_window_move(self->window, x, y);
#endif
  self->x = x;
  self->y = y;
  self->width = width;
  self->height = height;
  gtk_window_set_default_size(self->window, width, height);
  if (maximized) gtk_window_maximize(self->window);
  if (fullscreen) gtk_window_fullscreen(self->window);
}

static gboolean window_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (event->changed_mask &
      (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) {
    schedule_save(self);
  }
  if ((event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) &&
      self->window_channel != nullptr) {
    g_autoptr(FlValue) maximized = fl_value_new_bool(
        (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0);
    fl_method_channel_invoke_method(self->window_channel, "maximized",
                                    maximized, nullptr, nullptr, nullptr);
  }
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Jeansh started again while it runs: the window already up comes forward
  // instead of a second copy starting, as on Android and macOS — two copies
  // would each save their own tabs over the other's.
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // The icon installed beside the binary (see CMakeLists.txt), for the title
  // bar and the window switcher.
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe != nullptr) {
    g_autofree gchar* dir = g_path_get_dirname(exe);
    g_autofree gchar* icon =
        g_build_filename(dir, "data", "app_icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

  // No title bar: the tab strip is the title bar, and the app draws the
  // window's buttons at its right (title_bar.dart). An empty titlebar
  // widget rather than an undecorated window, so GTK still draws its own
  // client-side frame — the shadow where there is a compositor, and the
  // resize edges on any window manager — and asks the window manager to
  // draw nothing.
  //
  // Not on an X display with no window manager at all, as under a bare
  // Xvfb: there nothing decorates the window anyway, and GTK's own frame
  // never lays out its content without one, leaving the view a pixel wide.
  gtk_window_set_title(window, "Jeansh");
  gboolean frame = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  frame = !GDK_IS_X11_SCREEN(screen) ||
          g_strcmp0(gdk_x11_screen_get_window_manager_name(screen),
                    "unknown") != 0;
#endif
  if (frame) {
    GtkWidget* titlebar = gtk_event_box_new();
    gtk_widget_set_size_request(titlebar, -1, 0);
    gtk_widget_show(titlebar);
    gtk_window_set_titlebar(window, titlebar);
  }
  self->window = window;
  g_signal_connect(window, "window-state-event",
                   G_CALLBACK(window_state_cb), self);

  gtk_window_set_default_size(window, 1280, 720);
  restore_geometry(self);
  g_signal_connect(window, "configure-event", G_CALLBACK(configure_cb), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_cb), self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "sshbox/window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->window_channel,
                                            window_call_cb, self, nullptr);
  g_signal_add_emission_hook(
      g_signal_lookup("button-press-event", GTK_TYPE_WIDGET), 0,
      remember_press, nullptr, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  if (self->save_source != 0) {
    g_source_remove(self->save_source);
    self->save_source = 0;
  }
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     // No flags, which makes the application
                                     // unique by its id: see activate. Not
                                     // G_APPLICATION_DEFAULT_FLAGS, which is
                                     // newer than Ubuntu 22.04's GLib.
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}
