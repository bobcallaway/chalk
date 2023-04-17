## Load information based on profiles.
##
## TODO: don't call into plugins if it's not needed.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import config, plugins, options, tables, strutils, glob, os

# We collect things in four different places

type CKind = enum CkChalkInfo, CkPostRunInfo, CkHostInfo

proc registerProfileKeys(profiles: openarray[string]): int {.discardable.} =
  result = 0

  # We always subscribe to _VALIDATED, even if they don't want to
  # report it; they might subscribe to the error logs it generates.
  #
  # This basically ends up forcing getPostChalkInfo() to run in
  # the system plugin.
  subscribedKeys["_VALIDATED"] = true

  for item in profiles:
    if item == "" or chalkConfig.profiles[item].enabled == false: continue
    result = result + 1
    for name, content in chalkConfig.profiles[item].keys:
      if content.report: subscribedKeys[name] = true

proc hasSubscribedKey(p: Plugin, keys: seq[string], dict: ChalkDict): bool =
  # Decides whether to run a given plugin... does it export any key we
  # are subscribed to, that hasn't already been provided?
  for k in keys:
    if k in p.configInfo.ignore:            continue
    if k notin subscribedKeys and k != "*": continue
    if k in p.configInfo.overrides: return true
    if k notin dict:                return true

  return false

proc canWrite(plugin: Plugin, key: string, decls: seq[string]): bool =
  # This would all be redundant to what we can check in the config file spec,
  # except that we do allow "*" fields for plugins, so we need the runtime
  # check to filter out inappropriate items.
  let spec = chalkConfig.keySpecs[key]

  if key in plugin.configInfo.ignore: return false

  if spec.codec:
    if plugin.configInfo.codec:
      return true
    else:
      error("Plugin '" & plugin.name & "' can't write codec key: '" & key & "'")
      return false

  if key notin decls and "*" notin decls:
    error("Plugin '" & plugin.name & "' produced undeclared key: '" & key & "'")
    return false
  if not spec.system:
    return true

  case plugin.name
  of "system", "metsys":
    return true
  of "conffile":
    if spec.confAsSystem:
      return true
  else: discard

  error("Plugin '" & plugin.name & "' can't write system key: '" & key & "'")
  return false

proc collectHostInfo() =
  let
    path        = chalkConfig.getArtifactSearchPath()
    isInserting = getCommandName() in chalkConfig.getValidChalkCommandNames()

  for plugin in getPlugins():
    let subscribed = plugin.configInfo.preRunKeys
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue
    let dict = plugin.getHostInfo(path, isInserting)
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not isInserting and k[0] != '_':                      continue
      if not plugin.canWrite(k, plugin.configInfo.preRunKeys): continue
      if k notin hostInfo or k in plugin.configInfo.overrides:
        hostInfo[k] = v

proc collectPostChalkInfo(artifact: ChalkObj) =
  let
    isInserting = getCommandName() in chalkConfig.getValidChalkCommandNames()

  for plugin in getPlugins():
    let
      data       = artifact.collectedData
      subscribed = plugin.configInfo.postChalkKeys
    if not plugin.hasSubscribedKey(subscribed, data): continue
    if plugin.configInfo.codec and plugin != artifact.myCodec:  continue

    let dict = plugin.getPostChalkInfo(artifact, isInserting)
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.postChalkKeys): continue
      if k notin artifact.collectedData or k in plugin.configInfo.overrides:
        artifact.collectedData[k] = v

  if not isInserting and artifact.postHash != "":
    artifact.collectedData["_CURRENT_HASH"] = pack(artifact.postHash)


proc collectChalkInfo*(obj: ChalkObj) =
  # Called from the appropriate commands.
  obj.opFailed      = false
  obj.collectedData = ChalkDict()
  let data          = obj.collectedData

  for plugin in getPlugins():

    if plugin == Plugin(obj.myCodec):
      data["CHALK_ID"]      = pack(obj.myCodec.getChalkID(obj))
      data["HASH"]          = pack(obj.rawHash.toHex().toLowerAscii())
      data["ARTIFACT_PATH"] = pack(resolvePath(obj.fullpath))
    elif plugin.configInfo.codec and plugin != obj.myCodec: continue

    let subscribed = plugin.configInfo.artifactKeys
    if not plugin.hasSubscribedKey(subscribed, data): continue

    let dict = plugin.getChalkInfo(obj)
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.artifactKeys): continue
      if k notin obj.collectedData or k in plugin.configInfo.overrides:
        obj.collectedData[k] = v

proc collectPostRunInfo*() =
  ## Called from report generation in commands.nim, not the main
  ## artifact loop below.
  for plugin in getPlugins():
    let subscribed = plugin.configInfo.postRunKeys
    if not plugin.hasSubscribedKey(subscribed, hostInfo): continue

    let dict = plugin.getPostRunInfo(allChalks)
    if dict == nil or len(dict) == 0: continue

    for k, v in dict:
      if not plugin.canWrite(k, plugin.configInfo.postRunKeys): continue
      if k notin hostInfo or k in plugin.configInfo.overrides:
        hostInfo[k] = v

