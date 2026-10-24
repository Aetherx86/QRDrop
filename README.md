# QRDrop 🚀

> **맥(Mac)과 아이폰(iOS) 간에 Wi-Fi, 블루투스, 인터넷 없이 순수 카메라 광학으로 초고속 전송하는 오프라인 전송기**

![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B%20%2F%20SwiftUI-orange)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ 핵심 기능

1. **✍️ 텍스트 직접 입력 & 실시간 QR 생성**:
   - 보낼 메모나 링크를 입력하는 즉시 화면에 선명한 고해상도 QR 코드가 생성됩니다.
   - 맥/아이폰 클립보드에 복사된 내용을 클릭 한 번으로 가져오는 **[클립보드 붙여넣기]** 지원.
   - **아이폰 기본 카메라 앱**을 켜서 비추면 1초 만에 텍스트가 인식되어 즉시 복사/이동 가능!

2. **📁 파일 드래그 앤 드롭 전송**:
   - 텍스트 파일, 소스 코드(`.swift`, `.py`, `.js` 등), 마크다운(`.md`), 설정 파일 등을 드롭존에 끌어다 놓기만 하면 자동 감지.
   - 분량이 긴 문서는 책장 넘기듯 넘길 수 있는 **페이지 분할 QR (`1 / 3 페이지`)** 지원.

3. **📱 iOS 수신 엔진 탑재 (애니메이션 QR 광학 복원)**:
   - 아이폰에 QRDrop 앱을 설치하면, 맥에서 초당 10프레임 이상 고속으로 회전하는 애니메이션 QR 코드를 비추기만 해도 비트맵 청크 맵이 실시간으로 채워지며 완전한 원본 파일로 자동 조립·복원됩니다.
   - zlib 압축 해제 및 SHA-256 무결성 검증 통과 후 iOS 파일 앱 저장 및 공유 시트(`ShareLink`) 지원.

4. **📡 완전 오프라인 & 네트워크 0%**:
   - Wi-Fi 연결 없음, 블루투스 페어링 없음, 셀룰러 데이터 0% 사용.
   - 비행기 모드나 에어갭(Air-gapped) 보안 환경에서도 100% 작동.

---

## 📲 아이폰(iOS)에 설치 및 사용하는 방법

### 방법 1: Xcode로 내 아이폰에 직접 설치 (가장 추천)
1. Mac에 아이폰을 케이블로 연결합니다.
2. Mac에서 `QRDrop.xcodeproj`를 더블 클릭하여 Xcode로 엽니다.
3. 상단 기기 선택 창에서 `My Mac` 대신 **연결된 본인의 아이폰**을 선택합니다.
4. 좌측 프로젝트 설정(`QRDrop`) -> **Signing & Capabilities** 탭에서 **Team**을 본인의 개인 Apple ID(무료 개발자 계정)로 선택합니다.
5. `Cmd + R`을 누르면 아이폰에 **QRDrop** 앱이 자동으로 설치되고 실행됩니다!
   *(처음 실행 시 아이폰 [설정] -> [일반] -> [VPN 및 기기 관리]에서 개발자 신뢰를 탭해주시면 됩니다)*

### 방법 2: SideStore / AltStore / Sideloadly를 이용한 설치 (.ipa)
1. `QRDrop/build/QRDrop-iOS.ipa` 패키지를 추출합니다.
2. Sideloadly 또는 AltStore로 해당 IPA를 아이폰에 설치합니다.

---

## 🎯 사용 시나리오

* **시나리오 A: 별도 앱 설치 없이 아이폰 순정 카메라로 텍스트 받기**
  1. 맥에서 `QRDrop` 실행 -> [✍️ 텍스트 직접 입력]에 메모나 링크 입력
  2. 아이폰 기본 카메라를 켜고 맥 화면의 QR 코드를 비춤
  3. 노란색 안내 박스를 탭하여 복사 또는 사파리 이동

* **시나리오 B: iOS QRDrop 앱으로 대용량 파일/문서 고속 광학 수신**
  1. 맥에서 `QRDrop` 실행 -> [📁 파일 드롭 전송]에 문서 파일 드롭 (고속 애니메이션 QR 재생 시작)
  2. 아이폰에서 `QRDrop` 실행 -> 상단 [받기 (카메라 스캔)] 탭 선택
  3. 맥 화면을 비추면 청크 블록이 순식간에 채워지며 원본 파일 복원 완료!
  4. [파일로 저장] 또는 [공유]를 눌러 카카오톡, 메모, 파일 앱에 저장

---

## 🛠️ 기술 스택

- **UI Framework**: SwiftUI (Universal macOS & iOS, ViewThatFits 반응형 레이아웃)
- **Vision & Camera**: AVFoundation (`AVCaptureSession`, `AVCaptureMetadataOutput`), Vision Framework
- **Integrity & Compression**: Apple CryptoKit (SHA-256), Compression Framework (zlib)
- **Architecture**: Strict Concurrency (Swift 6 Ready), Zero-Warning Build
