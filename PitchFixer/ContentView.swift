import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AudioKit
import AudioKitEX
import SoundpipeAudioKit

// MARK: - オーディオ処理マネージャー
class AudioPitchManager {
    // 再生・書き出し用の標準エンジン
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var pitchUnit = AVAudioUnitTimePitch()
    
    // 解析用のAudioKitエンジン
    private let analysisEngine = AudioEngine()

    // --- 再生機能 ---
    func playWithPitchShift(url: URL, cents: Float) {
        audioEngine.stop()
        guard let audioFile = try? AVAudioFile(forReading: url) else { return }
        audioEngine.attach(playerNode)
        audioEngine.attach(pitchUnit)
        pitchUnit.pitch = cents
        let format = audioFile.processingFormat
        audioEngine.connect(playerNode, to: pitchUnit, format: format)
        audioEngine.connect(pitchUnit, to: audioEngine.mainMixerNode, format: format)
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        do {
            try audioEngine.start()
            playerNode.play()
        } catch {
            print("再生エラー: \(error)")
        }
    }

    func stop() {
        playerNode.stop()
        audioEngine.stop()
    }
    
    func detectPitch(url: URL, completion: @escaping (PitchAnalysisResult) -> Void) {
        // クロージャの中身を軽くするため、実際の処理は別メソッドに任せる
        DispatchQueue.global(qos: .userInitiated).async {
            self.runAnalysis(url: url, completion: completion)
        }
    }

    // 実際の解析ロジックを分離
    private func runAnalysis(url: URL, completion: @escaping (PitchAnalysisResult) -> Void) {
        guard let file = try? AVAudioFile(forReading: url) else {
            completion(PitchAnalysisResult())
            return
        }

        // AudioKitのプレイヤーを生成
        let player = AudioPlayer(file: file)!
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
            
            // --- 修正箇所：秒数を計算して再生 ---
            let sampleRate = file.fileFormat.sampleRate
            let startTime = Double(file.length / 4) / sampleRate // 曲の25%地点を秒で計算
            player.play(from: startTime)
            // ----------------------------------
            
            print("🚀 解析開始（開始地点: \(String(format: "%.1f", startTime))秒）...")
            
            Thread.sleep(forTimeInterval: 3.0)
            
            player.stop()
            tap.stop()
            analysisEngine.stop()

            if detectedOffsets.isEmpty {
                completion(PitchAnalysisResult())
            } else {
                let result = self.calculateFinalResult(offsets: detectedOffsets)
                completion(result)
            }
        } catch {
            completion(PitchAnalysisResult())
        }
    }

    // 計算処理をさらに分離（コンパイラの負荷を減らす）
    private func calculateFinalResult(offsets: [Float]) -> PitchAnalysisResult {
        let sorted = offsets.sorted()
        let medianDeviation = Double(sorted[sorted.count / 2])
        
        // 分割して計算することで "reasonable time" エラーを防ぐ
        let power = medianDeviation / 1200.0
        let multiplier = pow(2.0, power)
        let hz = 440.0 * multiplier
        
        return PitchAnalysisResult(
            detectedHz: Float(hz),
            centsOffset: Float(-medianDeviation),
            reliability: offsets.count
        )
    }

    // --- 書き出し機能 (安定したAVFoundationを継続使用) ---
    func export(inputURL: URL, outputURL: URL, cents: Float, completion: @escaping (Bool) -> Void) {
        do {
            let inputFile = try AVAudioFile(forReading: inputURL)
            let processingFormat = inputFile.processingFormat
            let exportEngine = AVAudioEngine()
            let exportPlayer = AVAudioPlayerNode()
            let exportPitch = AVAudioUnitTimePitch()
            
            exportPitch.pitch = cents
            exportEngine.attach(exportPlayer)
            exportEngine.attach(exportPitch)
            
            exportEngine.connect(exportPlayer, to: exportPitch, format: processingFormat)
            exportEngine.connect(exportPitch, to: exportEngine.mainMixerNode, format: processingFormat)
            
            // 💡 M4A（AAC）用の圧縮設定
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000, // 192kbps (高音質)
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            // Manual Rendering（オフライン書き出し）の設定
            let renderFormat = exportEngine.mainMixerNode.outputFormat(forBus: 0)
            try exportEngine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4096)
            
            // 💡 圧縮設定を使ってファイルを作成
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
            
            exportPlayer.scheduleFile(inputFile, at: nil, completionHandler: nil)
            try exportEngine.start()
            exportPlayer.play()
            
            let buffer = AVAudioPCMBuffer(pcmFormat: exportEngine.manualRenderingFormat, frameCapacity: 4096)!
            
            while exportEngine.manualRenderingSampleTime < inputFile.length {
                let frameCount = inputFile.length - exportEngine.manualRenderingSampleTime
                let framesToRender = min(frameCount, 4096)
                let status = try exportEngine.renderOffline(AVAudioFrameCount(framesToRender), to: buffer)
                
                if status == .success {
                    try outputFile.write(from: buffer)
                } else {
                    completion(false)
                    return
                }
            }
            
            exportPlayer.stop()
            exportEngine.stop()
            completion(true)
            
        } catch {
            print("❌ Export Error: \(error)")
            completion(false)
        }
    }
}

