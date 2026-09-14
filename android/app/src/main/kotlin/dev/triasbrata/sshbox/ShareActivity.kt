package dev.triasbrata.sshbox

import android.app.Activity
import android.content.Intent
import android.os.Bundle

// "Share with Jeansh" lands here, inside the sending app's task, and is handed
// on to MainActivity in Jeansh's own task. Given the share directly,
// MainActivity was started as a second copy in the sender's task, where
// singleTop cannot see the one already running: a new FlutterEngine, with no
// sessions to upload to.
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(
            Intent(intent)
                .setClass(this, MainActivity::class.java)
                // NEW_TASK finds Jeansh's task by its root, MainActivity, even
                // with taskAffinity="", and brings it forward. CLEAR_TOP closes
                // a file picker or Custom Tab left open over it, and with
                // SINGLE_TOP the running MainActivity takes the share in
                // onNewIntent instead of being recreated. With no Jeansh
                // running, this starts MainActivity in a task of its own.
                //
                // The sender's read grant is passed on, so MainActivity can
                // still open the files after this activity is gone; no other
                // flag of the sender's comes along.
                .setFlags(
                    (intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION) or
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                ),
        )
        finish()
    }
}
