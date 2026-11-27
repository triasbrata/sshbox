#include "my_application.h"

#include <cerrno>
#include <cstring>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// A window after the first: its own GtkWindow with its own view on the one
// engine, which the app opens and closes through sshbox/windows. The first
// window is id 0, and never destroyed while the app runs — its view is the
// engine's implicit view, which has to be there — only hidden.
typedef struct {
  MyApplication* app;
  gint id;
  GtkWindow* window;
  FlView* view;
  // The timer that tells the app where the window is, once it has held
  // still.
  guint moved_source;
  // Where it was last, while neither maximized nor full screen.
  gint x, y, width, height;
} ExtraWindow;

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // sshbox/windows: the app opens, closes and raises windows on it, and
  // hears on it where they are, which has focus, and when one is asked to
  // close.
  FlMethodChannel* windows_channel;
  FlView* main_view;
  GList* extras;
  gint next_window_id;
  // Whether the app asked for several windows, and so is asked before one
  // closes, not told after.
  gboolean multi;
  // The first window closing for real, rather than being asked of the app.
  gboolean closing;
  // The first window hidden after it was closed while others stay open, to
  // be shown again by the next window the app opens.
  gboolean main_hidden;
  // sshbox/window: the buttons and the tab strip the app draws in place of a
  // title bar ask the window to move, minimize, maximize and close on it,
  // and hear on it when the window is maximized or restored.
  FlMethodChannel* window_channel;
  GtkWindow* window;
  // Where the window was and how big, while neither maximized nor full
  // screen: what comes back at the next start (see restore_geometry).
  gint x, y, width, height;
  guint save_source;
  // The timer that reads the geometry above once the window has held still
  // (see configure_cb).
  guint commit_source;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static gboolean ask_close(MyApplication* self, gint id);
static void notify_moved(MyApplication* self, gint id, gint x, gint y,
                         gint width, gint height, gboolean maximized);
static GtkWindow* window_of_view(MyApplication* self, gint64 view_id);

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
  // A window after the first says which it is, in a map beside what it asks.
  FlValue* args = fl_method_call_get_args(call);
  if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
    FlValue* view = fl_value_lookup_string(args, "view");
    if (view != nullptr && fl_value_get_type(view) == FL_VALUE_TYPE_INT) {
      window = window_of_view(self, fl_value_get_int(view));
      if (window == nullptr) {
        fl_method_call_respond_success(call, nullptr, nullptr);
        return;
      }
    }
  }
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

// The window manager moves and resizes a window in steps when it maximizes
// it, and the maximized state is told after the first of them: the place of
// the window seen then is a step on the way, and kept, it came back at the
// next start as the window's normal place (the one a window manager gives
// back on un-maximize), wrong. And GTK takes a configure event after this
// handler has seen it, so the position and size it gives while one is being
// handled are the event before's. So a configure event only starts a timer,
// and the place is read when it fires, once nothing has changed for a moment
// and the window is neither maximized nor full screen; a change of state
// cancels the timer (see window_state_cb).
static gboolean commit_geometry(gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->commit_source = 0;
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
  if (gdk_window == nullptr) return G_SOURCE_REMOVE;
  GdkWindowState state = gdk_window_get_state(gdk_window);
  if (!(state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                 GDK_WINDOW_STATE_ICONIFIED))) {
    gtk_window_get_position(self->window, &self->x, &self->y);
    gtk_window_get_size(self->window, &self->width, &self->height);
    schedule_save(self);
    notify_moved(self, 0, self->x, self->y, self->width, self->height, FALSE);
  }
  return G_SOURCE_REMOVE;
}

static void drop_pending_geometry(MyApplication* self) {
  if (self->commit_source != 0) g_source_remove(self->commit_source);
  self->commit_source = 0;
}

static gboolean configure_cb(GtkWidget* widget, GdkEventConfigure* event,
                             gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  GdkWindowState state = gdk_window_get_state(gtk_widget_get_window(widget));
  if (!(state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                 GDK_WINDOW_STATE_ICONIFIED))) {
    drop_pending_geometry(self);
    self->commit_source = g_timeout_add(150, commit_geometry, self);
  }
  return FALSE;
}

// A change made in the last moments is still pending: it counts.
static void flush_geometry(MyApplication* self) {
  if (self->commit_source != 0) {
    g_source_remove(self->commit_source);
    commit_geometry(self);
  }
  if (self->save_source != 0) {
    g_source_remove(self->save_source);
    save_geometry(self);
  }
}

