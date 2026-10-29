package dev.clipmesh.android

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.Base64

/** All decoding runs off the UI thread. A hard byte/pixel bound precedes allocation. */
object ImageClipboard {
    // At most one running decode and the newest pending image; no descriptor is opened
    // until the task runs, so dropping an old pending image cannot leak a URI handle.
    fun newReader()=java.util.concurrent.ThreadPoolExecutor(1,1,0,java.util.concurrent.TimeUnit.MILLISECONDS,
        java.util.concurrent.ArrayBlockingQueue<Runnable>(1),java.util.concurrent.ThreadPoolExecutor.DiscardOldestPolicy())
    fun readBounded(input:InputStream, limit:Int=MAX_IMAGE_BYTES):ByteArray {
        val output=ByteArrayOutputStream(); val buffer=ByteArray(8192)
        while(true) {
            val n=input.read(buffer); if(n<0) break
            require(output.size()+n<=limit) { "Image exceeds 8 MiB" }
            output.write(buffer,0,n)
        }
        return output.toByteArray()
    }
    fun canonicalPng(bytes:ByteArray):ByteArray {
      try {
        require(bytes.size<=MAX_IMAGE_BYTES)
        val bounds=BitmapFactory.Options().apply { inJustDecodeBounds=true }
        BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
        require(bounds.outWidth in 1..16384 && bounds.outHeight in 1..16384 && bounds.outWidth.toLong()*bounds.outHeight<=40_000_000) { "Image dimensions exceed 40 megapixels" }
        // Preserve PNG bytes. Re-encoding a received PNG would defeat byte-hash loop suppression.
        if(bounds.outMimeType=="image/png") { validatePng(bytes); return bytes }
        val bitmap=try { BitmapFactory.decodeByteArray(bytes,0,bytes.size) ?: error("Unreadable image") } catch (_:OutOfMemoryError) { error("Image exceeds device memory") }
        try {
            val output=object:ByteArrayOutputStream() {
                override fun write(b:ByteArray,off:Int,len:Int) { require(count+len<=MAX_IMAGE_BYTES); super.write(b,off,len) }
                override fun write(b:Int) { require(count<MAX_IMAGE_BYTES); super.write(b) }
            }
            check(bitmap.compress(Bitmap.CompressFormat.PNG,100,output))
            return output.toByteArray().also { validatePng(it) }
        } finally { bitmap.recycle() }
      } catch (_:OutOfMemoryError) { error("Image exceeds device memory") }
    }
    fun fromUri(resolver:ContentResolver,uri:Uri):ByteArray {
        require(uri.scheme=="content") { "Only content image URIs are supported" }
        return resolver.openInputStream(uri)?.use { canonicalPng(readBounded(it)) } ?: error("Image unavailable")
    }
    fun encoded(bytes:ByteArray)=Base64.getEncoder().encodeToString(bytes)
}
