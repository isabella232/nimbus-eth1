# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/[os, strutils],
  chronicles, stew/io2,
  eth/p2p/discoveryv5/enr

iterator strippedLines(filename: string): string {.raises: [ref IOError].} =
  for line in lines(filename):
    let stripped = strip(line)
    if stripped.startsWith('#'): # Comments
      continue

    if stripped.len > 0:
      yield stripped

proc addBootstrapNode(bootstrapAddr: string,
                       bootstrapEnrs: var seq[Record]) =
  var enrRec: enr.Record
  if enrRec.fromURI(bootstrapAddr):
    bootstrapEnrs.add enrRec
  else:
    warn "Ignoring invalid bootstrap ENR", bootstrapAddr

proc loadBootstrapFile*(bootstrapFile: string,
                        bootstrapEnrs: var seq[Record]) =
  if bootstrapFile.len == 0: return
  let ext = splitFile(bootstrapFile).ext
  if cmpIgnoreCase(ext, ".txt") == 0 or cmpIgnoreCase(ext, ".enr") == 0 :
    try:
      for ln in strippedLines(bootstrapFile):
        addBootstrapNode(ln, bootstrapEnrs)
    except IOError as e:
      fatal "Could not read bootstrap file", msg = e.msg
      quit 1
  else:
    fatal "Unknown bootstrap file format", ext
    quit 1

# Note:
# Currently just works with the network private key stored as hex in a file.
# In the future it would be nice to re-use keystore from nimbus-eth2 for this.
# However that would require the pull the keystore.nim and parts of
# keystore_management.nim out of nimbus-eth2.
proc getPersistentNetKey*(
    rng: var BrHmacDrbgContext, keyFilePath: string, dataDir: string):
    PrivateKey =
  if fileAccessible(keyFilePath, {AccessFlags.Find}):
    info "Network key file is present, reading key", key_file = keyFilePath

    let readResult = readAllChars(keyFilePath)
    if readResult.isErr():
      fatal "Could not load network key file", key_file = keyFilePath
      quit QuitFailure

    let netKeyInHex = readResult.get()
    if netKeyInHex.len() == 64:
      let netKey = PrivateKey.fromHex(netkeyInHex)
      if netKey.isOk():
        info "Network key was successfully read", key_file = keyFilePath
        netKey.get()
      else:
        fatal "Invalid private key length in file", key_file = keyFilePath
        quit QuitFailure
    else:
      fatal "Invalid private key from file", key_file = keyFilePath
      quit QuitFailure

  else:
    info "Network key file is missing, creating a new one",
      key_file = keyFilePath
    let key = PrivateKey.random(rng)

    if io2.writeFile(keyFilePath, $key).isErr:
      fatal "Failed to write the network key file", key_file = keyFilePath
      quit 1

    info "New network key file was created", key_file = keyFilePath

    key
