//
//  WelfareSpiderLoader.swift
//  vbox
//
//  福利专区专用远程 Spider 脚本加载器。
//
//  设计边界：
//  - 只服务 serviceType == "welfare_spider" 的福利平台。
//  - 只允许加载 sources/welfare-js/ 下的脚本。
//  - 不注册到 SpiderManager，不参与普通首页、普通搜索和普通播放。
//

import Foundation

enum WelfareSpiderLoaderError: LocalizedError {
    case invalidServiceType(String)
    case missingAPI
    case unsupportedScriptType(String?)
    case invalidScriptPath(String)
    case invalidRemoteURL(String)
    case emptyScript

    var errorDescription: String? {
        switch self {
        case .invalidServiceType(let value):
            return "平台类型不是 welfare_spider：\(value)"
        case .missingAPI:
            return "远程平台未配置 api 脚本路径"
        case .unsupportedScriptType(let value):
            return "暂不支持该脚本类型：\(value ?? "nil")"
        case .invalidScriptPath(let path):
            return "福利 Spider 只允许加载 sources/welfare-js/ 下的脚本：\(path)"
        case .invalidRemoteURL(let value):
            return "无法生成远程脚本地址：\(value)"
        case .emptyScript:
            return "远程脚本内容为空"
        }
    }
}

struct WelfareSpiderScript: Equatable {
    let platformKey: String
    let remoteURL: URL
    let localURL: URL
    let content: String
    let loadedAt: Date
}

final class WelfareSpiderLoader {
    static let shared = WelfareSpiderLoader()

    private let fileManager = FileManager.default

    private init() {}

    func loadScript(for platform: WelfarePlatform) async throws -> WelfareSpiderScript {
        try validate(platform)

        guard let api = platform.api?.trimmingCharacters(in: .whitespacesAndNewlines),
              !api.isEmpty else {
            throw WelfareSpiderLoaderError.missingAPI
        }

        guard let remoteURL = makeRemoteURL(from: api) else {
            throw WelfareSpiderLoaderError.invalidRemoteURL(api)
        }

        let data = try await fetchData(from: remoteURL)
        guard let content = String(data: data, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WelfareSpiderLoaderError.emptyScript
        }

        let localURL = try cacheURL(for: platform, remoteURL: remoteURL)
        try data.write(to: localURL, options: .atomic)

        return WelfareSpiderScript(
            platformKey: platform.platformKey,
            remoteURL: remoteURL,
            localURL: localURL,
            content: content,
            loadedAt: Date()
        )
    }

    func cachedScript(for platform: WelfarePlatform) -> WelfareSpiderScript? {
        guard let api = platform.api,
              let remoteURL = makeRemoteURL(from: api),
              let localURL = try? cacheURL(for: platform, remoteURL: remoteURL),
              fileManager.fileExists(atPath: localURL.path),
              let data = try? Data(contentsOf: localURL),
              let content = String(data: data, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let attributes = try? fileManager.attributesOfItem(atPath: localURL.path)
        let modifiedAt = attributes?[.modificationDate] as? Date

        return WelfareSpiderScript(
            platformKey: platform.platformKey,
            remoteURL: remoteURL,
            localURL: localURL,
            content: content,
            loadedAt: modifiedAt ?? Date()
        )
    }

    private func validate(_ platform: WelfarePlatform) throws {
        guard platform.isWelfareSpider else {
            throw WelfareSpiderLoaderError.invalidServiceType(platform.serviceType)
        }

        let type = platform.scriptType?.lowercased()
        guard type == nil || type == "python" || type == "javascript" else {
            throw WelfareSpiderLoaderError.unsupportedScriptType(platform.scriptType)
        }

        guard let api = platform.api?.trimmingCharacters(in: .whitespacesAndNewlines),
              !api.isEmpty else {
            throw WelfareSpiderLoaderError.missingAPI
        }

        guard isAllowedWelfareScriptPath(api) else {
            throw WelfareSpiderLoaderError.invalidScriptPath(api)
        }
    }

    private func isAllowedWelfareScriptPath(_ api: String) -> Bool {
        let normalized = api
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "./", with: "")
        return normalized.contains("sources/welfare-js/")
            || normalized.hasPrefix("welfare-js/")
    }

    private func makeRemoteURL(from api: String) -> URL? {
        let trimmed = api.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        // 空/无效的默认源地址回退内置默认，仍解析失败则交给调用方走 invalidRemoteURL 错误
        guard let manifest = URL(string: RemoteSourceConfigManager.currentDefaultManifestURL()) else {
            return nil
        }
        let normalized = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "./", with: "")

        if normalized.hasPrefix("sources/") {
            let repoRoot = manifest
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return URL(string: normalized, relativeTo: repoRoot)?.absoluteURL
        }

        if normalized.hasPrefix("welfare-js/") {
            let sourcesRoot = manifest.deletingLastPathComponent()
            return URL(string: normalized, relativeTo: sourcesRoot)?.absoluteURL
        }

        return nil
    }

    private func fetchData(from url: URL) async throws -> Data {
        var lastError: Error?
        for candidate in proxyCandidateURLs(for: url) {
            do {
                var request = URLRequest(url: candidate, timeoutInterval: 20)
                request.setValue("Dart/3.4 (dart:io)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    private func proxyCandidateURLs(for url: URL) -> [URL] {
        let original = url.absoluteString
        guard let host = url.host,
              host.contains("github.io") || host.contains("githubusercontent.com") else {
            return [url]
        }

        var candidates: [URL] = []
        if let fast = URL(string: "https://ghfast.top/" + original) {
            candidates.append(fast)
        }
        if let proxy = URL(string: "https://gh-proxy.com/" + original) {
            candidates.append(proxy)
        }
        candidates.append(url)
        return candidates
    }

    private func cacheURL(for platform: WelfarePlatform, remoteURL: URL) throws -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs
            .appendingPathComponent("remote_sources", isDirectory: true)
            .appendingPathComponent("welfare_spider", isDirectory: true)

        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let ext = remoteURL.pathExtension.isEmpty ? "py" : remoteURL.pathExtension
        let safeKey = platform.platformKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("\(safeKey).\(ext)")
    }
}
