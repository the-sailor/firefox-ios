/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import Storage
import XCGLogger

private let log = Logger.syncLogger

// Because generic protocols in Swift are a pain in the ass.
public protocol BookmarkStorer {
    // TODO: this should probably return a timestamp.
    func applyUpstreamCompletionOp(op: UpstreamCompletionOp) -> Deferred<Maybe<POSTResult>>
}

public class UpstreamCompletionOp: PerhapsNoOp {
    // Upload these records from the buffer, but with these child lists.
    public var amendChildrenFromBuffer: [GUID: [GUID]] = [:]

    // Upload these records as-is.
    public var records: [Record<BookmarkBasePayload>] = []

    public let ifUnmodifiedSince: Timestamp?

    public var isNoOp: Bool {
        return records.isEmpty
    }

    public init(ifUnmodifiedSince: Timestamp?=nil) {
        self.ifUnmodifiedSince = ifUnmodifiedSince
    }
}

public struct BookmarksMergeResult: PerhapsNoOp {
    let uploadCompletion: UpstreamCompletionOp
    let overrideCompletion: LocalOverrideCompletionOp
    let bufferCompletion: BufferCompletionOp

    public var isNoOp: Bool {
        return self.uploadCompletion.isNoOp &&
               self.overrideCompletion.isNoOp &&
               self.bufferCompletion.isNoOp
    }

    func applyToClient(client: BookmarkStorer, storage: SyncableBookmarks, buffer: BookmarkBufferStorage) -> Success {
        return client.applyUpstreamCompletionOp(self.uploadCompletion)
          >>== { storage.applyLocalOverrideCompletionOp(self.overrideCompletion, withModifiedTimestamp: $0.modified) }
           >>> { buffer.applyBufferCompletionOp(self.bufferCompletion) }
    }

    static let NoOp = BookmarksMergeResult(uploadCompletion: UpstreamCompletionOp(), overrideCompletion: LocalOverrideCompletionOp(), bufferCompletion: BufferCompletionOp())
}

func guidOnceOnlyStack() -> OnceOnlyStack<GUID, GUID> {
    return OnceOnlyStack<GUID, GUID>(key: { $0 })
}

func nodeOnceOnlyStack() -> OnceOnlyStack<BookmarkTreeNode, GUID> {
    return OnceOnlyStack<BookmarkTreeNode, GUID>(key: { $0.recordGUID })
}

// MARK: - Errors.

public class BookmarksMergeError: MaybeErrorType {
    public var description: String {
        return "Merge error"
    }
}

public class BookmarksMergeConsistencyError: BookmarksMergeError {
    override public var description: String {
        return "Merge consistency error"
    }
}

public class BookmarksMergeErrorTreeIsUnrooted: BookmarksMergeConsistencyError {
    public let roots: Set<GUID>

    public init(roots: Set<GUID>) {
        self.roots = roots
    }

    override public var description: String {
        return "Tree is unrooted: roots are \(self.roots)"
    }
}

protocol MirrorItemSource {
    func getBufferItemWithGUID(guid: GUID) -> Deferred<Maybe<BookmarkMirrorItem>>
    func getBufferItemsWithGUIDs(guids: [GUID]) -> Deferred<Maybe<[GUID: BookmarkMirrorItem]>>
}

enum MergeState<T> {
    case Unknown
    case Unchanged
    case Remote
    case Local
    case New(value: T)
}

class MergedTreeNode {
    let guid: GUID
    let mirror: BookmarkTreeNode?
    var remote: BookmarkTreeNode?
    var local: BookmarkTreeNode?

    var valueState: MergeState<BookmarkMirrorItem> = MergeState.Unknown
    var structureState: MergeState<BookmarkTreeNode> = MergeState.Unknown

    init(guid: GUID, mirror: BookmarkTreeNode?) {
        self.guid = guid
        self.mirror = mirror
    }
}

class MergedTree {
    var root: MergedTreeNode
    var deleted: Set<GUID> = Set()

    init(mirrorRoot: BookmarkTreeNode) {
        self.root = MergedTreeNode(guid: mirrorRoot.recordGUID, mirror: mirrorRoot)
        self.root.valueState = MergeState.Unchanged
        self.root.structureState = MergeState.Unchanged
    }
}