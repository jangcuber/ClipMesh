package dev.clipmesh.android

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.security.MessageDigest

/** Private provider: Android grants read access only to the actual paste recipient. */
class ClipboardImageProvider:ContentProvider() {
    companion object {
        private const val AUTHORITY="dev.clipmesh.android.images"
        fun put(context:Context,bytes:ByteArray):Uri {
            validatePng(bytes)
            val directory=File(context.cacheDir,"clipboard-images").apply { mkdirs() }
            val hash=MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            val file=File(directory,"$hash.png")
            if(!file.exists()) {
                val temp=File.createTempFile("incoming-",".tmp",directory)
                try { temp.writeBytes(bytes); check(temp.renameTo(file)) } finally { temp.delete() }
            }
            file.setLastModified(System.currentTimeMillis())
            directory.listFiles()?.filter { it!=file }?.sortedByDescending { it.lastModified() }?.drop(15)?.forEach { it.delete() }
            return Uri.Builder().scheme("content").authority(AUTHORITY).appendPath("image").appendPath(file.name).build()
        }
    }
    override fun onCreate()=true
    private fun file(uri:Uri):File {
        require(uri.authority==AUTHORITY && uri.pathSegments.size==2 && uri.pathSegments[0]=="image" && uri.pathSegments[1].matches(Regex("[a-f0-9]{64}\\.png")))
        return File(File(requireNotNull(context).cacheDir,"clipboard-images"),uri.pathSegments[1])
    }
    override fun openFile(uri:Uri,mode:String):ParcelFileDescriptor {
        if(mode!="r") throw SecurityException("Read only")
        return ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun getType(uri:Uri):String { file(uri); return "image/png" }
    override fun query(uri:Uri,projection:Array<out String>?,selection:String?,selectionArgs:Array<out String>?,sortOrder:String?):Cursor {
        val file=file(uri); val columns=projection ?: arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE)
        return MatrixCursor(columns).apply { addRow(columns.map { when(it) { OpenableColumns.DISPLAY_NAME -> "ClipMesh.png"; OpenableColumns.SIZE -> file.length(); else -> null } }.toTypedArray()) }
    }
    override fun insert(uri:Uri,values:ContentValues?):Uri?=throw SecurityException()
    override fun delete(uri:Uri,selection:String?,selectionArgs:Array<out String>?):Int=throw SecurityException()
    override fun update(uri:Uri,values:ContentValues?,selection:String?,selectionArgs:Array<out String>?):Int=throw SecurityException()
}
