import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Camera Capture (custom AVCapture-based with explicit flash toggle)

extension AIInsights {
    /// Custom camera capture using AVCaptureSession. Provides explicit Flash
    /// (auto / on / off) and a shortcut to the photo library — UIImagePickerController
    /// hid those behind small icons that users missed.
    struct CameraCaptureView: UIViewControllerRepresentable {
        static let mealPhotoTarget = 3

        @Environment(\.dismiss) var dismiss
        var targetCount: Int = Self.mealPhotoTarget
        var onImagesCaptured: ([Data]) -> Void

        func makeUIViewController(context: Context) -> AICameraCaptureViewController {
            let vc = AICameraCaptureViewController()
            vc.targetCount = max(1, targetCount)
            vc.onCapturedBatch = { images in
                if !images.isEmpty {
                    onImagesCaptured(images)
                }
                dismiss()
            }
            vc.onCancel = { dismiss() }
            return vc
        }

        func updateUIViewController(_ uiViewController: AICameraCaptureViewController, context _: Context) {
            uiViewController.targetCount = max(1, targetCount)
        }
    }

    /// Standalone Photo Library picker. Used as the entry-point when the user wants
    /// to analyze an existing photo instead of taking one.
    struct PhotoLibraryPickerView: UIViewControllerRepresentable {
        @Environment(\.dismiss) var dismiss
        let selectionLimit: Int
        var onImagesPicked: ([Data]) -> Void

        init(selectionLimit: Int = 1, onImagesPicked: @escaping ([Data]) -> Void) {
            self.selectionLimit = max(1, selectionLimit)
            self.onImagesPicked = onImagesPicked
        }

