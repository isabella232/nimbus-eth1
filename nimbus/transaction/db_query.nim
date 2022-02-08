# Nimbus - Steps towards a fast and small Ethereum data store
#
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  sets, tables, memfiles, strutils,
  stint, chronicles, stew/byteutils,
  eth/common/eth_types,
  ../constants,
  ./host_types

const traceQuery        = false
  # Set this to `trace` low-level parse steps of each query.
const traceQueryBytes   = false
  # Set this to enable even lower-level steps.

# The purposes of the present format and very simple query methods here is to
# be a read-only proof of concept of very compact Eth account/storage state
# history, to show that it's _sufficiently_ compact to be interesting.
#
# The files it reads are generated by extracting the state history from an
# Erigon node in a separate ad-hoc ETL process.
#
# ----------------------------------------------------------------------------
#
# `memfiles.nim` stdlib module very helpfully provides memory-mapped files
# for POSIX and Windows.  (Thanks Zahary!)
#
# IMPORTANT: `mmap` is used here for this PoC but not intended to remain.
#
# This comment is to preempt anticipated feedback about the LMDB issues
# mentioned in `nimbus/db/select_backend.nim`.
#
# It is very convenient for this read-only proof of concept, while the
# database is built up in Nim layers.  Certainly it simplifies the query
# code, making it easier to explain and show the compression and traversal,
# compared with a version using high-performance async file I/O.
#
# But actually single-threaded `mmap` is a very slow method for this type of
# database.  Memory-mapped files don't have appropriate performance
# characteristics, not to mention portability issues.  I measured 25 times
# slower doing random-access reads via `mmap` like this compared with good
# async I/O on my Linux test system.
#
# Specifically, memory-mapped files perform badly with single-threaded code
# doing random-access reads to a very large database.  Because the state file
# is much larger than RAM, most queries block in a page fault doing I/O to
# the underlying storage device.  Most queries are located randomly due to
# Ethereum hashed trie keys, and are different from one Ethereum block to the
# next, so OS filesystem read-ahead just makes performance worse.  Those
# reads block Chronos in a page fault, and it's not possible for other async
# tasks to progress while waiting for storage.  Worse, it's not possible to
# reach I/O queue depth > 1 this way, so the underlying filesystem and the
# SSD itself operate at their very slowest.
#
# ----------------------------------------------------------------------------
#
# The format is a large, read-only file which is easy to search, but that's a
# little misleading.
#
# To those who know what makes a database work (B-trees/LSM-trees etc), it may
# be clear that the format here can't be updated fast.  Really though, it's not
# far off a format that supports updates while keeping good query performance
# and similar compression.  Watch this space if you're intrigued about how that
# transformation is done!
#
# This is being implemented in tested steps into a compressed (for Eth) but
# _writable_ data format, that supports "O(1)"[*] and 1 IOP state queries, fast
# bulk-range writes for super-snap sync, and fast random-writes for execution.
# Offline experiments have been done on Mainnet data to validate the concepts
# and to benchmark low-level I/O performance.  Also don't pay too close
# attention to the ad-hoc byte coding in this file.  It's scaffolding while
# we're importing data.
#
# [*] Because other clients' literature says "O(1)" queries.  Technically all
# of them are at least O(log N) because they mean O(1) database lookups, and a
# single database lookup is O(log N) reads by itself.  It may be reduced to
# O(1) under certain cache scaling assumptions and well-designed caching of
# interior pages.  We count "leaf IOPS" as a reasonably proportional proxy for
# IOPS under these assumptions.
#
# On a more concrete note, our method, when cached, takes approximately 1 leaf
# IOPS to read both a small account and N `SLOAD` storage reads, due to
# locality in the layout of small accounts.  1+N for large accounts (those with
# large storage or history).  Contrast 1 and 1+N with 2+2N and 2+2N leaf IOPS
# are used by TurboGeth-derived clients.
#
# So our method should be faster at random-read queries in an absolute sense
# when SSD I/O performance is the bottleneck, rather than CPU.  Our method is
# more CPU intensive, due to compression not layout (they could be separated).