static gboolean delete_cb(GtkWidget* widget, GdkEvent* event,
                          gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  // The app decides whether the window goes, and says so with `close`.
  if (!self->closing && ask_close(self, 0)) return TRUE;
  flush_geometry(self);
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
    // What the window manager did on the way to this state is not a place.
    drop_pending_geometry(self);
    schedule_save(self);
  }
  if ((event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) &&
      self->window_channel != nullptr) {
    g_autoptr(FlValue) maximized = fl_value_new_bool(
        (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0);
    fl_method_channel_invoke_method(self->window_channel, "maximized",
                                    maximized, nullptr, nullptr, nullptr);
    notify_moved(self, 0, self->x, self->y, self->width, self->height,
                 (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0);
  }
  return FALSE;
}

static gboolean main_focus_cb(GtkWidget* widget, GdkEventFocus* event,
                              gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->windows_channel != nullptr) {
    g_autoptr(FlValue) id = fl_value_new_int(0);
    fl_method_channel_invoke_method(self->windows_channel, "focused", id,
                                    nullptr, nullptr, nullptr);
  }
  return FALSE;
}

// ---- sshbox/windows: more than one window --------------------------------

// A window with the title bar the app draws in place of one, and the app's
// icon: the first window's, and every other's.
static GtkWindow* new_app_window(GApplication* application) {
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
  return window;
}

static void send_event(MyApplication* self, const gchar* method,
                       FlValue* args) {
  if (self->windows_channel == nullptr) return;
  fl_method_channel_invoke_method(self->windows_channel, method, args, nullptr,
                                  nullptr, nullptr);
}

// The app is asked to close window [id], which stays until it says so. False
// when the app has not asked for several windows: then it closes as it
// always did.
static gboolean ask_close(MyApplication* self, gint id) {
  if (!self->multi || self->windows_channel == nullptr) return FALSE;
  g_autoptr(FlValue) value = fl_value_new_int(id);
  send_event(self, "closeRequested", value);
  return TRUE;
}

static void notify_moved(MyApplication* self, gint id, gint x, gint y,
                         gint width, gint height, gboolean maximized) {
  if (!self->multi || self->windows_channel == nullptr) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "id", fl_value_new_int(id));
  fl_value_set_string_take(map, "x", fl_value_new_float(x));
  fl_value_set_string_take(map, "y", fl_value_new_float(y));
  fl_value_set_string_take(map, "width", fl_value_new_float(width));
  fl_value_set_string_take(map, "height", fl_value_new_float(height));
  fl_value_set_string_take(map, "maximized", fl_value_new_bool(maximized));
  send_event(self, "moved", map);
}

static GtkWindow* window_of_view(MyApplication* self, gint64 view_id) {
  if (view_id == 0) return self->window;
  for (GList* l = self->extras; l != nullptr; l = l->next) {
    ExtraWindow* extra = static_cast<ExtraWindow*>(l->data);
    if (fl_view_get_id(extra->view) == view_id) return extra->window;
  }
  return nullptr;
}

static ExtraWindow* extra_by_id(MyApplication* self, gint id) {
  for (GList* l = self->extras; l != nullptr; l = l->next) {
    ExtraWindow* extra = static_cast<ExtraWindow*>(l->data);
    if (extra->id == id) return extra;
  }
  return nullptr;
}

// A number the app sent, which Dart's int and double both reach as.
static gboolean number_of(FlValue* map, const gchar* key, gdouble* out) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr) return FALSE;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    *out = static_cast<gdouble>(fl_value_get_int(value));
    return TRUE;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    *out = fl_value_get_float(value);
    return TRUE;
  }
  return FALSE;
}

// The frame the app sent for a window, if it is one: each number within
// ±100000 and a size of at least 200 by 150.
static gboolean frame_of(FlValue* args, gint* x, gint* y, gint* width,
                         gint* height, gboolean* maximized) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  gdouble n[4];
  const gchar* keys[4] = {"x", "y", "width", "height"};
  for (int i = 0; i < 4; i++) {
    if (!number_of(args, keys[i], &n[i]) || n[i] < -100000 || n[i] > 100000) {
      return FALSE;
    }
  }
  if (n[2] < 200 || n[3] < 150) return FALSE;
  *x = static_cast<gint>(n[0]);
  *y = static_cast<gint>(n[1]);
  *width = static_cast<gint>(n[2]);
  *height = static_cast<gint>(n[3]);
  FlValue* flag = fl_value_lookup_string(args, "maximized");
  *maximized = flag != nullptr &&
               fl_value_get_type(flag) == FL_VALUE_TYPE_BOOL &&
               fl_value_get_bool(flag);
  return TRUE;
}

typedef struct {
  MyApplication* app;
  gint id;
  FlView* view;
  gint tries;
} Announce;

