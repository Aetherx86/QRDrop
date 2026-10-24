# QRDrop 🚀

> **맥(Mac)에서 아이폰으로, 별도 수신 앱 없이 순수 카메라 광학으로 전송하는 초경량 오프라인 전송기**

![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B%20%2F%20SwiftUI-orange)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ 핵심 기능

1. **✍️ 텍스트 직접 입력 & 실시간 QR 생성**:
   - 보낼 메모나 링크를 입력하는 즉시 화면에 선명한 고해상도 QR 코드가 생성됩니다.
   - 맥 클립보드에 복사된 내용을 클릭 한 번으로 가져오는 **[클립보드 붙여넣기]** 지원.
   - **아이폰 기본 카메라 앱**을 켜서 비추면 1초 만에 텍스트가 인식되어 즉시 복사/이동 가능!

2. **📁 파일 드래그 앤 드롭 전송**:
   - 텍스트 파일, 소스 코드(`.swift`, `.py`, `.js` 등), 마크다운(`.md`), 설정 파일 등을 드롭존에 끌어다 놓기만 하면 자동 감지.
   - 분량이 긴 문서는 책장 넘기듯 넘길 수 있는 **페이지 분할 QR (`1 / 3 페이지`)** 지원.

3. **📡 완전 오프라인 & 수신 엔진 불필요**:
   - Wi-Fi 연결 없음, 블루투스 없음, 셀룰러 데이터 0% 사용.
   - 비행기 모드에서도 완벽하게 작동하는 순수 광학 전송.

4. **🔄 고속 애니메이션 QR 시퀀스 (AirQR 프로토콜)**:
   - 큰 용량의 데이터를 zlib 압축 + SHA-256 체크섬을 포함한 경량 청크(`QRF1`)로 분할하여 초당 6~15 프레임 고속 순환 전송 지원.

---

## 🛠️ 기술 스택

- **UI Framework**: SwiftUI (NavigationStack, Observation Framework `@Observable`)
- **Graphics & Vision**: CoreImage (`CIQRCodeGenerator`), Vision Framework
- **Compression & Integrity**: zlib compression (`NSData.compressed`), Apple CryptoKit (SHA-256)
- **Architecture**: Clean MVVM, Strict Concurrency (Swift 6 Ready)

---

## 💻 실행 방법

### Xcode에서 실행
1. `Untitled Project.xcodeproj`를 Xcode로 엽니다.
2. 실행 대상을 **My Mac**으로 설정하고 `Cmd + R`을 누릅니다.

### 독립 앱 실행
- 빌드된 `QRDrop.app`을 더블 클릭하면 바로 실행됩니다.