type
  EthDB* = ref object
    memFile:            MemFile
    queries:            uint64
    queryPagesL1:       uint64
    queryPagesL2:       uint64

  DbHeader = object
    fileVersion:        uint64
    statesEnd:          uint64
    statesStart:        uint64
    pageShift:          uint64
    blockFirst:         uint64
    blockLast:          uint64
    countAccounts:      uint64
    countStorages:      uint64

  DbAccount* = object
    nonce*:             AccountNonce
    incarnation*:       uint64
    balance*:           UInt256
    codeHash*:          Hash256

  DbStorage = object
    incarnation*:       uint64
    slot*:              UInt256
    value*:             UInt256

  DbSlotResult* = object
    value*:             UInt256

  DbGeneralKeyBits = enum
    DbkHasBlockNumber
    DbkHasAddress
    #DbHasAddressHash
    DbkHasIncarnation
    DbkHasSlot
    #DbHasSlotHash

  DbGeneralKeyFlags = set[DbGeneralKeyBits]

  DbGeneralKey = object
    flags:              DbGeneralKeyFlags
    blockNumber:        BlockNumber
    address:            EthAddress
    #addressHash:        Hash256
    incarnation:        uint64
    slot:               UInt256
    #slotHash:           Hash256

  DbGeneralValueBits = enum
    DbvHasBlockNumber
    DbvHasAddress
    DbvHasAccount
    DbvHasStorage

  DbGeneralValueFlags = set[DbGeneralValueBits]

  DbGeneralValue = object
    flags:              DbGeneralValueFlags
    blockNumber:        BlockNumber
    address:            EthAddress
    account:            DbAccount
    storage:            DbStorage

  DbMatch = enum
    # Polarity: Whether a key is EQ, GT or LT than a looked up value.
    MatchEQ       # Key equals value.
    MatchGT       # Key strictly greater than value.
    MatchLT       # Key strictly less than value.
    MatchNotFound # No value.

template toHex(hash: Hash256): string = hash.data.toHex

proc traceGeneralKey(key: DbGeneralKey) =
  trace "- Search key flags", flags=key.flags
  if DbkHasBlockNumber in key.flags:
    trace "-   Key block", `block`=key.blockNumber
  if DbkHasAddress in key.flags:
    trace "-   Key address", address=key.address.toHex
  if DbkHasIncarnation in key.flags:
    trace "-   Key incarnation", inc=key.incarnation
  if DbkHasSlot in key.flags:
    trace "-   Key slot", inc=key.slot.toHex

proc traceGeneralValue(value: DbGeneralValue, offset: uint, len: uint) =
  trace "- Entry value flags + offset", flags=value.flags,
    offset, offsetHex=("0x" & offset.toHex.toLower), len
  if DbvHasBlockNumber in value.flags:
    trace "-   Value block", `block`=value.blockNumber
  if DbvHasAddress in value.flags:
    trace "-   Value address", address=value.address.toHex
  if DbvHasAccount in value.flags:
    trace "-   Value account.nonce", nonce=value.account.nonce
    trace "-   Value account.incarnation", incarnation=value.account.incarnation
    trace "-   Value account.balance", balance=value.account.balance.dumpHex
    if value.account.codeHash == ZERO_HASH256:
      trace "-   Value account.codeHash", codeHash="0"
    else:
      trace "-   Value account.codeHash", codeHash=value.account.codeHash.toHex
  if DbvHasStorage in value.flags:
    trace "-   Value storage.incarnation", incarnation=value.storage.incarnation
    trace "-   Value storage.slot", slot=value.storage.slot.dumpHex
    trace "-   Value storage.value", value=value.storage.value.dumpHex

