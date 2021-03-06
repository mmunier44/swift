//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

/// A wrapper around _RawSetStorage that provides most of the
/// implementation of Set.
@usableFromInline
@_fixed_layout
internal struct _NativeSet<Element: Hashable> {
  /// See the comments on _RawSetStorage and its subclasses to understand why we
  /// store an untyped storage here.
  @usableFromInline
  internal var _storage: _RawSetStorage

  /// Constructs an instance from the empty singleton.
  @inlinable
  @inline(__always)
  internal init() {
    self._storage = _RawSetStorage.empty
  }

  /// Constructs a native set adopting the given storage.
  @inlinable
  @inline(__always)
  internal init(_ storage: __owned _RawSetStorage) {
    self._storage = storage
  }

  @inlinable
  internal init(capacity: Int) {
    self._storage = _SetStorage<Element>.allocate(capacity: capacity)
  }

#if _runtime(_ObjC)
  @inlinable
  internal init(_ cocoa: __owned _CocoaSet) {
    self.init(cocoa, capacity: cocoa.count)
  }

  @inlinable
  internal init(_ cocoa: __owned _CocoaSet, capacity: Int) {
    _sanityCheck(cocoa.count <= capacity)
    self.init(capacity: capacity)
    for element in cocoa {
      let nativeElement = _forceBridgeFromObjectiveC(element, Element.self)
      insertNew(nativeElement, isUnique: true)
    }
  }
#endif
}

extension _NativeSet { // Primitive fields
  @usableFromInline
  internal typealias Bucket = _HashTable.Bucket

  @inlinable
  internal var capacity: Int {
    @inline(__always)
    get {
      return _assumeNonNegative(_storage._capacity)
    }
  }

  @inlinable
  internal var hashTable: _HashTable {
    @inline(__always) get {
      return _storage._hashTable
    }
  }

  // This API is unsafe and needs a `_fixLifetime` in the caller.
  @inlinable
  internal var _elements: UnsafeMutablePointer<Element> {
    return _storage._rawElements.assumingMemoryBound(to: Element.self)
  }
}

extension _NativeSet { // Low-level unchecked operations
  @inlinable
  @inline(__always)
  internal func uncheckedElement(at bucket: Bucket) -> Element {
    defer { _fixLifetime(self) }
    _sanityCheck(hashTable.isOccupied(bucket))
    return _elements[bucket.offset]
  }

  @inlinable
  @inline(__always)
  internal func uncheckedInitialize(
    at bucket: Bucket,
    to element: __owned Element) {
    _sanityCheck(hashTable.isValid(bucket))
    (_elements + bucket.offset).initialize(to: element)
  }
}

extension _NativeSet { // Low-level lookup operations
  @inlinable
  @inline(__always)
  internal func hashValue(for element: Element) -> Int {
    return element._rawHashValue(seed: _storage._seed)
  }

  @inlinable
  @inline(__always)
  internal func find(_ element: Element) -> (bucket: Bucket, found: Bool) {
    return find(element, hashValue: self.hashValue(for: element))
  }

  /// Search for a given element, assuming it has the specified hash value.
  ///
  /// If the element is not present in this set, return the position where it
  /// could be inserted.
  @inlinable
  @inline(__always)
  internal func find(
    _ element: Element,
    hashValue: Int
  ) -> (bucket: Bucket, found: Bool) {
    let hashTable = self.hashTable
    var bucket = hashTable.idealBucket(forHashValue: hashValue)
    while hashTable._isOccupied(bucket) {
      if uncheckedElement(at: bucket) == element {
        return (bucket, true)
      }
      bucket = hashTable.bucket(wrappedAfter: bucket)
    }
    return (bucket, false)
  }
}

extension _NativeSet { // ensureUnique
  @inlinable
  internal mutating func resize(capacity: Int) {
    let capacity = Swift.max(capacity, self.capacity)
    let result = _NativeSet(_SetStorage<Element>.allocate(capacity: capacity))
    if count > 0 {
      for bucket in hashTable {
        let element = (self._elements + bucket.offset).move()
        result._unsafeInsertNew(element)
      }
      // Clear out old storage, ensuring that its deinit won't overrelease the
      // elements we've just moved out.
      _storage._hashTable.clear()
      _storage._count = 0
    }
    _storage = result._storage
  }

