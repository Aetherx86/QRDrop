# QRDrop

> **맥(Mac)과 아이폰(iOS) 간에 Wi-Fi, 블루투스, 인터넷 없이 순수 카메라 광학으로 초고속 전송하는 오프라인 전송기**

![Platform](https://img.shields.io/badge/Platform-macOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/Swift-6.0%2B%20%2F%20SwiftUI-orange)
![Version](https://img.shields.io/badge/Version-0.2.0-informational)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 핵심 기능

1. **텍스트 직접 입력 및 실시간 QR 생성**:
   - 보낼 메모나 링크를 입력하는 즉시 화면에 선명한 고해상도 QR 코드가 생성됩니다.
   - 맥/아이폰 클립보드에 복사된 내용을 클릭 한 번으로 가져오는 **[클립보드 붙여넣기]** 지원.
   - **아이폰 기본 카메라 앱**을 켜서 비추면 1초 만에 텍스트가 인식되어 즉시 복사/이동 가능.

2. **파일 드래그 앤 드롭 전송**:
   - 텍스트 파일, 소스 코드(`.swift`, `.py`, `.js` 등), 마크다운(`.md`), 설정 파일 등을 드롭존에 끌어다 놓기만 하면 자동 감지.
   - 분량이 긴 문서는 책장 넘기듯 넘길 수 있는 **페이지 분할 QR (`1 / 3 페이지`)** 지원.

3. **iOS 수신 엔진 탑재 (애니메이션 QR 광학 복원)**:
   - 아이폰에 QRDrop 앱을 설치하면, 맥에서 초당 10프레임 이상 고속으로 회전하는 애니메이션 QR 코드를 비추기만 해도 비트맵 청크 맵이 실시간으로 채워지며 완전한 원본 파일로 자동 조립·복원됩니다.
   - `QRF1`, `QRF2`(CRC32 + SHA-256), 그리고 `QRFF` Luby Transform 파운틴 코드 스트림을 모두 수신 및 복원하며, zlib 압축 해제 및 SHA-256 무결성 검증 통과 후 iOS 파일 앱 저장 및 공유 시트(`ShareLink`)를 지원합니다.

4. **완전 오프라인 및 에어갭 보안**:
   - Wi-Fi 연결 없음, 블루투스 페어링 없음, 셀룰러 데이터 0% 사용.
   - 비행기 모드나 에어갭(Air-gapped) 보안 환경에서도 100% 작동하며, 선택적 `HKDF-SHA256` + `AES-GCM-256` 암호화 봉투(`QRE1`)를 통해 광학 스니핑을 방지합니다.

---

## v0.2.0 주요 업그레이드 및 CLI 사용법

`v0.2.0`부터 `QRDrop`은 Xcode 유니버설 앱(`QRDrop.xcodeproj`)과 함께 Swift Package Manager 라이브러리(`QRDropCore`) 및 커맨드라인 도구(`qrdrop`)를 제공합니다.

### 1. 프로토콜 v2 (`QRF2`) 및 Luby Transform 파운틴 코딩 (`QRFF`)
- **`QRF2` 프레임**: 프레임별 IEEE 802.3 `CRC32` 체크섬, `PacketFlags` 비트마스크, 전체 64자리 `SHA-256` 해시, 경로 탐색(`../`) 및 제어 문자 파일명 살균(`TransferPacket.sanitizeFileName`), 크기 상한 검증 압축 해제(`DataCompressor.decompressBounded`)를 지원합니다.
- **`QRFF` 파운틴 코드**: 결정론적 `SplitMix64` 차수 샘플링과 GF(2) 가우스-조르단 소거법 디코더(`FountainDecoder`)를 통해 프레임 유실이나 순서 뒤바뀜이 발생해도 임의의 선형 독립 드롭릿 수집만으로 원본 파일을 100% 복원합니다.

```bash
# 빌드 및 전체 테스트 스위트 실행
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# 버전 확인
.build/debug/qrdrop --version

# 파운틴 코딩(QRFF) + AES-GCM-256 암호화 인코딩 및 파이프라인 복원
.build/debug/qrdrop encode --text "Air-gapped optical fountain payload test" --name "secret.txt" --fountain --passphrase "k1" \
  | .build/debug/qrdrop decode --passphrase "k1" --json
```

### 2. AES-GCM-256 + HKDF-SHA256 암호화 페이로드 봉투 (`QRE1`)
- 패스프레이즈와 16바이트 랜덤 솔트, 도메인 분리 컨텍스트(`QRDrop-v0.2-AES256GCM`)를 기반으로 `HKDF<SHA256>` 대칭키를 유도하고, 헤더 및 컨텍스트를 AAD(Associated Authenticated Data)로 바인딩하여 `AES.GCM`으로 암호화합니다.

```bash
# 단독 QRE1 암호화 봉투 생성 (--json 출력 지원)
.build/debug/qrdrop encrypt --text "Classified optical memo" --passphrase "vault-key" --context "ops" --json
```

### 3. 구조화된 QR 페이로드 인코더 및 검증기 (`Wi-Fi`, `vCard 3.0`, `URI`, `Inspector`)
- 특수문자 이스케이프 및 길이·제어문자 검증이 포함된 `WIFI:` 네트워크 설정, `BEGIN:VCARD` 연락처, 위험 스킴(`javascript:`, `data:`, `file:`, `vbscript:`)을 차단하는 `URIPayload`, 그리고 모든 QR 문자열 포맷을 자동 분류하는 `QRPayloadInspector`를 제공합니다.

```bash
# Wi-Fi QR 페이로드 생성
.build/debug/qrdrop payload wifi --ssid "AirGap_Lab" --password "optical-transfer" --auth WPA --json

# vCard 3.0 연락처 QR 페이로드 생성
.build/debug/qrdrop payload vcard --name "Jeong Hoon Kim" --org "QRDrop" --email "contact@example.com" --json

# 파운틴 코딩 손실 복원 벤치마크 (25% 프레임 손실 시뮬레이션)
.build/debug/qrdrop benchmark --bytes 8192 --chunk-size 256 --loss 0.25 --json
```

---

## 아이폰(iOS)에 설치 및 사용하는 방법

### 방법 1: Xcode로 내 아이폰에 직접 설치 (가장 추천)
1. Mac에 아이폰을 케이블로 연결합니다.
2. Mac에서 `QRDrop.xcodeproj`를 더블 클릭하여 Xcode로 엽니다.
3. 상단 기기 선택 창에서 `My Mac` 대신 **연결된 본인의 아이폰**을 선택합니다.
4. 좌측 프로젝트 설정(`QRDrop`) -> **Signing & Capabilities** 탭에서 **Team**을 본인의 개인 Apple ID(무료 개발자 계정)로 선택합니다.
5. `Cmd + R`을 누르면 아이폰에 **QRDrop** 앱이 자동으로 설치되고 실행됩니다.
   *(처음 실행 시 아이폰 [설정] -> [일반] -> [VPN 및 기기 관리]에서 개발자 신뢰를 탭해주시면 됩니다)*

### 방법 2: SideStore / AltStore / Sideloadly를 이용한 설치 (.ipa)
1. `QRDrop/build/QRDrop-iOS.ipa` 패키지를 추출합니다.
2. Sideloadly 또는 AltStore로 해당 IPA를 아이폰에 설치합니다.

---

## 사용 시나리오

* **시나리오 A: 별도 앱 설치 없이 아이폰 순정 카메라로 텍스트 받기**
  1. 맥에서 `QRDrop` 실행 -> [텍스트 직접 입력]에 메모나 링크 입력
  2. 아이폰 기본 카메라를 켜고 맥 화면의 QR 코드를 비춤
  3. 노란색 안내 박스를 탭하여 복사 또는 사파리 이동

* **시나리오 B: iOS QRDrop 앱으로 대용량 파일/문서 고속 광학 수신**
  1. 맥에서 `QRDrop` 실행 -> [파일 드롭 전송]에 문서 파일 드롭 (고속 애니메이션 QR 재생 시작)
  2. 아이폰에서 `QRDrop` 실행 -> 상단 [받기 (카메라 스캔)] 탭 선택
  3. 맥 화면을 비추면 청크 블록이 순식간에 채워지며 원본 파일 복원 완료
  4. [파일로 저장] 또는 [공유]를 눌러 메모, 파일 앱 등에 저장

---

## 기술 스택

- **UI Framework**: SwiftUI (Universal macOS & iOS, ViewThatFits 반응형 레이아웃)
- **Vision & Camera**: AVFoundation (`AVCaptureSession`, `AVCaptureMetadataOutput`), Vision Framework
- **Integrity, Erasure Coding & Cryptography**: Apple CryptoKit (`SHA-256`, `HKDF<SHA256>`, `AES.GCM`), IEEE 802.3 `CRC32`, GF(2) Luby Transform Fountain Code, Compression Framework (`zlib`)
- **Architecture**: Strict Concurrency (Swift 6 Ready), SwiftPM (`QRDropCore` + `qrdrop` CLI + `QRDropTests`), Zero-Warning Build
