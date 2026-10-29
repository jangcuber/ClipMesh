import Foundation

/// Pure presentation mapping: relay connectivity alone never becomes a fake device count.
struct DashboardState {
    var title: String
    var detail: String
    var peers: String
    static func make(config: Configuration, status: [String: Any]?, now: Date = Date()) -> DashboardState {
        guard config.active != nil else { return .init(title: "기기 연결을 시작하세요", detail: "다른 기기의 QR을 스캔해 같은 그룹에 참여하세요.", peers: "연결된 기기 확인 전") }
        if config.paused { return .init(title: "동기화 꺼짐", detail: "아래 스위치를 켜면 텍스트와 이미지가 동기화됩니다.", peers: "동기화가 꺼져 있습니다") }
        if (status?["group_id"] as? String).map({ $0 != config.active_group }) == true || ((status?["group_id"] as? String) == nil && (status?["group"] as? String).map({ $0 != config.active?.name }) == true) {
            return .init(title: "그룹 연결 전환 중", detail: "선택한 그룹의 연결 상태를 확인하고 있습니다.", peers: "연결된 기기 확인 중")
        }
        let updated = status?["updated_ms"] as? Double ?? 0
        guard updated > 0, now.timeIntervalSince1970 * 1000 - updated < 10_000 else {
            return .init(title: "연결 상태 확인 중", detail: "상태가 갱신되지 않으면 리스프링 후 다시 확인하세요.", peers: "연결된 기기 확인 중")
        }
        let raw = status?["status"] as? String ?? ""
        let route = status?["transport"] as? String ?? ""
        let online = raw.hasPrefix("Connected")
        let title = online ? "동기화 준비됨" : raw == "Connecting" ? "기기에 연결 중" : "연결을 다시 시도하는 중"
        let detail: String
        if route == "p2p-direct" || raw.contains("direct P2P") { detail = "기기끼리 직접 연결 · 텍스트와 이미지 동기화" }
        else if route == "iroh-relay" || raw.contains("encrypted relay") { detail = "암호화 릴레이로 연결 · 텍스트와 이미지 동기화" }
        else if online { detail = "릴레이에 연결됨 · 직접 연결을 사용할 수 없으면 자동으로 이어집니다" }
        else { detail = "인터넷 연결과 다른 기기의 동기화 상태를 확인하세요." }
        let count = status?["connected_peer_count"] as? Int
        let peers = count.map { $0 > 0 ? "연결된 다른 기기 \($0)대" : "연결된 다른 기기를 기다리는 중" } ?? "연결된 기기 수 확인 중"
        return .init(title: title, detail: detail, peers: peers)
    }
    static func peerDescription(_ peer: [String: Any]) -> String {
        let name = (peer["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "이름 없는 기기"
        let platform = ["macos": "Mac", "windows": "Windows", "ios": "iPhone", "android": "Android"][peer["platform"] as? String ?? ""] ?? "기기"
        let route = ["direct": "직접 연결", "relay": "암호화 릴레이", "connecting": "연결 중"][peer["route"] as? String ?? ""] ?? "연결 확인 중"
        return "\(name) · \(platform) · \(route)"
    }
}