// Tells the app a window's view is up, once it has an id: on the next turn
// of the main loop, since the engine says it has added the view after the
// window is made.
static gboolean announce_opened(gpointer user_data) {
  Announce* announce = static_cast<Announce*>(user_data);
  gint64 view_id = fl_view_get_id(announce->view);
  if (view_id < 0 && announce->tries++ < 50) return G_SOURCE_CONTINUE;
  if (view_id >= 0) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "id", fl_value_new_int(announce->id));
    fl_value_set_string_take(map, "viewId", fl_value_new_int(view_id));
    send_event(announce->app, "opened", map);
  }
  g_object_unref(announce->view);
  g_free(announce);
  return G_SOURCE_REMOVE;
}

static void announce_later(MyApplication* self, gint id, FlView* view) {
  Announce* announce = g_new0(Announce, 1);
  announce->app = self;
  announce->id = id;
  announce->view = FL_VIEW(g_object_ref(view));
  g_timeout_add(20, announce_opened, announce);
}

static gboolean extra_moved(gpointer user_data) {
  ExtraWindow* extra = static_cast<ExtraWindow*>(user_data);
  extra->moved_source = 0;
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(extra->window));
  if (gdk_window == nullptr) return G_SOURCE_REMOVE;
  GdkWindowState state = gdk_window_get_state(gdk_window);
  if (state & GDK_WINDOW_STATE_ICONIFIED) return G_SOURCE_REMOVE;
  gboolean maximized =
      (state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) != 0;
  if (!maximized) {
    gtk_window_get_position(extra->window, &extra->x, &extra->y);
    gtk_window_get_size(extra->window, &extra->width, &extra->height);
  }
  notify_moved(extra->app, extra->id, extra->x, extra->y, extra->width,
               extra->height, maximized);
  return G_SOURCE_REMOVE;
}

static void extra_schedule_moved(ExtraWindow* extra) {
  if (extra->moved_source != 0) g_source_remove(extra->moved_source);
  extra->moved_source = g_timeout_add(300, extra_moved, extra);
}

static gboolean extra_configure_cb(GtkWidget* widget, GdkEventConfigure* event,
                                   gpointer user_data) {
  extra_schedule_moved(static_cast<ExtraWindow*>(user_data));
  return FALSE;
}

static gboolean extra_state_cb(GtkWidget* widget, GdkEventWindowState* event,
                               gpointer user_data) {
  ExtraWindow* extra = static_cast<ExtraWindow*>(user_data);
  if (event->changed_mask &
      (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN)) {
    extra_schedule_moved(extra);
  }
  if ((event->changed_mask & GDK_WINDOW_STATE_MAXIMIZED) &&
      extra->app->window_channel != nullptr) {
    // A window after the first says which it is.
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "view",
                             fl_value_new_int(fl_view_get_id(extra->view)));
    fl_value_set_string_take(
        map, "value",
        fl_value_new_bool((event->new_window_state &
                           GDK_WINDOW_STATE_MAXIMIZED) != 0));
    fl_method_channel_invoke_method(extra->app->window_channel, "maximized",
                                    map, nullptr, nullptr, nullptr);
  }
  return FALSE;
}

static gboolean extra_focus_cb(GtkWidget* widget, GdkEventFocus* event,
                               gpointer user_data) {
  ExtraWindow* extra = static_cast<ExtraWindow*>(user_data);
  g_autoptr(FlValue) id = fl_value_new_int(extra->id);
  send_event(extra->app, "focused", id);
  return FALSE;
}

static gboolean extra_delete_cb(GtkWidget* widget, GdkEvent* event,
                                gpointer user_data) {
  ExtraWindow* extra = static_cast<ExtraWindow*>(user_data);
  // Stays until the app says `close`.
  return ask_close(extra->app, extra->id);
}

static void extra_destroy_cb(GtkWidget* widget, gpointer user_data) {
  ExtraWindow* extra = static_cast<ExtraWindow*>(user_data);
  MyApplication* self = extra->app;
  if (extra->moved_source != 0) g_source_remove(extra->moved_source);
  self->extras = g_list_remove(self->extras, extra);
  if (self->windows_channel != nullptr) {
    g_autoptr(FlValue) id = fl_value_new_int(extra->id);
    send_event(self, "closed", id);
  }
  g_free(extra);
}

static void extra_first_frame_cb(ExtraWindow* extra, FlView* view) {
  gtk_widget_show(GTK_WIDGET(extra->window));
}

