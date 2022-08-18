//===------------------ RawSyntax.swift - Raw Syntax nodes ----------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

typealias RawSyntaxBuffer = UnsafeBufferPointer<RawSyntax?>
typealias RawTriviaPieceBuffer = UnsafeBufferPointer<RawTriviaPiece>

fileprivate extension SyntaxKind {
  /// Whether this node kind should be considered as `hasError` for purposes of `RecursiveRawSyntaxFlags`.
  var hasError: Bool {
    return self == .unexpectedNodes || self.isMissing
  }
}

struct RecursiveRawSyntaxFlags: OptionSet {
  let rawValue: UInt8

  /// Whether the tree contained by this layout has any missing or unexpected nodes.
  static let hasError = RecursiveRawSyntaxFlags(rawValue: 1 << 0)
}

/// Node data for RawSyntax tree. Tagged union plus common data.
internal struct RawSyntaxData {
  internal enum Payload {
    case parsedToken(ParsedToken)
    case materializedToken(MaterializedToken)
    case layout(Layout)
  }

  /// Token with lazy trivia parsing.
  ///
  /// The RawSyntax's `arena` must have a valid trivia parsing function to
  /// lazily materialize the leading/trailing trivia pieces.
  struct ParsedToken {
    var tokenKind: RawTokenKind

    /// Whole text of this token including leading/trailing trivia.
    var wholeText: SyntaxText

    /// Range of the actual token’s text.
    ///
    /// Text in `wholeText` before `textRange.lowerBound` is leading trivia and
    /// after `textRange.upperBound` is trailing trivia.
    var textRange: Range<SyntaxText.Index>
  }

  /// Token typically created with `TokenSyntax.<someToken>`.
  struct MaterializedToken {
    var tokenKind: RawTokenKind
    var tokenText: SyntaxText
    var triviaPieces: RawTriviaPieceBuffer
    var numLeadingTrivia: UInt32
    var byteLength: UInt32
  }

  /// Layout node including collections.
  struct Layout {
    var kind: SyntaxKind
    var layout: RawSyntaxBuffer
    var byteLength: Int
    /// Number of nodes in this subtree, excluding this node.
    var descendantCount: Int
    var recursiveFlags: RecursiveRawSyntaxFlags
  }

  var payload: Payload
  var arenaReference: SyntaxArenaRef
}

extension RawSyntaxData.ParsedToken {
  var tokenText: SyntaxText {
    SyntaxText(rebasing: wholeText[textRange])
  }
  var leadingTriviaText: SyntaxText {
    SyntaxText(rebasing: wholeText[..<textRange.lowerBound])
  }
  var trailingTriviaText: SyntaxText {
    SyntaxText(rebasing: wholeText[textRange.upperBound...])
  }
}

extension RawSyntaxData.MaterializedToken {
  var leadingTrivia: RawTriviaPieceBuffer {
    RawTriviaPieceBuffer(rebasing: triviaPieces[..<Int(numLeadingTrivia)])
  }
  var trailingTrivia: RawTriviaPieceBuffer {
    RawTriviaPieceBuffer(rebasing: triviaPieces[Int(numLeadingTrivia)...])
  }
}

/// Represents the raw tree structure underlying the syntax tree. These nodes
/// have no notion of identity and only provide structure to the tree. They
/// are immutable and can be freely shared between syntax nodes.
@_spi(RawSyntax)
public struct RawSyntax {

  /// Pointer to the actual data which resides in a SyntaxArena.
  var pointer: UnsafePointer<RawSyntaxData>
  init(pointer: UnsafePointer<RawSyntaxData>) {
    self.pointer = pointer
  }

  init(arena: __shared SyntaxArena, payload: RawSyntaxData.Payload) {
    let arenaRef = SyntaxArenaRef(arena)
    self.init(pointer: arena.intern(RawSyntaxData(payload: payload, arenaReference: arenaRef)))
  }

  var rawData: RawSyntaxData {
    unsafeAddress { pointer }
  }

  internal var arenaReference: SyntaxArenaRef {
    rawData.arenaReference
  }

  internal var arena: SyntaxArena {
    rawData.arenaReference.value
  }

  internal var payload: RawSyntaxData.Payload {
    _read { yield rawData.payload }
  }
}

// MARK: - Accessors

extension RawSyntax {
  /// The syntax kind of this raw syntax.
  var kind: SyntaxKind {
    switch rawData.payload {
    case .parsedToken(_): return .token
    case .materializedToken(_): return .token
    case .layout(let dat): return dat.kind
    }
  }

  /// Whether or not this node is a token one.
  var isToken: Bool {
    kind == .token
  }

