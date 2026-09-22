package dev.triasbrata.sshbox

import android.content.Context
import io.sentry.Hint
import io.sentry.Sentry
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.android.core.SentryAndroid
import io.sentry.protocol.DebugImage
import io.sentry.protocol.DebugMeta
import io.sentry.protocol.Device
import io.sentry.protocol.Mechanism
import io.sentry.protocol.OperatingSystem
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.SentryStackTrace

/**
 * sentry-android, started here rather than by sentry_flutter, for the one
 * thing sentry_flutter will not let the app set: a beforeSend of its own.
 *
 * A native crash — a SIGSEGV caught by the NDK handler, an ANR, an uncaught
 * Java exception — is written and sent by sentry-android alone, and never
 * passes through Dart's `scrubEvent`. sentry_flutter's own init sets
 * `beforeSend` to a callback of its own that only adds tags, so such an event
 * went out with the phone's kernel build string, its Sentry installation id as
 * both user and device id, its timezone, locale, battery and storage, whether
 * it is rooted and which store installed it. Dart turns sentry_flutter's init
 * off (`autoInitializeNativeSdk`) and calls [start] instead, with the DSN it
 * was built with, so the DSN is still never written anywhere but the build.
 *
 * Dart's own events are untouched by this: sentry_flutter hands them to
 * sentry-android as finished envelopes, which it sends as they are, already
 * scrubbed on the Dart side.
 */
object NativeCrashes {
    fun start(context: Context, dsn: String, environment: String) =
        SentryAndroid.init(context) { o ->
            o.dsn = dsn
            o.environment = environment
            // What sentry_flutter set from crash_reporting.dart's options, where
            // that differs from sentry-android's own default. Everything else —
            // the NDK handler on, tombstones off, no PII, no screenshot, no
            // tracing — is already the default on both sides.
            o.isEnableAutoSessionTracking = false
            o.enableAllAutoBreadcrumbs(false)
            o.maxBreadcrumbs = 0
            o.beforeBreadcrumb = SentryOptions.BeforeBreadcrumbCallback { _, _ -> null }
            // Dart's events go out through this SDK's transport, at Dart's
            // timeouts as before.
            o.connectionTimeoutMillis = 5000
            o.readTimeoutMillis = 5000
            o.beforeSend = SentryOptions.BeforeSendCallback { event, hint -> scrub(event, hint) }
        }

    /** For the switch being turned off while the app runs. */
    fun stop() = Sentry.close()

    /**
     * The native half of `scrubEvent` in lib/src/telemetry/crash_reporting.dart:
     * the event rebuilt from what is worth keeping, never edited, so a field a
     * later sentry-android starts filling in is dropped without anyone having
     * to notice it.
     *
     * Gone by construction: the user and the device's id (both the install's
     * Sentry id), the device's name, timezone, locale, boot time, battery,
     * memory, storage and connection; the OS's build, kernel version, raw
     * description and rooted flag; the app context and its install hash; tags,
     * which carry the installer store and whether it was side-loaded; extras,
     * breadcrumbs, the trace context and its thread name, threads, the
     * message, the transaction and the server name. What is kept is what Dart
     * keeps, less what Dart can scrub and Kotlin cannot: an exception's value —
     * its message, which for a Java exception can be a path or a URI — goes,
     * and so do every frame's registers and variables.
     *
     * What symbolication needs is kept, reduced: each frame's instruction
     * address, and each debug image by its format, ids, load address and size,
     * its file cut to a bare name. A load address is where this one process
     * happened to put the library, chosen afresh each run, and an image's ids
     * name the build it came from, the same for everyone running it; neither
     * says whose device it was. The rest of an image and of debug meta goes.
     */
    fun scrub(event: SentryEvent, hint: Hint): SentryEvent {
        // Screenshots, view hierarchies, ANR thread dumps, raw tombstones and
        // whatever a scope attached: all read from the hint after this returns.
        hint.clearAttachments()
        hint.screenshot = null
        hint.viewHierarchy = null
        hint.threadDump = null
        hint.tombstone = null

        return SentryEvent(event.timestamp).apply {
            eventId = event.eventId
            level = event.level
            platform = event.platform
            release = event.release
            dist = event.dist
            environment = event.environment
            sdk = event.sdk
            fingerprints = event.fingerprints
            exceptions = event.exceptions?.map(::exception)
            debugMeta = event.debugMeta?.images?.let { images ->
                DebugMeta().apply { this.images = images.map(::image) }
            }
            event.contexts.operatingSystem?.let { os ->
                contexts.setOperatingSystem(
                    OperatingSystem().apply {
                        name = os.name
                        version = os.version
                    },
                )
            }
            event.contexts.device?.let { d ->
                contexts.setDevice(
                    Device().apply {
                        family = d.family
                        model = d.model
                        manufacturer = d.manufacturer
                        brand = d.brand
                        archs = d.archs
                        isSimulator = d.isSimulator
                    },
                )
            }
        }
    }

    private fun exception(e: SentryException) = SentryException().apply {
        type = e.type
        module = e.module
        threadId = e.threadId
        // A mechanism's data and meta are free maps; a tombstone's holds the
        // signal's fault address.
        mechanism = e.mechanism?.let { m ->
            Mechanism().apply {
                type = m.type
                isHandled = m.isHandled
                synthetic = m.synthetic
            }
        }
        stacktrace = e.stacktrace?.let { s -> SentryStackTrace(s.frames?.map(::frame)) }
    }

    /**
     * A frame by name and instruction address. A library's path is cut to its file name, since
     * an app's own libraries sit under /data/app/~~<random>==/, a folder made
     * per install.
     */
    private fun frame(f: SentryStackFrame) = SentryStackFrame().apply {
        function = f.function
        module = f.module
        filename = f.filename?.substringAfterLast('/')
        `package` = f.`package`?.substringAfterLast('/')
        instructionAddr = f.instructionAddr
        lineno = f.lineno
        colno = f.colno
        isInApp = f.isInApp
        isNative = f.isNative
        platform = f.platform
    }

    /**
     * An image as symbolication needs it. `type` says whether the ids are an
     * ELF's, a Mach-O's or a ProGuard mapping's, without which Sentry reads
     * none of it.
     */
    private fun image(i: DebugImage) = DebugImage().apply {
        type = i.type
        uuid = i.uuid
        debugId = i.debugId
        imageAddr = i.imageAddr
        imageSize = i.imageSize
        codeFile = i.codeFile?.substringAfterLast('/')
    }
}