  @inlinable
  internal mutating func copy(capacity: Int) -> Bool {
    let capacity = Swift.max(capacity, self.capacity)
    let (newStorage, rehash) = _SetStorage<Element>.reallocate(
      original: _storage,
      capacity: capacity)
    let result = _NativeSet(newStorage)
    if count > 0 {
      if rehash {
        for bucket in hashTable {
          result._unsafeInsertNew(self.uncheckedElement(at: bucket))
        }
      } else {
        result.hashTable.copyContents(of: hashTable)
        result._storage._count = self.count
        for bucket in hashTable {
          let element = uncheckedElement(at: bucket)
          result.uncheckedInitialize(at: bucket, to: element)
        }
      }
    }
    _storage = result._storage
    return rehash
  }

  /// Ensure storage of self is uniquely held and can hold at least `capacity`
  /// elements. Returns true iff contents were rehashed.
  @inlinable
  @inline(__always)
  internal mutating func ensureUnique(isUnique: Bool, capacity: Int) -> Bool {
    if _fastPath(capacity <= self.capacity && isUnique) {
      return false
    }
    guard isUnique else {
      return copy(capacity: capacity)
    }
    resize(capacity: capacity)
    return true
  }

  @inlinable
  internal mutating func reserveCapacity(_ capacity: Int, isUnique: Bool) {
    _ = ensureUnique(isUnique: isUnique, capacity: capacity)
  }
}

extension _NativeSet: _SetBuffer {
  @usableFromInline
  internal typealias Index = Bucket

  @inlinable
  internal var startIndex: Index {
    return hashTable.startBucket
  }

  @inlinable
  internal var endIndex: Index {
    return hashTable.endBucket
  }

  @inlinable
  internal func index(after index: Index) -> Index {
    return hashTable.occupiedBucket(after: index)
  }

  @inlinable
  @inline(__always)
  internal func index(for element: Element) -> Index? {
    if count == 0 {
      // Fast path that avoids computing the hash of the key.
      return nil
    }
    let (bucket, found) = find(element)
    guard found else { return nil }
    return bucket
  }

  @inlinable
  internal var count: Int {
    @inline(__always) get {
      return _assumeNonNegative(_storage._count)
    }
  }

  @inlinable
  @inline(__always)
  internal func contains(_ member: Element) -> Bool {
    // Fast path: Don't calculate the hash if the set has no elements.
    if count == 0 { return false }
    return find(member).found
  }

  @inlinable
  @inline(__always)
  internal func element(at index: Index) -> Element {
    hashTable.checkOccupied(index)
    return _elements[index.offset]
  }
}

// This function has a highly visible name to make it stand out in stack traces.
@usableFromInline
@inline(never)
internal func ELEMENT_TYPE_OF_SET_VIOLATES_HASHABLE_REQUIREMENTS(
  _ elementType: Any.Type
) -> Never {
  _assertionFailure(
    "Fatal error",
    """
    Duplicate elements of type '\(elementType)' were found in a Set.
    This usually means either that the type violates Hashable's requirements, or
    that members of such a set were mutated after insertion.
    """,
    flags: _fatalErrorFlags())
}

extension _NativeSet { // Insertions
  /// Insert a new element into uniquely held storage.
  /// Storage must be uniquely referenced with adequate capacity.
  /// The `element` must not be already present in the Set.
  @inlinable
  internal func _unsafeInsertNew(_ element: __owned Element) {
    _sanityCheck(count + 1 <= capacity)
    let hashValue = self.hashValue(for: element)
    if _isDebugAssertConfiguration() {
      // In debug builds, perform a full lookup and trap if we detect duplicate
      // elements -- these imply that the Element type violates Hashable
      // requirements. This is generally more costly than a direct insertion,
      // because we'll need to compare elements in case of hash collisions.
      let (bucket, found) = find(element, hashValue: hashValue)
      guard !found else {
        ELEMENT_TYPE_OF_SET_VIOLATES_HASHABLE_REQUIREMENTS(Element.self)
      }
      hashTable.insert(bucket)
      uncheckedInitialize(at: bucket, to: element)
    } else {
      let bucket = hashTable.insertNew(hashValue: hashValue)
      uncheckedInitialize(at: bucket, to: element)
    }
    _storage._count += 1
  }

