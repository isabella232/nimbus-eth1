# Nimbus - Ethereum Snap Protocol (SNAP), version 1
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module implements Ethereum Snapshot Protocol (SNAP), `snap/1`, as
## specified at:
##
## - [Ethereum Snapshot Protocol (SNAP)]
##   (https://github.com/ethereum/devp2p/blob/master/caps/snap.md)
##
## Performance benefits
## --------------------
##
## `snap` is used for much higher performance transfer of the entire Ethereum
## execution state (accounts, storage, bytecode) compared with hexary trie
## traversal using `eth` `GetNodeData`.
##
## It improves both network and local storage performance.  The benefits are
## substantial, and summarised here:
##
## - [Ethereum Snapshot Protocol (SNAP) - Expected results]
##   (https://github.com/ethereum/devp2p/blob/master/caps/snap.md)
## - [Geth v1.10.0 - Snap sync]
##   (https://blog.ethereum.org/2021/03/03/geth-v1-10-0/#snap-sync)
##
## In the Snap sync model, local storage benefits require clients to adopt a
## different representation of Ethereum state than the trie storage that Geth
## (and most clients) traditionally used, and still do in archive mode,
##
## However, Nimbus's sync method obtains similar local storage benefits
## whichever network protocol is used.  Nimbus uses `snap` protocol because it
## is a more efficient network protocol.
##
## Remote state and Beam sync benefits
## -----------------------------------
##
## `snap` was not intended for Beam sync, or "remote state on demand", used by
## transactions executing locally that fetch state from the network instead of
## local storage.
##
## Even so, as a lucky accident `snap` allows individual states to be fetched
## in fewer network round trips than `eth`.  Often a single round trip,
## compared with about 10 round trips per account query over `eth`.  This is
## because `eth` `GetNodeData` requires a trie traversal chasing hashes
## sequentially, while `snap` `GetTrieNode` trie traversal can be done with
## predictable paths.
##
## Therefore `snap` can be used to accelerate remote states and Beam sync.
##
## Distributed hash table (DHT) building block
## -------------------------------------------
##
## Although `snap` was designed for bootstrapping clients with the entire
## Ethereum state, it is well suited to fetching only a subset of path ranges.
## This may be useful for bootstrapping distributed hash tables (DHTs).
##
## Path range metadata benefits
## ----------------------------
##
## Because data is handled in path ranges, this allows a compact metadata
## representation of what data is stored locally and what isn't, compared with
## the size of a representation of partially completed trie traversal with
## `eth` `GetNodeData`.  Due to the smaller metadata, after aborting a partial
## sync and restarting, it is possible to resume quickly, without waiting for
## the very slow local database scan associated with older versions of Geth.
##
## However, Nimbus's sync method uses this principle as inspiration to
## obtain similar metadata benefits whichever network protocol is used.

import
  std/options,
  chronos, stint, chronicles, stew/byteutils, nimcrypto/hash,
  eth/[common/eth_types, rlp, p2p],
  eth/p2p/[rlpx, private/p2p_types, blockchain_utils],
  ./sync_types

type
  SnapAccount* = object
    accHash*: LeafPath
    accBody* {.rlpCustomSerialization.}: Account

  SnapAccountProof* = seq[Blob]

  SnapStorage* = object
    slotHash*: LeafPath
    slotData*: Blob

  SnapStorageProof* = seq[Blob]

# The `snap` protocol represents `Account` differently from the regular RLP
# serialisation used in `eth` protocol as well as the canonical Merkle hash
# over all accounts.  In `snap`, empty storage hash and empty code hash are
# each represented by an RLP zero-length string instead of the full hash.  This
# avoids transmitting these hashes in about 90% of accounts.  We need to
# recognise or set these hashes in `Account` when serialising RLP for `snap`.

const EMPTY_STORAGE_HASH* =
  "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421".toDigest
const EMPTY_CODE_HASH* =
  "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470".toDigest

proc read*(rlp: var Rlp, t: var SnapAccount, _: type Account): Account {.inline.} =
  ## RLP decoding for `SnapAccount`, which contains a path and account.
  ## The snap representation of the account differs from `Account` RLP.
  ## Empty storage hash and empty code hash are each represented by an
  ## RLP zero-length string instead of the full hash.
  rlp.tryEnterList()
  result.nonce = rlp.read(typeof(result.nonce))
  result.balance = rlp.read(typeof(result.balance))

  if rlp.blobLen != 0 or not rlp.isBlob:
    result.storageRoot = rlp.read(typeof(result.storageRoot))
    if result.storageRoot == EMPTY_STORAGE_HASH:
      raise newException(RlpTypeMismatch,
        "EMPTY_STORAGE_HASH not encoded as empty string in Snap protocol"
      )
  else:
    rlp.skipElem()
    result.storageRoot = EMPTY_STORAGE_HASH

  if rlp.blobLen != 0 or not rlp.isBlob:
    result.codeHash = rlp.read(typeof(result.codeHash))
    if result.codeHash == EMPTY_CODE_HASH:
      raise newException(RlpTypeMismatch,
        "EMPTY_CODE_HASH not encoded as empty string in Snap protocol"
      )
  else:
    rlp.skipElem()
    result.codeHash = EMPTY_CODE_HASH