  /// Whether or not this node is a collection one.
  var isCollection: Bool {
    kind.isSyntaxCollection
  }

  /// Whether or not this node is an unknown one.
  var isUnknown: Bool {
    kind.isUnknown
  }

  var recursiveFlags: RecursiveRawSyntaxFlags {
    switch rawData.payload {
    case .materializedToken, .parsedToken:
      var recursiveFlags: RecursiveRawSyntaxFlags = []
      if presence == .missing {
        recursiveFlags.insert(.hasError)
      }
      return recursiveFlags
    case .layout(let dat):
      return dat.recursiveFlags
    }
  }

  /// Child nodes.
  var children: RawSyntaxBuffer {
    switch rawData.payload {
    case .parsedToken(_),
         .materializedToken(_):
      return .init(start: nil, count: 0)
    case .layout(let dat):
      return dat.layout
    }
  }

  func child(at index: Int) -> RawSyntax? {
    guard hasChild(at: index) else { return nil }
    return children[index]
  }

  func hasChild(at index: Int) -> Bool {
    children[index] != nil
  }

  /// The number of children, `present` or `missing`, in this node.
  var numberOfChildren: Int {
    return children.count
  }

  /// Total number of nodes in this sub-tree, including `self` node.
  var totalNodes: Int {
    switch rawData.payload {
    case .parsedToken(_),
         .materializedToken(_):
      return 1
    case .layout(let dat):
      return dat.descendantCount + 1
    }
  }

  var presence: SourcePresence {
    if self.byteLength != 0 {
      // The node has source text associated with it. It's present.
      return .present
    }
    if self.isCollection || self.isUnknown {
      // We always consider collections 'present' because they can just be empty.
      return .present
    }
    if isToken && (self.tokenView!.rawKind == .eof || self.tokenView!.rawKind == .stringSegment) {
      // The end of file token never has source code associated with it but we
      // still consider it valid.
      // String segments can be empty if they occur in an empty string literal or in between two interpolation segments.
      return .present
    }

    // If none of the above apply, the node is missing.
    return .missing
  }

  /// The "width" of the node.
  ///
  /// Sum of text byte lengths of all descendant token nodes.
  var byteLength: Int {
    switch rawData.payload {
    case .parsedToken(let dat): return dat.wholeText.count
    case .materializedToken(let dat): return Int(dat.byteLength)
    case .layout(let dat): return dat.byteLength
    }
  }

  var totalLength: SourceLength {
    SourceLength(utf8Length: byteLength)
  }

  /// Replaces the leading trivia of the first token in this syntax tree by `leadingTrivia`.
  /// If the syntax tree did not contain a token and thus no trivia could be attached to it, `nil` is returned.
  /// - Parameters:
  ///   - leadingTrivia: The trivia to attach.
  func withLeadingTrivia(_ leadingTrivia: Trivia) -> RawSyntax? {
    switch view {
    case .token(let tokenView):
      return .makeMaterializedToken(
        kind: tokenView.formKind(),
        leadingTrivia: leadingTrivia,
        trailingTrivia: tokenView.formTrailingTrivia(),
        arena: arena)
    case .layout(let layoutView):
      for (index, child) in children.enumerated() {
        if let replaced = child?.withLeadingTrivia(leadingTrivia) {
          return layoutView.replacingChild(at: index, with: replaced, arena: arena)
        }
      }
      return nil
    }
  }

  /// Replaces the trailing trivia of the last token in this syntax tree by `trailingTrivia`.
  /// If the syntax tree did not contain a token and thus no trivia could be attached to it, `nil` is returned.
  /// - Parameters:
  ///   - trailingTrivia: The trivia to attach.
  func withTrailingTrivia(_ trailingTrivia: Trivia) -> RawSyntax? {
    switch view {
    case .token(let tokenView):
      return .makeMaterializedToken(
        kind: tokenView.formKind(),
        leadingTrivia: tokenView.formLeadingTrivia(),
        trailingTrivia: trailingTrivia,
        arena: arena)
    case .layout(let layoutView):
      for (index, child) in children.enumerated().reversed() {
        if let replaced = child?.withTrailingTrivia(trailingTrivia) {
          return layoutView.replacingChild(at: index, with: replaced, arena: arena)
        }
      }
      return nil
    }
  }

  /// Returns the child at the provided cursor in the layout.
  /// - Parameter index: The index of the child you're accessing.
  /// - Returns: The child at the provided index.
  subscript<CursorType: RawRepresentable>(_ index: CursorType) -> RawSyntax?
    where CursorType.RawValue == Int {
    return child(at: index.rawValue)
  }
}

