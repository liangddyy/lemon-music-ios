//
//  AudioStreamCache.swift
//  AudioStreaming
//
//  Optional progressive cache integration for remote audio streams.
//

import Foundation

public protocol AudioStreamCache: AnyObject {
    func configure(
        key: String,
        totalLength: Int,
        mimeType: String?,
        headerLength: Int,
        remoteDataOffset: Int
    )
    func cachedByteCount(for key: String) -> Int
    func totalByteCount(for key: String) -> Int
    func data(for key: String, offset: Int, length: Int) -> Data?
    func store(data: Data, at offset: Int, for key: String)
    func complete(key: String)
}
