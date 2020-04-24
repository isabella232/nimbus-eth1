import
  faststreams/input_stream, eth/[common, rlp], stint, stew/endians2,
  eth/trie/[db, trie_defs], nimcrypto/[keccak, hash],
  ./witness_types, stew/byteutils

type
  DB = TrieDatabaseRef

  NodeKey = object
    usedBytes: int
    data*: array[32, byte]

  TreeBuilder = object
    input: InputStream
    db: DB
    root: KeccakHash

proc initTreeBuilder*(input: InputStream, db: DB): TreeBuilder =
  result.input = input
  result.db = db
  result.root = emptyRlpHash

proc initTreeBuilder*(input: openArray[byte], db: DB): TreeBuilder =
  result.input = memoryInput(input)
  result.db = db
  result.root = emptyRlpHash
  
func rootHash*(t: TreeBuilder): KeccakHash {.inline.} =
  t.root

proc writeNode(t: var TreeBuilder, n: openArray[byte]): KeccakHash =
  result = keccak(n)
  t.db.put(result.data, n)

template readByte(t: var TreeBuilder): byte =
  t.input.read

template len(t: TreeBuilder): int =
  t.input.len

template peek(t: TreeBuilder): byte =
  t.input.peek

template read(t: var TreeBuilder, len: int): auto =
  t.input.read(len)

proc readU32(t: var TreeBuilder): uint32 =
  result = fromBytesBE(uint32, t.read(4))

proc toAddress(r: var EthAddress, x: openArray[byte]) {.inline.} =
  r[0..19] = x[0..19]

proc toKeccak(r: var NodeKey, x: openArray[byte]) {.inline.} =
  r.data[0..31] = x[0..31]
  r.usedBytes = 32

proc toKeccak(x: openArray[byte]): NodeKey {.inline.} =
  result.data[0..31] = x[0..31]
  result.usedBytes = 32

proc append(r: var RlpWriter, n: NodeKey) =
  if n.usedBytes < 32:
    r.append rlpFromBytes(n.data.toOpenArray(0, n.usedBytes-1))
  else:
    r.append n.data.toOpenArray(0, n.usedBytes-1)

proc toNodeKey(z: openArray[byte]): NodeKey =
  if z.len < 32:
    result.usedBytes = z.len
    result.data[0..z.len-1] = z[0..z.len-1]
  else:
    result.data = keccak(z).data
    result.usedBytes = 32

proc branchNode(t: var TreeBuilder, depth: int, has16Elem: bool = true): NodeKey
proc extensionNode(t: var TreeBuilder, depth: int): NodeKey
proc accountNode(t: var TreeBuilder, depth: int): NodeKey
proc accountStorageLeafNode(t: var TreeBuilder, depth: int): NodeKey
proc hashNode(t: var TreeBuilder): NodeKey

proc treeNode*(t: var TreeBuilder, depth: int = 0, accountMode = false): NodeKey =
  assert(depth < 64)
  let nodeType = TrieNodeType(t.readByte)

  case nodeType
  of BranchNodeType: result = t.branchNode(depth)
  of Branch17NodeType: result = t.branchNode(depth, false)
  of ExtensionNodeType: result = t.extensionNode(depth)
  of AccountNodeType:
    if accountMode:
      # parse account storage leaf node
      result = t.accountStorageLeafNode(depth)
    else:
      result = t.accountNode(depth)
  of HashNodeType: result = t.hashNode()

  if depth == 0 and result.usedBytes < 32:
    result.data = keccak(result.data.toOpenArray(0, result.usedBytes-1)).data
    result.usedBytes = 32

