package dev.clipmesh.android

import org.json.JSONObject
import java.net.URI
import java.nio.charset.StandardCharsets.UTF_8
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

const val MAX_TEXT_BYTES = 1_048_576
const val MAX_IMAGE_BYTES = 8 * 1_048_576
const val MAX_FRAME_BYTES = 24 * 1_048_576 + 4096
const val MAX_CLOCK = 9_007_199_254_740_991L

data class Group(val name: String, val relay: String, val key: ByteArray, val transport:String = "relay",val seeds:List<String> = emptyList()) {
    val id: String get() = MessageDigest.getInstance("SHA-256").digest(key).joinToString("") { "%02x".format(it) }
    fun json() = JSONObject().put("v", 1).put("name", name).put("relay", relay).put("key", Base64.getEncoder().encodeToString(key)).apply { if(transport=="p2p") put("transport","p2p"); if(seeds.isNotEmpty()) put("seeds",org.json.JSONArray(seeds)) }
    fun invite(): String = "clipmesh://join#" + Base64.getUrlEncoder().withoutPadding().encodeToString(json().toString().toByteArray(UTF_8))
    val endpoint: String get() = relay.trimEnd('/') + "/v1/ws/" + id
    companion object {
        fun parse(json: JSONObject): Group {
            require(json.getInt("v") == 1) { "Unsupported pairing version" }
            val name = json.getString("name")
            require(name.isNotBlank() && name.toByteArray(UTF_8).size <= 200) { "Group name must contain 1–200 UTF-8 bytes" }
            val transport=json.optString("transport","relay")
            require(transport=="relay" || transport=="p2p") { "Unsupported transport" }
            val relay=json.optString("relay","").trimEnd('/')
            if(relay.isEmpty()) require(transport=="p2p") { "서버 주소가 없는 그룹은 P2P가 필요합니다" }
            else {
                val uri=URI(relay)
                require(uri.scheme in setOf("ws","wss") && !uri.host.isNullOrBlank() && uri.rawUserInfo==null && uri.rawQuery==null && uri.rawFragment==null && uri.rawPath.orEmpty().isEmpty()) { "Relay must be ws://host:port or wss://host" }
            }
            val array=json.optJSONArray("seeds")
            require(!json.has("seeds") || array!=null) { "Invalid endpoint list" }
            require((array?.length() ?: 0)<=32) { "Too many endpoint seeds" }
            val seeds=(0 until (array?.length() ?: 0)).map { index -> array!!.getString(index).also { require(isEndpointId(it)) { "Invalid endpoint identity" } } }.distinct()
            val key = Base64.getDecoder().decode(json.getString("key"))
            require(key.size == 32) { "Pairing key must be 32 bytes" }
            return Group(name,relay,key,transport,seeds)
        }
        fun fromInvite(value: String): Group {
            require(value.length <= 8192) { "Pairing invitation is too large" }
            val uri = URI(value.trim())
            require(uri.scheme == "clipmesh" && uri.host == "join" && uri.rawQuery == null) { "Invalid ClipMesh invitation" }
            val data = Base64.getUrlDecoder().decode(uri.rawFragment ?: error("Invitation has no key"))
            return parse(JSONObject(String(data, UTF_8)))
        }
        fun create(name: String, relay: String = ""): Group = parse(JSONObject().put("v",1).put("name",name).put("relay",relay).put("key",Base64.getEncoder().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })).put("transport","p2p"))
    }
}

data class ClipEvent(val id: String, val device: String, val clock: Long, val createdMs: Long, val text: String, val mime: String = "text/plain"): Comparable<ClipEvent> {
    override fun compareTo(other: ClipEvent): Int = compareValuesBy(this, other, { it.clock }, { it.device }, { it.id })
    fun json() = JSONObject().put("v",1).put("id",id).put("device",device).put("clock",clock).put("created_ms",createdMs).put("mime",mime).put("text",text)
    companion object {
        fun parse(json: JSONObject): ClipEvent {
            require(json.getInt("v") == 1) { "Unsupported clipboard event" }
            val mime = json.getString("mime")
            val id = json.getString("id"); val device = json.getString("device")
            require(UUID.fromString(id).toString() == id && UUID.fromString(device).toString() == device) { "Invalid event identity" }
            val rawClock = json.get("clock")
            val rawCreated = json.get("created_ms")
            require(rawClock is Number && rawCreated is Number && rawClock.toString().matches(Regex("[1-9][0-9]{0,15}")) && rawCreated.toString().matches(Regex("[0-9]{1,16}"))) { "Invalid event clock" }
            val clock = rawClock.toString().toLong(); val created = rawCreated.toString().toLong()
            require(clock in 1 until MAX_CLOCK && created in 0..MAX_CLOCK) { "Invalid event clock" }
            val text = json.getString("text")
            validatePayload(mime,text)
            return ClipEvent(id,device,clock,created,text,mime)
        }
    }
}

