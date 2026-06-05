import SwiftUI
import Foundation
import AppKit
import Combine

// メインのコンテンツビュー
struct ContentView: View {
    @State private var selectedFiles: [URL] = []
    @State private var sortType = 0 // 0: 名前, 1: 日付, 2: サイズ
    @State private var isAscending: Bool = true
    @State private var isProcessing: Bool = false
    @State private var statusMessage: String = ""
    @State private var showPermissionAlert: Bool = false
    @State private var permissionErrorFile: String = ""
    @State private var permissionErrorFiles: [URL] = []
    
    var body: some View {
        VStack {
            // ツールバー
            HStack {
                Button(action: selectFiles) {
                    HStack {
                        // systemNameの代わりにテキストを使用
                        Text("📁")
                        Text("ファイルを選択")
                    }
                }
                
                Spacer()
                
                // ソートオプションの選択
                Picker(selection: $sortType, label: Text("ソート:")) {
                    Text("名前").tag(0)
                    Text("日付").tag(1)
                    Text("サイズ").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 250)
                // Catalina用に.onChangeの代わりにカスタム監視を使用
                .onReceive(Just(sortType)) { _ in sortFiles() }
                
                // 昇順・降順の切り替え
                Button(action: {
                    isAscending.toggle()
                    sortFiles()
                }) {
                    // systemNameの代わりにテキストを使用
                    Text(isAscending ? "↑" : "↓")
                }
                
                Spacer()
                
                // 処理の実行ボタン
                Button(action: processFiles) {
                    HStack {
                        // systemNameの代わりにテキストを使用
                        Text("☁️❌")
                        Text("iCloudからダウンロードを削除")
                    }
                }
                .disabled(selectedFiles.isEmpty || isProcessing)
            }
            .padding()
            
            // ファイルリスト - Catalina互換の基本的なリスト
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sortedFiles, id: \.self) { url in
                        FileRowSimple(url: url)
                            .padding(.horizontal)
                    }
                }
            }
            .border(Color.gray.opacity(0.2), width: 1)
            
            // ステータスバー
            HStack {
                Text(statusMessage)
                Spacer()
                Text("選択済み: \(selectedFiles.count) ファイル")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))
        }
        .frame(minWidth: 600, minHeight: 400)
        // アクセス権限エラーのアラート
        .alert(isPresented: $showPermissionAlert) {
            Alert(
                title: Text("アクセス権限エラー"),
                message: Text("\(permissionErrorFile)などのファイルにアクセスする権限がありません。再度権限を付与しますか？"),
                primaryButton: .default(Text("はい")) {
                    requestFilePermission()
                },
                secondaryButton: .cancel(Text("いいえ"))
            )
        }
    }
    
    // ソート済みファイルの取得
    private var sortedFiles: [URL] {
        return selectedFiles.sorted { file1, file2 in
            let result: Bool
            
            switch sortType {
            case 0: // 名前
                result = file1.lastPathComponent.localizedCaseInsensitiveCompare(file2.lastPathComponent) == .orderedAscending
            case 1: // 日付
                let date1 = try? FileManager.default.attributesOfItem(atPath: file1.path)[.modificationDate] as? Date ?? Date.distantPast
                let date2 = try? FileManager.default.attributesOfItem(atPath: file2.path)[.modificationDate] as? Date ?? Date.distantPast
                result = date1! < date2!
            case 2: // サイズ
                let size1 = try? FileManager.default.attributesOfItem(atPath: file1.path)[.size] as? UInt64 ?? 0
                let size2 = try? FileManager.default.attributesOfItem(atPath: file2.path)[.size] as? UInt64 ?? 0
                result = size1! < size2!
            default:
                result = false
            }
            
            return isAscending ? result : !result
        }
    }
    
    // ファイル選択ダイアログの表示
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        
        panel.begin { response in
            if response == .OK {
                selectedFiles = panel.urls
                sortFiles()
                statusMessage = "\(panel.urls.count) ファイルが選択されました"
            }
        }
    }
    
    // ファイルのソート処理
    private func sortFiles() {
        // sortedFilesプロパティが自動的にソートするので、ここでは何もしない
    }
    
    // iCloudからダウンロードを削除する処理
    private func processFiles() {
        isProcessing = true
        statusMessage = "処理中..."
        permissionErrorFiles = []
        
        DispatchQueue.global(qos: .userInitiated).async {
            var successCount = 0
            
            for url in selectedFiles {
                let result = evictFileFromiCloud(at: url)
                if result.success {
                    successCount += 1
                } else if result.permissionError {
                    // 権限エラーの場合はリストに追加
                    DispatchQueue.main.async {
                        permissionErrorFiles.append(url)
                    }
                }
            }
            
            DispatchQueue.main.async {
                isProcessing = false
                
                if !permissionErrorFiles.isEmpty {
                    // 権限エラーがあった場合はアラートを表示
                    permissionErrorFile = permissionErrorFiles.first?.lastPathComponent ?? ""
                    showPermissionAlert = true
                    statusMessage = "\(successCount)/\(selectedFiles.count) ファイルの処理が完了しました。\(permissionErrorFiles.count)ファイルにアクセス権限がありません。"
                } else {
                    statusMessage = "\(successCount)/\(selectedFiles.count) ファイルの処理が完了しました"
                }
            }
        }
    }
    
    // iCloudからファイルを削除（ローカルコピーのみ）する処理
    private func evictFileFromiCloud(at url: URL) -> (success: Bool, permissionError: Bool) {
        // macOS 10.15 Catalina互換のiCloudファイル操作
        let task = Process()
        
        // macOS 10.15では.executableURLを使う代わりに.launchPathを使用する
        task.launchPath = "/usr/bin/env"
        task.arguments = ["brctl", "evict", url.path]
        
        do {
            // macOS 10.15では.runを使う前に環境を設定する
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            // macOS 10.15との互換性のために直接実行
            try task.run()
            task.waitUntilExit()
            
            // 結果を確認
            let status = task.terminationStatus
            if status != 0 {
                if let data = try pipe.fileHandleForReading.readToEnd(),
                   let output = String(data: data, encoding: .utf8) {
                    print("コマンド実行エラー: \(output)")
                    
                    // 権限エラーの検出
                    if output.contains("Operation not permitted") || 
                       output.contains("Permission denied") ||
                       output.contains("アクセス権限がありません") {
                        return (false, true)
                    }
                }
                return (false, false)
            }
            
            return (true, false)
        } catch {
            print("コマンド実行エラー: \(error.localizedDescription)")
            // 権限エラーの検出
            let errorString = error.localizedDescription
            if errorString.contains("Operation not permitted") || 
               errorString.contains("Permission denied") ||
               errorString.contains("アクセス権限がありません") {
                return (false, true)
            }
            return (false, false)
        }
    }
    
    // ファイルへのアクセス権限を再要求
    private func requestFilePermission() {
        guard !permissionErrorFiles.isEmpty else { return }
        
        // アクセス権限のリクエストダイアログを表示
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.message = "ファイルへのアクセス権限を付与してください"
        panel.prompt = "アクセス権限を付与"
        
        if let url = permissionErrorFiles.first {
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        
        panel.begin { response in
            if response == .OK {
                // 権限が付与されたので、処理を再開
                self.processPermissionGrantedFiles()
            }
        }
    }
    
    // アクセス権限が付与されたファイルを再処理
    private func processPermissionGrantedFiles() {
        guard !permissionErrorFiles.isEmpty else { return }
        
        isProcessing = true
        statusMessage = "アクセス権限が付与されたファイルを処理中..."
        
        let filesToProcess = permissionErrorFiles
        permissionErrorFiles = []
        
        DispatchQueue.global(qos: .userInitiated).async {
            var successCount = 0
            
            for url in filesToProcess {
                let result = evictFileFromiCloud(at: url)
                if result.success {
                    successCount += 1
                } else if result.permissionError {
                    // まだ権限エラーが発生する場合
                    DispatchQueue.main.async {
                        permissionErrorFiles.append(url)
                    }
                }
            }
            
            DispatchQueue.main.async {
                isProcessing = false
                
                if !permissionErrorFiles.isEmpty {
                    // まだ権限エラーがある場合
                    permissionErrorFile = permissionErrorFiles.first?.lastPathComponent ?? ""
                    showPermissionAlert = true
                    statusMessage = "\(successCount)/\(filesToProcess.count) ファイルの追加処理が完了しました。\(permissionErrorFiles.count)ファイルにアクセス権限がありません。"
                } else {
                    statusMessage = "\(successCount)/\(filesToProcess.count) ファイルの追加処理が完了しました"
                }
            }
        }
    }
}