proc branchNode(t: var TreeBuilder, depth: int, has16Elem: bool): NodeKey =
  assert(depth < 64)
  let mask = constructBranchMask(t.readByte, t.readByte)

  when defined(debugDepth):
    let readDepth = t.readByte.int
    doAssert(readDepth == depth, "branchNode " & $readDepth & " vs. " & $depth)

  when defined(debugHash):
    let hash = toKeccak(t.read(32))

  var r = initRlpList(17)

  for i in 0 ..< 16:
    if mask.branchMaskBitIsSet(i):
      r.append t.treeNode(depth+1)
    else:
      r.append ""

  template safePeek(t: var TreeBuilder): int =
    if t.len == 0 or has16Elem:
      -1
    else:
      t.peek().int

  # add the 17th elem
  let nodeType = t.safePeek()
  if nodeType == AccountNodeType.int:
    r.append accountNode(t, depth+1)
  elif nodeType == HashNodeType.int:
    r.append hashNode(t)
  else:
    # anything else is empty
    r.append ""

  result = toNodeKey(r.finish)

  when defined(debugHash):
    if result != hash:
      debugEcho "DEPTH: ", depth
      debugEcho "result: ", result.data.toHex, " vs. ", hash.data.toHex

func hexPrefix(r: var RlpWriter, x: openArray[byte], nibblesLen: int) =
  var bytes: array[33, byte]
  if (nibblesLen mod 2) == 0:
    bytes[0] = 0.byte
    var i = 1
    for y in x:
      bytes[i] = y
      inc i
  else:
    bytes[0] = 0b0001_0000.byte or (x[0] shr 4)
    var last = nibblesLen div 2
    for i in 1..last:
      bytes[i] = (x[i-1] shl 4) or (x[i] shr 4)

  r.append toOpenArray(bytes, 0, nibblesLen div 2)

proc extensionNode(t: var TreeBuilder, depth: int): NodeKey =
  assert(depth < 63)
  let nibblesLen = int(t.readByte)
  assert(nibblesLen < 65)
  var r = initRlpList(2)
  r.hexPrefix(t.read(nibblesLen div 2 + nibblesLen mod 2), nibblesLen)

  when defined(debugDepth):
    let readDepth = t.readByte.int
    doAssert(readDepth == depth, "extensionNode " & $readDepth & " vs. " & $depth)

  when defined(debugHash):
    let hash = toKeccak(t.read(32))

  assert(depth + nibblesLen < 65)
  let nodeType = TrieNodeType(t.readByte)

  case nodeType
  of BranchNodeType: r.append t.branchNode(depth + nibblesLen)
  of Branch17NodeType: r.append t.branchNode(depth + nibblesLen, false)
  of HashNodeType: r.append t.hashNode()
  else: raise newException(ValueError, "wrong type during parsing child of extension node")

  result = toNodeKey(r.finish)

  when defined(debugHash):
    if result != hash:
      debugEcho "DEPTH: ", depth
    doAssert(result == hash, "EXT HASH DIFF " & result.data.toHex & " vs. " & hash.data.toHex)

proc accountNode(t: var TreeBuilder, depth: int): NodeKey =
  assert(depth < 65)
  let len = t.readU32().int
  result = toNodeKey(t.read(len))

  when defined(debugDepth):
    let readDepth = t.readByte.int
    doAssert(readDepth == depth, "accountNode " & $readDepth & " vs. " & $depth)

  #[let nodeType = AccountType(t.readByte)
  let nibblesLen = 64 - depth
  let pathNibbles = @(t.read(nibblesLen div 2 + nibblesLen mod 2))
  let address = toAddress(t.read(20))
  let balance = UInt256.fromBytesBE(t.read(32), false)
  # TODO: why nonce must be 32 bytes, isn't 64 bit uint  enough?
  let nonce = UInt256.fromBytesBE(t.read(32), false)
  if nodeType == ExtendedAccountType:
    let codeLen = t.readU32()
    let code = @(t.read(codeLen))
    # switch to account storage parsing mode
    # and reset the depth
    t.treeNode(0, accountMode = true)]#

proc accountStorageLeafNode(t: var TreeBuilder, depth: int): NodeKey =
  assert(depth < 65)
  let nibblesLen = 64 - depth
  let pathNibbles = @(t.read(nibblesLen div 2 + nibblesLen mod 2))
  let key = @(t.read(32))
  let val = @(t.read(32))

proc hashNode(t: var TreeBuilder): NodeKey =
  result.toKeccak(t.read(32))
