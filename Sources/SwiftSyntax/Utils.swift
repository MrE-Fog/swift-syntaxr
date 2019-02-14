//===-------------------- Utils.swift - Utility Functions -----------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public struct ByteSourceRange: Equatable {
  public let offset: Int
  public let length: Int

  public init(offset: Int, length: Int) {
    self.offset = offset
    self.length = length
  }

  public var endOffset: Int {
    return offset+length
  }

  public var isEmpty: Bool {
    return length == 0
  }

  public func intersectsOrTouches(_ other: ByteSourceRange) -> Bool {
    return self.endOffset >= other.offset &&
      self.offset <= other.endOffset
  }

  public func intersects(_ other: ByteSourceRange) -> Bool {
    return self.endOffset > other.offset &&
      self.offset < other.endOffset
  }

  /// Returns the byte range for the overlapping region between two ranges.
  public func intersected(_ other: ByteSourceRange) -> ByteSourceRange {
    let start = max(self.offset, other.offset)
    let end = min(self.endOffset, other.endOffset)
    if start > end {
      return ByteSourceRange(offset: 0, length: 0)
    } else {
      return ByteSourceRange(offset: start, length: end-start)
    }
  }
}

public struct SourceEdit {
  /// The byte range of the original source buffer that the edit applies to.
  public let range: ByteSourceRange
  /// The length of the edit replacement in UTF8 bytes.
  public let replacementLength: Int

  public init(range: ByteSourceRange, replacementLength: Int) {
    self.range = range
    self.replacementLength = replacementLength
  }

  public func intersectsOrTouchesRange(_ other: ByteSourceRange) -> Bool {
    return self.range.intersectsOrTouches(other)
  }

  public func intersectsRange(_ other: ByteSourceRange) -> Bool {
    return self.range.intersects(other)
  }
}

extension String {
  static func fromBuffer(_ textBuffer: UnsafeBufferPointer<UInt8>) -> String {
    return String(decoding: textBuffer, as: UTF8.self)
  }

  var isNativeUTF8: Bool {
    return utf8.withContiguousStorageIfAvailable { _ in 0 } != nil
  }

  mutating func makeNativeUTF8IfNeeded() {
    if !isNativeUTF8 {
      self += ""
    }
  }

  func utf8Slice(offset: Int, length: Int) -> Substring {
    if length == 0 {
      return Substring()
    }
    let utf8 = self.utf8
    let begin = utf8.index(utf8.startIndex, offsetBy: offset)
    let end = utf8.index(begin, offsetBy: length)
    return Substring(utf8[begin..<end])
  }
}
