# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Tool to download chain history data from local node, and save it to the json
# file.
# Data of each block is rlp encoded list of: 
# [blockHeader, [block_transactions, block_uncles], block_receipts]
# Json file has following format:
# {
#   "hexEncodedBlockHash: {
#      "rlp": "hex of rlp encoded list [blockHeader, [block_transactions, block_uncles], block_receipts]",
#      "number": "block number"
#    },
#   ...,
#   ...,
# }
#
#

{.push raises: [Defect].}

import
  std/[json, typetraits, strutils, os],
  confutils,
  stew/[byteutils, io2],
  json_serialization,
  faststreams, chronicles,
  eth/[common, rlp], chronos,
  eth/common/eth_types_json_serialization,
  ../../premix/downloader

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "EthData"
  elif defined(macosx):
    "Library" / "Application Support" / "EthData"
  else:
    ".cache" / "ethData"

  getHomeDir() / dataDir

const
  defaultDataDirDesc = defaultDataDir()
  defaultFileName = "eth-history-data.json"

type
  ExporterConf* = object
    logLevel* {.
      defaultValue: LogLevel.INFO
      defaultValueDesc: $LogLevel.INFO
      desc: "Sets the log level"
      name: "log-level" .}: LogLevel
    initialBlock* {.
      desc: "Number of first block which should be downloaded"
      defaultValue: 0
      name: "initial-block" .}: uint64
    endBlock* {.
      desc: "Number of last block which should be downloaded"
      defaultValue: 0
      name: "end-block" .}: uint64
    dataDir* {.
      desc: "The directory where generated file will be placed"
      defaultValue: defaultDataDir()
      defaultValueDesc: $defaultDataDirDesc
      name: "data-dir" .}: OutDir
    filename* {.
      desc: "default name of the file with history data"
      defaultValue: defaultFileName
      name: "filename" .}: string

  DataRecord = object
    rlp: string
    number: uint64

proc writeBlock(writer: var JsonWriter, blck: Block) {.raises: [IOError, Defect].} =
  let 
    enc = rlp.encodeList(blck.header, blck.body, blck.receipts)
    asHex = to0xHex(enc)
    dataRecord = DataRecord(rlp: asHex, number: cast[uint64](blck.header.blockNumber))
    headerHash = to0xHex(rlpHash(blck.header).data)

  writer.writeField(headerHash, dataRecord)

proc downloadBlock(i: uint64): Block =
  let num = u256(i)
  try:
    # premix has hardcoded making request to local host which is "127.0.0.1:8545"
    # which is defult port of geth json rpc server
    return requestBlock(num, flags = {DownloadReceipts})
  except CatchableError as e:
    fatal "Error while requesting Block", error = e.msg
    quit 1

proc createAndOpenFile(config: ExporterConf): OutputStreamHandle =
  # Creates directory and file specified in config, if file already exists 
  # program is aborted with info to user, to avoid losing data

  let filePath = config.dataDir / config.filename

  if isFile(filePath):
    fatal "File under provided path already exists and would be overwritten",
      path = filePath
    quit 1

  let res = createPath(distinctBase(config.dataDir))

  if res.isErr():
    fatal "Error occurred while creating directory", error = res.error
    quit 1

  try:
    # this means that each time file be overwritten, but it is ok for such one
    # off toll
    return fileOutput(filePath)
  except IOError as e:
    fatal "Error occurred while opening the file", error = e.msg
    quit 1

proc run(config: ExporterConf) =
  let fh = createAndOpenFile(config)

  try:
    var writer = JsonWriter[DefaultFlavor].init(fh.s)
    writer.beginRecord()
    for i in config.initialBlock..config.endBlock:
      let blck = downloadBlock(i)
      writer.writeBlock(blck)
    writer.endRecord()
    info "File successfully written"
  except IOError as e:
    fatal "Error occoured while writing to file", error = e.msg
    quit 1
  finally:
    try:
      fh.close()
    except IOError as e:
      fatal "Error occoured while closing file", error = e.msg
      quit 1

when isMainModule:
  {.pop.}
  let config = ExporterConf.load()
  {.push raises: [Defect].}

  if (config.endBlock < config.initialBlock):
    fatal "Initial block number should be smaller than end block number",
      initialBlock = config.initialBlock,
      endBlock = config.endBlock
    quit 1

  setLogLevel(config.logLevel)

  run(config)
