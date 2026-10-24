package dev.triasbrata.sshbox

import android.view.KeyEvent.ACTION_DOWN
import android.view.KeyEvent.ACTION_UP
import android.view.KeyEvent.KEYCODE_A
import android.view.KeyEvent.KEYCODE_B
import android.view.KeyEvent.KEYCODE_CTRL_LEFT
import android.view.KeyEvent.KEYCODE_DPAD_DOWN
import android.view.KeyEvent.KEYCODE_DPAD_LEFT
import android.view.KeyEvent.KEYCODE_DPAD_RIGHT
import android.view.KeyEvent.KEYCODE_DPAD_UP
import android.view.KeyEvent.KEYCODE_E
import android.view.KeyEvent.KEYCODE_I
import android.view.KeyEvent.KEYCODE_K
import android.view.KeyEvent.KEYCODE_SHIFT_LEFT
import android.view.KeyEvent.META_ALT_ON
import android.view.KeyEvent.META_CTRL_LEFT_ON
import android.view.KeyEvent.META_CTRL_ON
import android.view.KeyEvent.META_META_ON
import android.view.KeyEvent.META_SHIFT_LEFT_ON
import android.view.KeyEvent.META_SHIFT_ON
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RichChordsTest {
    private val ctrl = META_CTRL_ON or META_CTRL_LEFT_ON
    private val shift = META_SHIFT_ON or META_SHIFT_LEFT_ON

    private fun wanted() = RichChords().apply { wanted = true }

    @Test
    fun `Ctrl+B, I, E and K are taken as their formats while Rich text wants them`() {
        val chords = wanted()
        for ((key, name) in listOf(
            KEYCODE_B to "bold",
            KEYCODE_I to "italic",
            KEYCODE_E to "code",
            KEYCODE_K to "link",
        )) {
            assertEquals(name, chords.take(ACTION_DOWN, key, ctrl))
            // Its up is taken with nothing to do.
            assertEquals("", chords.take(ACTION_UP, key, ctrl))
        }
    }

    @Test
    fun `Shift+arrows select, and with Ctrl a word at a time`() {
        val chords = wanted()
        for ((key, name) in listOf(
            KEYCODE_DPAD_LEFT to "left",
            KEYCODE_DPAD_RIGHT to "right",
            KEYCODE_DPAD_UP to "up",
            KEYCODE_DPAD_DOWN to "down",
        )) {
            assertEquals("select:$name", chords.take(ACTION_DOWN, key, shift))
            assertEquals("", chords.take(ACTION_UP, key, shift))
            assertEquals("select:$name:word", chords.take(ACTION_DOWN, key, shift or ctrl))
            assertEquals("", chords.take(ACTION_UP, key, shift or ctrl))
        }
    }

    @Test
    fun `a held arrow selects again with each repeat, and a held B does not bold again`() {
        val chords = wanted()
        assertEquals("select:right", chords.take(ACTION_DOWN, KEYCODE_DPAD_RIGHT, shift))
        assertEquals("select:right", chords.take(ACTION_DOWN, KEYCODE_DPAD_RIGHT, shift))
        // Shift let go first: still the held arrow's, up and all.
        assertEquals("select:right", chords.take(ACTION_DOWN, KEYCODE_DPAD_RIGHT, 0))
        assertEquals("", chords.take(ACTION_UP, KEYCODE_DPAD_RIGHT, 0))
        // Then over: a plain arrow moves the caret through the IME again.
        assertNull(chords.take(ACTION_DOWN, KEYCODE_DPAD_RIGHT, 0))

        assertEquals("bold", chords.take(ACTION_DOWN, KEYCODE_B, ctrl))
        assertEquals("", chords.take(ACTION_DOWN, KEYCODE_B, ctrl))
        assertEquals("", chords.take(ACTION_UP, KEYCODE_B, 0))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_B, 0))
    }

    @Test
    fun `nothing is taken while Rich text does not want it, so a terminal gets its keys`() {
        val chords = RichChords()
        assertNull(chords.take(ACTION_DOWN, KEYCODE_B, ctrl))
        assertNull(chords.take(ACTION_UP, KEYCODE_B, ctrl))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_DPAD_LEFT, shift))
    }

    @Test
    fun `plain letters, plain arrows, Ctrl+Shift+B, other letters and the modifiers go on`() {
        val chords = wanted()
        assertNull(chords.take(ACTION_DOWN, KEYCODE_B, 0))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_B, shift))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_B, ctrl or shift))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_A, ctrl))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_DPAD_LEFT, 0))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_DPAD_LEFT, ctrl))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_CTRL_LEFT, ctrl))
        assertNull(chords.take(ACTION_DOWN, KEYCODE_SHIFT_LEFT, shift))
    }

    @Test
    fun `Alt or Meta as well is not the chord`() {
        val chords = wanted()
        for (other in listOf(META_ALT_ON, META_META_ON)) {
            assertNull(chords.take(ACTION_DOWN, KEYCODE_B, ctrl or other))
            assertNull(chords.take(ACTION_DOWN, KEYCODE_DPAD_LEFT, shift or other))
        }
    }

    @Test
    fun `an up with no taken down goes on`() {
        val chords = wanted()
        assertNull(chords.take(ACTION_UP, KEYCODE_B, ctrl))
    }
}