        func makeUIViewController(context: Context) -> PHPickerViewController {
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = selectionLimit
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_: PHPickerViewController, context _: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        final class Coordinator: NSObject, PHPickerViewControllerDelegate {
            let parent: PhotoLibraryPickerView
            init(_ parent: PhotoLibraryPickerView) { self.parent = parent }

            func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
                guard !results.isEmpty else {
                    parent.dismiss()
                    return
                }

                let group = DispatchGroup()
                let lock = NSLock()
                var pickedImages: [(Int, Data)] = []

                for (idx, result) in results.enumerated() {
                    let provider = result.itemProvider
                    guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        defer { group.leave() }
                        guard let image = object as? UIImage,
                              let data = image.jpegData(compressionQuality: 0.7)
                        else { return }
                        lock.lock()
                        pickedImages.append((idx, data))
                        lock.unlock()
                    }
                }

                group.notify(queue: .main) { [weak self] in
                    let ordered = pickedImages
                        .sorted { $0.0 < $1.0 }
                        .map { $0.1 }
                    if !ordered.isEmpty {
                        self?.parent.onImagesPicked(ordered)
                    }
                    self?.parent.dismiss()
                }
            }
        }
    }

    /// Backing view-controller for `CameraCaptureView`.
    /// Stays open after each shot until `targetCount` (default 3) or Done.
    final class AICameraCaptureViewController: UIViewController, AVCapturePhotoCaptureDelegate, PHPickerViewControllerDelegate {
        var onCapturedBatch: (([Data]) -> Void)?
        var onCancel: (() -> Void)?
        var targetCount: Int = CameraCaptureView.mealPhotoTarget

        private let session = AVCaptureSession()
        private let photoOutput = AVCapturePhotoOutput()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var device: AVCaptureDevice?
        private var flashMode: AVCaptureDevice.FlashMode = .auto
        private weak var flashButton: UIButton?
        private weak var doneButton: UIButton?
        private weak var countLabel: UILabel?
        private weak var captureButton: UIButton?
        private weak var hintView: MealAngleHintView?
        private weak var hintCaption: UILabel?
        private var capturedJPEGs: [Data] = []
        private var isCapturing = false
        private var didFinish = false

        private var plannedAngles: [MealCaptureAngle] {
            Array(MealCaptureAngle.allCases.prefix(max(1, targetCount)))
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()
            configureUI()
            showHint(for: plannedAngles.first ?? .topDown, flash: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                session.stopRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
        }

        private func configureSession() {
            guard let videoDevice = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: videoDevice)
            else { return }
            self.device = videoDevice

            session.beginConfiguration()
            session.sessionPreset = .photo
            if session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        private func configureUI() {
            let topBar = UIView()
            topBar.translatesAutoresizingMaskIntoConstraints = false
            topBar.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            view.addSubview(topBar)

            let cancel = UIButton(type: .system)
            cancel.setTitle(NSLocalizedString("Cancel", comment: "Cancel camera"), for: .normal)
            cancel.setTitleColor(.white, for: .normal)
            cancel.titleLabel?.font = .boldSystemFont(ofSize: 16)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            topBar.addSubview(cancel)

            let done = UIButton(type: .system)
            done.setTitle(NSLocalizedString("Done", comment: "Finish multi-photo camera"), for: .normal)
            done.setTitleColor(.white, for: .normal)
            done.titleLabel?.font = .boldSystemFont(ofSize: 16)
            done.translatesAutoresizingMaskIntoConstraints = false
            done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
            done.isEnabled = false
            done.alpha = 0.45
            topBar.addSubview(done)
            doneButton = done

            let count = UILabel()
            count.textColor = .white
            count.font = .boldSystemFont(ofSize: 15)
            count.textAlignment = .center
            count.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(count)
            countLabel = count

            let flash = UIButton(type: .system)
            flash.tintColor = .white
            flash.setImage(UIImage(systemName: "bolt.badge.a.fill"), for: .normal)
            flash.imageView?.contentMode = .scaleAspectFit
            flash.translatesAutoresizingMaskIntoConstraints = false
            flash.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
            topBar.addSubview(flash)
            flashButton = flash

            let hint = MealAngleHintView()
            hint.translatesAutoresizingMaskIntoConstraints = false
            hint.isUserInteractionEnabled = false
            view.addSubview(hint)
            hintView = hint

            let caption = UILabel()
            caption.textColor = .white
            caption.font = .systemFont(ofSize: 16, weight: .semibold)
            caption.textAlignment = .center
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.layer.shadowColor = UIColor.black.cgColor
            caption.layer.shadowOpacity = 0.8
            caption.layer.shadowRadius = 4
            view.addSubview(caption)
            hintCaption = caption

            let bottomBar = UIView()
            bottomBar.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.4)
            view.addSubview(bottomBar)

            let library = UIButton(type: .system)
            library.tintColor = .white
            library.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
            library.imageView?.contentMode = .scaleAspectFit
            library.translatesAutoresizingMaskIntoConstraints = false
            library.addTarget(self, action: #selector(libraryTapped), for: .touchUpInside)
            bottomBar.addSubview(library)

            let capture = UIButton(type: .system)
            capture.translatesAutoresizingMaskIntoConstraints = false
            capture.backgroundColor = .white
            capture.layer.cornerRadius = 36
            capture.layer.borderWidth = 4
            capture.layer.borderColor = UIColor.lightGray.cgColor
            capture.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
            bottomBar.addSubview(capture)
            captureButton = capture

            NSLayoutConstraint.activate([
                topBar.topAnchor.constraint(equalTo: view.topAnchor),
                topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                topBar.heightAnchor.constraint(equalToConstant: 96),

                cancel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
                cancel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -12),

                done.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
                done.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -12),

                flash.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -16),
                flash.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -12),
                flash.widthAnchor.constraint(equalToConstant: 32),
                flash.heightAnchor.constraint(equalToConstant: 32),

                count.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
                count.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -16),

                hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hint.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
                hint.widthAnchor.constraint(equalToConstant: 220),
                hint.heightAnchor.constraint(equalToConstant: 180),

                caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                caption.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
                caption.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
                caption.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

                bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                bottomBar.heightAnchor.constraint(equalToConstant: 140),

                capture.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
                capture.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                capture.widthAnchor.constraint(equalToConstant: 72),
                capture.heightAnchor.constraint(equalToConstant: 72),

                library.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 28),
                library.centerYAnchor.constraint(equalTo: capture.centerYAnchor),
                library.widthAnchor.constraint(equalToConstant: 36),
                library.heightAnchor.constraint(equalToConstant: 36)
            ])

            refreshChrome()
        }

        private func refreshChrome() {
            let taken = capturedJPEGs.count
            countLabel?.text = "\(taken)/\(targetCount)"
            doneButton?.isEnabled = taken > 0
            doneButton?.alpha = taken > 0 ? 1 : 0.45
            captureButton?.isEnabled = !isCapturing && taken < targetCount
            captureButton?.alpha = (taken < targetCount) ? 1 : 0.4
        }

        private func currentAngle() -> MealCaptureAngle {
            let index = min(capturedJPEGs.count, max(0, plannedAngles.count - 1))
            return plannedAngles[index]
        }

        private func showHint(for angle: MealCaptureAngle, flash: Bool) {
            hintView?.angle = angle
            hintCaption?.text = angle.instruction
            guard flash else {
                hintView?.alpha = 0.92
                hintCaption?.alpha = 1
                return
            }
            hintView?.alpha = 0
            hintCaption?.alpha = 0
            UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
                self.hintView?.alpha = 1
                self.hintCaption?.alpha = 1
            } completion: { _ in
                UIView.animate(withDuration: 0.28, delay: 0.85, options: [.curveEaseIn]) {
                    self.hintView?.alpha = 0.55
                    self.hintCaption?.alpha = 0.9
                }
            }
        }

        @objc private func cancelTapped() {
            guard !didFinish else { return }
            didFinish = true
            onCancel?()
        }

        @objc private func doneTapped() {
            finishIfNeeded()
        }

        @objc private func flashTapped() {
            switch flashMode {
            case .auto: flashMode = .on
            case .on: flashMode = .off
            case .off: flashMode = .auto
            @unknown default: flashMode = .auto
            }
            let iconName: String
            switch flashMode {
            case .auto: iconName = "bolt.badge.a.fill"
            case .on: iconName = "bolt.fill"
            case .off: iconName = "bolt.slash.fill"
            @unknown default: iconName = "bolt.badge.a.fill"
            }
            flashButton?.setImage(UIImage(systemName: iconName), for: .normal)
        }

        @objc private func captureTapped() {
            guard !isCapturing, capturedJPEGs.count < targetCount else { return }
            isCapturing = true
            refreshChrome()
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }

        @objc private func libraryTapped() {
            guard capturedJPEGs.count < targetCount else { return }
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = max(1, targetCount - capturedJPEGs.count)
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            present(picker, animated: true)
        }

        func photoOutput(
            _: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error _: Error?
        ) {
            let jpeg: Data?
            if let data = photo.fileDataRepresentation(),
               let image = UIImage(data: data)
            {
                jpeg = image.jpegData(compressionQuality: 0.7)
            } else {
                jpeg = photo.fileDataRepresentation()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isCapturing = false
                guard let jpeg else {
                    self.refreshChrome()
                    return
                }
                self.appendPhoto(jpeg)
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            let remaining = max(0, targetCount - capturedJPEGs.count)
            let group = DispatchGroup()
            let lock = NSLock()
            var picked: [(Int, Data)] = []
            for (idx, result) in results.prefix(remaining).enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage,
                          let data = image.jpegData(compressionQuality: 0.7)
                    else { return }
                    lock.lock()
                    picked.append((idx, data))
                    lock.unlock()
                }
            }
            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                for data in picked.sorted(by: { $0.0 < $1.0 }).map(\.1) {
                    self.appendPhoto(data)
                    if self.capturedJPEGs.count >= self.targetCount { break }
                }
            }
        }

        private func appendPhoto(_ data: Data) {
            guard !didFinish, capturedJPEGs.count < targetCount else { return }
            capturedJPEGs.append(data)
            isCapturing = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            refreshChrome()
            if capturedJPEGs.count >= targetCount {
                finishIfNeeded()
                return
            }
            showHint(for: currentAngle(), flash: true)
        }

        private func finishIfNeeded() {
            guard !didFinish else { return }
            didFinish = true
            let photos = capturedJPEGs
            onCapturedBatch?(photos)
        }
    }

    enum MealCaptureAngle: Int, CaseIterable {
        case topDown
        case side
        case otherSide

        var instruction: String {
            switch self {
            case .topDown:
                return NSLocalizedString("Top-down view", comment: "FoodFinder camera angle hint top-down")
            case .side:
                return NSLocalizedString("Side view", comment: "FoodFinder camera angle hint side")
            case .otherSide:
                return NSLocalizedString("Other side", comment: "FoodFinder camera angle hint other side")
            }
        }
    }

    /// Diagrammatic (not photoreal) overlay: plate + arrows for the next angle.
    final class MealAngleHintView: UIView {
        var angle: MealCaptureAngle = .topDown {
            didSet { setNeedsDisplay() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            backgroundColor = .clear
            isOpaque = false
        }

        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            ctx.clear(rect)
            let plate = CGRect(x: rect.midX - 54, y: rect.midY - 28, width: 108, height: 72)
            UIColor.white.withAlphaComponent(0.92).setStroke()
            let platePath = UIBezierPath(ovalIn: plate)
            platePath.lineWidth = 3
            platePath.stroke()
            let inner = plate.insetBy(dx: 10, dy: 8)
            UIBezierPath(ovalIn: inner).stroke()

            switch angle {
            case .topDown:
                drawArrow(from: CGPoint(x: rect.midX, y: plate.minY - 36), to: CGPoint(x: rect.midX, y: plate.minY - 4))
            case .side:
                drawArrow(from: CGPoint(x: plate.maxX + 36, y: plate.midY), to: CGPoint(x: plate.maxX + 6, y: plate.midY))
            case .otherSide:
                drawArrow(from: CGPoint(x: plate.minX - 36, y: plate.minY - 8), to: CGPoint(x: plate.minX - 4, y: plate.midY - 6))
            }
        }

        private func drawArrow(from: CGPoint, to: CGPoint) {
            UIColor.white.withAlphaComponent(0.95).setStroke()
            UIColor.white.withAlphaComponent(0.95).setFill()
            let line = UIBezierPath()
            line.move(to: from)
            line.addLine(to: to)
            line.lineWidth = 4
            line.lineCapStyle = .round
            line.stroke()

            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(1, hypot(dx, dy))
            let ux = dx / length
            let uy = dy / length
            let head: CGFloat = 12
            let left = CGPoint(x: to.x - ux * head - uy * 7, y: to.y - uy * head + ux * 7)
            let right = CGPoint(x: to.x - ux * head + uy * 7, y: to.y - uy * head - ux * 7)
            let triangle = UIBezierPath()
            triangle.move(to: to)
            triangle.addLine(to: left)
            triangle.addLine(to: right)
            triangle.close()
            triangle.fill()
        }
    }

    // MARK: - Barcode Scanner View (AVFoundation)

    /// A SwiftUI wrapper around AVCaptureSession for scanning barcodes.
    /// When `dismissOnScan` is false the session stays open so multiple
    /// products can be attached to one in-progress meal; the user dismisses
    /// with Done when finished.
    struct BarcodeScannerView: UIViewControllerRepresentable {
        @Environment(\.dismiss) var dismiss
        var dismissOnScan: Bool = true
        var onBarcodeScanned: (String) -> Void

        func makeUIViewController(context: Context) -> BarcodeScannerViewController {
            let vc = BarcodeScannerViewController()
            vc.dismissOnScan = dismissOnScan
            vc.onBarcodeScanned = { barcode in
                onBarcodeScanned(barcode)
                if dismissOnScan {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        dismiss()
                    }
                }
            }
            vc.onCancel = {
                dismiss()
            }
            return vc
        }

        func updateUIViewController(_: BarcodeScannerViewController, context _: Context) {}
    }

    class BarcodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onBarcodeScanned: ((String) -> Void)?
        var onCancel: (() -> Void)?
        var dismissOnScan: Bool = true

        private var captureSession: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var captureDevice: AVCaptureDevice?
        private weak var torchButton: UIButton?
        private weak var scanFrameView: UIView?
        private weak var instructionLabel: UILabel?
        private var hasScanned = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            let session = AVCaptureSession()

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device)
            else {
                showError()
                return
            }
            captureDevice = device

            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.ean8, .ean13, .upce, .code128, .code39, .code93, .qr]
            }

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.layer.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            previewLayer = preview

            captureSession = session

            // Cancel / Done button
            let cancelButton = UIButton(type: .system)
            let cancelTitle = dismissOnScan
                ? NSLocalizedString("Cancel", comment: "Cancel barcode scan")
                : NSLocalizedString("Done", comment: "Finish barcode scanning")
            cancelButton.setTitle(cancelTitle, for: .normal)
            cancelButton.setTitleColor(.white, for: .normal)
            cancelButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
            cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            cancelButton.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancelButton)
            NSLayoutConstraint.activate([
                cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
                cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
            ])

            // Torch / flashlight button (only if the device has a torch)
            if device.hasTorch {
                let torch = UIButton(type: .system)
                torch.tintColor = .white
                torch.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
                torch.translatesAutoresizingMaskIntoConstraints = false
                torch.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
                view.addSubview(torch)
                NSLayoutConstraint.activate([
                    torch.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
                    torch.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                    torch.widthAnchor.constraint(equalToConstant: 32),
                    torch.heightAnchor.constraint(equalToConstant: 32)
                ])
                torchButton = torch
            }

            // Scan frame overlay
            let frameView = UIView()
            frameView.layer.borderColor = UIColor.systemBlue.cgColor
            frameView.layer.borderWidth = 2
            frameView.layer.cornerRadius = 12
            frameView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(frameView)
            scanFrameView = frameView
            NSLayoutConstraint.activate([
                frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                frameView.widthAnchor.constraint(equalToConstant: 280),
                frameView.heightAnchor.constraint(equalToConstant: 140)
            ])

            // Instruction label
            let label = UILabel()
            label.text = dismissOnScan
                ? NSLocalizedString("Point at a barcode", comment: "Barcode scanner instruction")
                : NSLocalizedString("Scan products, then tap Done", comment: "Barcode scanner multi-scan instruction")
            label.textColor = .white
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            instructionLabel = label
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 20)
            ])

            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
        }

        @objc private func cancelTapped() {
            captureSession?.stopRunning()
            disableTorch()
            onCancel?()
        }

        @objc private func torchTapped() {
            guard let device = captureDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if device.torchMode == .on {
                    device.torchMode = .off
                    torchButton?.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
                } else {
                    try device.setTorchModeOn(level: 1.0)
                    torchButton?.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
                }
                device.unlockForConfiguration()
            } catch {
                // Silently ignore torch errors (e.g. device too hot, permission denied).
            }
        }

        private func disableTorch() {
            guard let device = captureDevice, device.hasTorch, device.torchMode == .on else { return }
            try? device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            disableTorch()
        }

        func metadataOutput(
            _: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from _: AVCaptureConnection
        ) {
            guard !hasScanned,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let barcode = object.stringValue
            else { return }

            hasScanned = true

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            showScanSuccess()
            onBarcodeScanned?(barcode)

            if dismissOnScan {
                captureSession?.stopRunning()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.resetForNextScan()
                }
            }
        }

        private func showScanSuccess() {
            scanFrameView?.layer.borderColor = UIColor.systemGreen.cgColor
            scanFrameView?.layer.borderWidth = 4
            instructionLabel?.text = NSLocalizedString("Barcode scanned", comment: "Barcode scanner success")
            instructionLabel?.textColor = .systemGreen

            let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
            check.tintColor = .systemGreen
            check.contentMode = .scaleAspectFit
            check.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(check)
            NSLayoutConstraint.activate([
                check.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                check.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                check.widthAnchor.constraint(equalToConstant: 56),
                check.heightAnchor.constraint(equalToConstant: 56)
            ])
            check.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
            check.alpha = 0
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                check.alpha = 1
                check.transform = .identity
            }
            check.tag = 9_401
        }

        private func resetForNextScan() {
            hasScanned = false
            scanFrameView?.layer.borderColor = UIColor.systemBlue.cgColor
            scanFrameView?.layer.borderWidth = 2
            instructionLabel?.text = NSLocalizedString("Scan products, then tap Done", comment: "Barcode scanner multi-scan instruction")
            instructionLabel?.textColor = .white
            view.viewWithTag(9_401)?.removeFromSuperview()
            if captureSession?.isRunning == false {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.captureSession?.startRunning()
                }
            }
        }

        private func showError() {
            let label = UILabel()
            label.text = NSLocalizedString("Camera not available", comment: "Camera error")
            label.textColor = .white
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
    }
}
