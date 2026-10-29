package dev.clipmesh.android

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.*
import com.google.zxing.BarcodeFormat
import com.google.zxing.ResultPoint
import com.journeyapps.barcodescanner.*

/** Native Activity: does not load IntentIntegrator's optional Fragment classes or CaptureManager. */
class QrScanActivity:Activity() {
    private var camera:DecoratedBarcodeView?=null
    private var resumed=false
    private var failed=false
    private var delivered=false
    private lateinit var root:LinearLayout
    private lateinit var help:TextView
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        root=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setPadding(20,28,20,20) }
        help=TextView(this).apply { text="다른 기기의 ClipMesh QR을 비춰주세요"; textSize=18f; setPadding(8,12,8,12); root.addView(this) }
        root.addView(Button(this).apply { text="취소"; setOnClickListener { finish() } })
        setContentView(root)
        if(checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) createCamera()
        else requestPermissions(arrayOf(Manifest.permission.CAMERA),CAMERA_REQUEST)
    }
    private fun createCamera() {
        if(camera!=null || failed || isFinishing) return
        guarded {
            val view=DecoratedBarcodeView(this)
            camera=view
            view.barcodeView.setUseTextureView(false)
            view.setStatusText("ClipMesh 그룹 QR")
            view.setDecoderFactory(DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE)))
            view.barcodeView.addStateListener(object:CameraPreview.StateListener {
                override fun previewSized() {}
                override fun previewStarted() {}
                override fun previewStopped() {}
                override fun cameraClosed() {}
                override fun cameraError(error:Exception) { runOnUiThread { showFailure(error.javaClass.simpleName) } }
            })
            view.decodeContinuous(object:BarcodeCallback {
                override fun barcodeResult(result:BarcodeResult) {
                    if(delivered || failed) return
                    val value=result.text ?: return
                    if(value.length>8192 || !value.startsWith("clipmesh://join#")) { help.text="ClipMesh 그룹 QR을 스캔해 주세요"; return }
                    delivered=true
                    setResult(RESULT_OK,Intent().putExtra("SCAN_RESULT",value))
                    finish()
                }
                override fun possibleResultPoints(resultPoints:MutableList<ResultPoint>?) {}
            })
            root.addView(view,0,LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,0,1f))
            if(resumed) view.resume()
        }
    }
    private fun guarded(action:()->Unit) {
        try { action() } catch(error:Exception) { showFailure(error.javaClass.simpleName) }
        catch(error:LinkageError) { showFailure(error.javaClass.simpleName) }
    }
    private fun showFailure(code:String) {
        if(failed || delivered || isFinishing || isDestroyed) return
        failed=true
        // Exception class only: never persist camera frames, QR data, URIs or stack contents.
        getSharedPreferences("clipmesh.scan",MODE_PRIVATE).edit().putString("last_error",code.take(80)).apply()
        try { camera?.pause() } catch(_:Exception) {} catch(_:LinkageError) {}
        camera?.let { root.removeView(it) }; camera=null
        help.text="카메라를 열지 못했습니다. 카메라 권한을 확인해 주세요. 뒤로 돌아가 QR 사진 가져오기나 고급 설정의 초대 링크로도 참여할 수 있습니다.\n진단: $code"
        setResult(RESULT_CANCELED,Intent().putExtra("SCAN_ERROR",code))
    }
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<out String>,grantResults:IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==CAMERA_REQUEST) {
            if(grantResults.firstOrNull()==PackageManager.PERMISSION_GRANTED) createCamera() else showFailure("CameraPermissionDenied")
        }
    }
    override fun onResume() { super.onResume(); resumed=true; if(!failed && !delivered) guarded { camera?.resume() } }
    override fun onPause() { resumed=false; guarded { camera?.pause() }; super.onPause() }
    companion object { private const val CAMERA_REQUEST=12 }
}
