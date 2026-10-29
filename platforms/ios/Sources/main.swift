import UIKit
import CryptoKit

final class SettingsController: UITableViewController {
    private var config = Configuration.load()
    private var statusTimer: Timer?
    private var advanced = false
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ClipMesh"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: UIApplication.didBecomeActiveNotification, object: nil)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { statusTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
    @objc private func refresh() { config = Configuration.load(); if isViewLoaded && view.window != nil { tableView.reloadData() } }
    private var status: [String: Any]? {
        (try? Data(contentsOf: statusURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 3 : section == 1 ? 2 : advanced ? 6 : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { ["내 기기", "기기 추가", "설정"][section] }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "복사한 텍스트와 이미지가 같은 그룹의 기기에 자동으로 전달됩니다." }
        if section == 1 { return "다른 기기에서도 ClipMesh를 열고 QR을 스캔하세요. QR에는 그룹의 비밀키가 포함되어 있습니다." }
        return advanced ? "네트워크 설정은 그룹에 포함되어 자동으로 전달됩니다. 그룹을 삭제해도 다른 기기의 접근 권한은 취소되지 않습니다." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            if indexPath.row == 0 {
                let state = DashboardState.make(config: config, status: status)
                cell.textLabel?.text = state.title; cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
                cell.detailTextLabel?.text = state.detail + "\n" + state.peers
                cell.accessoryType = .disclosureIndicator
            } else if indexPath.row == 1 {
                cell.textLabel?.text = "현재 그룹"
                cell.detailTextLabel?.text = config.active?.name ?? "아직 참여한 그룹이 없습니다"
                cell.accessoryType = .disclosureIndicator
            } else {
                cell.textLabel?.text = "동기화 켜기"
                let toggle = UISwitch(); toggle.isOn = !config.paused
                toggle.addTarget(self, action: #selector(toggleSync(_:)), for: .valueChanged); cell.accessoryView = toggle
            }
        } else if indexPath.section == 1 {
            cell.textLabel?.text = indexPath.row == 0 ? "QR 스캔해서 참여" : "내 그룹 QR 보여주기"
            cell.imageView?.image = UIImage(systemName: indexPath.row == 0 ? "qrcode.viewfinder" : "qrcode")
            cell.accessoryType = .disclosureIndicator
        } else if indexPath.row == 0 {
            cell.textLabel?.text = advanced ? "고급 설정 접기" : "고급 설정"
            cell.imageView?.image = UIImage(systemName: "gearshape")
        } else if indexPath.row == 1 {
            cell.textLabel?.text = "초대 링크로 참여"; cell.accessoryType = .disclosureIndicator
        } else if indexPath.row == 2 {
            cell.textLabel?.text = "새 그룹 만들기"; cell.accessoryType = .disclosureIndicator
        } else if indexPath.row == 3 {
            cell.textLabel?.text = "직접 연결 우선"
            cell.detailTextLabel?.text = "연결이 어려우면 암호화 릴레이로 자동 전환"
            let toggle = UISwitch(); toggle.isOn = config.active?.transport == "p2p"; toggle.isEnabled = config.active != nil
            toggle.addTarget(self, action: #selector(toggleP2P(_:)), for: .valueChanged); cell.accessoryView = toggle
        } else if indexPath.row == 4 {
            cell.textLabel?.text = "릴레이 주소"
            cell.detailTextLabel?.text = config.active.map { $0.relay.isEmpty ? "주소 입력 없이 자동 연결" : $0.relay } ?? "그룹을 선택하세요"
        } else {
            cell.textLabel?.text = "현재 그룹을 이 기기에서 삭제"; cell.textLabel?.textColor = .systemRed
        }
        return cell
    }
    @objc private func toggleSync(_ sender: UISwitch) {
        config = Configuration.load()
        guard !sender.isOn || config.active != nil else { sender.isOn = false; show("먼저 QR을 스캔하거나 그룹을 만들어 주세요."); return }
        config.paused = !sender.isOn; save()
    }
    @objc private func toggleP2P(_ sender: UISwitch) {
        config = Configuration.load()
        guard let index = config.groups.firstIndex(where: { $0.id == config.active_group }) else { return }
        if !sender.isOn && config.groups[index].relay.isEmpty { sender.isOn = true; show("주소 없이 만든 그룹은 자동 직접 연결을 사용합니다."); return }
        config.groups[index].transport = sender.isOn ? "p2p" : nil; save()
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true); config = Configuration.load()
        if indexPath.section == 0 {
            if indexPath.row == 0 { showPeers() }
            if indexPath.row == 1 { chooseGroup() }
        } else if indexPath.section == 1 {
            if indexPath.row == 0 { scanPairing() } else { sharePairing() }
        } else {
            switch indexPath.row {
            case 0: advanced.toggle(); tableView.reloadSections(IndexSet(integer: 2), with: .automatic)
            case 1: join()
            case 2: create()
            case 5: removeActive()
            default: break
            }
        }
    }
    private func showPeers() {
        let details = status?["peer_details"] as? [[String: Any]] ?? []
        let state = DashboardState.make(config: config, status: status)
        show(state.peers + (details.isEmpty ? "" : "\n\n" + details.map(DashboardState.peerDescription).joined(separator: "\n")))
    }
    private func chooseGroup() {
        guard !config.groups.isEmpty else { scanPairing(); return }
        let alert = UIAlertController(title: "동기화할 그룹", message: "한 번에 한 그룹과 동기화합니다.", preferredStyle: .actionSheet)
        for group in config.groups {
            alert.addAction(UIAlertAction(title: (group.id == config.active_group ? "✓ " : "") + group.name, style: .default) { [weak self] _ in
                guard let self else { return }; self.config = Configuration.load()
                guard self.config.groups.contains(where: { $0.id == group.id }) else { self.refresh(); return }
                self.config.active_group = group.id; self.save()
            })
        }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel)); presentSheet(alert)
    }
    private func removeActive() {
        guard let active = config.active else { return }
        let alert = UIAlertController(title: "그룹 삭제", message: "이 기기에서 ‘\(active.name)’ 그룹을 삭제할까요?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.addAction(UIAlertAction(title: "삭제", style: .destructive) { [weak self] _ in
            guard let self else { return }; self.config = Configuration.load(); self.config.groups.removeAll { $0.id == active.id }
            if self.config.active_group == active.id { self.config.active_group = self.config.groups.first?.id ?? ""; self.config.paused = true }
            self.save()
        }); present(alert, animated: true)
    }
    private func join() {
        let alert = UIAlertController(title: "초대 링크로 참여", message: "다른 기기에서 받은 비공개 초대 링크를 붙여넣으세요.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "clipmesh://join#…"; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.addAction(UIAlertAction(title: "참여", style: .default) { [weak self, weak alert] _ in
            do { try self?.acceptInvitation(alert?.textFields?.first?.text ?? "") } catch { self?.show(error.localizedDescription) }
        }); present(alert, animated: true)
    }
    private func acceptInvitation(_ value: String) throws {
        let group = try Group.parse(value); config = Configuration.load()
        if let old = config.groups.firstIndex(where: { $0.id == group.id }) { config.groups[old] = group } else { config.groups.append(group) }
        config.active_group = group.id; config.paused = true; save(); show("그룹에 참여했습니다. ‘동기화 켜기’를 켜 주세요.")
    }
    private func scanPairing() {
        let scanner = PairingScanner()
        scanner.onInvitation = { [weak self, weak scanner] value in
            guard let self else { return }; self.navigationController?.popToViewController(self, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { do { try self.acceptInvitation(value) } catch { self.show(error.localizedDescription) } }
            scanner?.onInvitation = nil
        }; navigationController?.pushViewController(scanner, animated: true)
    }
    private func create() {
        let alert = UIAlertController(title: "새 그룹 만들기", message: "이름만 정하면 자동으로 연결을 준비합니다. 그룹을 만들면 동기화가 켜집니다.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "그룹 이름"; $0.text = "내 기기" }
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.addAction(UIAlertAction(title: "만들기", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            do {
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
                let group = Group(name: alert?.textFields?[0].text ?? "", relay: "", key: key, transport: "p2p")
                try group.validate(); self.config = Configuration.load()
                self.config.groups.append(group); self.config.active_group = group.id; self.config.paused = false; self.save(); self.sharePairing()
            } catch { self.show(error.localizedDescription) }
        }); present(alert, animated: true)
    }
    private func sharePairing() {
        config = Configuration.load()
        guard let selected = config.active else { show("먼저 그룹에 참여하거나 새 그룹을 만들어 주세요."); return }
        if selected.transport == "p2p" && config.paused { show("‘동기화 켜기’를 켠 다음 QR을 보여 주세요. 연결 정보를 자동으로 준비합니다."); return }
        let controller = PairingDisplayController()
        controller.groupProvider = {
            let latest = Configuration.load()
            guard var group = latest.groups.first(where: { $0.id == selected.id }) else { return nil }
            if group.transport == "p2p" {
                let value = (try? Data(contentsOf: statusURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                guard let exported = group.shareable(status: value) else { return nil }
                group = exported
            }
            return group
        }
        navigationController?.pushViewController(controller, animated: true)
    }
    private func presentSheet(_ alert: UIAlertController) {
        alert.popoverPresentationController?.sourceView = view; alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(alert, animated: true)
    }
    private func save() { do { try config.save(); tableView.reloadData() } catch { show("설정을 저장할 수 없습니다: \(error.localizedDescription)") } }
    private func show(_ message: String) {
        let alert = UIAlertController(title: "ClipMesh", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default)); present(alert, animated: true)
    }
}
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = UINavigationController(rootViewController: SettingsController(style: .insetGrouped)); window.makeKeyAndVisible(); self.window = window; return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