// Catalina互換の簡素化ファイル行表示
struct FileRowSimple: View {
    let url: URL
    @State private var fileSize: String = ""
    @State private var fileDate: String = ""
    
    var body: some View {
        HStack {
            // 簡易的なファイルアイコン（SF Symbolsは使わず絵文字を使用）
            Text("📄")
                .font(.title)
                .padding(.trailing, 5)
            
            VStack(alignment: .leading) {
                Text(url.lastPathComponent)
                    .fontWeight(.medium)
                Text(url.path)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                Text(fileSize)
                Text(fileDate)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(4)
        .onAppear {
            loadFileDetails()
        }
    }
    
    private func loadFileDetails() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            
            // ファイルサイズの整形
            if let size = attributes[.size] as? UInt64 {
                fileSize = formatFileSize(size)
            }
            
            // 更新日の整形
            if let date = attributes[.modificationDate] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                fileDate = formatter.string(from: date)
            }
        } catch {
            print("ファイル情報の取得に失敗: \(error.localizedDescription)")
        }
    }
    
    // ファイルサイズを読みやすい形式に変換
    private func formatFileSize(_ size: UInt64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useAll]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: Int64(size))
    }
}

// macOS 10.15 Catalina互換の拡張
// Catalinaでは直接onChangeを使用できないため、onReceiveを利用
