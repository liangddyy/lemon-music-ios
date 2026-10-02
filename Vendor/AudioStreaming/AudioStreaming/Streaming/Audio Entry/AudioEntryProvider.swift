//
//  Created by Dimitrios Chatzieleftheriou on 11/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

protocol AudioEntryProviding {
    func provideAudioEntry(url: URL, httpMethod: String?, httpBody: Data?, headers: [String: String]) -> AudioEntry
    func provideAudioEntry(url: URL, headers: [String: String]) -> AudioEntry
    func provideAudioEntry(url: URL, headers: [String: String], cacheKey: String) -> AudioEntry
    func provideAudioEntry(url: URL, headers: [String: String], cacheKey: String?, playbackID: String) -> AudioEntry
    func provideAudioEntry(url: URL) -> AudioEntry
}

final class AudioEntryProvider: AudioEntryProviding {
    private let networkingClient: NetworkingClient
    private let underlyingQueue: DispatchQueue
    private let outputAudioFormat: AVAudioFormat
    private weak var streamCache: AudioStreamCache?

    init(networkingClient: NetworkingClient,
         underlyingQueue: DispatchQueue,
         outputAudioFormat: AVAudioFormat,
         streamCache: AudioStreamCache?)
    {
        self.networkingClient = networkingClient
        self.underlyingQueue = underlyingQueue
        self.outputAudioFormat = outputAudioFormat
        self.streamCache = streamCache
    }

    func provideAudioEntry(url: URL, headers: [String: String]) -> AudioEntry {
        let source = self.source(for: url, httpMethod: nil, httpBody: nil, headers: headers, cacheKey: nil)
        return AudioEntry(source: source,
                          entryId: AudioEntryId(id: url.absoluteString),
                          outputAudioFormat: outputAudioFormat)
    }

    func provideAudioEntry(url: URL, headers: [String: String], cacheKey: String) -> AudioEntry {
        let source = self.source(for: url, httpMethod: nil, httpBody: nil, headers: headers, cacheKey: cacheKey)
        return AudioEntry(source: source,
                          entryId: AudioEntryId(id: url.absoluteString),
                          outputAudioFormat: outputAudioFormat)
    }

    func provideAudioEntry(url: URL, headers: [String: String], cacheKey: String?, playbackID: String) -> AudioEntry {
        let source = self.source(for: url, httpMethod: nil, httpBody: nil, headers: headers, cacheKey: cacheKey)
        return AudioEntry(source: source, entryId: AudioEntryId(id: playbackID), outputAudioFormat: outputAudioFormat)
    }
    
    func provideAudioEntry(url: URL, httpMethod: String?, httpBody: Data?, headers: [String: String]) -> AudioEntry {
        let source = self.source(for: url, httpMethod: httpMethod, httpBody: httpBody, headers: headers, cacheKey: nil)
        return AudioEntry(source: source,
                          entryId: AudioEntryId(id: url.absoluteString),
                          outputAudioFormat: outputAudioFormat)
    }

    func provideAudioEntry(url: URL) -> AudioEntry {
        provideAudioEntry(url: url, headers: [:])
    }
    
    func provideAudioSource(
        url: URL,
        httpMethod: String?,
        httpBody: Data?,
        headers: [String: String],
        cacheKey: String?
    ) -> AudioStreamSource {
        RemoteAudioSource(networking: networkingClient,
                          url: url,
                          httpMethod: httpMethod,
                          httpBody: httpBody,
                          underlyingQueue: underlyingQueue,
                          httpHeaders: headers,
                          streamCache: streamCache,
                          cacheKey: cacheKey)
    }

    func provideFileAudioSource(url: URL) -> CoreAudioStreamSource {
        FileAudioSource(url: url, underlyingQueue: underlyingQueue)
    }

    func source(
        for url: URL,
        httpMethod: String?,
        httpBody: Data?,
        headers: [String: String],
        cacheKey: String?
    ) -> CoreAudioStreamSource {
        guard !url.isFileURL else {
            return provideFileAudioSource(url: url)
        }
        return provideAudioSource(
            url: url,
            httpMethod: httpMethod,
            httpBody: httpBody,
            headers: headers,
            cacheKey: cacheKey
        )
    }
}
