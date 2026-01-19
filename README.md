# PitchFixer 440

オーディオファイルのピッチを検出し、440Hz（A4）に補正するmacOS/iOSアプリケーションです。

## 機能

- **ピッチ検出**: オーディオファイルのピッチを自動検出
- **440Hz補正**: 検出されたピッチを440Hz（A4）に補正
- **複数フォーマット対応**: MP3、WAV、M4Aなどの主要なオーディオフォーマットに対応
- **ドラッグ&ドロップ**: ファイルをドロップするだけで簡単に処理

## 対応プラットフォーム

- macOS 15.6以降
- iOS 26.2以降

## 必要な環境

- Xcode 26.2以降
- Swift 5.0以降

## セットアップ

### 1. リポジトリのクローン

```bash
git clone https://github.com/Tatsurou-Yajima/PitchFixer.git
cd PitchFixer
```

### 2. Xcodeでプロジェクトを開く

```bash
open PitchFixer.xcodeproj
```

### 3. 依存関係の解決

プロジェクトを開くと、Swift Package Managerが自動的に依存関係を解決します：

- AudioKit 5.6.5以降
- AudioKitEX 5.6.2以降
- SoundpipeAudioKit 5.7.3以降

### 4. ビルドと実行

- **macOS**: `Cmd + R` でビルド&実行
- **iOS**: シミュレーターまたは実機を選択して `Cmd + R` でビルド&実行

## 使い方

### macOS

1. アプリを起動
2. オーディオファイルをドロップ領域にドラッグ&ドロップ、または「ファイルを選択」ボタンをクリック
3. アプリが自動的にピッチを検出
4. 「440Hzに補正して保存」ボタンをクリック
5. 保存先を選択して保存

### iOS

1. アプリを起動
2. 「ファイルを選択」ボタンをタップしてオーディオファイルを選択
3. アプリが自動的にピッチを検出
4. 「440Hzに補正して保存」ボタンをタップ
5. 保存先を選択して保存

## 技術スタック

- **SwiftUI**: ユーザーインターフェース
- **AudioKit**: オーディオ処理とピッチ検出
- **AVFoundation**: オーディオファイルの読み書き
- **UniformTypeIdentifiers**: ファイルタイプの識別

## プロジェクト構造

```
PitchFixer/
├── PitchFixer/
│   ├── PitchFixerApp.swift      # アプリエントリーポイント
│   ├── ContentView.swift         # メインUIとオーディオ処理ロジック
│   └── Info.plist               # アプリ設定
├── PitchFixer.xcodeproj/        # Xcodeプロジェクトファイル
└── README.md                    # このファイル
```

## 主なコンポーネント

### AudioPitchManager
オーディオファイルのピッチ検出と補正を行うマネージャークラス。

- `detectPitch(url:completion:)`: オーディオファイルのピッチを検出
- `export(inputURL:outputURL:cents:completion:)`: ピッチを補正してエクスポート

### PitchAnalysisResult
ピッチ解析結果を保持する構造体。

- `detectedHz`: 検出された周波数（Hz）
- `centsOffset`: 440Hzからのセント偏差
- `reliability`: 検出の信頼性（検出回数）

## ライセンス

このプロジェクトは個人開発プロジェクトです。
