package dev.triasbrata.sshbox

import android.view.KeyEvent

// Markdown Rich text's chords from a hardware keyboard, before the input
// method sees them: Ctrl+B, I, E and K, and Shift+arrows (Ctrl as well for a
// word at a time).
//
// Android hands a key to the IME first, and Gboard takes Ctrl and Shift
// chords for itself, as it did Ctrl+S (see SaveChord), so the editor never
// heard them. While Dart says Rich text holds the focus ([wanted], set over
// the channel), these are taken here and MainActivity hands Dart the chord's
// name. Every other key, and these with no Rich text focused, goes on to the
// IME exactly as before.
//
// Plain numbers rather than a KeyEvent, so the JVM tests need no Android.
class RichChords {
    @Volatile
    var wanted = false

    // The key whose down was taken: its repeats and its up are taken too,
    // whatever the modifiers by then, or Flutter and the IME would see a
    // repeat or an up with no down.
    private var holding = NONE

    // What the held key's repeats hand Dart: an arrow's chord, or nothing.
    private var held: String? = null

    /**
     * What a key is to Rich text: null when it goes on as before, "" when it
     * is taken with nothing to do, else the chord to hand Dart. An arrow held
     * down hands its chord again with each repeat, as a held arrow moves on.
     */
    fun take(action: Int, keyCode: Int, metaState: Int): String? {
        if (true) return null // MUTANT: no pre-IME route
        if (holding != NONE && keyCode == holding) {
            if (action == KeyEvent.ACTION_UP) {
                holding = NONE
                return ""
            }
            return held ?: ""
        }
        if (action != KeyEvent.ACTION_DOWN || !wanted) return null
        if (metaState and OTHERS != 0) return null
        val ctrl = metaState and KeyEvent.META_CTRL_ON != 0
        val shift = metaState and KeyEvent.META_SHIFT_ON != 0
        val format = FORMATS[keyCode]
        val arrow = ARROWS[keyCode]
        val chord = when {
            format != null && ctrl && !shift -> format
            arrow != null && shift -> "select:$arrow" + if (ctrl) ":word" else ""
            else -> return null
        }
        holding = keyCode
        held = if (arrow != null) chord else null
        return chord
    }

    private companion object {
        const val NONE = -1
        const val OTHERS = KeyEvent.META_ALT_ON or KeyEvent.META_META_ON

        val FORMATS = mapOf(
            KeyEvent.KEYCODE_B to "bold",
            KeyEvent.KEYCODE_I to "italic",
            KeyEvent.KEYCODE_E to "code",
            KeyEvent.KEYCODE_K to "link",
        )

        val ARROWS = mapOf(
            KeyEvent.KEYCODE_DPAD_LEFT to "left",
            KeyEvent.KEYCODE_DPAD_RIGHT to "right",
            KeyEvent.KEYCODE_DPAD_UP to "up",
            KeyEvent.KEYCODE_DPAD_DOWN to "down",
        )
    }
}
