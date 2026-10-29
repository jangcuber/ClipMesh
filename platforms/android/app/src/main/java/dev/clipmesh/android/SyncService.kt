package dev.clipmesh.android

import android.app.*
import android.content.*
import android.os.*
import java.util.concurrent.atomic.AtomicReference

class SyncService: Service() {
    private lateinit var store: ConfigStore
    @Volatile private var engine: SyncEngine? = null
    @Volatile private var generation=0L
    private lateinit var clipboard: ClipboardManager
    private val lastCapture=java.util.concurrent.atomic.AtomicLong()
    private val imageReader = ImageClipboard.newReader()
    private val main = Handler(Looper.getMainLooper())
    private val listener = ClipboardManager.OnPrimaryClipChangedListener { captureForegroundClipboard() }
    companion object {
        val instance = AtomicReference<SyncService?>()
        @Volatile var status: String = "동기화 꺼짐"
        @Volatile var connection=ConnectionStatus()
        const val ACTION_PAUSE = "dev.clipmesh.android.PAUSE"
        const val ACTION_STOP = "dev.clipmesh.android.STOP"
        const val ACTION_RELOAD = "dev.clipmesh.android.RELOAD"
    }
    override fun onCreate() {
        super.onCreate()
        store = ConfigStore(this)
        clipboard = getSystemService(ClipboardManager::class.java)
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("sync","Clipboard synchronization",NotificationManager.IMPORTANCE_LOW))
        startForeground(1,notification("백그라운드 동기화 시작 중"))
        clipboard.addPrimaryClipChangedListener(listener)
        instance.set(this)
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        when(intent?.action) {
            ACTION_STOP -> { store.enabled = false; store.paused=false; stopSelf(); return START_NOT_STICKY }
            ACTION_PAUSE -> { val paused=!store.paused; store.paused=paused; engine?.pause(paused); return START_STICKY }
        }
        if (!store.enabled) { stopSelf(); return START_NOT_STICKY }
        if(engine == null || intent?.action == ACTION_RELOAD) {
            generation++
            connection=ConnectionStatus()
            invalidateOlderCaptures()
            engine?.stop(); engine = null
            val engineGeneration=generation
            try {
                val group = store.active()?.let { store.transportGroup(it) }
                if(group == null) { store.enabled=false; updateStatus("참여한 그룹 없음"); stopSelf(); return START_NOT_STICKY }
                engine = SyncEngine(store,group,{ event ->
                    if(generation==engineGeneration && store.enabled && !store.paused) {
                        invalidateOlderCaptures()
                        main.post { applyRemote(event,engineGeneration) }
                    }
                },{ message -> main.post { if(generation==engineGeneration && store.enabled) updateStatus(message) } },{ link -> if(generation==engineGeneration && store.enabled) { connection=link; store.rememberEndpoints(group.id,link.selfId,link.seedIds) } }).also { it.start() }
            } catch (_: Exception) { store.enabled=false; updateStatus("설정을 읽지 못했습니다"); stopSelf(); return START_NOT_STICKY }
        }
        return START_STICKY
    }
    private fun applyRemote(event:ClipEvent,engineGeneration:Long) {
        if(generation!=engineGeneration || !store.enabled || store.paused) return
        // Remote writes must invalidate slow local decodes before their clipboard echo arrives.
        invalidateOlderCaptures()
        try {
            if(event.mime=="image/png") {
                val uri=ClipboardImageProvider.put(this,java.util.Base64.getDecoder().decode(event.text))
                clipboard.setPrimaryClip(ClipData.newUri(contentResolver,"ClipMesh image",uri))
                BridgeDiagnostics.imagesReceived.incrementAndGet()
            } else clipboard.setPrimaryClip(ClipData.newPlainText("ClipMesh",event.text))
        } catch (_:Exception) { updateStatus("Android에서 클립보드 쓰기를 차단했습니다") }
    }
    fun acceptsCapture()=store.enabled && !store.paused
    @Synchronized private fun invalidateOlderCaptures() { lastCapture.set(SystemClock.elapsedRealtimeNanos()) }
    @Synchronized private fun acceptPayload(text:String,mime:String,observed:Long) {
        if(!store.enabled || store.paused || observed<lastCapture.get()) return
        lastCapture.set(observed)
        if(mime=="image/png") BridgeDiagnostics.imagesCaptured.incrementAndGet()
        engine?.copy(text,mime)
    }
    fun acceptSystemClipboard(text:String,observed:Long=SystemClock.elapsedRealtimeNanos()) { acceptPayload(text,"text/plain",observed) }
    fun acceptSystemImage(bytes:ByteArray,observed:Long=SystemClock.elapsedRealtimeNanos()) {
        acceptPayload(ImageClipboard.encoded(bytes),"image/png",observed)
    }
    fun captureForegroundClipboard() {
        try {
            val observed=SystemClock.elapsedRealtimeNanos()
            val clip=clipboard.primaryClip?.takeIf { it.itemCount>0 } ?: return
            val item=clip.getItemAt(0)
            val uri=item.uri
            if(uri!=null && (clip.description.hasMimeType("image/*") || contentResolver.getType(uri)?.startsWith("image/")==true)) {
                imageReader.execute { try { acceptSystemImage(ImageClipboard.fromUri(contentResolver,uri),observed) } catch (_:Exception) { BridgeDiagnostics.imagesRejected.incrementAndGet(); main.post { updateStatus("이미지를 읽지 못했습니다 · 최대 8 MiB / 40 MP") } } }
            } else item.text?.toString()?.let { acceptSystemClipboard(it,observed) }
        }
        catch (_: Exception) { /* Android restricts background reads; system hook supplies those. */ }
    }
    private fun notification(message:String):Notification {
        val open = PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this,2,Intent(this,SyncService::class.java).setAction(ACTION_STOP),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this,"sync").setContentTitle("ClipMesh · 동기화 켜짐").setContentText(if(connection.connected) connection.label() else message)
            .setSmallIcon(android.R.drawable.ic_menu_share).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null,"동기화 끄기",stop).build()).build()
    }
    private fun updateStatus(message:String) {
        status = message
        getSystemService(NotificationManager::class.java).notify(1,notification(message))
    }
    override fun onDestroy() {
        generation++
        invalidateOlderCaptures()
        instance.compareAndSet(this,null); clipboard.removePrimaryClipChangedListener(listener)
        engine?.stop(); engine = null; imageReader.shutdownNow(); status = "동기화 꺼짐"; connection=ConnectionStatus()
        super.onDestroy()
    }
    override fun onBind(intent:Intent?) = null
}

fun shouldAutoStart(enabled:Boolean,paused:Boolean,hasGroup:Boolean)=enabled && !paused && hasGroup

class BootReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        if(intent.action!=Intent.ACTION_BOOT_COMPLETED && intent.action!=Intent.ACTION_MY_PACKAGE_REPLACED) return
        try {
            val store=ConfigStore(context)
            if(!shouldAutoStart(store.enabled,store.paused,store.active()!=null)) return
            context.startForegroundService(Intent(context,SyncService::class.java).setAction(SyncService.ACTION_RELOAD))
            context.getSharedPreferences("clipmesh.lifecycle",Context.MODE_PRIVATE).edit().remove("restart_error").apply()
        } catch(error:Exception) {
            context.getSharedPreferences("clipmesh.lifecycle",Context.MODE_PRIVATE).edit().putString("restart_error",error.javaClass.simpleName).apply()
        }
    }
}
