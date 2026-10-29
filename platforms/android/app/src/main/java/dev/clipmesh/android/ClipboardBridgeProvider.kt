package dev.clipmesh.android

import android.content.*
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process
import android.os.ParcelFileDescriptor
import java.util.concurrent.Executors

/** Exported solely for system_server. No public broadcast carries clipboard contents. */
class ClipboardBridgeProvider: ContentProvider() {
    private val reader = Executors.newSingleThreadExecutor()
    private val imageReader=ImageClipboard.newReader()
    override fun onCreate() = true
    override fun call(method:String,arg:String?,extras:Bundle?):Bundle {
        val uid = Binder.getCallingUid()
        if (uid != Process.SYSTEM_UID && uid != Process.myUid()) throw SecurityException("System UID required")
        if(method=="capture_enabled") {
            return Bundle().apply { putBoolean("enabled",extras?.getInt("user_id",-1)==Process.myUid()/100000 && SyncService.instance.get()?.acceptsCapture()==true) }
        }
        if(method=="capture_status") {
            if(extras?.getInt("user_id",-1)==Process.myUid()/100000 && arg=="image_grant_failed") BridgeDiagnostics.uriGrantFailures.incrementAndGet()
            return Bundle()
        }
        if (method != "capture") throw IllegalArgumentException("Unknown operation")
        val observed=extras?.getLong("observed_ns",0)?.takeIf { it>0 } ?: android.os.SystemClock.elapsedRealtimeNanos()
        val mime = extras?.getString("mime") ?: "text/plain"
        if(mime != "text/plain" && !mime.startsWith("image/")) return Bundle()
        val userId = extras?.getInt("user_id",-1) ?: -1
        // Never forward another Android user's clipboard to the owner profile.
        if (userId != Process.myUid() / 100000) {
            @Suppress("DEPRECATION")
            extras?.getParcelable<ParcelFileDescriptor>("stream")?.close()
            return Bundle()
        }
        if(mime.startsWith("image/")) {
            @Suppress("DEPRECATION")
            val imageUri=extras?.getParcelable<Uri>("image_uri") ?: return Bundle()
            if(imageUri.scheme!="content" || SyncService.instance.get()?.acceptsCapture()!=true) return Bundle()
            imageReader.execute {
                try { SyncService.instance.get()?.acceptSystemImage(ImageClipboard.fromUri(requireNotNull(context).contentResolver,imageUri),observed) }
                catch (_:Exception) { BridgeDiagnostics.imagesRejected.incrementAndGet() }
            }
            return Bundle()
        }
        @Suppress("DEPRECATION")
        val stream = extras?.getParcelable<ParcelFileDescriptor>("stream") ?: return Bundle()
        if (SyncService.instance.get()?.acceptsCapture()!=true) { stream.close(); return Bundle() }
        reader.execute {
            try {
                ParcelFileDescriptor.AutoCloseInputStream(stream).use { input ->
                    val out = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while(true) {
                        val n = input.read(buffer)
                        if(n < 0) break
                        if(out.size() + n > MAX_TEXT_BYTES) return@execute
                        out.write(buffer,0,n)
                    }
                    SyncService.instance.get()?.acceptSystemClipboard(out.toString("UTF-8"),observed)
                }
            } catch (_:Exception) { /* Dropped IPC is isolated from system_server. */ }
        }
        return Bundle()
    }
    override fun query(uri:Uri,projection:Array<out String>?,selection:String?,selectionArgs:Array<out String>?,sortOrder:String?):Cursor? = null
    override fun getType(uri:Uri):String? = null
    override fun insert(uri:Uri,values:ContentValues?):Uri? = throw SecurityException()
    override fun delete(uri:Uri,selection:String?,selectionArgs:Array<out String>?):Int = throw SecurityException()
    override fun update(uri:Uri,values:ContentValues?,selection:String?,selectionArgs:Array<out String>?):Int = throw SecurityException()
}