  /// Insert a new element into uniquely held storage.
  /// Storage must be uniquely referenced.
  /// The `element` must not be already present in the Set.
  @inlinable
  internal mutating func insertNew(_ element: __owned Element, isUnique: Bool) {
    _ = ensureUnique(isUnique: isUnique, capacity: count + 1)
    _unsafeInsertNew(element)
  }

  @inlinable
  internal func _unsafeInsertNew(_ element: __owned Element, at bucket: Bucket) {
    hashTable.insert(bucket)
    uncheckedInitialize(at: bucket, to: element)
    _storage._count += 1
  }

  @inlinable
  internal mutating func insertNew(
    _ element: __owned Element,
    at bucket: Bucket,
    isUnique: Bool
  ) {
    _sanityCheck(!hashTable.isOccupied(bucket))
    var bucket = bucket
    let rehashed = ensureUnique(isUnique: isUnique, capacity: count + 1)
    if rehashed {
      let (b, f) = find(element)
      if f {
        ELEMENT_TYPE_OF_SET_VIOLATES_HASHABLE_REQUIREMENTS(Element.self)
      }
      bucket = b
    }
    _unsafeInsertNew(element, at: bucket)
  }

  @inlinable
  internal mutating func update(
    with element: __owned Element,
    isUnique: Bool
  ) -> Element? {
    var (bucket, found) = find(element)
    let rehashed = ensureUnique(
      isUnique: isUnique,
      capacity: count + (found ? 0 : 1))
    if rehashed {
      let (b, f) = find(element)
      if f != found {
        ELEMENT_TYPE_OF_SET_VIOLATES_HASHABLE_REQUIREMENTS(Element.self)
      }
      bucket = b
    }
    if found {
      let old = (_elements + bucket.offset).move()
      uncheckedInitialize(at: bucket, to: element)
      return old
    }
    _unsafeInsertNew(element, at: bucket)
    return nil
  }
}

extension _NativeSet: _HashTableDelegate {
  @inlinable
  @inline(__always)
  internal func hashValue(at bucket: Bucket) -> Int {
    return hashValue(for: uncheckedElement(at: bucket))
  }

  @inlinable
  @inline(__always)
  internal func moveEntry(from source: Bucket, to target: Bucket) {
    (_elements + target.offset)
      .moveInitialize(from: _elements + source.offset, count: 1)
  }
}

extension _NativeSet { // Deletion
  @inlinable
  internal mutating func _delete(at bucket: Bucket) {
    hashTable.delete(at: bucket, with: self)
    _storage._count -= 1
  }

  @inlinable
  @inline(__always)
  internal mutating func uncheckedRemove(
    at bucket: Bucket,
    isUnique: Bool) -> Element {
    _sanityCheck(hashTable.isOccupied(bucket))
    let rehashed = ensureUnique(isUnique: isUnique, capacity: capacity)
    _sanityCheck(!rehashed)
    let old = (_elements + bucket.offset).move()
    _delete(at: bucket)
    return old
  }

  @inlinable
  @inline(__always)
  internal mutating func remove(at index: Index, isUnique: Bool) -> Element {
    _precondition(hashTable.isOccupied(index), "Invalid index")
    return uncheckedRemove(at: index, isUnique: isUnique)
  }

  @usableFromInline
  internal mutating func removeAll(isUnique: Bool) {
    guard isUnique else {
      let scale = self._storage._scale
      _storage = _SetStorage<Element>.allocate(scale: scale)
      return
    }
    for bucket in hashTable {
      (_elements + bucket.offset).deinitialize(count: 1)
    }
    hashTable.clear()
    _storage._count = 0
  }
}

extension _NativeSet: Sequence {
  @usableFromInline
  @_fixed_layout
  internal struct Iterator {
    // The iterator is iterating over a frozen view of the collection state, so
    // it keeps its own reference to the set.
    @usableFromInline
    internal let base: _NativeSet
    @usableFromInline
    internal var iterator: _HashTable.Iterator

    @inlinable
    init(_ base: __owned _NativeSet) {
      self.base = base
      self.iterator = base.hashTable.makeIterator()
    }
  }

  @inlinable
  internal __consuming func makeIterator() -> Iterator {
    return Iterator(self)
  }
}

extension _NativeSet.Iterator: IteratorProtocol {
  @inlinable
  internal mutating func next() -> Element? {
    guard let index = iterator.next() else { return nil }
    return base.uncheckedElement(at: index)
  }
}