template header(db: EthDB): DbHeader =
  doAssert not db.memFile.mem.isNil
  cast[ptr DbHeader](db.memFile.mem)[]

template offset(db: EthDB, offset: uint64): ptr byte =
  cast[ptr byte](db.memFile.mem) + offset

template `+`(p: ptr byte, offset: uint64): ptr byte =
  cast[ptr byte](cast[uint](p) + offset)

template inc(p: var ptr byte) = p = p + 1

proc compareAddresses(a, b: EthAddress): DbMatch {.inline.} =
  for i in 0 ..< 20:
    if a[i] != b[i]:
      return if a[i] < b[i]: MatchLT else: MatchGT
  return MatchEQ

proc compareNumbers(a, b: uint64 | BlockNumber | UInt256): DbMatch {.inline.} =
  if a < b: MatchLT elif a > b: MatchGT else: MatchEQ

proc compareBooleans(a, b: bool): DbMatch {.inline.} =
  if a == b: MatchEQ elif not a: MatchLT else: MatchGT

proc compareGeneral(key: DbGeneralKey, value: DbGeneralValue): DbMatch =
  var match = compareBooleans(DbkHasAddress in key.flags,
                              DbvHasAddress in value.flags)
  if match != MatchEQ:
    return match

  if DbkHasAddress in key.flags:
    match = compareAddresses(key.address, value.address)
    if match != MatchEQ:
      return match

  match = compareBooleans(DbkHasIncarnation in key.flags,
                          DbvHasStorage in value.flags)
  if match != MatchEQ:
    return match

  if DbkHasIncarnation in key.flags:
    match = compareNumbers(key.incarnation, value.storage.incarnation)
    if match != MatchEQ:
       return match

  match = compareBooleans(DbkHasSlot in key.flags,
                          DbvHasStorage in value.flags)
  if match != MatchEQ:
    return match

  if DbkHasSlot in key.flags:
    match = compareNumbers(key.slot, value.storage.slot)
    if match != MatchEQ:
      return match

  match = compareBooleans(DbkHasBlockNumber in key.flags,
                          DbvHasBlockNumber in value.flags)
  if match != MatchEQ:
    return match

  if DbkHasBlockNumber in key.flags:
    match = compareNumbers(key.blockNumber, value.blockNumber)
    if match != MatchEQ:
      return match

  return match

