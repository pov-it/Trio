import AVFoundation
import SwiftUI
import UIKit

// MARK: - Camera Capture View (UIImagePickerController wrapper)

extension AIInsights {
    /// A SwiftUI wrapper around UIImagePickerController for taking food photos.
    struct CameraCaptureView: UIViewControllerRepresentable {
        @Environment(\.dismiss) var dismiss
        var onImageCaptured: (Data) -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_: UIImagePickerController, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let parent: CameraCaptureView

            init(_ parent: CameraCaptureView) {
                self.parent = parent
            }

            func imagePickerController(
                _: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                if let image = info[.originalImage] as? UIImage,
                   let data = image.jpegData(compressionQuality: 0.7)
                {
                    parent.onImageCaptured(data)
                }
                parent.dismiss()
            }

            func imagePickerControllerDidCancel(_: UIImagePickerController) {
                parent.dismiss()
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
            onCancel?()
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