// A window after the first, on the engine the first window's view runs.
static ExtraWindow* create_extra(MyApplication* self, FlValue* frame) {
  FlEngine* engine = fl_view_get_engine(self->main_view);
  GtkWindow* window = new_app_window(G_APPLICATION(self));
  ExtraWindow* extra = g_new0(ExtraWindow, 1);
  extra->app = self;
  extra->id = self->next_window_id++;
  extra->window = window;
  extra->width = 1280;
  extra->height = 720;
  gtk_window_set_default_size(window, extra->width, extra->height);

  gint x, y, width, height;
  gboolean maximized;
  if (frame_of(frame, &x, &y, &width, &height, &maximized)) {
    extra->x = x;
    extra->y = y;
    extra->width = width;
    extra->height = height;
    gtk_window_set_default_size(window, width, height);
#ifdef GDK_WINDOWING_X11
    if (GDK_IS_X11_DISPLAY(gtk_widget_get_display(GTK_WIDGET(window)))) {
      gtk_window_move(window, x, y);
    }
#endif
    if (maximized) gtk_window_maximize(window);
  }

  extra->view = fl_view_new_for_engine(engine);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(extra->view, &background_color);
  gtk_widget_show(GTK_WIDGET(extra->view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(extra->view));

  g_signal_connect(window, "configure-event", G_CALLBACK(extra_configure_cb),
                   extra);
  g_signal_connect(window, "window-state-event", G_CALLBACK(extra_state_cb),
                   extra);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(extra_focus_cb),
                   extra);
  g_signal_connect(window, "delete-event", G_CALLBACK(extra_delete_cb), extra);
  g_signal_connect(window, "destroy", G_CALLBACK(extra_destroy_cb), extra);
  g_signal_connect_swapped(extra->view, "first-frame",
                           G_CALLBACK(extra_first_frame_cb), extra);
  gtk_widget_realize(GTK_WIDGET(extra->view));
  self->extras = g_list_append(self->extras, extra);
  return extra;
}

static void windows_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                            gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "supported") == 0) {
    self->multi = TRUE;
    g_autoptr(FlValue) yes = fl_value_new_bool(TRUE);
    fl_method_call_respond_success(call, yes, nullptr);
  } else if (strcmp(method, "open") == 0) {
    gint id;
    if (self->main_hidden) {
      // The first window comes back before a new one is made.
      self->main_hidden = FALSE;
      id = 0;
      gint x, y, width, height;
      gboolean maximized;
      if (frame_of(args, &x, &y, &width, &height, &maximized)) {
        gtk_window_resize(self->window, width, height);
#ifdef GDK_WINDOWING_X11
        if (GDK_IS_X11_DISPLAY(
                gtk_widget_get_display(GTK_WIDGET(self->window)))) {
          gtk_window_move(self->window, x, y);
        }
#endif
        if (maximized) gtk_window_maximize(self->window);
      }
      gtk_widget_show(GTK_WIDGET(self->window));
      gtk_window_present(self->window);
      announce_later(self, 0, self->main_view);
    } else {
      ExtraWindow* extra = create_extra(self, args);
      id = extra->id;
      announce_later(self, id, extra->view);
    }
    g_autoptr(FlValue) answer = fl_value_new_int(id);
    fl_method_call_respond_success(call, answer, nullptr);
  } else if (strcmp(method, "close") == 0 && args != nullptr &&
             fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
    gint id = static_cast<gint>(fl_value_get_int(args));
    ExtraWindow* extra = id == 0 ? nullptr : extra_by_id(self, id);
    if (id == 0) {
      if (self->extras == nullptr) {
        // The last window: the app quits, and keeps where it was.
        self->closing = TRUE;
        gtk_window_close(self->window);
      } else {
        flush_geometry(self);
        self->main_hidden = TRUE;
        gtk_widget_hide(GTK_WIDGET(self->window));
      }
    } else if (extra != nullptr) {
      if (self->main_hidden && g_list_length(self->extras) == 1) {
        // The last window left is this one: the app quits.
        g_application_quit(G_APPLICATION(self));
      } else {
        gtk_widget_destroy(GTK_WIDGET(extra->window));
      }
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (strcmp(method, "activate") == 0 && args != nullptr &&
             fl_value_get_type(args) == FL_VALUE_TYPE_INT) {
    gint id = static_cast<gint>(fl_value_get_int(args));
    ExtraWindow* extra = id == 0 ? nullptr : extra_by_id(self, id);
    GtkWindow* window = id == 0 ? self->window : nullptr;
    if (extra != nullptr) window = extra->window;
    if (window != nullptr) gtk_window_present(window);
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
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
    GtkWindow* active =
        gtk_application_get_active_window(GTK_APPLICATION(application));
    gtk_window_present(active != nullptr ? active
                                         : GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window = new_app_window(application);
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
  self->main_view = view;
  self->next_window_id = 1;
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
  self->windows_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "sshbox/windows", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->windows_channel,
                                            windows_call_cb, self, nullptr);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(main_focus_cb), self);
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
  g_clear_object(&self->windows_channel);
  g_list_free(self->extras);
  self->extras = nullptr;
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
