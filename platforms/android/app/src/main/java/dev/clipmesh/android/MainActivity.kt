package dev.clipmesh.android

import android.Manifest
import android.app.*
import android.content.*
import android.os.*
import android.provider.Settings
import android.view.View
import android.widget.*
import android.graphics.Bitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

class MainActivity:Activity() {
    private lateinit var store:ConfigStore
    private lateinit var status:TextView
    private lateinit var active:TextView
    private lateinit var master:Button
    private lateinit var advanced:LinearLayout
    private lateinit var diagnostics:TextView
    private val handler=Handler(Looper.getMainLooper())
    private val refresh=object:Runnable { override fun run() { updateState(); handler.postDelayed(this,1000) } }
    private fun dp(value:Int)=(value*resources.displayMetrics.density).toInt()
    private fun column()=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL }
    private fun label(parent:LinearLayout,value:String,size:Float=16f)=TextView(this).apply {
        text=value; textSize=size; setPadding(0,dp(8),0,dp(8)); parent.addView(this)
    }
    private fun button(parent:LinearLayout,value:String,action:()->Unit)=Button(this).apply {
        text=value; isAllCaps=false; setOnClickListener { action() }; parent.addView(this)
    }
    override fun onCreate(state:Bundle?) {
        super.onCreate(state)
        store=ConfigStore(this)
        // Previous releases exposed a separate pause switch. Migrate that state
        // into the single visible off state; enabling always resumes explicitly.
        if(store.paused) { store.paused=false; store.enabled=false; stopService(Intent(this,SyncService::class.java)) }
        val root=column().apply { setPadding(dp(24),dp(24),dp(24),dp(24)) }
        label(root,"ClipMesh",30f)
        label(root,"복사하면 연결된 기기로 전달됩니다",16f)
        active=label(root,"",20f)
        status=label(root,"",17f).apply { setTextIsSelectable(true); accessibilityLiveRegion=View.ACCESSIBILITY_LIVE_REGION_POLITE }
        master=button(root,"동기화 켜기") { safely { toggleSync() } }
        button(root,"새 기기 연결 · QR 스캔") { scanQr() }
        button(root,"QR 사진 가져오기") { safely { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE),QR_IMAGE_REQUEST) } }
        button(root,"다른 기기에 보여줄 QR") { safely { showInvite(store.active() ?: error("먼저 다른 기기의 QR을 스캔해 그룹에 참여하세요")) } }
        button(root,"동기화 그룹 선택") { chooseGroup() }
        label(root,"한 번 켜두면 화면을 닫아도 동기화하며, 재부팅 후 첫 잠금 해제 뒤 자동으로 다시 시작합니다.\n텍스트와 이미지(최대 8 MiB)를 지원합니다.",14f)
        label(root,"처음 한 번: Vector에서 ClipMesh → System Framework를 선택하고 재부팅하세요. 배터리는 ‘제한 없음’, 절전 앱 목록에서는 제외하세요. 강제 종료했다면 앱을 다시 열어야 합니다.",14f)
        advanced=column().apply { visibility=View.GONE }
        button(root,"고급 설정 · 직접 참여 / 새 그룹 / 진단") { advanced.visibility=if(advanced.visibility==View.VISIBLE) View.GONE else View.VISIBLE }
        root.addView(advanced)
        button(advanced,"초대 링크로 직접 참여") { showManualInvite() }
        button(advanced,"새 동기화 그룹 만들기") { createGroup() }
        button(advanced,"P2P 자동 연결 사용") { safely {
            val group=(store.active() ?: error("먼저 그룹에 참여하세요")).copy(transport="p2p")
            store.saveGroup(group); configurationChanged()
            Toast.makeText(this,"직접 연결을 우선 시도하고 필요하면 중계합니다",Toast.LENGTH_LONG).show()
        } }
        button(advanced,"Mac 없이 연결로 전환") { safely {
            val current=store.active() ?: error("먼저 그룹에 참여하세요")
            val ids=store.endpointIds(current.id)
            require(ids.isNotEmpty()) { "먼저 P2P 자동 연결과 동기화를 켜 연결 ID를 준비해 주세요" }
            val group=current.withPairingSeeds(ids).copy(relay="",transport="p2p")
            store.saveGroup(group); configurationChanged(); showInvite(group)
        } }
        button(advanced,"현재 클립보드 보내기") { SyncService.instance.get()?.captureForegroundClipboard() }
        button(advanced,"배터리 설정 열기") { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
        diagnostics=label(advanced,"",13f).apply { setTextIsSelectable(true) }
        label(advanced,"QR과 초대 링크에는 그룹의 비밀키가 들어 있습니다. 신뢰하는 기기에만 보여주세요. 서버 연결만으로 다른 기기 연결이 확인되지는 않습니다.",13f)
        setContentView(ScrollView(this).apply { addView(root) })
        updateState()
        intent?.data?.toString()?.let { confirmJoin(it) }
    }
    override fun onNewIntent(intent:Intent) { super.onNewIntent(intent); setIntent(intent); intent.data?.toString()?.let { confirmJoin(it) } }
    override fun onResume() {
        super.onResume()
        safely {
            if(shouldAutoStart(store.enabled,store.paused,store.active()!=null) && SyncService.instance.get()==null)
                startForegroundService(Intent(this,SyncService::class.java).setAction(SyncService.ACTION_RELOAD))
        }
        handler.post(refresh)
    }
    override fun onPause() { handler.removeCallbacks(refresh); super.onPause() }
    private fun toggleSync() {
        if(store.enabled && !store.paused) {
            store.enabled=false; store.paused=false
            stopService(Intent(this,SyncService::class.java))
        } else {
            require(store.active()!=null) { "먼저 다른 기기의 QR을 스캔해 그룹에 참여하세요" }
            enableSync()
        }
        updateState()
    }
    private fun enableSync() {
        if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=android.content.pm.PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),1)
        store.paused=false; store.enabled=true
        try { startForegroundService(Intent(this,SyncService::class.java).setAction(SyncService.ACTION_RELOAD)) }
        catch(error:Exception) { store.enabled=false; throw error }
    }
    private fun updateState() {
        try {
            active.text="그룹 · ${store.active()?.name ?: "참여한 그룹 없음"}"
            val enabled=store.enabled && !store.paused
            master.text=if(enabled) "동기화 끄기" else "동기화 켜기"
            status.text=if(!enabled) "동기화 꺼짐" else if(SyncService.instance.get()==null) "백그라운드 서비스 시작 중" else SyncService.connection.let { it.label()+it.deviceLabel().takeIf { value -> value.isNotEmpty() }?.let { value -> "\n$value" }.orEmpty() }
            diagnostics.text="앱 0.3.0\n서비스: ${SyncService.status}\n${BridgeDiagnostics.summary()}\nQR 진단: ${getSharedPreferences("clipmesh.scan",MODE_PRIVATE).getString("last_error","없음")}\n최근 자동 시작 오류: ${getSharedPreferences("clipmesh.lifecycle",MODE_PRIVATE).getString("restart_error","없음")}"
        } catch(_:Exception) { status.text="설정을 읽을 수 없습니다" }
    }
    private fun configurationChanged() {
        if(store.active()==null) { store.enabled=false; store.paused=false; stopService(Intent(this,SyncService::class.java)) }
        else if(store.enabled) startForegroundService(Intent(this,SyncService::class.java).setAction(SyncService.ACTION_RELOAD))
        updateState()
    }
    private fun chooseGroup()=safely {
        val groups=store.groups()
        require(groups.isNotEmpty()) { "다른 기기의 QR을 스캔하거나 고급 설정에서 그룹을 만드세요" }
        AlertDialog.Builder(this).setTitle("동기화 그룹 선택")
            .setItems(groups.map { it.name }.toTypedArray()) { _,i -> safely { store.activate(groups[i].id); configurationChanged() } }
            .setNeutralButton("현재 그룹 삭제") { _,_ -> AlertDialog.Builder(this).setTitle("이 기기에서 그룹을 삭제할까요?")
                .setMessage("다른 기기의 그룹은 삭제되지 않습니다.")
                .setPositiveButton("삭제") { _,_ -> safely { store.active()?.let { store.removeGroup(it.id) }; configurationChanged() } }.setNegativeButton("취소",null).show() }
            .setNegativeButton("취소",null).show()
    }
    private fun showManualInvite() {
        val value=EditText(this).apply { hint="clipmesh://join#… 초대 링크"; maxLines=5; inputType=android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS }
        val dialog=AlertDialog.Builder(this).setTitle("초대 링크로 참여").setView(value).setPositiveButton("참여",null).setNegativeButton("취소",null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { safely { val group=Group.fromInvite(value.text.toString()); store.saveGroup(group); value.text.clear(); configurationChanged(); dialog.dismiss() } } }
        dialog.show()
    }
    private fun createGroup() {
        val layout=column().apply { setPadding(dp(20),0,dp(20),0) }
        val name=EditText(this).apply { hint="그룹 이름"; setSingleLine(); layout.addView(this) }
        val relay=EditText(this).apply { hint="중계 주소 (선택사항 · 비워도 됨)"; setSingleLine(); inputType=android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_URI; layout.addView(this) }
        val dialog=AlertDialog.Builder(this).setTitle("새 동기화 그룹").setMessage("이미 사용 중인 그룹이 있다면 QR로 참여하세요. 새 그룹은 별도 클립보드를 만들고 동기화를 켜 QR을 준비합니다. Mac이나 임시 터널 주소는 필요하지 않습니다.").setView(layout).setPositiveButton("만들기",null).setNegativeButton("취소",null).create()
        dialog.setOnShowListener { dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { safely { val group=Group.create(name.text.toString().trim(),relay.text.toString().trim()); store.saveGroup(group); enableSync(); updateState(); dialog.dismiss(); showInvite(group) } } }
        dialog.show()
    }
    private fun scanQr() {
        try { startActivityForResult(Intent(this,QrScanActivity::class.java),QR_SCAN_REQUEST) }
        catch(error:Exception) { scanFailure(error.javaClass.simpleName) }
        catch(error:LinkageError) { scanFailure(error.javaClass.simpleName) }
    }
    private fun scanFailure(code:String) {
        getSharedPreferences("clipmesh.scan",MODE_PRIVATE).edit().putString("last_error",code.take(80)).apply()
        AlertDialog.Builder(this).setTitle("QR 스캔을 열지 못했습니다")
            .setMessage("QR 사진 가져오기나 고급 설정의 초대 링크로 참여해 주세요.\n진단: $code")
            .setPositiveButton("확인",null).show()
    }
    @Deprecated("Native Activity result compatibility")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==QR_SCAN_REQUEST) {
            if(resultCode==RESULT_OK) data?.getStringExtra("SCAN_RESULT")?.let { confirmJoin(it) }
            return
        }
        if(requestCode==QR_IMAGE_REQUEST && resultCode==RESULT_OK) data?.data?.let { importQr(it) }
    }
    private fun importQr(uri:android.net.Uri) {
        Thread {
            try {
                val bytes=contentResolver.openInputStream(uri)?.use { ImageClipboard.readBounded(it) } ?: error("이미지를 열 수 없습니다")
                val bounds=android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds=true }
                android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
                require(bounds.outWidth>0 && bounds.outHeight>0 && bounds.outWidth.toLong()*bounds.outHeight<=40_000_000) { "QR 사진이 너무 큽니다" }
                val options=android.graphics.BitmapFactory.Options().apply { inSampleSize=1; while(bounds.outWidth/inSampleSize>2048 || bounds.outHeight/inSampleSize>2048) inSampleSize=if(inSampleSize<1) 2 else inSampleSize*2 }
                val bitmap=android.graphics.BitmapFactory.decodeByteArray(bytes,0,bytes.size,options) ?: error("이미지를 읽을 수 없습니다")
                val value=try {
                    val pixels=IntArray(bitmap.width*bitmap.height)
                    bitmap.getPixels(pixels,0,bitmap.width,0,0,bitmap.width,bitmap.height)
                    QrDecoder.decode(bitmap.width,bitmap.height,pixels)
                } finally { bitmap.recycle() }
                runOnUiThread { if(!isFinishing && !isDestroyed) confirmJoin(value) }
            } catch(error:Exception) { runOnUiThread { if(!isFinishing && !isDestroyed) scanFailure(error.javaClass.simpleName) } }
            catch(_:OutOfMemoryError) { runOnUiThread { if(!isFinishing && !isDestroyed) scanFailure("ImageMemoryLimit") } }
        }.start()
    }
    companion object { private const val QR_SCAN_REQUEST=4301; private const val QR_IMAGE_REQUEST=4302 }
    private fun confirmJoin(value:String)=safely {
        val group=Group.fromInvite(value)
        AlertDialog.Builder(this).setTitle("${group.name} 그룹에 참여할까요?")
            .setMessage("참여한 기기 사이에 클립보드를 공유합니다. 동기화가 꺼져 있으면 참여 후 켜주세요.")
            .setPositiveButton("참여") { _,_ -> safely { store.saveGroup(group); configurationChanged() } }.setNegativeButton("취소",null).show()
    }
    private fun showInvite(group:Group) {
        if(group.transport=="p2p" && store.endpointIds(group.id).isEmpty()) {
            if(!store.enabled || store.paused) {
                AlertDialog.Builder(this).setTitle("QR 연결 준비")
                    .setMessage("이 기기의 연결 ID를 만들려면 동기화를 켜야 합니다.")
                    .setPositiveButton("켜고 QR 준비") { _,_ -> safely { enableSync(); waitForInvite(group) } }.setNegativeButton("취소",null).show()
            } else waitForInvite(group)
            return
        }
        renderInvite(group.withPairingSeeds(store.endpointIds(group.id)))
    }
    private fun waitForInvite(group:Group) {
        val dialog=AlertDialog.Builder(this).setTitle("연결 QR 준비 중").setMessage("기기의 연결 ID를 준비하고 있습니다…").setNegativeButton("취소",null).show()
        val started=SystemClock.elapsedRealtime()
        val task=object:Runnable { override fun run() {
            if(isFinishing || isDestroyed || !dialog.isShowing) return
            if(store.active()?.id!=group.id) { dialog.dismiss(); return }
            val ids=store.endpointIds(group.id)
            if(ids.isNotEmpty()) { dialog.dismiss(); safely { renderInvite(group.withPairingSeeds(ids)) }; return }
            if(SystemClock.elapsedRealtime()-started>15_000) {
                dialog.dismiss()
                AlertDialog.Builder(this@MainActivity).setTitle("연결 ID 준비가 지연됩니다")
                    .setMessage("동기화를 껐다 켠 뒤 QR을 다시 열어주세요. 고급 설정에서 전송 모듈 상태를 확인할 수 있습니다.")
                    .setPositiveButton("확인",null).show()
                return
            }
            handler.postDelayed(this,300)
        } }
        handler.post(task)
    }
    private fun renderInvite(original:Group) {
        val group=if(original.transport=="p2p" && store.endpointIds(original.id).isNotEmpty()) original.copy(relay="",seeds=original.seeds.take(16)) else original
        val size=720
        val matrix=QrDecoder.encodeInvite(group,size).second
        val bitmap=Bitmap.createBitmap(size,size,Bitmap.Config.ARGB_8888)
        bitmap.setPixels(IntArray(size*size) { i -> if(matrix[i%size,i/size]) android.graphics.Color.BLACK else android.graphics.Color.WHITE },0,size,0,0,size,size)
        val layout=column().apply { setPadding(dp(16),dp(8),dp(16),dp(8)) }
        layout.addView(ImageView(this).apply { setImageBitmap(bitmap); adjustViewBounds=true; contentDescription="${group.name} 그룹 참여 QR" })
        label(layout,"다른 기기에서 ‘QR 스캔’을 누르세요. 신뢰하는 기기에만 보여주세요.",14f)
        AlertDialog.Builder(this).setTitle("${group.name} · 기기 연결").setView(layout)
            .setPositiveButton("초대 링크 공유") { _,_ -> startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT,group.invite()),"그룹 초대 공유")) }
            .setNegativeButton("닫기",null).show()
    }
    private fun safely(action:()->Unit) { try { action() } catch(e:Exception) { AlertDialog.Builder(this).setTitle("ClipMesh").setMessage(e.message ?: "작업을 완료할 수 없습니다").setPositiveButton("확인",null).show() } }
}