proc append*(rlpWriter: var RlpWriter, t: SnapAccount, account: Account) {.inline.} =
  ## RLP encoding for `SnapAccount`, which contains a path and account.
  ## The snap representation of the account differs from `Account` RLP.
  ## Empty storage hash and empty code hash are each represented by an
  ## RLP zero-length string instead of the full hash.
  rlpWriter.append(account.nonce)
  rlpWriter.append(account.balance)

  if account.storageRoot == EMPTY_STORAGE_HASH:
    rlpWriter.append("")
  else:
    rlpWriter.append(account.storageRoot)

  if account.codeHash == EMPTY_CODE_HASH:
    rlpWriter.append("")
  else:
    rlpWriter.append(account.codeHash)

p2pProtocol snap1(version = 1,
                  rlpxName = "snap",
                  useRequestIds = true):

  requestResponse:
    # User message 0x00: GetAccountRange.
    # Note: `origin` and `limit` differs from the specification to match Geth.
    proc getAccountRange(peer: Peer, rootHash: TrieHash,
                         startingHash: LeafPath, responseBytes: uint64) =
      tracePacket "<< Received snap.GetAccountRange (0x00)",
        pathStart=($startingHash), stateRoot=($rootHash), responseBytes, peer

      tracePacket ">> Replying EMPTY snap.AccountRange (0x01)", sent=0, peer
      await response.send(@[], @[])

    # User message 0x01: AccountRange.
    proc accountRange(peer: Peer, accounts: seq[SnapAccount],
                      proof: SnapAccountProof)

  requestResponse:
    # User message 0x02: GetStorageRanges.
    # Note: `origin` and `limit` differs from the specification to match Geth.
    proc getStorageRanges(peer: Peer, rootHash: TrieHash,
                          accountHashes: openArray[LeafPath],
                          startingHash: LeafPath,
                          responseBytes: uint64) =
      if startingHash == leafLow:
        # Fetching storage for multiple accounts.
        tracePacket "<< Received snap.GetStorageRanges/A (0x02)",
          accountPaths=accountHashes.len,
          stateRoot=($rootHash), responseBytes, peer
      elif accountHashes.len == 1:
        # Fetching partial storage for one account, aka. "large contract".
        tracePacket "<< Received snap.GetStorageRanges/S (0x02)",
          storagePathStart=($startingHash),
          stateRoot=($rootHash), responseBytes, peer
      else:
        # This branch is separated because these shouldn't occur.  It's not
        # really specified what happens when there are multiple accounts and
        # non-default path range.
        tracePacket "<< Received snap.GetStorageRanges/AS?? (0x02)",
          accountPaths=accountHashes.len, storagePathStart=($startingHash),
          stateRoot=($rootHash), responseBytes, peer

      tracePacket ">> Replying EMPTY snap.StorageRanges (0x03)", sent=0, peer
      await response.send(@[], @[])

    # User message 0x03: StorageRanges.
    # Note: See comments in this file for a list of Geth quirks to expect.
    proc storageRange(peer: Peer, slots: openArray[seq[SnapStorage]],
                      proof: SnapStorageProof)

  # User message 0x04: GetByteCodes.
  requestResponse:
    proc getByteCodes(peer: Peer, hashes: openArray[NodeHash],
                      responseBytes: uint64) =
      tracePacket "<< Received snap.GetByteCodes (0x04)",
        hashCount=hashes.len, responseBytes, peer

      tracePacket ">> Replying EMPTY snap.ByteCodes (0x05)", sent=0, peer
      await response.send(@[])

    # User message 0x05: ByteCodes.
    proc byteCodes(peer: Peer, codes: openArray[Blob])

  # User message 0x06: GetTrieNodes.
  requestResponse:
    proc getTrieNodes(peer: Peer, rootHash: TrieHash,
                      paths: openArray[InteriorPath], responseBytes: uint64) =
      tracePacket "<< Received snap.GetTrieNodes (0x06)",
        pathCount=paths.len, stateRoot=($rootHash), responseBytes, peer

      tracePacket ">> Replying EMPTY snap.TrieNodes (0x07)", sent=0, peer
      await response.send(@[])

    # User message 0x07: TrieNodes.
    proc trieNodes(peer: Peer, nodes: openArray[Blob])