# The two below functions are helpers for the allArtifacts() iterator
# and the self-extractor (in the case of findChalk anyway).
proc ignoreArtifact(path: string, globs: seq[glob.Glob]): bool {.inline.} =
  for item in globs:
    if path.matches(item): return true
  return false

proc findChalk(codec:      Codec,
               searchPath: seq[string],
               exclusions: var seq[string],
               ignoreList: seq[glob.Glob],
               recurse:    bool): (bool, seq[ChalkObj]) {.inline.} =
  var goOn = true # Keep trying other codecs if nothing is found

  if len(searchPath) != 0: codec.searchPath = searchPath
  else:                    codec.searchPath = @[resolvePath("")]

  let chalks = codec.scanArtifactLocations(exclusions, ignoreList, recurse)
  if len(chalks) != 0:  goOn = codec.keepScanningOnSuccess()

  return (goOn, chalks)

iterator allArtifacts*(): ChalkObj =
  let
    cmd          = getCommandName()
    artifactPath = chalkConfig.getArtifactSearchPath()
    recursive    = chalkConfig.getRecursive()

  var
    skips:        seq[Glob]     = @[]
    chalks:       seq[ChalkObj]
    exclude:      seq[string]   = if cmd == "confload": @[]
                                  else: @[resolvePath(getAppFileName())]

  if isChalkingOp():
    for item in chalkConfig.getIgnorePatterns(): skips.add(glob("**/" & item))
  for codec in getCodecs():
    var goOn: bool
    trace("Asking codec '" &  codec.name & "' to find existing chalk.")
    # A codec can return 'false' to short-circuit all other plugins.
    # This is used, for instance, with containers.
    (goOn, chalks) = codec.findChalk(artifactPath, exclude, skips, recursive)
    for obj in chalks:
      discard obj.acquireFileStream()
      obj.myCodec = codec
      let path    = obj.fullPath
      if isChalkingOp():
        if path.ignoreArtifact(skips):
          unmarked.add(path)
          if obj.isMarked(): info(path & ": Ignoring, but previously chalked")
          else:              trace(path & ": ignoring artifact")
        else:
          allChalks.add(obj)
          if obj.isMarked(): info(path & ": Existing chalk mark extracted")
          else:              trace(path & ": Currently unchalked")
      else:
        allChalks.add(obj)
        if not obj.isMarked():
          unmarked.add(path)
          warn(path & ": Artifact is unchalked")
        else:
          for k, v in obj.extract:
            obj.collectedData[k] = v

          info(path & ": Chalk mark extracted")

      yield obj
      # On an insert, any more errors in this object are going to be
      # post-chalk, so need to go to the system errors list.
      currentErrorObject = none(ChalkObj)
      if obj.fullpath notin unmarked: obj.collectPostChalkInfo()
      obj.closeFileStream()
    if len(chalks) > 0 and not goOn: break


proc getSelfExtraction*(): Option[ChalkObj] =
  # If we call twice and we're on a platform where we don't
  # have a codec for this type of executable, avoid dupe errors.
  once:
    var
      myPath = @[resolvePath(getAppFileName())]
      exclusions: seq[string] = @[]
      chalks:     seq[ChalkObj]
      ignore:     bool

    trace("Checking chalk binary '" & myPath[0] & "' for embedded config")

    for codec in getCodecs():
      if hostOS notin codec.getNativeObjPlatforms(): continue
      (ignore, chalks) = codec.findChalk(myPath, exclusions, @[], false)
      selfChalk = chalks[0]
      if not selfChalk.isMarked():
        warn("No existing self-chalk mark found.")
      elif "CHALK_ID" notin chalks[0].extract:
        error("Self-chalk mark found, but is invalid.")
      selfId  = some(codec.getChalkId(selfChalk))
      selfChalk.myCodec = codec
      return some(selfChalk)

    warn("We have no codec for this platform's native executable type")
    canSelfInject = false

  if selfChalk != nil: return some(selfChalk)
  else:                return none(ChalkObj)

proc initCollection*() =
  let config       = getOutputConfig()
  let cmdprofnames = [config.chalk, config.hostreport, config.artifactReport,
                      config.invalidChalkReport]
  if registerProfileKeys(cmdprofnames) == 0:
    error("FATAL: no output reporting configured (all specs in the " &
          "command's 'outconf' object are disabled")
    quit(1)
  for name, report in chalkConfig.reportSpecs:
    if getCommandName() notin report.use_when and "*" notin report.use_when:
      continue

    registerProfileKeys([report.artifactProfile,
                         report.hostProfile,
                         report.invalidChalkProfile])
  collectHostInfo()