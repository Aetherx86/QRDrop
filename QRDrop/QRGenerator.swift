import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// 고성능 선명한 QR 코드 생성 엔진
@MainActor
public final class QRGenerator {
    public static let shared = QRGenerator()
    
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let filter = CIFilter.qrCodeGenerator()
    
    // 메모리 캐시 (현재 세션의 QR 이미지 캐시)
    private var imageCache = NSCache<NSString, CGImageWrapper>()
    
    private final class CGImageWrapper {
        let image: CGImage
        init(image: CGImage) { self.image = image }
    }
    
    public init() {
        imageCache.countLimit = 200
    }
    
    /// 텍스트로부터 고화질 흑백 QR 코드 CGImage 생성
    /// 백그라운드 스레드에서 병렬 생성 가능한 초고속 QR 생성 메서드
    public nonisolated static func makeQRCode(from string: String, targetSize: CGFloat = 512) -> CGImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        
        guard let outputCI = filter.outputImage else { return nil }
        let extent = outputCI.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        
        let scale = targetSize / extent.width
        let transformed = outputCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
        return sharedContext.createCGImage(transformed, from: transformed.extent)
    }

    public func generateQRCode(from string: String, targetSize: CGFloat = 512) -> CGImage? {
        let cacheKey = "\(string.hashValue)_\(Int(targetSize))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached.image
        }
        
        guard let data = string.data(using: .utf8) else { return nil }
        
        filter.message = data
        // Error Correction: M(15%)이 카메라 움직임 및 빠른 애니메이션 스캔 시 가장 안정적
        filter.correctionLevel = "M"
        
        guard let outputCI = filter.outputImage else { return nil }
        
        // 원본 크기 대비 목표 크기 배율 계산
        let extent = outputCI.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        
        let scale = targetSize / extent.width
        let transformed = outputCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        
        imageCache.setObject(CGImageWrapper(image: cgImage), forKey: cacheKey)
        return cgImage
    }
    
    /// 캐시 초기화
    public func clearCache() {
        imageCache.removeAllObjects()
    }
}
