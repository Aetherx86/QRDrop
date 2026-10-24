import SwiftUI

public enum TransferMode: String, CaseIterable, Identifiable {
    case sender
    case receiver
    
    public var id: String {
        switch self {
        case .sender: return "sender"
        case .receiver: return "receiver"
        }
    }
    
    public var icon: String {
        switch self {
        case .sender: return "qrcode"
        case .receiver: return "camera.viewfinder"
        }
    }
    
    public var title: String {
        #if os(macOS)
        switch self {
        case .sender: return "폰으로 보내기"
        case .receiver: return "폰에서 받기"
        }
        #else
        switch self {
        case .sender: return "맥으로 보내기"
        case .receiver: return "맥에서 받기"
        }
        #endif
    }
}

public struct ContentView: View {
    #if os(macOS)
    @State private var selectedMode: TransferMode = .sender
    #else
    @State private var selectedMode: TransferMode = .receiver
    #endif
    
    @State private var senderVM = SenderViewModel()
    @State private var receiverVM = ReceiverViewModel()
    @State private var isSimulating: Bool = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 상단 모드 세그먼트 스위처
                Picker("모드", selection: $selectedMode) {
                    ForEach(TransferMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                
                Divider()
                
                // 모드별 화면
                Group {
                    switch selectedMode {
                    case .sender:
                        SenderView(viewModel: senderVM)
                    case .receiver:
                        ReceiverView(viewModel: receiverVM)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("QRDrop")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        runLoopbackSimulation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isSimulating ? "arrow.triangle.2.circlepath.circle.fill" : "play.fill")
                            Text("가상 수신 테스트")
                        }
                        .font(.subheadline.bold())
                    }
                    .disabled(isSimulating)
                }
            }
            #if os(macOS)
            .frame(minWidth: 700, minHeight: 620)
            #endif
        }
    }
    
    private func runLoopbackSimulation() {
        isSimulating = true
        receiverVM.reset()
        selectedMode = .receiver
        
        let sampleData = """
        🎉 축하합니다! QRDrop 오프라인 파일 전송이 성공했습니다.
        
        - 파일명: offline_secret_doc.txt
        - 전송 방식: 고속 애니메이션 QR 광학 시퀀스
        - 무결성 검증: SHA-256 Checksum 일치
        - 네트워크 상태: 비행기 모드에서도 100% 작동
        
        이 파일은 맥에서 송신되어 카메라 프레임 단위로 수신 및 조립되었습니다.
        """.data(using: .utf8)!
        
        let originalSize = sampleData.count
        let compressed = DataCompressor.compress(sampleData)
        let sha = DataCompressor.sha256Prefix(for: compressed)
        let chunkSize = 60
        let total = Int(ceil(Double(compressed.count) / Double(chunkSize)))
        let fileID = "sim" + UUID().uuidString.prefix(5).lowercased()
        
        var packets: [TransferPacket] = []
        for i in 0..<total {
            let start = i * chunkSize
            let end = min(start + chunkSize, compressed.count)
            let chunk = compressed.subdata(in: start..<end)
            packets.append(TransferPacket(
                fileID: fileID,
                chunkIndex: i,
                totalChunks: total,
                fileName: "offline_secret_doc.txt",
                originalSize: originalSize,
                sha256Prefix: sha,
                payloadData: chunk
            ))
        }
        
        let shuffled = packets.shuffled()
        
        Task {
            for packet in shuffled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                await MainActor.run {
                    receiverVM.processScannedCode(packet.serialize())
                }
            }
            await MainActor.run {
                isSimulating = false
            }
        }
    }
}

#Preview {
    ContentView()
}