extension RawSyntax {
  func toOpaque() -> UnsafeRawPointer {
    UnsafeRawPointer(pointer)
  }

  static func fromOpaque(_ pointer: UnsafeRawPointer) -> RawSyntax {
    Self(pointer: pointer.assumingMemoryBound(to: RawSyntaxData.self))
  }
}

extension RawSyntax: TextOutputStreamable, CustomStringConvertible {
  /// Prints the RawSyntax node, and all of its children, to the provided
  /// stream. This implementation must be source-accurate.
  /// - Parameter stream: The stream on which to output this node.
  public func write<Target: TextOutputStream>(to target: inout Target) {
    switch rawData.payload {
    case .parsedToken(let dat):
      String(syntaxText: dat.wholeText).write(to: &target)
      break
    case .materializedToken(let dat):
      for p in dat.leadingTrivia { p.write(to: &target) }
      String(syntaxText: dat.tokenText).write(to: &target)
      for p in dat.trailingTrivia { p.write(to: &target) }
      break
    case .layout(let dat):
      for case let child? in dat.layout {
        child.write(to: &target)
      }
      break
    }
  }

  /// A source-accurate description of this node.
  public var description: String {
    var s = ""
    self.write(to: &s)
    return s
  }
}

extension RawSyntax {
  /// Return the first token of a layout node that should be traversed by `viewMode`.
  func firstToken(viewMode: SyntaxTreeViewMode) -> RawSyntaxTokenView? {
    guard viewMode.shouldTraverse(node: self) else { return nil }
    switch view {
    case .token(let tokenView):
      return tokenView
    case .layout:
      for child in children {
        if let token = child?.firstToken(viewMode: viewMode) {
          return token
        }
      }
      return nil
    }
  }

  /// Return the last token of a layout node that should be traversed by `viewMode`.
  func lastToken(viewMode: SyntaxTreeViewMode) -> RawSyntaxTokenView? {
    guard viewMode.shouldTraverse(node: self) else { return nil }
    switch view {
    case .token(let tokenView):
      return tokenView
    case .layout:
      for child in children.reversed() {
        if let token = child?.lastToken(viewMode: viewMode) {
          return token
        }
      }
      return nil
    }
  }

  func formLeadingTrivia() -> Trivia? {
    firstToken(viewMode: .sourceAccurate)?.formLeadingTrivia()
  }

  func formTrailingTrivia() -> Trivia? {
    lastToken(viewMode: .sourceAccurate)?.formTrailingTrivia()
  }
}

extension RawSyntax {
  var leadingTriviaByteLength: Int {
    firstToken(viewMode: .sourceAccurate)?.leadingTriviaByteLength ?? 0
  }

  var trailingTriviaByteLength: Int {
    lastToken(viewMode: .sourceAccurate)?.trailingTriviaByteLength ?? 0
  }

  /// The length of this node’s content, without the first leading and the last
  /// trailing trivia. Intermediate trivia inside a layout node is included in
  /// this.
  var contentByteLength: Int {
    let result = byteLength - leadingTriviaByteLength - trailingTriviaByteLength
    assert(result >= 0)
    return result
  }

  var leadingTriviaLength: SourceLength {
    SourceLength(utf8Length: leadingTriviaByteLength)
  }

  var trailingTriviaLength: SourceLength {
    SourceLength(utf8Length: trailingTriviaByteLength)
  }

  /// The length of this node excluding its leading and trailing trivia.
  var contentLength: SourceLength {
    SourceLength(utf8Length: contentByteLength)
  }
}

// MARK: - Factories.

private func makeRawTriviaPieces(leadingTrivia: Trivia, trailingTrivia: Trivia, arena: SyntaxArena) -> (pieces: RawTriviaPieceBuffer, byteLength: Int) {
  let totalTriviaCount = leadingTrivia.count + trailingTrivia.count

  if totalTriviaCount != 0 {
    var byteLength = 0
    let buffer = arena.allocateRawTriviaPieceBuffer(count: totalTriviaCount)
    var ptr = buffer.baseAddress!
    for piece in leadingTrivia + trailingTrivia {
      byteLength += piece.sourceLength.utf8Length
      ptr.initialize(to: .make(piece, arena: arena))
      ptr = ptr.advanced(by: 1)
    }
    return (pieces: .init(buffer), byteLength: byteLength)
  } else {
    return (pieces: .init(start: nil, count: 0), byteLength: 0)
  }
}

