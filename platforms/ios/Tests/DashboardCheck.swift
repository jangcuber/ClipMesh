import Foundation
@main struct DashboardCheck {
    static func main() throws {
        let group = Group(name: "내 기기", relay: "wss://example.com", key: Data(repeating: 4, count: 32).base64EncodedString(), transport: "p2p")
        var config = Configuration(device: UUID().uuidString.lowercased(), name: "iPhone", groups: [group], active_group: group.id, paused: false)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let direct: [String: Any] = ["updated_ms": time.timeIntervalSince1970 * 1000, "status": "Connected · direct P2P", "transport": "p2p-direct", "connected_peer_count": 3]
        var shown = DashboardState.make(config: config, status: direct, now: time)
        precondition(shown.title == "동기화 준비됨" && shown.peers.contains("3대") && shown.detail.contains("직접 연결"))
        let ws: [String: Any] = ["updated_ms": time.timeIntervalSince1970 * 1000, "status": "Connected · websocket", "transport": "websocket"]
        shown = DashboardState.make(config: config, status: ws, now: time)
        precondition(shown.peers == "연결된 기기 수 확인 중") // Relay is not an authenticated peer.
        shown = DashboardState.make(config: config, status: direct, now: time.addingTimeInterval(11))
        precondition(shown.title == "연결 상태 확인 중" && !shown.peers.contains("3대"))
        var otherGroup = direct; otherGroup["group"] = "다른 그룹"
        precondition(DashboardState.make(config: config, status: otherGroup, now: time).title == "그룹 연결 전환 중")
        config.paused = true
        precondition(DashboardState.make(config: config, status: direct, now: time).title == "동기화 꺼짐")
        config.groups = []; config.active_group = ""
        precondition(DashboardState.make(config: config, status: direct, now: time).title == "기기 연결을 시작하세요")
        precondition(DashboardState.peerDescription(["name": "작업 PC", "platform": "windows", "route": "direct"]) == "작업 PC · Windows · 직접 연결")
        print("PASS: Korean dashboard uses authenticated other-peer count, unknown relay count, stale-status guard, pause/unpaired states and peer labels")
    }
}
