package dev.clipmesh.android

import org.json.JSONObject

/** Server reachability and authenticated device sessions are separate evidence. */
data class ConnectionStatus(val connected:Boolean=false,val transport:String="reconnecting",val peers:Int?=null,val peerNames:List<String> = emptyList(),val selfId:String?=null,val seedIds:List<String> = emptyList()) {
    fun label():String {
        if(!connected) return if(transport=="helper-unavailable") "전송 모듈을 시작하지 못했습니다 · 앱 업데이트 또는 동기화를 다시 켜주세요" else "연결 중 · 다른 기기를 찾고 있습니다"
        val route=when(transport) { "p2p-direct" -> "기기 간 직접 연결"; "iroh-relay" -> "인터넷 중계 연결"; else -> "서버 연결" }
        return when(val count=peers) {
            null -> "$route · 연결 기기 수 확인 안 됨"
            0 -> "$route · 다른 기기를 기다리는 중"
            else -> "$route · 다른 기기 ${count}대 연결 확인"
        }
    }
    fun deviceLabel()=if(!connected || peerNames.isEmpty()) "" else "연결된 기기: "+peerNames.joinToString(" · ")
    companion object {
        fun parse(json:JSONObject)=ConnectionStatus(json.optBoolean("connected",false),json.optString("transport","reconnecting"),
            when { json.has("connected_peer_count") && !json.isNull("connected_peer_count") -> json.getInt("connected_peer_count").coerceAtLeast(0)
                json.has("peers") && !json.isNull("peers") -> json.getInt("peers").coerceAtLeast(0)
                else -> null },
            json.optJSONArray("peer_details")?.let { list -> (0 until minOf(list.length(),64)).mapNotNull { index ->
                val peer=list.optJSONObject(index) ?: return@mapNotNull null
                if(peer.optString("route") !in setOf("direct","relay")) return@mapNotNull null
                peer.optString("name").takeIf { it.isNotBlank() } ?: peer.optString("platform").takeIf { it.isNotBlank() } ?: "기기 "+peer.optString("id").take(8)
            } } ?: emptyList(),json.optString("self_id").takeIf(::isEndpointId),
            json.optJSONArray("seed_ids")?.let { ids -> (0 until minOf(ids.length(),32)).mapNotNull { i -> ids.optString(i).takeIf(::isEndpointId) }.distinct() } ?: emptyList())
    }
}
