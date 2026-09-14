package dev.triasbrata.sshbox

import android.content.Intent
import android.net.Uri
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

    // A download waiting in the save dialog: Dart's copy, and who to tell.
    private var saving: Pair<File, MethodChannel.Result>? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "takeShared") {
                    result.success(pending)
                    pending = null
                } else if (call.method == "saveAs") {
                    saveAs(call.argument("path")!!, call.argument("name")!!, result)
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

    // A download, the other way. file_picker's saveFile wants the whole file
    // as bytes over the channel, which froze the app on a big one; Dart
    // streams it to a file of its own instead and hands over the path. The
    // answer is true once it is copied into the picked document, false when
    // the dialog is dismissed. The copy is Dart's to delete either way.
    private fun saveAs(path: String, name: String, result: MethodChannel.Result) {
        if (saving != null) {
            result.error("busy", "another download is waiting to be saved", null)
            return
        }
        saving = File(path) to result
        startActivityForResult(
            Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                // file_picker's type for it too: a specific one lets some
                // providers put an extension of their own on the name.
                .setType("application/octet-stream")
                .putExtra(Intent.EXTRA_TITLE, name),
            SAVE_AS,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_AS) return
        val (file, result) = saving ?: return
        saving = null
        val target = data?.data
        if (resultCode != RESULT_OK || target == null) {
            result.success(false)
            return
        }
        // Off the main thread, which is Flutter's UI thread too: 70 MB copied
        // there is an "isn't responding".
        Thread {
            val error = try {
                file.inputStream().use { input ->
                    contentResolver.openOutputStream(target)!!.use { input.copyTo(it) }
                }
                null
            } catch (e: Exception) {
                e
            }
            runOnUiThread {
                if (error == null) {
                    result.success(true)
                } else {
                    result.error("save_failed", error.message ?: error.toString(), null)
                }
            }
        }.start()
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

        // Ours alone among the request codes plugins pass through here.
        const val SAVE_AS = 0x5a5e
    }
}
