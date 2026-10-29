package dev.clipmesh.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Keys and latest-event text are encrypted at rest with an app-private Android Keystore key. */
class ConfigStore(context: Context) {
    val appContext:Context = context.applicationContext
    private val prefs = context.getSharedPreferences("clipmesh", Context.MODE_PRIVATE)
    private val alias = "clipmesh.local.v1"
    private fun secret(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias,null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    private fun encrypt(text: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE,secret()) }
        return Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(text.toByteArray(Charsets.UTF_8)))
    }
    private fun decrypt(value: String): String {
        val bytes = Base64.getDecoder().decode(value)
        require(bytes.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE,secret(),GCMParameterSpec(128,bytes.copyOfRange(0,12))) }
        return String(cipher.doFinal(bytes.copyOfRange(12,bytes.size)),Charsets.UTF_8)
    }
    @Synchronized fun groups(): List<Group> {
        val raw = prefs.getString("groups",null) ?: return emptyList()
        val list = JSONArray(decrypt(raw))
        return (0 until list.length()).map { Group.parse(list.getJSONObject(it)) }
    }
    @Synchronized fun saveGroup(group: Group) {
        val all = groups().filter { it.id != group.id } + group
        prefs.edit().putString("groups",encrypt(JSONArray().apply { all.forEach { put(it.json()) } }.toString())).putString("active",group.id).commit()
    }
    @Synchronized fun removeGroup(id: String) {
        val remaining = groups().filter { it.id != id }
        prefs.edit().putString("groups",encrypt(JSONArray().apply { remaining.forEach { put(it.json()) } }.toString()))
            .remove("state.$id").remove("endpoints.$id").putString("active",remaining.firstOrNull()?.id).commit()
    }
    @Synchronized fun rememberEndpoints(groupId:String,selfId:String?,seedIds:List<String>) {
        if(selfId==null || !isEndpointId(selfId)) return
        val ids=(listOf(selfId)+seedIds.filter(::isEndpointId)).distinct().take(32)
        val encoded=JSONArray(ids).toString()
        if(prefs.getString("endpoints.$groupId",null)!=encoded) prefs.edit().putString("endpoints.$groupId",encoded).commit()
    }
    @Synchronized fun endpointIds(groupId:String):List<String> {
        val array=JSONArray(prefs.getString("endpoints.$groupId","[]"))
        return (0 until minOf(array.length(),32)).mapNotNull { array.optString(it).takeIf(::isEndpointId) }.distinct()
    }
    fun transportGroup(group:Group)=group.withPairingSeeds(endpointIds(group.id))
    fun active(): Group? = groups().firstOrNull { it.id == prefs.getString("active",null) }
    fun activate(id: String) { require(groups().any { it.id == id }); prefs.edit().putString("active",id).commit() }
    fun device(): String {
        prefs.getString("device",null)?.let { return it }
        return UUID.randomUUID().toString().also { prefs.edit().putString("device",it).commit() }
    }
    var enabled: Boolean get() = prefs.getBoolean("enabled",false); set(value) { prefs.edit().putBoolean("enabled",value).commit() }
    var paused: Boolean get() = prefs.getBoolean("paused",false); set(value) { prefs.edit().putBoolean("paused",value).commit() }
    @Synchronized fun state(group: Group): Pair<Long,ClipEvent?> {
        val value = prefs.getString("state.${group.id}",null) ?: return 0L to null
        val json = JSONObject(decrypt(value))
        return json.getLong("clock") to json.optJSONObject("event")?.let { ClipEvent.parse(it) }
    }
    @Synchronized fun saveState(group: Group, clock: Long, event: ClipEvent?) {
        val json = JSONObject().put("clock",clock)
        if (event != null) json.put("event",event.json())
        check(prefs.edit().putString("state.${group.id}",encrypt(json.toString())).commit()) { "Could not persist sync state" }
    }
}