proc queryPage(db: EthDB, offsetStart, offsetEnd: uint64, key: DbGeneralKey,
               valueOut: var DbGeneralValue, all: bool): DbMatch =
  var
    posEnd = db.offset(offsetEnd)
    pos = db.offset(offsetStart)
    b: byte

  template getByte =
    if pos > posEnd:
      break entryLoop
    if traceQueryBytes and false:
      let offset = cast[uint](pos) - cast[uint](db.memFile.mem)
      trace "- Decoding byte", byte=("0x" & pos[].toHex.toLower),
          offset=offset, offsetHex=("0x" & offset.toHex.toLower)
    b = pos[]
    inc pos

  template readVariable64(into: var uint64) =
    getByte
    if b < 224:
      into = b.uint64
    else:
      var remainder = (b - 224).uint64
      getByte
      into = b.uint64
      while remainder != 0:
        getByte
        into = (into shl 8) or b.uint64
        dec remainder

  template readFixed256(into: var UInt256) =
    getByte
    into = b.u256
    for i in 0 ..< 31:
      getByte
      into = (into shl 8) or b.u256

  template readVariable256(into: var UInt256) =
    getByte
    if b < 224:
      into = b.u256
    else:
      var remainder = (b - 224).int
      getByte
      into = b.u256
      while remainder != 0:
        getByte
        into = (into shl 8) or b.u256
        dec remainder

  var blockNumber: uint64
  var readerAddress: EthAddress
  var readerStorageIncarnation: uint64
  var readerSlot: UInt256

  const
    CODE_PAGE_PADDING = 0   # Single value 0
    CODE_BLOCK_NUMBER = 1   # Range 1..8
    CODE_ADDRESS      = 9   # Single value 9
    CODE_ACCOUNT      = 10  # Range 10..73
    CODE_STORAGE      = 74  # Range 74..249
    CODE_INCARNATION  = 250 # Single value 250

  template nextEntry(generalValue: var DbGeneralValue) =
    var bytecodeIncarnation: uint64 = 0
    while true:
      getByte
      case b

      of CODE_PAGE_PADDING:

        # End of page
        break entryLoop

      of CODE_BLOCK_NUMBER .. CODE_BLOCK_NUMBER + 7:

        let len = (b - CODE_BLOCK_NUMBER + 1).int
        blockNumber = 0
        for i in 0 ..< len:
          getByte
          blockNumber = (blockNumber shl 8) or b.uint64

      of CODE_ADDRESS:

        for i in 0 ..< 20:
          getByte
          readerAddress[i] = b
        readerStorageIncarnation = 0

      of CODE_ACCOUNT .. CODE_ACCOUNT + 63:

        generalValue.flags = { DbvHasBlockNumber, DbvHasAddress, DbvHasAccount }
        generalValue.blockNumber = blockNumber.toBlockNumber
        generalValue.address = readerAddress

        template account: var DbAccount = generalValue.account
        let flags = b - CODE_ACCOUNT

        if (flags and 1) != 0:
          readVariable256(account.balance)
        else:
          account.balance = 0.u256

        if (flags and 2) != 0:
          for i in 0 ..< 32:
            getByte
            account.codeHash.data[i] = b
        else:
          account.codeHash = ZERO_HASH256

        if (flags and (3 shl 2)) == (3 shl 2):
          readVariable64(account.nonce)
        else:
          account.nonce = ((flags shr 2) and 3).AccountNonce

        if (flags and (3 shl 4)) == (3 shl 4):
          readVariable64(account.incarnation)
        else:
          account.incarnation = ((flags shr 4) and 3).uint64

        # At this point we have an account entry.
        readerStorageIncarnation = account.incarnation
        break

      of CODE_STORAGE .. CODE_STORAGE + 160 + 15:

        generalValue.flags = { DbvHasBlockNumber, DbvHasAddress, DbvHasStorage }
        generalValue.blockNumber = blockNumber.toBlockNumber
        generalValue.address = readerAddress

        template storage: var DbStorage = generalValue.storage
        let flags = b - CODE_STORAGE

        storage.incarnation = readerStorageIncarnation
        if storage.incarnation == 0:
          storage.incarnation = 1
        if bytecodeIncarnation != 0:
          storage.incarnation += bytecodeIncarnation

        if (flags shr 4) < 9:
          storage.slot = (flags shr 4).u256
        elif (flags shr 4) == 9:
          readVariable256(storage.slot)
        else:
          readFixed256(storage.slot)

        if (flags and (1 shl 3)) != 0:
          storage.slot += readerSlot + 1

        if (flags and 7) < 6:
          storage.value = (flags and 7).u256
        else:
          readVariable256(storage.value)
          if (flags and 1) != 0:
            storage.value = not storage.value

        # At this point we have a storage entry.
        readerStorageIncarnation = storage.incarnation
        readerSlot = storage.slot
        break

      of CODE_INCARNATION:
        readVariable64(bytecodeIncarnation)

      else:
        let offset = cast[uint](pos) - 1 - cast[uint](db.memFile.mem)
        trace "DB: Syntax error in data file", byte=("0x" & b.toHex.toLower),
          offset=offset, offsetHex=("0x" & offset.toHex.toLower)
        break entryLoop

  var haveSavedValue = false
  var savedValue: DbGeneralValue
  var match = MatchNotFound
  valueOut.flags = {}

  block entryLoop:
    while true:
      let entryPos = pos
      nextEntry(valueOut)
      if traceQuery:
        let entryOffset = cast[uint](entryPos) - cast[uint](db.memFile.mem)
        let entryLen = cast[uint](pos) - cast[uint](entryPos)
        traceGeneralValue(valueOut, entryOffset, entryLen)
      match = compareGeneral(key, valueOut)
      if match != MatchGT or not all:
        break entryLoop
      savedValue = valueOut
      haveSavedValue = true

  if match == MatchLT and haveSavedValue:
    valueOut = savedValue
    match = MatchGT

  if traceQuery:
    if match == MatchNotFound:
      trace "- Query result: Nothing found", match
    else:
      trace "- Query result", match
      traceGeneralValue(valueOut, 0, 0)

  return match

