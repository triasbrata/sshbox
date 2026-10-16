package dev.triasbrata.sshbox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class NotificationIconTest {
    /**
     * `Resources.getIdentifier` returns `Integer.parseInt(name)` when the name
     * is a number, before any lookup by name (JEANSH-8): the name handed to
     * the plugin has to be exactly the drawable's id in decimal, nothing else.
     */
    @Test
    fun theIconIsNamedByItsIdInDecimal() {
        val name = NotificationIcon.name()
        assertEquals(R.drawable.ic_stat_jeansh, Integer.parseInt(name))
        assertNotEquals(0, Integer.parseInt(name))
    }
}