object Wire {
    fun seal(group: Group, event: ClipEvent, nonce: ByteArray = ByteArray(12).also { SecureRandom().nextBytes(it) }): String {
        require(nonce.size == 12)
        validatePayload(event.mime,event.text)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(group.key,"AES"), GCMParameterSpec(128,nonce))
        cipher.updateAAD("clipmesh:v1:${group.id}".toByteArray(UTF_8))
        val encrypted = cipher.doFinal(event.json().toString().toByteArray(UTF_8))
        return JSONObject().put("v",1).put("group",group.id).put("nonce",Base64.getEncoder().encodeToString(nonce)).put("ciphertext",Base64.getEncoder().encodeToString(encrypted)).toString()
    }
    fun open(group: Group, frame: String): ClipEvent {
        require(frame.toByteArray(UTF_8).size <= MAX_FRAME_BYTES) { "Encrypted frame too large" }
        val json = JSONObject(frame)
        require(json.getInt("v") == 1 && json.getString("group") == group.id) { "Wrong group" }
        val nonce = Base64.getDecoder().decode(json.getString("nonce"))
        require(nonce.size == 12) { "Invalid nonce" }
        val encrypted = Base64.getDecoder().decode(json.getString("ciphertext"))
        require(encrypted.size in 16..(MAX_FRAME_BYTES - 100))
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE,SecretKeySpec(group.key,"AES"),GCMParameterSpec(128,nonce))
        cipher.updateAAD("clipmesh:v1:${group.id}".toByteArray(UTF_8))
        return ClipEvent.parse(JSONObject(String(cipher.doFinal(encrypted),UTF_8)))
    }
}

/** Bounds checked before any bitmap allocation. PNG pixels are decoded by Android only after this. */
fun validatePayload(mime:String,text:String) {
    when(mime) {
        "text/plain" -> require(text.toByteArray(UTF_8).size <= MAX_TEXT_BYTES) { "Clipboard text exceeds 1 MiB" }
        "image/png" -> {
            require(text.length <= (MAX_IMAGE_BYTES + 2) / 3 * 4) { "Clipboard image exceeds 8 MiB" }
            validatePng(Base64.getDecoder().decode(text))
        }
        else -> error("Unsupported clipboard MIME type")
    }
}
fun validatePng(bytes:ByteArray) {
    require(bytes.size in 33..MAX_IMAGE_BYTES) { "Clipboard image exceeds 8 MiB or is incomplete" }
    require(bytes.copyOfRange(0,8).contentEquals(byteArrayOf(-119,80,78,71,13,10,26,10))) { "Invalid PNG signature" }
    require(bytes.copyOfRange(8,16).contentEquals(byteArrayOf(0,0,0,13,73,72,68,82))) { "Missing PNG dimensions" }
    fun dimension(offset:Int):Long = (0 until 4).fold(0L) { a,i -> (a shl 8) or (bytes[offset+i].toLong() and 255) }
    val width=dimension(16); val height=dimension(20)
    require(width in 1..16384 && height in 1..16384 && width*height <= 40_000_000) { "Image dimensions exceed 40 megapixels" }
}
fun payloadHash(mime:String,text:String):String {
    val bytes=if(mime=="image/png") Base64.getDecoder().decode(text) else text.toByteArray(UTF_8)
    return mime+":"+Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-256").digest(bytes))
}

fun isEndpointId(value:String)=value.matches(Regex("[a-f0-9]{64}"))
fun Group.withPairingSeeds(identities:List<String>):Group {
    require(identities.size<=32 && identities.all(::isEndpointId)) { "Invalid endpoint seed list" }
    return copy(seeds=(identities+seeds).distinct().take(32))
}