// 解析詳細データを保持する構造体
struct PitchAnalysisResult {
    var detectedHz: Float = 0.0     // 推定された元の基準ピッチ (例: 432.4Hz)
    var centsOffset: Float = 0.0    // 440Hzからのズレ (例: -30.5セント)
    var reliability: Int = 0        // 有効だったサンプル数 (例: 10個中8個)
    
    // 表示用のラベル
    var hzString: String { String(format: "%.1f Hz", detectedHz) }
    var centsString: String { String(format: "%.1f セント", centsOffset) }
}

struct ContentView: View {
    @State private var audioManager = AudioPitchManager()
    @State private var fileName: String = "ファイルをドロップしてください"
    @State private var fileURL: URL? = nil
    @State private var isTargeted: Bool = false
    @State private var currentCents: Float = 0
    @State private var isAnalyzing: Bool = false
    @State private var isExporting: Bool = false
    @State private var analysisResult: PitchAnalysisResult? = nil

    var body: some View {
        VStack(spacing: 25) {
            Text("440Hz 自動チューニング補正")
                .font(.title2).bold()
            
            // 視覚的なガイドとしての枠（判定は外側で行うため、ここには onDrop を書かない）
            RoundedRectangle(cornerRadius: 15)
                .stroke(isTargeted ? Color.blue : Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [5]))
                .background(isTargeted ? Color.blue.opacity(0.1) : Color.clear)
                .frame(width: 350, height: 180)
                .overlay(
                    VStack(spacing: 12) {
                        if isAnalyzing {
                            ProgressView("楽曲を解析中...")
                        } else {
                            Image(systemName: fileURL == nil ? "doc.badge.plus" : "music.note")
                                .font(.system(size: 40))
                                .foregroundColor(fileURL == nil ? .gray : .blue)
                            Text(fileName)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                )

            Button("ファイルを選択") { selectFile() }
                .buttonStyle(.bordered)
                .disabled(isAnalyzing || isExporting)

            Divider().padding(.horizontal)

            if let result = analysisResult, !isAnalyzing {
                VStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("楽曲解析レポート").font(.headline)
                        Divider()
                        HStack { Text("元の基準ピッチ:"); Spacer(); Text(result.hzString).bold().foregroundColor(.blue) }
                        HStack { Text("440Hzとの差:"); Spacer(); Text("\(String(format: "%+.1f", -result.centsOffset)) セント").bold().foregroundColor(.orange) }
                        HStack { Text("解析信頼度:"); Spacer(); Text("\(result.reliability) / 10 ポイント確認").font(.caption).foregroundColor(.secondary) }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                    .frame(width: 350)

                    if isExporting {
                        ProgressView("書き出し中...")
                    } else {
                        Button(action: saveFile) {
                            Text("440Hzに補正して保存").frame(width: 250, height: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 550)
        .contentShape(Rectangle()) // 透明な隙間でも反応するようにする
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, _) in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                updateSelectedFile(url)
            } else if let url = item as? URL {
                updateSelectedFile(url)
            }
        }
        return true
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .audio]
        if panel.runModal() == .OK, let url = panel.url {
            updateSelectedFile(url)
        }
    }

    private func updateSelectedFile(_ url: URL) {
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
                if result.reliability > 0 {
                    self.saveFile()
                }
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func saveFile() {
        guard let sourceURL = fileURL, let result = analysisResult else { return }
        
        let savePanel = NSSavePanel()
        // 💡 M4A形式を指定
        savePanel.allowedContentTypes = [.mpeg4Audio]
        
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(originalName)_440Hz.m4a"
        
        if savePanel.runModal() == .OK, let targetURL = savePanel.url {
            isExporting = true
            let access = sourceURL.startAccessingSecurityScopedResource()
            
            audioManager.export(inputURL: sourceURL, outputURL: targetURL, cents: result.centsOffset) { success in
                DispatchQueue.main.async {
                    self.isExporting = false
                    if access { sourceURL.stopAccessingSecurityScopedResource() }
                    if success {
                        print("✅ M4A保存完了")
                        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                    }
                }
            }
        }
    }
}
