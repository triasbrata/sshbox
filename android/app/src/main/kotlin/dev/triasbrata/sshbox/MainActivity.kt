package dev.triasbrata.sshbox

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// Receives files handed to us by another app's share sheet and puts them
// somewhere Dart can read.
//
// A share arrives as a content:// URI owned by the sending app, which SFTP
// cannot open — so it is copied into our own cache first, and only the path
// crosses the channel.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    // A cold start: the app was dead, so the share, forwarded by ShareActivity,
    // is what launched us and Dart is not listening yet. The files wait here until Dart
    // asks — the same shape as app_links' getInitialLink.
    private var pending: List<Map<String, String>>? = null

    // A launcher tap that Android answered with a second MainActivity on top
    // of ours, instead of bringing our task back. It does that when a file
    // picker or Custom Tab is open over ours and the task was last started or
    // resumed by an intent other than the launcher's: a share, or a
    // notification tap that cold-started the app. Finishing at once shows the
    // task as it was. finish() goes before super.onCreate, which is where
    // FlutterActivity makes its engine and starts Dart.
    override fun onCreate(savedInstanceState: Bundle?) {
        if (!isTaskRoot && intent.action == Intent.ACTION_MAIN &&
            intent.hasCategory(Intent.CATEGORY_LAUNCHER)
        ) {
            finish()
        }
        super.onCreate(savedInstanceState)
    }

    // The copy finished above gets an engine with no plugins that never runs
    // Dart, so nothing of the app starts for it, and it is destroyed with the
    // copy. Every other start gets FlutterActivity's own engine, as before.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        if (isFinishing) FlutterEngine(context, null, false)
        else super.provideFlutterEngine(context)

    override fun shouldDestroyEngineWithHost(): Boolean =
        isFinishing || super.shouldDestroyEngineWithHost()

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // The copy finished in onCreate: it must not clear the cache the
        // running Jeansh may still be uploading shared files from.
        if (isFinishing) return
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeShared") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        // Copies from an earlier run were uploaded or abandoned with it; a
        // shared photo or document should not sit in our cache for good.
        File(cacheDir, "shared").deleteRecursively()
        pending = filesIn(intent)
    }

    // A share while we are already running: ShareActivity brings our task
    // forward and, with launchMode singleTop, delivers it here rather than to
    // a new instance. Dart is listening by now.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val files = filesIn(intent) ?: return
        channel?.invokeMethod("shared", files)
    }

    private fun filesIn(intent: Intent?): List<Map<String, String>>? {
        val uris: List<Uri> = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.streamExtra())
            Intent.ACTION_SEND_MULTIPLE -> intent.streamExtras()
            else -> emptyList()
        }
        // Text-only shares carry no stream: nothing to upload, and nothing to
        // report either.
        return uris.mapNotNull(::copyToCache).ifEmpty { null }
    }

    private fun copyToCache(uri: Uri): Map<String, String>? {
        // The display name comes from another app, so strip path separators
        // before it is used to build a path of ours.
        val name = (displayName(uri) ?: uri.lastPathSegment ?: "shared")
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .ifEmpty { "shared" }

        val target = File(File(cacheDir, "shared"), "${System.nanoTime()}-$name")
        target.parentFile?.mkdirs()

        return try {
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { source ->
                target.outputStream().use { sink -> source.copyTo(sink) }
            }
            mapOf("path" to target.absolutePath, "name" to name)
        } catch (error: Exception) {
            // A revoked or dead content URI is the sender's problem, not a
            // reason to take the app down.
            null
        }
    }

    private fun displayName(uri: Uri): String? =
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (column >= 0 && cursor.moveToFirst()) cursor.getString(column) else null
        }

    @Suppress("DEPRECATION")
    private fun Intent.streamExtra(): Uri? = getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun Intent.streamExtras(): List<Uri> =
        getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()

    private companion object {
        const val CHANNEL = "sshbox/share"
    }
}
