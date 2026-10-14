package dev.triasbrata.sshbox

import android.view.KeyEvent.ACTION_DOWN
import android.view.KeyEvent.ACTION_UP
import android.view.KeyEvent.KEYCODE_A
import android.view.KeyEvent.KEYCODE_CTRL_LEFT
import android.view.KeyEvent.KEYCODE_S
import android.view.KeyEvent.META_ALT_ON
import android.view.KeyEvent.META_CTRL_LEFT_ON
import android.view.KeyEvent.META_CTRL_ON
import android.view.KeyEvent.META_META_ON
import android.view.KeyEvent.META_SHIFT_ON
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SaveChordTest {
    private val ctrl = META_CTRL_ON or META_CTRL_LEFT_ON

    private fun wanted() = SaveChord().apply { wanted = true }

    @Test
    fun `Ctrl+S is taken, down and up, while an editor wants it`() {
        val chord = wanted()
        assertTrue(chord.take(ACTION_DOWN, KEYCODE_S, ctrl))
        assertTrue(chord.take(ACTION_UP, KEYCODE_S, ctrl))
    }

    @Test
    fun `nothing is taken while no editor wants it, so a terminal gets its ^S`() {
        val chord = SaveChord()
        assertFalse(chord.take(ACTION_DOWN, KEYCODE_S, ctrl))
        assertFalse(chord.take(ACTION_UP, KEYCODE_S, ctrl))
    }

    @Test
    fun `S alone, another letter and Ctrl itself go on to the IME`() {
        val chord = wanted()
        assertFalse(chord.take(ACTION_DOWN, KEYCODE_S, 0))
        assertFalse(chord.take(ACTION_UP, KEYCODE_S, 0))
        assertFalse(chord.take(ACTION_DOWN, KEYCODE_A, ctrl))
        assertFalse(chord.take(ACTION_DOWN, KEYCODE_CTRL_LEFT, ctrl))
    }

    @Test
    fun `Ctrl+S with Alt, Shift or Meta as well is not the save`() {
        val chord = wanted()
        for (other in listOf(META_ALT_ON, META_SHIFT_ON, META_META_ON)) {
            assertFalse(chord.take(ACTION_DOWN, KEYCODE_S, ctrl or other))
        }
    }

    @Test
    fun `a taken S keeps its repeats and its up, even with Ctrl let go first`() {
        val chord = wanted()
        assertTrue(chord.take(ACTION_DOWN, KEYCODE_S, ctrl))
        assertTrue(chord.take(ACTION_DOWN, KEYCODE_S, 0))
        assertTrue(chord.take(ACTION_UP, KEYCODE_S, 0))
        // And then it is over: a plain S goes to the IME again.
        assertFalse(chord.take(ACTION_DOWN, KEYCODE_S, 0))
    }

    @Test
    fun `an S taken while wanted still gives its up if the editor lets go`() {
        val chord = wanted()
        assertTrue(chord.take(ACTION_DOWN, KEYCODE_S, ctrl))
        chord.wanted = false
        assertTrue(chord.take(ACTION_UP, KEYCODE_S, ctrl))
        assertFalse(chord.take(ACTION_DOWN, KEYCODE_S, ctrl))
    }
}
