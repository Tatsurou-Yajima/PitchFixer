import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AudioKit
import AudioKitEX
import SoundpipeAudioKit

// MARK: - 1. 保存用のドキュメント構造体 (iOS/Mac共通)
struct AudioDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mpeg4Audio, .wav, .mp3] }
    var url: URL?

    init(url: URL?) { self.url = url }
    init(configuration: ReadConfiguration) throws { self.url = nil }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url = url else { throw CocoaError(.fileNoSuchFile) }
        return try FileWrapper(url: url)
    }
}

// MARK: - 2. 解析結果データ
struct PitchAnalysisResult {
    var detectedHz: Float = 0.0
    var centsOffset: Float = 0.0
    var reliability: Int = 0
    var hzString: String { String(format: "%.1f Hz", detectedHz) }
}

// MARK: - 3. オーディオ処理マネージャー
class AudioPitchManager {
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var pitchUnit = AVAudioUnitTimePitch()
    private let analysisEngine = AudioEngine()

    func detectPitch(url: URL, completion: @escaping (PitchAnalysisResult) -> Void) {
        // iOSでのオーディオセッション設定
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: .defaultToSpeaker)
        try? session.setActive(true)
        #endif

        DispatchQueue.global(qos: .userInitiated).async {
            self.runAnalysis(url: url, completion: completion)
        }
    }

    private func runAnalysis(url: URL, completion: @escaping (PitchAnalysisResult) -> Void) {
        guard let file = try? AVAudioFile(forReading: url),
              let player = AudioPlayer(file: file) else {
            completion(PitchAnalysisResult())
            return
        }

        player.volume = 0.01
        analysisEngine.output = player
        var detectedOffsets: [Float] = []
        
        let tap = PitchTap(player) { pitch, amp in
            if amp[0] > 0.01 {
                let freq = Double(pitch[0])
                let midi = 12.0 * log2(freq / 440.0) + 69.0
                let deviation = (midi - round(midi)) * 100.0
                detectedOffsets.append(Float(deviation))
            }
        }

        do {
            try analysisEngine.start()
            tap.start()
            let startTime = Double(file.length / 4) / file.fileFormat.sampleRate
            player.play(from: startTime)
            
            Thread.sleep(forTimeInterval: 3.0)
            
            player.stop()
            tap.stop()
            analysisEngine.stop()

            if detectedOffsets.isEmpty {
                completion(PitchAnalysisResult())
            } else {
                let sorted = detectedOffsets.sorted()
                let medianDeviation = Double(sorted[sorted.count / 2])
                let hz = 440.0 * pow(2.0, medianDeviation / 1200.0)
                completion(PitchAnalysisResult(detectedHz: Float(hz), centsOffset: Float(-medianDeviation), reliability: detectedOffsets.count))
            }
        } catch {
            completion(PitchAnalysisResult())
        }
    }

    func export(inputURL: URL, outputURL: URL, cents: Float, completion: @escaping (Bool) -> Void) {
        do {
            let inputFile = try AVAudioFile(forReading: inputURL)
            let exportEngine = AVAudioEngine()
            let exportPlayer = AVAudioPlayerNode()
            let exportPitch = AVAudioUnitTimePitch()
            
            exportPitch.pitch = cents
            exportEngine.attach(exportPlayer)
            exportEngine.attach(exportPitch)
            exportEngine.connect(exportPlayer, to: exportPitch, format: inputFile.processingFormat)
            exportEngine.connect(exportPitch, to: exportEngine.mainMixerNode, format: inputFile.processingFormat)
            
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            
            try exportEngine.enableManualRenderingMode(.offline, format: exportEngine.mainMixerNode.outputFormat(forBus: 0), maximumFrameCount: 4096)
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
            
            exportPlayer.scheduleFile(inputFile, at: nil)
            try exportEngine.start()
            exportPlayer.play()
            
            let buffer = AVAudioPCMBuffer(pcmFormat: exportEngine.manualRenderingFormat, frameCapacity: 4096)!
            while exportEngine.manualRenderingSampleTime < inputFile.length {
                let frameCount = min(inputFile.length - exportEngine.manualRenderingSampleTime, 4096)
                try exportEngine.renderOffline(AVAudioFrameCount(frameCount), to: buffer)
                try outputFile.write(from: buffer)
            }
            completion(true)
        } catch {
            completion(false)
        }
    }
}

// MARK: - 4. メインUI
struct ContentView: View {
    @State private var audioManager = AudioPitchManager()
    @State private var fileName: String = "ファイルをドロップまたは選択"
    @State private var fileURL: URL? = nil
    @State private var isAnalyzing = false
    @State private var isExporting = false
    @State private var analysisResult: PitchAnalysisResult? = nil
    
    // UI管理用
    @State private var isShowingImporter = false
    @State private var isShowingExporter = false
    @State private var tempExportURL: URL? = nil
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 25) {
            Text("PitchFixer 440")
                .font(.title2).bold()
            
            // ドロップ領域 (Mac/iPad対応)
            RoundedRectangle(cornerRadius: 15)
                .stroke(isTargeted ? Color.blue : Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [5]))
                .background(isTargeted ? Color.blue.opacity(0.1) : Color.clear)
                .frame(maxWidth: 400, minHeight: 180)
                .overlay(
                    VStack(spacing: 12) {
                        if isAnalyzing {
                            ProgressView("解析中...")
                        } else {
                            Image(systemName: fileURL == nil ? "doc.badge.plus" : "music.note")
                                .font(.system(size: 40))
                            Text(fileName).font(.callout).padding()
                        }
                    }
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }

            Button("ファイルを選択") { isShowingImporter = true }
                .buttonStyle(.bordered)
                .disabled(isAnalyzing || isExporting)

            if let result = analysisResult, !isAnalyzing {
                VStack(spacing: 15) {
                    Text("推定ピッチ: \(result.hzString)").bold()
                    if isExporting {
                        ProgressView("補正中...")
                    } else {
                        Button("440Hzに補正して保存") { startExport() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
            }
        }
        .padding()
        #if os(macOS)
        .frame(width: 500, height: 550)
        #endif
        // インポーター・エクスポーターの追加
        .fileImporter(isPresented: $isShowingImporter, allowedContentTypes: [.audio]) { result in
            if let url = try? result.get() { updateFile(url) }
        }
        .fileExporter(isPresented: $isShowingExporter, document: AudioDocument(url: tempExportURL), contentType: .mpeg4Audio, defaultFilename: "\(fileURL?.deletingPathExtension().lastPathComponent ?? "fixed")_440Hz") { _ in
            tempExportURL = nil
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, _) in
            if let url = item as? URL { updateFile(url) }
        }
        return true
    }

    private func updateFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        DispatchQueue.main.async {
            self.fileURL = url
            self.fileName = url.lastPathComponent
            self.isAnalyzing = true
            self.analysisResult = nil
        }
        audioManager.detectPitch(url: url) { result in
            DispatchQueue.main.async {
                self.analysisResult = result
                self.isAnalyzing = false
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func startExport() {
        guard let sourceURL = fileURL, let result = analysisResult else { return }
        isExporting = true
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let access = sourceURL.startAccessingSecurityScopedResource()
        
        audioManager.export(inputURL: sourceURL, outputURL: tempURL, cents: result.centsOffset) { success in
            DispatchQueue.main.async {
                isExporting = false
                if access { sourceURL.stopAccessingSecurityScopedResource() }
                if success {
                    self.tempExportURL = tempURL
                    self.isShowingExporter = true
                }
            }
        }
    }
}
