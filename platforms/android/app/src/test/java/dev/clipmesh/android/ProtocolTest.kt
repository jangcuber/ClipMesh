package dev.clipmesh.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ProtocolTest {
    private fun fixture() = JSONObject(javaClass.classLoader!!.getResource("v1-vector.json")!!.readText())
    @Test fun decryptIndependentRustNodeFixture() {
        val vector=fixture()
        val group=Group.parse(vector.getJSONObject("group").put("v",1))
        assertEquals(vector.getString("groupId"),group.id)
        assertEquals(group.id,Group.fromInvite(vector.getString("uri")).id)
        val event=Wire.open(group,vector.getJSONObject("envelope").toString())
        assertEquals(vector.getJSONObject("event").getString("text"),event.text)
        assertEquals(vector.getJSONObject("event").getLong("clock"),event.clock)
        assertEquals(event,Wire.open(group,Wire.seal(group,event)))
    }
    @Test fun authenticationRejectsChangedCiphertextAndWrongKey() {
        val vector=fixture(); val group=Group.parse(vector.getJSONObject("group").put("v",1))
        val envelope=vector.getJSONObject("envelope")
        val encoded=envelope.getString("ciphertext")
        envelope.put("ciphertext",(if(encoded[0]=='A') "B" else "A")+encoded.substring(1))
        assertThrows(Exception::class.java) { Wire.open(group,envelope.toString()) }
        val wrong=Group(group.name,group.relay,ByteArray(32){42})
        assertThrows(Exception::class.java) { Wire.open(wrong,vector.getJSONObject("envelope").toString()) }
    }
    @Test fun deterministicConflictResolutionDoesNotUseWallClock() {
        val a=ClipEvent("00000000-0000-4000-8000-000000000001","00000000-0000-4000-8000-000000000001",2,100,"A")
        val b=a.copy(device="00000000-0000-4000-8000-000000000002",createdMs=1,text="B")
        assertTrue(b>a)
        assertTrue(a.copy(clock=3)>b)
        assertTrue(a.copy(id="00000000-0000-4000-8000-000000000002")>a)
    }
    @Test fun rejectsMalformedPairingAndOversizedPayload() {
        assertThrows(Exception::class.java) { Group.fromInvite("https://example.com/#secret") }
        assertThrows(Exception::class.java) { Group.create("test","ws://host.invalid/path") }
        assertThrows(Exception::class.java) { Group.create("test","ws://user:pass@host.invalid") }
        val group=Group.create("test","ws://127.0.0.1:8787")
        assertThrows(Exception::class.java) { Wire.seal(group,ClipEvent(UUID.randomUUID().toString(),UUID.randomUUID().toString(),1,0,"x".repeat(MAX_TEXT_BYTES+1))) }
    }
    @Test fun rejectsUnsafeAndFractionalClocks() {
        val event=ClipEvent(UUID.randomUUID().toString(),UUID.randomUUID().toString(),1,0,"text").json()
        assertThrows(Exception::class.java) { ClipEvent.parse(event.put("clock",1.5)) }
        assertThrows(Exception::class.java) { ClipEvent.parse(event.put("clock",MAX_CLOCK+1)) }
        assertThrows(Exception::class.java) { ClipEvent.parse(event.put("clock",MAX_CLOCK)) }
        assertEquals(MAX_CLOCK-1,ClipEvent.parse(event.put("clock",MAX_CLOCK-1)).clock)
        assertThrows(Exception::class.java) { ClipEvent.parse(event.put("clock","1")) }
    }
    @Test fun groupNamesUseUtf8ByteBoundaries() {
        val name="가".repeat(66)+"ab"
        assertEquals(200,name.toByteArray(Charsets.UTF_8).size)
        val group=Group.create(name,"ws://127.0.0.1:8787")
        assertEquals(name,Group.fromInvite(group.invite()).name)
        assertThrows(Exception::class.java) { Group.create(name+"c","ws://127.0.0.1:8787") }
        assertThrows(Exception::class.java) { Group.create("가".repeat(67),"ws://127.0.0.1:8787") }
    }
    @Test fun acceptsWorstCaseControlCharacterExpansion() {
        val group=Group.create("test","ws://127.0.0.1:8787")
        val event=ClipEvent(UUID.randomUUID().toString(),UUID.randomUUID().toString(),1,0,"\u0000".repeat(MAX_TEXT_BYTES))
        assertEquals(event,Wire.open(group,Wire.seal(group,event)))
    }

    private fun png()=java.util.Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=")
    @Test fun encryptedPngRoundTripAndHashSuppression() {
        val group=Group.create("images","wss://relay.example")
        val payload=java.util.Base64.getEncoder().encodeToString(png())
        val event=ClipEvent(UUID.randomUUID().toString(),UUID.randomUUID().toString(),1,0,payload,"image/png")
        assertEquals(event,Wire.open(group,Wire.seal(group,event)))
        assertEquals(payloadHash("image/png",payload),payloadHash("image/png",payload))
        assertNotEquals(payloadHash("text/plain",payload),payloadHash("image/png",payload))
        assertEquals("p2p",Group.fromInvite(group.invite()).transport)
    }
    @Test fun rejectsPngBombsBadBase64AndUnsupportedMime() {
        val payload=java.util.Base64.getEncoder().encodeToString(png())
        validatePayload("image/png",payload)
        assertThrows(Exception::class.java) { validatePayload("image/png","invalid!") }
        assertThrows(Exception::class.java) { validatePayload("image/jpeg",payload) }
        assertThrows(Exception::class.java) { validatePng(png().apply { this[0]=0 }) }
        assertThrows(Exception::class.java) { validatePng(png().apply { this[16]=127 }) }
        assertThrows(Exception::class.java) { validatePng(png().apply { this[16]=0; this[17]=0; this[18]=0; this[19]=0 }) }
        assertThrows(Exception::class.java) { validatePayload("image/png","A".repeat((MAX_IMAGE_BYTES+2)/3*4+4)) }
    }
    @Test fun decryptIndependentNodePngFixture() {
        val vector=JSONObject(javaClass.classLoader!!.getResource("v1-image-vector.json")!!.readText())
        val group=Group.parse(vector.getJSONObject("group").put("v",1))
        val event=Wire.open(group,vector.getJSONObject("envelope").toString())
        assertEquals("image/png",event.mime)
        assertEquals(vector.getJSONObject("event").getString("text"),event.text)
        assertEquals(vector.getJSONObject("event").getLong("clock"),event.clock)
        validatePayload(event.mime,event.text)
    }
}