extension RawSyntax {
  /// "Designated" factory method to create a parsed token node.
  ///
  /// - Parameters:
  ///   - kind: Token kind.
  ///   - wholeText: Whole text of this token including trailing/leading trivia.
  ///   - textRange: Range of the token text in `wholeText`.
  ///   - arena: SyntaxArea to the result node data resides.
  internal static func parsedToken(
    kind: RawTokenKind,
    wholeText: SyntaxText,
    textRange: Range<SyntaxText.Index>,
    arena: SyntaxArena
  ) -> RawSyntax {
    let payload = RawSyntaxData.ParsedToken(
      tokenKind: kind, wholeText: wholeText, textRange: textRange)
    return RawSyntax(arena: arena, payload: .parsedToken(payload))
  }

  /// "Designated" factory method to create a materialized token node.
  ///
  /// This should not be called directly.
  /// Use `makeMaterializedToken(arena:kind:leadingTrivia:trailingTrivia:)` or
  /// `makeMissingToken(arena:kind:)` instead.
  ///
  /// - Parameters:
  ///   - arena: SyntaxArea to the result node data resides.
  ///   - kind: Token kind.
  ///   - text: Token text.
  ///   - triviaPieces: Raw trivia pieces including leading and trailing trivia.
  ///   - numLeadingTrivia: Number of leading trivia pieces in `triviaPieces`.
  ///   - byteLength: Byte length of this token including trivia.
  internal static func materializedToken(
    kind: RawTokenKind,
    text: SyntaxText,
    triviaPieces: RawTriviaPieceBuffer,
    numLeadingTrivia: UInt32,
    byteLength: UInt32,
    arena: SyntaxArena
  ) -> RawSyntax {
    let payload = RawSyntaxData.MaterializedToken(
      tokenKind: kind, tokenText: text,
      triviaPieces: triviaPieces,
      numLeadingTrivia: numLeadingTrivia,
      byteLength: byteLength)
    return RawSyntax(arena: arena, payload: .materializedToken(payload))
  }

  /// Factory method to create a materialized token node.
  ///
  /// - Parameters:
  ///   - arena: SyntaxArea to the result node data resides.
  ///   - kind: Token kind.
  ///   - text: Token text.
  ///   - leadingTrivia: Leading trivia.
  ///   - trailingTrivia: Trailing trivia.
  static func makeMaterializedToken(
    kind: TokenKind,
    leadingTrivia: Trivia,
    trailingTrivia: Trivia,
    presence: SourcePresence = .present,
    arena: SyntaxArena
  ) -> RawSyntax {
    let decomposed = kind.decomposeToRaw()
    let rawKind = decomposed.rawKind
    let text: SyntaxText
    switch presence {
    case .present:
      text = (decomposed.string.map({arena.intern($0)}) ??
              decomposed.rawKind.defaultText ??
              "")
    case .missing:
      text = SyntaxText()
    }

    var byteLength = text.count

    let triviaPieces = makeRawTriviaPieces(
      leadingTrivia: leadingTrivia, trailingTrivia: trailingTrivia, arena: arena)

    byteLength += triviaPieces.byteLength

    return .materializedToken(
      kind: rawKind, text: text, triviaPieces: triviaPieces.pieces,
      numLeadingTrivia: numericCast(leadingTrivia.count),
      byteLength: numericCast(byteLength),
      arena: arena)
  }

  static func makeMissingToken(
    kind: TokenKind,
    arena: SyntaxArena
  ) -> RawSyntax {
    let (rawKind, _) = kind.decomposeToRaw()
    return .materializedToken(
      kind: rawKind, text: "", triviaPieces: .init(start: nil, count: 0),
      numLeadingTrivia: 0, byteLength: 0,
      arena: arena)
  }
}

extension RawSyntax {
  /// "Designated" factory method to create a layout node.
  ///
  /// This should not be called directly.
  /// Use `makeLayout(arena:kind:uninitializedCount:initializingWith:)` or
  /// `makeEmptyLayout(arena:kind:)` instead.
  ///
  /// - Parameters:
  ///   - arena: SyntaxArea to the result node data resides.
  ///   - kind: Syntax kind. This should not be `.token`.
  ///   - layout: Layout buffer of the children.
  ///   - byteLength: Computed total byte length of this node.
  ///   - descedantCount: Total number of the descendant nodes in `layout`.
  fileprivate static func layout(
    kind: SyntaxKind,
    layout: RawSyntaxBuffer,
    byteLength: Int,
    descendantCount: Int,
    recursiveFlags: RecursiveRawSyntaxFlags,
    arena: SyntaxArena
  ) -> RawSyntax {
    validateLayout(layout: layout, as: kind)
    let payload = RawSyntaxData.Layout(
      kind: kind, layout: layout,
      byteLength: byteLength, descendantCount: descendantCount, recursiveFlags: recursiveFlags)
    return RawSyntax(arena: arena, payload: .layout(payload))
  }

