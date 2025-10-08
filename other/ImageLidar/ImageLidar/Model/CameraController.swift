/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that configures and manages the capture pipeline to stream video and LiDAR depth data.
*/

import Foundation
import AVFoundation
import CoreImage
import UIKit
import ARKit
import UniformTypeIdentifiers


protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
    func onNewPhotoData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject {
    
    enum ConfigurationError: Error {
        case lidarDeviceUnavailable
        case requiredFormatUnavailable
    }
    
    //private let preferredWidthResolution = 1920
    private let preferredWidthResolution = 4032
    
    private let videoQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoQueue", qos: .userInteractive)
    
    private(set) var captureSession: AVCaptureSession!
    
    private var photoOutput: AVCapturePhotoOutput!
    private var depthDataOutput: AVCaptureDepthDataOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    private var outputVideoSync: AVCaptureDataOutputSynchronizer!
    
    private var textureCache: CVMetalTextureCache!
    
    weak var delegate: CaptureDataReceiver?
    
    var isFilteringEnabled = true {
        didSet {
            depthDataOutput.isFilteringEnabled = isFilteringEnabled
        }
    }
    
    override init() {
        
        // Create a texture cache to hold sample buffer textures.
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  MetalEnvironment.shared.metalDevice,
                                  nil,
                                  &textureCache)
        
        super.init()
        
        do {
            try setupSession()
        } catch {
            fatalError("Unable to configure the capture session.")
        }
    }
    
    private func setupSession() throws {
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .inputPriority

        // Configure the capture session.
        captureSession.beginConfiguration()
        
        try setupCaptureInput()
        setupCaptureOutputs()
        
        // Finalize the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    private func setupCaptureInput() throws {
        // Look up the LiDAR camera.
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw ConfigurationError.lidarDeviceUnavailable
        }
        
        let minexposure = device.activeFormat.minExposureDuration
        let maxexposure = device.activeFormat.maxExposureDuration

        print("Min exposure duration: \(minexposure.seconds)")
        print("Max exposure duration: \(maxexposure.seconds)")
        
        // Find a match that outputs video data in the format the app's custom Metal views require.
        guard let format = (device.formats.last { format in
            format.formatDescription.dimensions.width == preferredWidthResolution &&
            //format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            !format.isVideoBinned &&
            !format.supportedDepthDataFormats.isEmpty
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Find a match that outputs depth data in the format the app's custom Metal views require.
        guard let depthFormat = (format.supportedDepthDataFormats.last { depthFormat in
            depthFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_DepthFloat16
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Begin the device configuration.
        try device.lockForConfiguration()

        // Configure the device and depth formats.
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat

        // Set the device's exposure mode to custom, with a desired duration and ISO.
        //let desiredDuration = CMTimeMake(value: 1, timescale: 1000)
        //let desiredISO: Float = 1000.0
        //device.setExposureModeCustom(duration: desiredDuration,
        //                         iso: desiredISO,
        //                         completionHandler: nil)

        // Finish the device configuration.
        device.unlockForConfiguration()
        
        print("Selected video format: \(device.activeFormat)")
        print("Selected depth format: \(String(describing: device.activeDepthDataFormat))")
        
        // Add a device input to the capture session.
        let deviceInput = try AVCaptureDeviceInput(device: device)
        captureSession.addInput(deviceInput)
    }
    
    private func setupCaptureOutputs() {
        // Create an object to output video sample buffers.
        videoDataOutput = AVCaptureVideoDataOutput()
        captureSession.addOutput(videoDataOutput)
        
        // Create an object to output depth data.
        depthDataOutput = AVCaptureDepthDataOutput()
        depthDataOutput.isFilteringEnabled = isFilteringEnabled
        captureSession.addOutput(depthDataOutput)

        // Create an object to synchronize the delivery of depth and video data.
        outputVideoSync = AVCaptureDataOutputSynchronizer(dataOutputs: [depthDataOutput, videoDataOutput])
        outputVideoSync.setDelegate(self, queue: videoQueue)

        // Enable camera intrinsics matrix delivery.
        guard let outputConnection = videoDataOutput.connection(with: .video) else { return }
        if outputConnection.isCameraIntrinsicMatrixDeliverySupported {
            outputConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        
        // Create an object to output photos.
        photoOutput = AVCapturePhotoOutput()
        photoOutput.maxPhotoQualityPrioritization = .quality
        captureSession.addOutput(photoOutput)

        // Enable delivery of depth data after adding the output to the capture session.
        photoOutput.isDepthDataDeliveryEnabled = true
    }
    
    func startStream() {
        captureSession.startRunning()
    }
    
    func stopStream() {
        captureSession.stopRunning()
    }
}

// MARK: Output Synchronizer Delegate
extension CameraController: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Retrieve the synchronized depth and sample buffer container objects.
        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
              let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        
        guard let pixelBuffer = syncedVideoData.sampleBuffer.imageBuffer,
              let cameraCalibrationData = syncedDepthData.depthData.cameraCalibrationData else { return }
        
        // Package the captured data.
        let data = CameraCapturedData(depth: syncedDepthData.depthData.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewData(capturedData: data)
    }
}

// MARK: Photo Capture Delegate
extension CameraController: AVCapturePhotoCaptureDelegate {
    
    func capturePhoto(iso: Float, duration: CMTime) {

        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            print("Failed to access LiDAR camera.")
            return
        }

        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            print("Failed to lock device for exposure change: \(error)")
            return
        }

        var photoSettings: AVCapturePhotoSettings
        if  photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            photoSettings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
        } else {
            photoSettings = AVCapturePhotoSettings()
        }

        // Create a photo settings object for maximum photo quality
        //photoSettings = AVCapturePhotoSettings()
        //photoSettings.flashMode = .off

        // Capture depth data with this photo capture.
        photoSettings.isDepthDataDeliveryEnabled = true

        photoOutput.capturePhoto(with: photoSettings, delegate: self)

    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        
        // Retrieve the image and depth data.
        guard let pixelBuffer = photo.pixelBuffer,
              let depthData = photo.depthData,
              let cameraCalibrationData = depthData.cameraCalibrationData,
              let imageData = photo.fileDataRepresentation(),
              let photoUIImage = UIImage(data: imageData) else { return }
        
        // Stop the stream until the user returns to streaming mode.
        stopStream()
        
        let randomValue = String(format: "%04x", Int.random(in: 0...Int(UInt16.max)))
        let timestr = randomValue
            
        // Convert the depth data to the expected format.
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        
        // Package the captured data.
        let data = CameraCapturedData(depth: convertedDepth.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        let convertedDepthMap = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        // compute reciprocal of distance
        CVPixelBufferLockBaseAddress(convertedDepthMap, CVPixelBufferLockFlags(rawValue: 2))
        let width = CVPixelBufferGetWidth(convertedDepthMap)
        let height = CVPixelBufferGetHeight(convertedDepthMap)
        let floatBuffer = unsafeBitCast(
            CVPixelBufferGetBaseAddress(convertedDepthMap),
            to: UnsafeMutablePointer<Float32>.self
        )
        for row in 0 ..< height {
            for col in 0 ..< width {
                let index = width * row + col
                if floatBuffer[index] > 0.0 {
                    //floatBuffer[index] = 1.0 / (floatBuffer[index]+0.00001)
                    floatBuffer[index] = floatBuffer[index]+0.00001
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(convertedDepthMap, CVPixelBufferLockFlags(rawValue: 2))

        
        // Write depth as TIFF file
        writeDepthDataAsTIFF(depthMap: convertedDepthMap, filename: timestr)
        
        let convertedDepthMap2 = depthData.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat16).depthDataMap
        writeDepthDataAsTIFF(depthMap: convertedDepthMap2, filename: timestr+"_d")

        let image = UIImage(cgImage: photoUIImage.cgImage!, scale: photoUIImage.scale, orientation: .up)
        writeRGBData(image: image, filename: timestr)
        delegate?.onNewPhotoData(capturedData: data)
        
    }


    func writeDepthDataAsTIFF(depthMap: CVPixelBuffer, filename: String) {
    // Step 1: Create CIImage from CVPixelBuffer
    let ciImage = CIImage(cvPixelBuffer: depthMap)

    // Step 2: Create CGImage from CIImage using CIContext
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
        print("Failed to create CGImage from CIImage")
        return
    }

    // Step 3: Create URL for saving the TIFF file
    guard let url = try? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(filename + ".tiff") else {
        print("Failed to create file URL")
        return
    }

    // Step 4: Create image destination for TIFF
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
        print("Failed to create CGImageDestination")
        return
    }

    // Step 5: Add image to the destination and finalize
    CGImageDestinationAddImage(destination, cgImage, nil)

    if CGImageDestinationFinalize(destination) {
        print("Successfully wrote TIFF to \(url)")
    } else {
        print("Failed to write TIFF image")
    }
}

    func writeRGBData(image: UIImage, filename: String) {
        let jpgImageData = image.jpegData(compressionQuality: 1.0)
        guard let url = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent(filename + ".jpg") else { return }
        do {
            try jpgImageData!.write(to: url)
        } catch let error{
            print(error)
        }
    }
}