template checkHeader(db: EthDB) =
  doAssert db.memFile.mem != nil
  doAssert db.memFile.size >= sizeof(db.header)
  doAssert db.header.fileVersion == 202202111
  doAssert db.header.statesEnd <= db.memFile.size.uint64
  doAssert db.header.statesEnd >= db.header.statesStart
  doAssert db.header.pageShift >= 8 and db.header.pageShift <= 24

proc generalQuery(db: EthDB, key: DbGeneralKey,
                  valueOut: var DbGeneralValue): bool =
  if traceQuery:
    traceGeneralKey(key)
  db.checkHeader()
  inc db.queries

  # Querying the state history store for higher block numbers than it holds
  # will return the state of the last block that it does contain, which would
  # be wrong for accounts changed since then.  To prevent confusing errors that
  # would look like bugs, return not-found rather than incorrect values.
  # TODO: Signal that out-of-range is distinct from not-found.
  if key.blockNumber < db.header.blockFirst.toBlockNumber or
     key.blockNumber > db.header.blockLast.toBlockNumber:
     return false

  let
    pageShift = db.header.pageShift
    pageMask = (1.uint64 shl pageShift) - 1

  var
    lowOffset = db.header.statesStart
    highOffset = db.header.statesEnd - 1

  # The key we are looking for is between the lowest key in page
  # `lowOffset shr pageShift` and the highest key in page
  # `highOffset shr pageShift`, both inclusive.
  #
  # We hunt for it with two levels of binary search.  First using "search in
  # page, first key only" as a subroutine to locate the page.  Then using
  # "search in page, all keys" to locate the value.
  #
  # A subtle twist is that the query has mixed comparators.  We're not looking
  # for an exact match on all key components.  We need an exact match to
  # `address` and `slot`, but for `blockNumber` we search for the "max entry <=
  # search key", because this is really an interval tree with implicit
  # intervals (block ranges).  To find the entry, the second level search may
  # re-visit a page that was discarded early in the first level search.

  while true:
    if lowOffset > highOffset:
      return false

    var
      # Subtraction like this biases the rounding upwards, which reduces the
      # average number of search steps and page reads.
      midOffset = highOffset - ((highOffset - lowOffset) shr 1)
      midPageStart = midOffset and not pageMask
      midPageEnd = midPageStart or pageMask

    # For "max entry <= search key" it is always better to skip the first page
    # at L1 search if there is another page after (unless the first entry
    # happens to `MatchEQ`, which is unlikely).
    if traceQueryBytes:
      trace "-   Positions L1",
        midPageStart=("0x" & midPageStart.toHex),
        midPageEnd=("0x" & midPageEnd.toHex),
        lowOffset=("0x" & lowOffset.toHex),
        highOffset=("0x" & highOffset.toHex)
    if midPageStart <= lowOffset:
      if midPageEnd >= highOffset:
        break
      midPageStart += pageMask + 1
      midPageEnd = midPageStart or pageMask

    if midPageEnd > highOffset:
      midPageEnd = highOffset

    inc db.queryPagesL1
    case queryPage(db, midPageStart, midPageEnd, key, valueOut, false):
      of MatchEQ:
        return true
      of MatchLT:
        highOffset = midPageStart - 1
      of MatchGT:
        # The "max entry <= search key" might be inside the current page, but
        # might also be in a much higher page number.  We can set `lowOffset`
        # to either the start of the current page, or the start of the next one
        # and be prepared to backtrack one page.  Each has a subtle effect on
        # the average number of steps in L1 search.  The choice below is made
        # to interact with skipping the first page in code above, because
        # skipping the first page is beneficial at the first iteration as well.
        lowOffset = midPageStart
      of MatchNotFound:
        return false

  if traceQuery:
    trace "-   Positions L2",
      lowOffset=("0x" & lowOffset.toHex),
      highOffset=("0x" & highOffset.toHex)
  inc db.queryPagesL2
  case queryPage(db, lowOffset, highOffset, key, valueOut, true):
    of MatchEQ:
      return true
    of MatchGT:
      # Match exact address, incarnation and slot but "lowest >=" block number.
      if (DbkHasAddress in key.flags) != (DbvHasAddress in valueOut.flags):
        return false
      if DbkHasAddress in key.flags and
         compareAddresses(key.address, valueOut.address) != MatchEQ:
        return false
      if (DbkHasIncarnation in key.flags) != (DbvHasStorage in valueOut.flags):
        return false
      if DbkHasIncarnation in key.flags and
         key.incarnation != valueOut.storage.incarnation:
        return false
      if (DbkHasSlot in key.flags) != (DbvHasStorage in valueOut.flags):
        return false
      if DbkHasSlot in key.flags and
         key.slot != valueOut.storage.slot:
        return false
      return true
    else:
      return false

