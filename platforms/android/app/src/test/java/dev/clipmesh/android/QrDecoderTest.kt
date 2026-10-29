package dev.clipmesh.android

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.*
import org.junit.Test

class QrDecoderTest {
    private fun pixels(value:String):IntArray {
        val matrix=QRCodeWriter().encode(value,BarcodeFormat.QR_CODE,720,720)
        return IntArray(720*720) { i -> if(matrix[i%720,i/720]) -16777216 else -1 }
    }
    @Test fun localQrContainsExactGroupInvite() {
        val group=Group.create("맥과 갤럭시","wss://relay.example")
        val invite=group.invite()
        assertEquals(invite,QrDecoder.decode(720,720,pixels(invite)))
        assertEquals(group.id,Group.fromInvite(QrDecoder.decode(720,720,pixels(invite))).id)
    }
    @Test fun refusesOtherQrCodesAndOversizedBitmaps() {
        assertThrows(Exception::class.java) { QrDecoder.decode(720,720,pixels("https://example.com")) }
        assertThrows(Exception::class.java) { QrDecoder.decode(10000,10000,IntArray(1)) }
        assertThrows(Exception::class.java) { QrDecoder.decode(0,0,IntArray(0)) }
    }
}
