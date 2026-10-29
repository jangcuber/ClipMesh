package dev.clipmesh.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.BufferedReader
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** APK-bundled PIE executable is installed read-only by PackageManager, never downloaded. */
class TransportBridge(private val context:Context, private val group:Group, private val device:String,
    private val onFrame:(String)->Unit, private val onStatus:(ConnectionStatus)->Unit, private val onClosed:()->Unit) {
    private val workers=Executors.newFixedThreadPool(3)
    private val stopped=AtomicBoolean(false)
    private var process:Process?=null
    private var configFile:File?=null
    private var writer:java.io.BufferedWriter?=null
    fun start():Boolean {
        val executable=File(context.applicationInfo.nativeLibraryDir,"libclipmesh_transport.so")
        if(!executable.canExecute()) return false
        try {
            val file=File(context.noBackupFilesDir,"transport-${group.id}.json")
            configFile=file
            val config=JSONObject().put("v",1).put("device",device).put("name",("${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}").trim().take(100))
                .put("groups",JSONArray().put(group.json())).put("active_group",group.id).put("paused",false)
            file.writeText(config.toString()); file.setReadable(false,false); file.setReadable(true,true); file.setWritable(false,false); file.setWritable(true,true)
            val child=ProcessBuilder(executable.absolutePath,"transport","--config",file.absolutePath).start()
            process=child; writer=child.outputStream.bufferedWriter()
            workers.execute {
                try {
                    child.inputStream.bufferedReader().use { input ->
                        val lines=BoundedLines(input)
                        while(!stopped.get()) {
                            val line=lines.read() ?: break
                            val message=JSONObject(line)
                            when(message.optString("type")) {
                                "frame" -> onFrame(message.getString("frame"))
                                "status" -> onStatus(ConnectionStatus.parse(message))
                            }
                        }
                    }
                } catch (_:Exception) { /* Child diagnostics never contain clipboard data. */ }
                finally { if(!stopped.get()) { child.destroy(); onClosed() } }
            }
            workers.execute { try { child.errorStream.use { input -> val buffer=ByteArray(4096); while(input.read(buffer)>=0) { /* discard, never log payloads */ } } } catch (_:Exception) {} }
            return true
        } catch (_:Exception) { stop(); return false }
    }
    private class BoundedLines(private val input:BufferedReader) {
        private val buffer=CharArray(8192)
        private var offset=0
        private var count=0
        fun read():String? {
            val output=StringBuilder()
            while(true) {
                if(offset==count) {
                    count=input.read(buffer); offset=0
                    if(count<0) return if(output.isEmpty()) null else error("Incomplete bridge message")
                }
                var end=offset
                while(end<count && buffer[end]!='\n') end++
                require(output.length+end-offset<=MAX_FRAME_BYTES+4096) { "Bridge message too large" }
                output.append(buffer,offset,end-offset)
                val complete=end<count
                offset=if(complete) end+1 else end
                if(complete) return output.toString()
            }
        }
    }
    @Synchronized fun send(frame:String):Boolean = try {
        val output=writer ?: return false
        output.write(JSONObject().put("op","send").put("frame",frame).toString()); output.newLine(); output.flush(); true
    } catch (_:Exception) { false }
    fun stop() {
        if(!stopped.compareAndSet(false,true)) return
        try { writer?.close() } catch (_:Exception) {}
        process?.destroy(); process=null
        configFile?.delete(); configFile=null
        workers.shutdownNow()
    }
}
