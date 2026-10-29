package dev.clipmesh.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerlessGroupTest {
    @Test fun newGroupsNeedNoRelayAndRoundTripSeedsWithoutRekey() {
        val group=Group.create("내 기기")
        assertEquals("",group.relay); assertEquals("p2p",group.transport)
        val ids=listOf("a".repeat(64),"b".repeat(64))
        val invite=Group.fromInvite(group.withPairingSeeds(ids).invite())
        assertEquals(group.id,invite.id); assertArrayEquals(group.key,invite.key)
        assertEquals(ids,invite.seeds); assertEquals("",invite.relay)
    }
    @Test fun acceptsLegacyGroupsButEmptyRelayRequiresP2P() {
        val legacy=Group.create("legacy","wss://relay.example").json().apply { remove("transport") }
        assertEquals("relay",Group.parse(legacy).transport)
        assertThrows(Exception::class.java) { Group.parse(legacy.put("relay","")) }
        assertThrows(Exception::class.java) { Group.parse(legacy.put("transport","invalid")) }
    }
    @Test fun rejectsUnboundedOrMalformedPublicEndpointIds() {
        val group=Group.create("bounded").json()
        assertThrows(Exception::class.java) { Group.parse(group.put("seeds",JSONArray(List(33) { "a".repeat(64) }))) }
        assertThrows(Exception::class.java) { Group.parse(group.put("seeds",JSONArray().put("a".repeat(63)))) }
        assertThrows(Exception::class.java) { Group.parse(group.put("seeds",JSONArray().put("A".repeat(64)))) }
        assertThrows(Exception::class.java) { Group.parse(group.put("seeds","not an array")) }
    }
    @Test fun seedsAreBoundedUniqueAndNativeStatusDoesNotInventPresence() {
        val id="a".repeat(64)
        val status=ConnectionStatus.parse(JSONObject().put("connected",false).put("self_id",id).put("seed_ids",JSONArray().put(id).put(id).put("bad")))
        assertEquals(id,status.selfId); assertEquals(listOf(id),status.seedIds)
        assertFalse(status.connected); assertNull(status.peers)
        assertEquals(listOf(id),Group.create("dedup").withPairingSeeds(listOf(id,id)).seeds)
    }
    @Test fun rebootNeverEnablesUserStoppedOrPausedSync() {
        assertTrue(shouldAutoStart(true,false,true))
        assertFalse(shouldAutoStart(false,false,true))
        assertFalse(shouldAutoStart(true,true,true))
        assertFalse(shouldAutoStart(true,false,false))
    }
    @Test fun maximumAddressBookFitsQrWithoutDroppingOwnEndpoint() {
        val seeds=(1..32).map { it.toString(16).padStart(64,'0') }
        val group=Group.create("가".repeat(60)).copy(seeds=seeds)
        val encoded=QrDecoder.encodeInvite(group)
        val decoded=Group.fromInvite(encoded.first)
        assertEquals(group.id,decoded.id)
        assertEquals(seeds.first(),decoded.seeds.first())
        assertTrue(decoded.seeds.isNotEmpty() && decoded.seeds.size<=16)
    }
}
