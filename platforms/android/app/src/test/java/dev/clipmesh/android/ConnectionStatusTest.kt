package dev.clipmesh.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ConnectionStatusTest {
    @Test fun serverConnectionDoesNotInventPeers() {
        val status=ConnectionStatus.parse(JSONObject("""{"connected":true,"transport":"websocket","known_peer_count":4}"""))
        assertNull(status.peers)
        assertTrue(status.label().contains("연결 기기 수 확인 안 됨"))
        assertFalse(status.label().contains("4대"))
    }
    @Test fun cacheCountNeverOverridesAuthenticatedCount() {
        val status=ConnectionStatus.parse(JSONObject("""{"connected":true,"transport":"p2p-direct","peers":9,"connected_peer_count":3,"known_peer_count":12}"""))
        assertEquals(3,status.peers)
        assertTrue(status.label().contains("다른 기기 3대"))
    }
    @Test fun noPeerAndReconnectAreExplicit() {
        assertTrue(ConnectionStatus(true,"websocket",0).label().contains("다른 기기를 기다리는 중"))
        assertTrue(ConnectionStatus(false,"p2p-direct",3).label().startsWith("연결 중"))
        assertTrue(ConnectionStatus(true,"iroh-relay",2).label().contains("인터넷 중계 연결"))
    }
    @Test fun onlyLiveAuthenticatedPeerNamesAreShown() {
        val status=ConnectionStatus.parse(JSONObject("""{"connected":true,"connected_peer_count":2,"peer_details":[{"name":"Mac","route":"direct"},{"name":"iPhone","route":"relay"},{"name":"Offline PC","route":"connecting"}]}"""))
        assertEquals(listOf("Mac","iPhone"),status.peerNames)
        assertFalse(status.deviceLabel().contains("Offline"))
    }
}