  /// Factory method to create a layout node.
  ///
  /// - Parameters:
  ///   - arena: SyntaxArea to the result node data resides.
  ///   - kind: Syntax kind.
  ///   - count: Number of children.
  ///   - initializer: A closure that initializes elements.
  static func makeLayout(
    kind: SyntaxKind,
    uninitializedCount count: Int,
    arena: SyntaxArena,
    initializingWith initializer: (UnsafeMutableBufferPointer<RawSyntax?>) -> Void
  ) -> RawSyntax {
    // Allocate and initialize the list.
    let layoutBuffer = arena.allocateRawSyntaxBuffer(count: count)
    initializer(layoutBuffer)

    // Calculate the "byte width".
    var byteLength = 0
    var descendantCount = 0
    var recursiveFlags = RecursiveRawSyntaxFlags()
    if kind.hasError {
      recursiveFlags.insert(.hasError)
    }
    for case let node? in layoutBuffer {
      byteLength += node.byteLength
      descendantCount += node.totalNodes
      recursiveFlags.insert(node.recursiveFlags)
      arena.addChild(node.arenaReference)
    }
    return .layout(
      kind: kind,
      layout: RawSyntaxBuffer(layoutBuffer),
      byteLength: byteLength,
      descendantCount: descendantCount,
      recursiveFlags: recursiveFlags,
      arena: arena
    )
  }

  static func makeEmptyLayout(
    kind: SyntaxKind,
    arena: SyntaxArena
  ) -> RawSyntax {
    var recursiveFlags = RecursiveRawSyntaxFlags()
    if kind.hasError {
      recursiveFlags.insert(.hasError)
    }
    return .layout(
      kind: kind,
      layout: .init(start: nil, count: 0),
      byteLength: 0,
      descendantCount: 0,
      recursiveFlags: recursiveFlags,
      arena: arena
    )
  }

  static func makeLayout<C: Collection>(
    kind: SyntaxKind,
    from collection: C,
    arena: SyntaxArena
  ) -> RawSyntax where C.Element == RawSyntax? {
    .makeLayout(kind: kind, uninitializedCount: collection.count, arena: arena) {
      _ = $0.initialize(from: collection)
    }
  }
}

// MARK: - Debugging.

extension RawSyntax: CustomDebugStringConvertible {

  private func debugWrite<Target: TextOutputStream>(to target: inout Target, indent: Int, withChildren: Bool = false) {
    let childIndent = indent + 2
    switch rawData.payload {
    case .parsedToken(let dat):
      target.write(".parsedToken(")
      target.write(String(describing: dat.tokenKind))
      target.write(" wholeText=\(dat.tokenText.debugDescription)")
      target.write(" textRange=\(dat.textRange.description)")
    case .materializedToken(let dat):
      target.write(".materializedToken(")
      target.write(String(describing: dat.tokenKind))
      target.write(" text=\(dat.tokenText.debugDescription)")
      target.write(" numLeadingTrivia=\(dat.numLeadingTrivia)")
      target.write(" byteLength=\(dat.byteLength)")
      break
    case .layout(let dat):
      target.write(".layout(")
      target.write(String(describing: kind))
      target.write(" byteLength=\(dat.byteLength)")
      target.write(" descendantCount=\(dat.descendantCount)")
      if withChildren {
        for (num, child) in dat.layout.enumerated() {
          target.write("\n")
          target.write(String(repeating: " ", count: childIndent))
          target.write("\(num): ")
          if let child = child {
            child.debugWrite(to: &target, indent: childIndent)
          } else {
            target.write("<nil>")
          }
        }
      }
      break
    }
    target.write(")")
  }

  public var debugDescription: String {
    var string = ""
    debugWrite(to: &string, indent: 0, withChildren: false)
    return string
  }
}

extension RawSyntax: CustomReflectable {
  public var customMirror: Mirror {
    let mirrorChildren: [Any] = children.map {
      child in child ?? (nil as Any?) as Any
    }
    return Mirror(self, unlabeledChildren: mirrorChildren)
  }
}

enum RawSyntaxView {
  case token(RawSyntaxTokenView)
  case layout(RawSyntaxLayoutView)
}

extension RawSyntax {
  var view: RawSyntaxView {
    switch raw.payload {
    case .parsedToken, .materializedToken:
      return .token(tokenView!)
    case .layout:
      return .layout(layoutView!)
    }
  }
}

