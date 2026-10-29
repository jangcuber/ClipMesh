package dev.clipmesh.android

import okhttp3.*
import okio.ByteString
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** All state transitions run on one executor so copy and receive have a deterministic order. */
class SyncEngine(private val store: ConfigStore, private val group: Group, private val onClipboard: (ClipEvent)->Unit, private val onStatus:(String)->Unit, private val onConnection:(ConnectionStatus)->Unit) {
    private val executor = Executors.newSingleThreadScheduledExecutor()
    private val client = OkHttpClient.Builder().pingInterval(20,TimeUnit.SECONDS).build()
    private val device = store.device()
    private var socket: WebSocket? = null
    private var bridge:TransportBridge? = null
    private var nativeUnavailable=false
    private var nativeFailures=0
    private var stopped = false
    private var connected = false
    private var retry = 0
    private var reconnect: ScheduledFuture<*>? = null
    private var clock = 0L
    private var winner: ClipEvent? = null
    private var lastHash: String? = null
    private fun submit(action: ()->Unit) {
        try { executor.execute(action) } catch (_: java.util.concurrent.RejectedExecutionException) { /* Late network callback after stop. */ }
    }
    fun start() = submit {
        try {
            val state = store.state(group); clock = state.first; winner = state.second
            // This is protocol state only: startup never replaces the device clipboard.
            connect()
        } catch (_: Exception) { onStatus("저장 상태를 읽지 못했습니다 · 그룹에 다시 참여해 주세요") }
    }
    private fun connect() {
        if (stopped) return
        onConnection(ConnectionStatus())
        onStatus(if (store.paused) "일시 정지됨" else "연결 중")
        if(group.relay.isBlank()) nativeUnavailable=false
        if(group.transport=="p2p" && !nativeUnavailable) {
            lateinit var candidate:TransportBridge
            candidate=TransportBridge(store.appContext,group,device,{ frame -> submit { if(!stopped && bridge===candidate) receive(frame) } },{ link -> submit {
                if(stopped || bridge!==candidate) return@submit
                val wasConnected=connected
                val ready=link.connected
                connected=ready
                onConnection(link)
                onStatus(if(store.paused) "일시 정지됨" else if(ready) link.label() else "연결 끊김 · 다시 연결 중")
                if(ready && !wasConnected && !store.paused) winner?.let { candidate.send(Wire.seal(group,it)) }
            } },{ submit {
                if(stopped || bridge!==candidate) return@submit
                candidate.stop(); bridge=null; connected=false
                onConnection(ConnectionStatus())
                nativeFailures++
                if(nativeFailures>=3) nativeUnavailable=true
                onStatus(if(nativeUnavailable && group.relay.isNotBlank()) "직접 연결 불가 · 서버로 다시 연결 중" else "전송 모듈에 다시 연결 중")
                reconnect?.cancel(false); reconnect=executor.schedule({ connect() },2,TimeUnit.SECONDS)
            } })
            bridge=candidate
            if(candidate.start()) return
            candidate.stop(); bridge=null; nativeUnavailable=true
        }
        if(group.relay.isBlank()) {
            connected=false
            onConnection(ConnectionStatus(false,"helper-unavailable"))
            onStatus("전송 모듈을 시작하지 못했습니다 · 앱을 업데이트하거나 동기화를 다시 켜주세요")
            reconnect?.cancel(false)
            val delay=(1L shl retry.coerceAtMost(5)).coerceAtMost(30); retry++
            reconnect=executor.schedule({ connect() },delay,TimeUnit.SECONDS)
            return
        }
        socket = client.newWebSocket(Request.Builder().url(group.endpoint).build(),object: WebSocketListener() {
            override fun onOpen(webSocket:WebSocket,response:Response) { submit {
                if (stopped || webSocket !== socket) { webSocket.close(1000,"Stopped"); return@submit }
                connected = true; retry = 0
                onConnection(ConnectionStatus(true,"websocket",null))
                onStatus(if(store.paused) "일시 정지됨" else if(nativeUnavailable) "서버 연결 · P2P 사용 불가" else "서버 연결")
                if (!store.paused) winner?.let { webSocket.send(Wire.seal(group,it)) }
            } }
            override fun onMessage(webSocket:WebSocket,text:String) { submit { if (!stopped && webSocket === socket) receive(text) } }
            override fun onMessage(webSocket:WebSocket,bytes:ByteString) { webSocket.close(1003,"Text frames required") }
            override fun onFailure(webSocket:WebSocket,t:Throwable,response:Response?) { lost(webSocket) }
            override fun onClosed(webSocket:WebSocket,code:Int,reason:String) { lost(webSocket) }
        })
    }
    private fun lost(webSocket: WebSocket) {
        if (executor.isShutdown) return
        submit {
            if (stopped || webSocket !== socket) return@submit
            connected = false; socket = null
            onConnection(ConnectionStatus())
            onStatus(if (store.paused) "일시 정지됨 · 연결 끊김" else "연결 끊김 · 다시 연결 중")
            val delay = (1L shl retry.coerceAtMost(5)).coerceAtMost(30)
            retry++
            reconnect?.cancel(false)
            reconnect = executor.schedule({ connect() },delay,TimeUnit.SECONDS)
        }
    }
    fun copy(text: String, mime:String = "text/plain") { if (!executor.isShutdown) submit {
        if (stopped || !store.enabled || store.paused || (mime == "text/plain" && text.contains("clipmesh://join#"))) return@submit
        try {
            validatePayload(mime,text)
            val hash = payloadHash(mime,text)
            if(hash == lastHash) return@submit
            check(clock < MAX_CLOCK - 1)
            val event = ClipEvent(UUID.randomUUID().toString(),device,++clock,System.currentTimeMillis(),text,mime)
            store.saveState(group,clock,event)
            winner = event; lastHash = hash
            if (connected) sendFrame(Wire.seal(group,event))
        } catch (_: Exception) { onStatus("클립보드 변경을 저장하지 못했습니다") }
    } }
    private fun sendFrame(frame:String) { bridge?.let { it.send(frame); return }; socket?.send(frame) }
    private fun receive(frame: String) {
        if (store.paused) return
        try {
            val event = Wire.open(group,frame)
            clock = maxOf(clock,event.clock)
            val current = winner
            if (current != null && event <= current) { store.saveState(group,clock,current); return }
            store.saveState(group,clock,event)
            winner = event
            if (event.device != device && payloadHash(event.mime,event.text) != lastHash) {
                lastHash = payloadHash(event.mime,event.text)
                onClipboard(event)
            }
        } catch (_: Exception) { onStatus("지원하지 않거나 손상된 메시지를 거부했습니다") }
    }
    fun pause(paused: Boolean) { if (!executor.isShutdown) submit {
        store.paused = paused
        onStatus(if(paused) "일시 정지됨" else if(connected) "Connected" else "연결 끊김 · 다시 연결 중")
        // Reconnect to replay relay history after resume.
        if (!paused) { bridge?.stop(); bridge=null; socket?.cancel(); socket = null; connected = false; reconnect?.cancel(false); connect() }
    } }
    fun stop() {
        if (executor.isShutdown) return
        submit {
            stopped = true; reconnect?.cancel(false); bridge?.stop(); bridge=null; socket?.close(1000,"Stopped"); socket = null
            client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll()
            executor.shutdown()
        }
    }
}
