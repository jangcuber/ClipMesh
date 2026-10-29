import UIKit
import AVFoundation
import CoreImage

/// The invitation is rendered locally; no group secret is sent to a QR service.
func pairingQRImage(_ value: String) -> UIImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(value.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage, let bitmap = CIContext().createCGImage(image, from: image.extent) else { return nil }
    return UIImage(cgImage: bitmap)
}

final class PairingScanner: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onInvitation: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.clipmesh.qr.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var accepted = false
    private let message = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "QR 스캔해서 참여"
        view.backgroundColor = .black
        message.text = "다른 기기의 ClipMesh에 표시된 QR을 카메라로 비추세요."
        message.textColor = .white; message.numberOfLines = 0; message.textAlignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)])
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                if allowed { self.configure() }
                else { self.message.text = "QR을 스캔하려면 카메라 접근을 허용해 주세요. 고급 설정에서 초대 링크로도 참여할 수 있습니다." }
            }
        }
    }
    private func configure() {
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            message.text = "카메라를 사용할 수 없습니다. 고급 설정에서 초대 링크로 참여해 주세요."; return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { message.text = "QR 스캐너를 사용할 수 없습니다."; return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(layer, at: 0); preview = layer
        view.setNeedsLayout()
        sessionQueue.async { [session] in session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); sessionQueue.async { [session] in session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !accepted else { return }
        let values = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard let value = values.first(where: { (try? Group.parse($0)) != nil }) else {
            if !values.isEmpty { message.text = "ClipMesh 초대 QR이 아닙니다." }; return
        }
        accepted = true
        sessionQueue.async { [session] in session.stopRunning() }
        onInvitation?(value)
    }
}

/// Wait for the running helper's durable endpoint identity before advertising a new group.
final class PairingDisplayController: UIViewController {
    var groupProvider: (() -> Group?)?
    private var timer: Timer?
    private let image = UIImageView()
    private let label = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad(); title = "내 그룹 QR"; view.backgroundColor = .systemBackground
        image.backgroundColor = .white; image.contentMode = .scaleAspectFit; image.layer.magnificationFilter = .nearest
        label.text = "연결 정보를 준비하고 있습니다…\n잠시만 기다려 주세요."; label.numberOfLines = 0; label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [image, label]); stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24), image.heightAnchor.constraint(equalToConstant: 280)])
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.update() }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); timer?.invalidate(); timer = nil }
    private func update() {
        guard let group = groupProvider?(), let qr = pairingQRImage(group.pairing) else { return }
        image.image = qr
        let independence = group.transport == "p2p" && group.relay.isEmpty ? "Mac이 꺼져 있어도 연결된 기기끼리 동기화합니다." : "같은 그룹의 기기에 연결합니다."
        label.text = "다른 기기에서 QR을 스캔하세요.\n\(group.name)\n\n\(independence)\n신뢰하는 기기에게만 보여 주세요."
    }
}
