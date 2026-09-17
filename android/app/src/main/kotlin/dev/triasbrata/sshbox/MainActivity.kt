package dev.triasbrata.sshbox

import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference

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

    // One Jeansh at a time, however it was started. A second MainActivity is
    // a second FlutterEngine: another SessionManager, notification handler
    // and set of sessions beside the first. Android makes one whenever a
    // launch misses the running activity: a tap on a stale Jeansh card in
    // Recents, restored as the root of its old task; a launcher or
    // notification tap over a file picker or Custom Tab, added on top of our
    // task when another intent started it; a floating window, split screen or
    // "new window" started as a task of its own; a sshbox:// link fired
    // inside another app's task.
    //
    // The copy brings the running one's task forward, hands it the intent
    // through onNewIntent, as singleTop would have, so a link, notification
    // tap or share still lands, and finishes before super.onCreate, which is
    // where FlutterActivity makes its engine and starts Dart. As the root of
    // a task of its own it takes that task along, so no empty card stays in
    // Recents; anywhere else it leaves the task as it was.
    //
    // A relaunch for a config change is no copy: Android destroys the old
    // instance, which lets go of [live], before it creates the new one.
    override fun onCreate(savedInstanceState: Bundle?) {
        val running = live?.get()?.takeUnless { it.isFinishing || it.isDestroyed }
        if (running == null) {
            live = WeakReference(this)
        } else {
            // Our own tasks need no permission for this. Failing only leaves
            // the running one where it was; a crash here would end its sessions.
            runCatching {
                getSystemService(ActivityManager::class.java).appTasks
                    .firstOrNull { it.id() == running.taskId }
                    ?.moveToFront()
            }
            // A card from Recents, or an instance restored after the process
            // died, carries an old intent rather than a new request: Android
            // never hands those to a running activity either.
            if (savedInstanceState == null &&
                (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
            ) {
                running.onNewIntent(intent)
            }
            if (isTaskRoot && taskId != running.taskId) finishAndRemoveTask() else finish()
        }
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        if (live?.get() === this) live = null
        super.onDestroy()
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
                } else if (call.method == "saveAs") {
                    saveAs(call.argument("path")!!, call.argument("name")!!, result)
                } else if (call.method == "copyImage") {
                    copyImage(call.argument("path")!!, call.argument("name")!!, result)
                } else if (call.method == "open") {
                    result.success(open(Uri.parse(call.argument("uri")!!), call.argument("name")!!))
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
    // a new instance; a copy turned away in onCreate hands its intent over
    // here too. Dart is listening by now.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val files = filesIn(intent) ?: return
        channel?.invokeMethod("shared", files)
    }

    // A download, the other way. file_picker's saveFile wants the whole file
    // as bytes over the channel, which froze the app on a big one; Dart
    // streams it to a file of its own instead and hands over the path. The
    // answer is the picked document's URI once the copy is in it, for Open
    // in the Transfers tab, and null when the dialog is dismissed. The copy
    // is Dart's to delete either way.
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
            result.success(null)
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
                    result.success(target.toString())
                } else {
                    result.error("save_failed", error.message ?: error.toString(), null)
                }
            }
        }.start()
    }

    // An image on the clipboard, to paste into a chat or an editor. Android
    // has no clipboard for pixels: a clip holds a content:// URI the pasting
    // app reads, so the file behind it has to outlive this call and has to
    // sit where ClipFileProvider serves it. Dart's copy is neither — it is in
    // code_cache and goes when the tab closes — so it is copied into
    // cache/clip, which holds one image: the next Copy image replaces it.
    private fun copyImage(path: String, name: String, result: MethodChannel.Result) {
        // The name comes from a remote host, and it is about to build a path
        // of ours: one segment of it, and never one that walks out of the
        // directory.
        val safe = name.substringAfterLast('/').substringAfterLast('\\')
            .takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "image"
        // Up to 20 MB of copying, which is not for the main thread — Flutter's
        // UI runs on it.
        Thread {
            val clip = runCatching {
                val dir = File(cacheDir, "clip")
                dir.deleteRecursively()
                dir.mkdirs()
                val target = File(dir, safe)
                File(path).copyTo(target, overwrite = true)
                // newUri takes the type from the provider, which takes it from
                // the extension: the name has to keep its .png.
                ClipData.newUri(
                    contentResolver,
                    safe,
                    FileProvider.getUriForFile(this, "$packageName.files", target),
                )
            }
            runOnUiThread {
                // The system grants the pasting app read access to a URI on
                // the clipboard, which is why the provider grants URI
                // permissions and stays unexported.
                val error = clip.exceptionOrNull() ?: runCatching {
                    (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                        .setPrimaryClip(clip.getOrThrow())
                }.exceptionOrNull()
                if (error == null) {
                    result.success(null)
                } else {
                    result.error("copy_failed", error.message ?: error.toString(), null)
                }
            }
        }.start()
    }

    // A finished download, in whatever app the phone has for its kind: the
    // document the save dialog made, which that app reads through the grant
    // the dialog gave us. Its kind comes from its name, since the dialog was
    // asked for a plain octet stream. False when no app will, or the grant
    // has gone.
    private fun open(uri: Uri, name: String): Boolean = try {
        val type = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
            ?: contentResolver.getType(uri)
            ?: "*/*"
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, type)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
        )
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
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

    // TaskInfo.taskId came in API 29; before it, persistentId is the same id.
    @Suppress("DEPRECATION")
    private fun ActivityManager.AppTask.id(): Int? = taskInfo?.let {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) it.taskId else it.persistentId
    }

    private companion object {
        const val CHANNEL = "sshbox/share"

        // Ours alone among the request codes plugins pass through here.
        const val SAVE_AS = 0x5a5e

        // The MainActivity that got past onCreate's check, until it is
        // destroyed. Every copy lives in this one process, so this sees them all.
        var live: WeakReference<MainActivity>? = null
    }
}

// Serves cache/clip — the one image Copy image last put on the clipboard — to
// whichever app pastes it; see MainActivity.copyImage and res/xml/file_paths.
//
// A subclass of our own rather than androidx's FileProvider straight, because
// the manifest merger keys providers on their class name: a plugin that
// declared androidx's would collide with ours and fail the build.
class ClipFileProvider : FileProvider()
