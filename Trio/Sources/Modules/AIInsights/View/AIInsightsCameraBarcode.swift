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
        @Environment(\.dismiss) var dismiss
        var onImageCaptured: (Data) -> Void

        func makeUIViewController(context: Context) -> AICameraCaptureViewController {
            let vc = AICameraCaptureViewController()
            vc.onCaptured = { data in
                onImageCaptured(data)
                dismiss()
            }
            vc.onCancel = { dismiss() }
            vc.onPickFromLibrary = { data in
                onImageCaptured(data)
                dismiss()
            }
            return vc
        }

        func updateUIViewController(_: AICameraCaptureViewController, context _: Context) {}
    }

    /// Standalone Photo Library picker. Used as the entry-point when the user wants
    /// to analyze an existing photo instead of taking one.
    struct PhotoLibraryPickerView: UIViewControllerRepresentable {
        @Environment(\.dismiss) var dismiss
        var onImagePicked: (Data) -> Void

        func makeUIViewController(context: Context) -> PHPickerViewController {
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
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
                guard let result = results.first else {
                    parent.dismiss()
                    return
                }
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else {
                    parent.dismiss()
                    return
                }
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    DispatchQueue.main.async {
                        if let image = object as? UIImage,
                           let data = image.jpegData(compressionQuality: 0.7)
                        {
                            self?.parent.onImagePicked(data)
                        }
                        self?.parent.dismiss()
                    }
                }
            }
        }
    }

    /// Backing view-controller for `CameraCaptureView`.
    final class AICameraCaptureViewController: UIViewController, AVCapturePhotoCaptureDelegate, PHPickerViewControllerDelegate {
        var onCaptured: ((Data) -> Void)?
        var onCancel: (() -> Void)?
        var onPickFromLibrary: ((Data) -> Void)?

        private let session = AVCaptureSession()
        private let photoOutput = AVCapturePhotoOutput()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var device: AVCaptureDevice?
        private var flashMode: AVCaptureDevice.FlashMode = .auto
        private weak var flashButton: UIButton?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()
            configureUI()
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
            // Top bar
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

            let flash = UIButton(type: .system)
            flash.tintColor = .white
            flash.setImage(UIImage(systemName: "bolt.badge.a.fill"), for: .normal)
            flash.imageView?.contentMode = .scaleAspectFit
            flash.translatesAutoresizingMaskIntoConstraints = false
            flash.addTarget(self, action: #selector(flashTapped), for: .touchUpInside)
            topBar.addSubview(flash)
            flashButton = flash

            NSLayoutConstraint.activate([
                topBar.topAnchor.constraint(equalTo: view.topAnchor),
                topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                topBar.heightAnchor.constraint(equalToConstant: 96),

                cancel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
                cancel.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -12),

                flash.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
                flash.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -12),
                flash.widthAnchor.constraint(equalToConstant: 32),
                flash.heightAnchor.constraint(equalToConstant: 32)
            ])

            // Bottom bar
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

            NSLayoutConstraint.activate([
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
        }

        @objc private func cancelTapped() { onCancel?() }

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
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }

        @objc private func libraryTapped() {
            var config = PHPickerConfiguration()
            config.filter = .images
            config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            present(picker, animated: true)
        }

        func photoOutput(
            _: AVCapturePhotoOutput,
            didFinishProcessingPhoto photo: AVCapturePhoto,
            error _: Error?
        ) {
            if let data = photo.fileDataRepresentation() {
                onCaptured?(data)
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                DispatchQueue.main.async {
                    if let image = object as? UIImage,
                       let data = image.jpegData(compressionQuality: 0.7)
                    {
                        self?.onPickFromLibrary?(data)
                    }
                }
            }
        }
    }

    // MARK: - Barcode Scanner View (AVFoundation)

    /// A SwiftUI wrapper around AVCaptureSession for scanning barcodes.
    struct BarcodeScannerView: UIViewControllerRepresentable {
        @Environment(\.dismiss) var dismiss
        var onBarcodeScanned: (String) -> Void

        func makeUIViewController(context: Context) -> BarcodeScannerViewController {
            let vc = BarcodeScannerViewController()
            vc.onBarcodeScanned = { barcode in
                onBarcodeScanned(barcode)
                dismiss()
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

        private var captureSession: AVCaptureSession?
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var captureDevice: AVCaptureDevice?
        private weak var torchButton: UIButton?
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

            // Cancel button
            let cancelButton = UIButton(type: .system)
            cancelButton.setTitle(NSLocalizedString("Cancel", comment: "Cancel barcode scan"), for: .normal)
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
            NSLayoutConstraint.activate([
                frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                frameView.widthAnchor.constraint(equalToConstant: 280),
                frameView.heightAnchor.constraint(equalToConstant: 140)
            ])

            // Instruction label
            let label = UILabel()
            label.text = NSLocalizedString("Point at a barcode", comment: "Barcode scanner instruction")
            label.textColor = .white
            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
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
            captureSession?.stopRunning()

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            onBarcodeScanned?(barcode)
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
