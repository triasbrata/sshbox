package dev.triasbrata.sshbox

import io.sentry.Attachment
import io.sentry.Breadcrumb
import io.sentry.Hint
import io.sentry.JsonSerializer
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.SpanContext
import io.sentry.protocol.App
import io.sentry.protocol.DebugImage
import io.sentry.protocol.DebugMeta
import io.sentry.protocol.Device
import io.sentry.protocol.Mechanism
import io.sentry.protocol.Message
import io.sentry.protocol.OperatingSystem
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.SentryStackTrace
import io.sentry.protocol.SentryThread
import io.sentry.protocol.User
import java.io.StringWriter
import java.util.Date
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The native crash from the v1.0.79 triage, every field it leaked filled in,
 * through [NativeCrashes.scrub] and serialised exactly as it would be sent.
 */
class NativeCrashesTest {
    private fun crash() = SentryEvent().apply {
        platform = "native"
        release = "cloud.brata.terminal@1.0.79+83"
        environment = "release"
        user = User().apply { id = "install-id-as-user" }
        serverName = "server-leak"
        message = Message().apply { formatted = "Fatal signal in /data/user/0/secret-leak" }
        setTag("installerStore", "com.android.vending")
        setTag("isSideLoaded", "false")
        setExtra("extra", "extra-leak")
        addBreadcrumb(Breadcrumb("breadcrumb-leak"))
        threads = listOf(SentryThread().apply { name = "thread-leak" })
        debugMeta = DebugMeta().apply {
            images = listOf(DebugImage().apply { codeFile = "/data/app/~~rand-leak==/libflutter.so" })
        }
        contexts.setOperatingSystem(
            OperatingSystem().apply {
                name = "Android"
                version = "16"
                build = "os-build-leak"
                kernelVersion = "Linux version 6.1.99 (builder@kernel-host-leak)"
                isRooted = false
                rawDescription = "raw-leak"
            },
        )
        contexts.setDevice(
            Device().apply {
                id = "install-id-as-device"
                name = "device-name-leak"
                family = "Pad"
                model = "25091RP04C"
                manufacturer = "Xiaomi"
                brand = "Redmi"
                archs = arrayOf("arm64-v8a")
                timezone = TimeZone.getTimeZone("Asia/Makassar")
                locale = "id_ID"
                bootTime = Date(0)
                memorySize = 12345678L
                connectionType = "wifi-leak"
            },
        )
        contexts.setApp(App().apply { deviceAppHash = "app-hash-leak" })
        contexts.setTrace(SpanContext("ui.load").apply { setData("thread.name", "trace-thread-leak") })
        exceptions = listOf(
            SentryException().apply {
                type = "SIGSEGV"
                value = "Segfault at /data/user/0/value-leak"
                mechanism = Mechanism().apply {
                    type = "signalhandler"
                    isHandled = false
                    meta = mapOf("fault_addr" to "0xmeta-leak")
                    data = mapOf("data" to "data-leak")
                }
                stacktrace = SentryStackTrace(
                    listOf(
                        SentryStackFrame().apply {
                            function = "art::JniMethodStart"
                            `package` = "/data/app/~~rand-leak==/cloud.brata.terminal-rand-leak==/lib/arm64/libflutter.so"
                            instructionAddr = "0xaddr-leak"
                            vars = mapOf("local" to "var-leak")
                        },
                    ),
                ).apply { registers = mapOf("x0" to "0xregister-leak") }
            },
        )
    }

    @Test
    fun keepsWhatDartKeepsAndNothingElse() {
        val crash = crash()
        val hint = Hint().apply {
            addAttachment(Attachment(byteArrayOf(1), "scope.txt"))
            tombstone = Attachment(byteArrayOf(1), "tombstone")
            threadDump = Attachment(byteArrayOf(1), "threads.txt")
        }

        val out = NativeCrashes.scrub(crash, hint)
        val json = StringWriter().also { JsonSerializer(SentryOptions()).serialize(out, it) }.toString()

        for (leak in listOf(
            "leak", "install-id", "/data/", "installerStore", "isSideLoaded",
            "com.android.vending", "Makassar", "id_ID", "1970", "12345678",
        )) {
            assertFalse("$leak in $json", json.contains(leak))
        }
        for (kept in listOf(
            "SIGSEGV", "signalhandler", "art::JniMethodStart", "\"libflutter.so\"",
            "\"Android\"", "\"16\"", "25091RP04C", "Xiaomi", "Redmi", "arm64-v8a",
            "cloud.brata.terminal@1.0.79+83", "\"release\"", "\"native\"",
        )) {
            assertTrue("$kept not in $json", json.contains(kept))
        }
        assertEquals(crash.eventId, out.eventId)
        assertEquals(false, out.exceptions!!.single().mechanism!!.isHandled)

        assertTrue(hint.attachments.isEmpty())
        assertNull(hint.tombstone)
        assertNull(hint.threadDump)
    }
}
