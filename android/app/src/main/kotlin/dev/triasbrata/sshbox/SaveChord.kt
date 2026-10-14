package dev.triasbrata.sshbox

import android.view.KeyEvent

// Ctrl+S for the file editor, before the input method sees it.
//
// Android hands a key to the IME first, and Gboard types Ctrl+S as an "s",
// so Flutter never hears it. While Dart says an editor page holds the focus
// ([wanted], set over the channel), Ctrl+S with no Alt, Shift or Meta is
// taken here and given to Flutter's own key handling. Every other key, and
// Ctrl+S with no editor focused, goes on to the IME exactly as before.
//
// Plain numbers rather than a KeyEvent, so the JVM tests need no Android.
class SaveChord {
    @Volatile
    var wanted = false

    // An S down was taken: its repeats and its up are taken too, whatever the
    // modifiers by then, or Flutter would think S still held and the IME
    // would see an up with no down.
    private var holding = false

    /** Whether this key goes to Flutter before the IME rather than through it. */
    fun take(action: Int, keyCode: Int, metaState: Int): Boolean {
        if (keyCode != KeyEvent.KEYCODE_S) return false
        if (holding) {
            if (action == KeyEvent.ACTION_UP) holding = false
            return true
        }
        if (action != KeyEvent.ACTION_DOWN || !wanted) return false
        if (metaState and KeyEvent.META_CTRL_ON == 0) return false
        if (metaState and OTHERS != 0) return false
        holding = true
        return true
    }

    private companion object {
        const val OTHERS = KeyEvent.META_ALT_ON or KeyEvent.META_SHIFT_ON or KeyEvent.META_META_ON
    }
}