proc ethDbQueryAccount*(db: EthDB, blockNumber: BlockNumber,
                      address: EthAddress, accountResult: var DbAccount): bool =
  var key {.noinit.}: DbGeneralKey
  key.flags = { DbkHasBlockNumber, DbkHasAddress }
  key.blockNumber = blockNumber
  key.address = address

  var value {.noinit.}: DbGeneralValue
  let found = generalQuery(db, key, value)
  if not found:
    accountResult = DbAccount()
  else:
    accountResult = value.account
  return found

proc ethDbQueryStorage*(db: EthDB, blockNumber: BlockNumber,
                        address: EthAddress, slot: UInt256,
                        slotResult: var DbSlotResult): bool =
  var key {.noinit.}: DbGeneralKey
  key.flags = { DbkHasBlockNumber, DbkHasAddress }
  key.blockNumber = blockNumber
  key.address = address

  var value {.noinit.}: DbGeneralValue
  var found = generalQuery(db, key, value)
  if not found or value.account.incarnation == 0:
    slotResult.value = 0.u256
    return false

  key.flags = { DbkHasBlockNumber, DbkHasAddress, DbkHasIncarnation, DbkHasSlot }
  key.incarnation = value.account.incarnation
  key.slot = slot

  found = generalQuery(db, key, value)
  if not found:
    slotResult.value = 0.u256
  else:
    slotResult.value = value.storage.value
  return found

proc ethDbOpen*(path: string): EthDB {.raises: [IOError, OSError].} =
  ## Open an EthDB file.  Note, format is subject to rapid change.
  ## See comment at the start of this file about use of `memfile`.
  info "DB: Opening experimental compressed state history database",
    file=path
  # Raises `OSError` on error, good enough for this versipn.
  new result
  result.memFile = memfiles.open(path)

proc ethDbSize*(db: EthDB): uint64 =
  db.checkHeader()
  return db.header.statesEnd

proc ethDbShowStats*(db: EthDb) =
  let queryPages = db.queryPagesL1 + db.queryPagesL2
  debug "DB: Statistics so far", queries=db.queries,
    pagesPerQuery=(queryPages.float / db.queries.float), queryPages,
    queryPagesL1=db.queryPagesL1, queryPagesL1=db.queryPagesL2