package dev.clipmesh.android

import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer

object QrDecoder {
    fun encodeInvite(group:Group,size:Int=720):Pair<String,com.google.zxing.common.BitMatrix> {
        var candidate=group.copy(seeds=group.seeds.take(16))
        while(true) {
            val invite=candidate.invite()
            try { return invite to com.google.zxing.qrcode.QRCodeWriter().encode(invite,BarcodeFormat.QR_CODE,size,size,mapOf(EncodeHintType.MARGIN to 3)) }
            catch(error:WriterException) {
                if(candidate.seeds.size<=1) throw IllegalArgumentException("QR에 담을 수 없는 초대입니다 · 초대 링크 공유를 사용하세요",error)
                // The first seed is this device; the rest can be learned over authenticated QUIC.
                candidate=candidate.copy(seeds=candidate.seeds.dropLast(1))
            }
        }
    }
    fun decode(width:Int,height:Int,pixels:IntArray):String {
        require(width>0 && height>0 && width.toLong()*height<=4_194_304 && pixels.size.toLong()==width.toLong()*height) { "QR 이미지가 너무 큽니다" }
        val reader=MultiFormatReader()
        try {
            val bitmap=BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width,height,pixels)))
            val value=reader.decode(bitmap,mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),DecodeHintType.TRY_HARDER to true)).text
            require(value.length<=8192 && value.startsWith("clipmesh://join#")) { "ClipMesh 그룹 QR이 아닙니다" }
            return value
        } finally { reader.reset() }
    }
}
