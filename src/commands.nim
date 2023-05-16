## This module implements both individual commands, and includes
## --publish-defaults functionality for other commands.
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import tables, options, strutils, unicode, os, streams, posix, osproc, sugar,
       config, builtins, collect, chalkjson, plugins, plugins/codecDocker
from json import parseJson, getElems
import macros except error

let emptyReport               = toJson(ChalkDict())
var liftableKeys: seq[string] = @[]

proc showConfig*(force: bool = false)

proc setPerChalkReports(successProfileName: string,
                        invalidProfileName: string,
                        hostProfileName:    string) =
  var
    reports     = seq[string](@[])
    goodProfile = Profile(nil)
    badProfile  = Profile(nil)
    goodName    = successProfileName
    badName     = invalidProfileName
    hostProfile = chalkConfig.profiles[hostProfileName]

  if successProfileName != "" and successProfileName in chalkConfig.profiles:
    goodProfile = chalkConfig.profiles[successProfileName]

  if invalidProfileName != "" and invalidProfileName in chalkConfig.profiles:
    badProfile = chalkConfig.profiles[invalidProfileName]

  if goodProfile == nil or not goodProfile.enabled:
    goodProfile = badProfile
    goodName    = badName

  elif badProfile == nil or not badProfile.enabled:
    badProfile = goodProfile
    badName    = goodName

  if goodProfile == nil or not goodProfile.enabled: return

  # The below implements "lifting".  Lifting occurs when both a host
  # profile and artifact profile want to report on an artifact key.
  # The host report can only report it if the value is the same for
  # each artifact.  If it is, however, the intent is to NOT duplicate.
  # Therefore, what we do is explicitly turn off reporting at the
  # artifact level for any liftable key where the host profile is
  # going to report on it.
  #
  # However, we then need to turn those keys back on if we changed
  # them, because other custom reports this run may *only* ask for
  # something at the artifact level.  Therefore, we stash the key
  # objects, deleting them from the profile (absent means don't
  # report), and restore them at the end of the function.

  var
    goodStash: Table[string, KeyConfig]
    badStash:  Table[string, KeyConfig]

  if hostProfile != nil and hostProfile.enabled:
    for key in liftableKeys:
      if key notin hostProfile.keys or not hostProfile.keys[key].report:
        continue
      if key in goodProfile.keys and goodProfile.keys[key].report:
        goodStash[key] = goodProfile.keys[key]
        goodProfile.keys.del(key)
        trace("Lifting key '" & key & "' when host profile = '" &
          hostProfileName & "' and artifact profile = '" & goodName)
      if key in badProfile.keys and badProfile.keys[key].report:
        badStash[key] = badProfile.keys[key]
        badProfile.keys.del(key)
        trace("Lifting key '" & key & "' when host profile = '" &
          hostProfileName & "' and artifact profile = '" & badName)

  for chalk in getAllChalks():
    if not chalk.isMarked(): continue
    let
      profile   = if not chalk.opFailed: goodProfile else: badProfile
      oneReport = hostInfo.prepareContents(chalk.collectedData, profile)

    if oneReport != emptyReport: reports.add(oneReport)

  # Now, reset any profiles where we performed lifting.
  for key, conf in goodStash: goodProfile.keys[key] = conf
  for key, conf in badStash:  badProfile.keys[key] = conf

  let reportJson = "[ " & reports.join(", ") & "]"
  if len(reports) != 0:       hostInfo["_CHALKS"] = pack(reportJson)
  elif "_CHALKS" in hostInfo: hostInfo.del("_CHALKS")

# Next, our reporting.
template doCommandReport(): string =
  let
    conf        = getOutputConfig()
    hostProfile = chalkConfig.profiles[conf.hostReport]
    unmarked    = getUnmarked()

  if not hostProfile.enabled: ""
  else:
    setPerChalkReports(conf.artifactReport, conf.invalidChalkReport,
                       conf.hostReport)
    if len(unmarked) != 0: hostInfo["_UNMARKED"] = pack(unmarked)
    hostInfo.prepareContents(hostProfile)

template doEmbeddedReport(): Box =
  let
    conf        = getOutputConfig()
    hostProfile = chalkConfig.profiles[conf.hostReport]
    unmarked    = getUnmarked()

  if not hostProfile.enabled: pack("")
  else:
    setPerChalkReports(conf.artifactReport, conf.invalidChalkReport,
                       conf.hostReport)
    if "_CHALKS" in hostInfo:
      hostInfo["_CHALKS"]
    else:
      pack("")

template doCustomReporting() =
  for topic, spec in chalkConfig.reportSpecs:
    if not spec.enabled: continue
    var
      sinkConfs = spec.sinkConfigs
      topicObj  = registerTopic(topic)

    if getCommandName() notin spec.useWhen and "*" notin spec.useWhen:
      continue
    if topic == "audit" and not chalkConfig.getPublishAudit():
      continue
    if len(sinkConfs) == 0 and topic notin ["audit", "chalk_usage_stats"]:
      warn("Report '" & topic & "' has no configured sinks.  Skipping.")

    for sinkConfName in sinkConfs:
      let res = topicSubscribe((@[pack(topic), pack(sinkConfName)])).get()
      if not unpack[bool](res):
        warn("Report '" & topic & "' sink config is invalid. Skipping.")

    setPerChalkReports(spec.artifactProfile, spec.invalidChalkProfile,
                       spec.hostProfile)
    let profile = chalkConfig.profiles[spec.hostProfile]
    if profile.enabled:
      try:
        publish(topic, hostInfo.prepareContents(profile))
      except:
        error("Publishing to topic '" & topic & "' failed; an exception was " &
          "raised when trying to write to a sink. Please check your sink " &
          "configuration and outbound connectivity.  " &
          getCurrentExceptionMsg() & "\n")

proc liftUniformKeys() =
  let allChalks = getAllChalks()

  if len(allChalks) == 0: return

  var dictToUse: ChalkDict

  for key, spec in chalkConfig.keyspecs:
    # Host keys don't make sense to be lifted, so just skip.
    if spec.kind notin [int(KtChalk), int(KtNonChalk)]: continue
    var
      lift = true
      box: Option[Box] = none(Box)
    for chalk in allChalks:
      if getCommandName() in chalkConfig.getValidChalkCommandNames():
        dictToUse = chalk.collectedData
      else:
        dictToUse = chalk.extract

      if dictToUse == nil or key notin dictToUse:
        lift = false
        if key in hostInfo:
          liftableKeys.add(key)
          trace("Key  '" & key &
            "' was put in the host context by plugin and is liftable.")
        break
      if box.isNone():
        box = some(dictToUse[key])
      else:
        if dictToUse[key] != box.get():
          lift = false
          break
    if not lift:  continue

    for chalk in allChalks:
      if key in chalk.collectedData:
        chalk.collectedData.del(key)
    trace("Key '" & key & "' is liftable.")
    liftableKeys.add(key)
    hostInfo[key] = box.get()

proc doReporting(topic="report") =
  if inSubscan():
    let ctx = getCurrentCollectionCtx()
    if ctx.postprocessor != nil:
      ctx.postprocessor(ctx)
    liftUniformKeys()
    ctx.report = doEmbeddedReport()
  else:
    collectPostRunInfo()
    liftUniformKeys()
    let report = doCommandReport()
    if report != "":
      publish(topic, report)
    doCustomReporting()

proc runCmdExtract*(path: seq[string]) =
  initCollection()

  var numExtracts = 0
  for item in artifacts(path):
    numExtracts += 1

  if numExtracts == 0: warn("No items extracted")
  doReporting()

template oneEnvItem(key: string, f: untyped) =
  let item = chalkConfig.envConfig.`get f`()
  if item.isSome():
    dict[key] = pack[string](item.get())

proc runCmdEnv*() =
  initCollection()
  var dict = ChalkDict()

  oneEnvItem("CHALK_ID",       chalkId)
  oneEnvItem("METADATA_ID",    metadataId)
  oneEnvItem("ARTIFACT_HASH",  artifactHash)
  oneEnvItem("METADATA_HASH",  metadataHash)
  oneEnvItem("_ARTIFACT_PATH", artifactPath)

  if len(dict) != 0:
    let c = ChalkObj(extract: dict, collectedData: ChalkDict(),
                     opFailed: false, marked: true)
    c.addToAllChalks()

  doReporting()

proc runCmdInsert*(path: seq[string]) =
  initCollection()
  let virtual = chalkConfig.getVirtualChalk()

  for item in artifacts(path):
    trace(item.fullPath & ": begin chalking")
    item.collectChalkInfo()
    trace(item.fullPath & ": chalk data collection finished.")
    try:
      let toWrite = item.getChalkMarkAsStr()

      if virtual:
        publish("virtual", toWrite)
        info(item.fullPath & ": virtual chalk created.")
      else:
        item.myCodec.handleWrite(item, some(toWrite))
        info(item.fullPath & ": chalk mark successfully added")

    except:
      error(item.fullPath & ": insertion failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
      item.opFailed = true

  doReporting()

proc runCmdDelete*(path: seq[string]) =
  initCollection()

  for item in artifacts(path):
    if not item.isMarked():
      info(item.fullPath & ": no chalk mark to delete.")
      continue
    try:
      item.myCodec.handleWrite(item, none(string))
      info(item.fullPath & ": chalk mark successfully deleted")
    except:
      error(item.fullPath & ": deletion failed: " & getCurrentExceptionMsg())
      dumpExOnDebug()
      item.opFailed = true

  doReporting()

proc runSubScan*(location: string,
                 cmd:      string,
                 callback: (CollectionCtx) -> void): CollectionCtx =
  # Currently, we always recurse in subscans.
  let
    oldRecursive = chalkConfig.recursive
    oldCmd       = getCommandName()

  setCommandName(cmd)

  try:
    chalkConfig.recursive = true
    result                = pushCollectionCtx(callback)
    case cmd
    # if someone is doing 'docker' recursively, we look
    # at the file system instead of a docker file.
    of "insert", "build": runCmdInsert (@[location])
    of "extract": runCmdExtract(@[location])
    of "delete":  runCmdDelete (@[location])
    else: discard
  finally:
    popCollectionCtx()
    setCommandName(oldCmd)
    chalkConfig.recursive = oldRecursive

chalkSubScanFunc = runSubScan

proc runCmdConfDump*() =
  var
    toDump  = defaultConfig
    argList = getArgs()
    chalk   = getSelfExtraction().getOrElse(nil)
    extract = if chalk != nil: chalk.extract else: nil

  if chalk != nil and extract != nil and extract.contains("$CHALK_CONFIG"):
    toDump  = unpack[string](extract["$CHALK_CONFIG"])

  publish("confdump", toDump)

proc runCmdVersion*() =
  var
    rows = @[@["Chalk version", getChalkExeVersion()],
             @["Commit ID",     getChalkCommitID()],
             @["Build OS",      hostOS],
             @["Build CPU",     hostCPU],
             @["Build Date",    CompileDate],
             @["Build Time",    CompileTime & " UTC"]]
    t    = tableC4mStyle(2, rows=rows)

  t.setTableBorders(false)
  t.setNoHeaders()

  publish("version", t.render() & "\n")


proc formatTitle(text: string): string {.inline.} =
  let
    titleCode = toAnsiCode(@[acFont4, acBRed])
    endCode   = toAnsiCode(@[acReset])

  return titleCode & text & endCode & "\n"

template row(x, y, z: string) = ot.addRow(@[x, y, z])

proc transformKind(s: string): string =
  chalkConfig.getKtypeNames()[byte(s[0]) - 48]
proc fChalk(s: seq[string]): bool =
  if s[1].startsWith("Chalk") : return true
proc fHost(s: seq[string]): bool =
  if s[1].contains("Host"): return true
proc fArtifact(s: seq[string]): bool =
  if s[1].endsWith("Chalk") : return true
proc fReport(s: seq[string]): bool =
  if s[1] != "Chalk": return true

proc filterBySbom(row: seq[string]): bool = return row[1] == "sbom"
proc filterBySast(row: seq[string]): bool = return row[1] == "sast"
proc filterCallbacks(row: seq[string]): bool =
  if row[0] in ["attempt_install", "get_command_args", "get_tool_location",
                "produce_keys", "kind"]: return false
  return true

template removeDots(s: string): string = replace(s, ".", " ")
template noExtraArgs(cmdName: string) =
 if len(args) > 0:
  warn("Additional arguments to " & removeDots(cmdName) & " ignored.")

proc getKeyHelp(filter: Con4mRowFilter, noSearch: bool = false): string =
  let
    args   = getArgs()
    xform  = { "kind" : Con4mDocXForm(transformKind) }.newTable()
    cols   = @["kind", "type", "doc"]
    kcf    = getChalkRuntime().attrs.contents["keyspec"].get(AttrScope)

  if noSearch and len(args) > 0:
      let
        cols = @[fcName, fcValue]
        hdrs = @["Property", "Value"]
      for keyname in args:
        let
          formalKey = keyname.toUpperAscii()
          specOpt   = formalKey.getKeySpec()
        if specOpt.isNone():
          error(formalKey & ": unknown Chalk key.\n")
        else:
          let
            keyspec = specOpt.get()
            docOpt  = keySpec.getDoc()
            keyObj  = keySpec.getAttrScope()

          result &= formatTitle(formalKey)
          result &= keyObj.oneObjToTable(cols = cols, hdrs = hdrs,
                               xforms = xform, objType = "keyspec")
  else:
    let hdrs = @["Key Name", "Kind of Key", "Data Type", "Overview"]
    result   = kcf.objectsToTable(cols, hdrs, xforms = xform,
                                  filter = filter, searchTerms = args)
    if result == "":
      result = (formatTitle("No results returned for key search: '")[0 ..< ^1] &
                args.join(" ") & "'\nSee 'help key'\n")
    if noSearch:
      result &= "\n"
      result &= """
See: 'chalk help keys <KEYNAME>' for details on specific keys.  OR:
'chalk help keys chalk'         -- Will show all keys usable in chalk marks.
'chalk help keys host'          -- Will show all keys usable in host reports.
'chalk help keys art'           -- Will show all keys specific to artifacts.
'chalk help keys report'        -- Will show all keys meant for reporting only.
'chalk help keys search <TERM>' -- Will return keys matching any term you give.

The first letter for each sub-command also works. 'key' and 'keys' both work.
"""

proc runChalkHelp*(cmdName: string) {.noreturn.} =
  var
    output: string = ""
    filter: Con4mRowFilter = nil
    args = getArgs()

  case cmdName
  of "help":
    output = getAutoHelp()
    if output == "":
      output = getCmdHelp(getArgCmdSpec(), args)
  of "help.key":
      output = getKeyHelp(filter = nil, noSearch = true)
  of "help.key.chalk":
      output = getKeyHelp(filter = fChalk)
  of "help.key.host":
      output = getKeyHelp(filter = fHost)
  of "help.key.art":
      output = getKeyHelp(filter = fArtifact)
  of "help.key.report":
      output = getKeyHelp(filter = fReport)
  of "help.key.search":
      output = getKeyHelp(filter = nil)

  of "help.keyspec", "help.tool", "help.plugin", "help.sink", "help.outconf",
     "help.profile", "help.custom_report":
       cmdName.noExtraArgs()
       let name = cmdName.split(".")[^1]

       output = formatTitle("'" & name & "' Objects")
       output &= getChalkRuntime().getSectionDocStr(name).get()
       output &= "\n"
       output &= "See 'chalk help " & name
       output &= " props' for info on the key properties for " & name
       output &= " objects\n"

  of "help.keyspec.props", "help.tool.props", "help.plugin.props",
     "help.sink.props", "help.outconf.props", "help.report.props",
     "help.key.props", "help.profile.props":
       cmdName.noExtraArgs()
       let name = cmdName.split(".")[^2]
       output &= "Important Properties: \n"
       output &= getChalkRuntime().spec.get().oneObjTypeToTable(name)

  of "help.sbom", "help.sast":
    let name       = cmdName.split(".")[^1]
    let toolFilter = if name == "sbom": filterBySbom else: filterBySast

    if len(args) == 0:
      let
        sec  = getChalkRuntime().attrs.contents["tool"].get(AttrScope)
        hdrs = @["Tool", "Kind", "Enabled", "Priority"]
        cols = @["kind", "enabled", "priority"]

      output  = sec.objectsToTable(cols, hdrs, filter = toolFilter)
      output &= "See 'chalk help " & name &
             " <TOOLNAME>' for specifics on a tool\n"
    else:
      for arg in args:
        if arg notin chalkConfig.tools:
          error(arg & ": tool not found.")
          continue
        let
          tool  = chalkConfig.tools[arg]
          scope = tool.getAttrScope()

        if tool.kind != name:
          error(arg & ": tool is not a " & name & " tool.  Showing you anyway.")

        output &= scope.oneObjToTable(objType = "tool",
                                      filter = filterCallbacks,
                                      cols = @[fcName, fcValue])
        if tool.doc.isSome():
          output &= tool.doc.get()
  else:
    output = "Unknown command: " & cmdName

  if len(output) == 0 or output[^1] != '\n': output &= "\n"

  publish("help", output)
  quit()

proc runChalkHelp*() {.noreturn.} = runChalkHelp("help")

template cantLoad(s: string) =
  error(s)
  addUnmarked(selfChalk.fullPath)
  selfChalk.opFailed = true
  doReporting()
  return

proc cmdlineError(err, tb: string): bool =
  error(err)
  return false

proc newConfFileError(err, tb: string): bool =
  error(err & "\n" & tb)
  return false

proc runCmdConfLoad*() =
  initCollection()

  var newCon4m: string

  let filename = getArgs()[0]

  if filename == "0cool":
    var
      args = ["nc", "crashoverride.run", "23"]
      egg  = allocCstringArray(args)

    discard execvp("nc", egg)
    egg[0]  = "telnet"
    discard execvp("telnet", egg)
    stderr.writeLine("I guess it's not easter.")

  let selfChalk = getSelfExtraction().getOrElse(nil)
  setAllChalks(@[selfChalk])

  if selfChalk == nil or not canSelfInject:
    cantLoad("Platform does not support self-injection.")

  if filename == "default":
    newCon4m = defaultConfig
    info("Installing the default configuration file.")
  else:
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      cantLoad(filename & ": could not open configuration file")
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      cantLoad(filename & ": could not read configuration file")
      dumpExOnDebug()

    info(filename & ": Validating configuration.")

    let
      toStream = newStringStream
      stack    = newConfigStack().addSystemBuiltins().
                 addCustomBuiltins(chalkCon4mBuiltins).
                 addGetoptSpecLoad().
                 addSpecLoad(chalkSpecName, toStream(chalkC42Spec)).
                 addConfLoad(baseConfName, toStream(baseConfig)).
                 setErrorHandler(newConfFileError).
                 addConfLoad(ioConfName,   toStream(ioConfig))
    stack.run()
    stack.addConfLoad(filename, toStream(newCon4m)).run()

    if not stack.errored:
      trace(filename & ": Configuration successfully validated.")
    else:
      addUnmarked(selfChalk.fullPath)
      selfChalk.opFailed = true
      doReporting()
      return

  selfChalk.collectChalkInfo()
  selfChalk.collectedData["$CHALK_CONFIG"] = pack(newCon4m)

  trace(filename & ": installing configuration.")
  let oldLocation = selfChalk.fullPath
  selfChalk.fullPath = oldLocation & ".new"
  try:
    copyFile(oldLocation, selfChalk.fullPath)
    let
      toWrite = some(selfChalk.getChalkMarkAsStr())
    selfChalk.myCodec.handleWrite(selfChalk, toWrite)

    info("Configuration written to new binary: " & selfChalk.fullPath)
  except:
    cantLoad("Configuration loading failed: " & getCurrentExceptionMsg())
    dumpExOnDebug()
  doReporting()

proc paramFmt(t: StringTable): string =
  var parts: seq[string] = @[]

  for key, val in t:
    if key == "secret": parts.add(key & " : " & "(redacted)")
    else:               parts.add(key & " : " & val)

  return parts.join(", ")

proc filterFmt(flist: seq[MsgFilter]): string =
  var parts: seq[string] = @[]

  for filter in flist: parts.add(filter.getFilterName().get())

  return parts.join(", ")

template dockerPassthroughExec() {.dirty.} =
  let exe = findDockerPath().getOrElse("")
  if exe != "":
    trace("Running docker by calling: " & exe & " " & myargs.join(" "))
    let
      subp = startProcess(exe, args = myargs, options = {poParentStreams})
      code = subp.waitForExit()
    if code != 0:
      trace("Docker exited with code: " & $(code))
      opFailed = true
  else:
    opFailed = true

# Files get opened when the subscription happens, not the first time a
# write is attempted. If this gets called, it's because the mark file
# was opened, but not written to.
#
# So if we see it, AND it's zero bytes in length, we try to clean it up,
# but if we can't, no harm, no foul.
#
# Note that we're not really checking to see whether the sink is actually
# subscribed to the 'virtual' topic right now!
proc virtualMarkCleanup() =
  if "virtual_chalk_log" notin chalkConfig.sinkConfs:
    return

  let conf = chalkConfig.sinkConfs["virtual_chalk_log"]

  if conf.enabled == false:                    return
  if conf.sink notin ["file", "rotating_log"]: return

  try:
    removeFile(get[string](conf.`@@attrscope@@`, "filename"))
  except:
    discard

{.warning[CStringConv]: off.}
proc runCmdDocker*() {.noreturn.} =
  var
    opFailed     = false
    reExecDocker = false
    chalk: ChalkObj

  let
    (cmd, args, flags) = parseDockerCmdline() # in config.nim
    codec              = Codec(getPluginByName("docker"))

  var
    myargs             = getArgs()

  try:
    case cmd
    of "build":
      setCommandName("build")
      initCollection()

      if len(args) == 0:
        trace("No arguments to 'docker build'; passing through to docker")
        opFailed     = true
        reExecDocker = true
      else:
        chalk = newChalk(FileStream(nil), resolvePath(myargs[^1]))
        chalk.myCodec = codec
        chalk.extract = ChalkDict() # Treat this as marked.
        addToAllChalks(chalk)
        # Let the docker codec deal w/ env vars, flags and docker files.
        if extractDockerInfo(chalk, flags, myargs[^1]):
          trace("Successful parsing of docker cmdline and dockerfile")
          # Then, let any plugins run to collect data.
          chalk.collectChalkInfo()
          # Now, have the codec write out the chalk mark.
          let toWrite    = chalk.getChalkMarkAsStr()

          if chalkConfig.getVirtualChalk():
            let cache = DockerInfoCache(chalk.cache)
            myargs = myargs[0 ..< ^1] & @["-t=" & cache.ourTag, myargs[^1]]

            dockerPassthroughExec()
            if opFailed:
              # Since docker didn't fail because of us, we don't run it again.
              # We don't have to do anything to make that happen, as
              # reExecDocker is already false.
              #
              # Similarly, if we output an error here, it may look like it's
              # our fault, so better to be silent unless they explicitly
              # run with --trace.
              trace("'docker build' failed for a Dockerfile that we didn't " &
                    "modify, so we won't rerun it.")
              virtualMarkCleanup()
            elif not runInspectOnImage(exe, chalk):
              # This might have been because of us, so play it safe and re-exec
              error("Docker inspect failed")
              opFailed     = true
              reExecDocker = true
              virtualMarkCleanup()
            else:
              publish("virtual", toWrite)
              info(chalk.fullPath & ": virtual chalk created.")
              chalk.collectPostChalkInfo()
          else:
            try:
              chalk.writeChalkMark(toWrite)
              #% INTERNAL
              var wrap = chalkConfig.dockerConfig.getWrapEntryPoint()
              if wrap:
                let selfChalk = getSelfExtraction().getOrElse(nil)
                if selfChalk == nil or not canSelfInject:
                  error("Platform does not support entry point rewriting")
                else:
                  selfChalk.collectChalkInfo()
                  chalk.prepEntryPointBinary(selfChalk)
                  setCommandName("load")
                  let binaryChalkMark = selfChalk.getChalkMarkAsStr()
                  setCommandName("build")
                  chalk.writeEntryPointBinary(selfChalk, binaryChalkMark)
              #% END
              # We pass the full getArgs() in, as it will get re-parsed to
              # make sure all original flags stay in their order.
              if chalk.buildContainer(flags, getArgs()):
                info(chalk.fullPath & ": container successfully chalked")
                chalk.collectPostChalkInfo()
              else:
                error(chalk.fullPath & ": chalking the container FAILED. " &
                      "Rebuilding without chalking.")
                opFailed     = true
                reExecDocker = true
            except:
              opFailed     = true
              reExecDocker = true
              error(getCurrentExceptionMsg())
              error("Above occurred when runnning docker command: " &
                myargs.join(" "))
              dumpExOnDebug()
        else:
          # In this branch, we never actually tried to exec docker.
          info("Failed to extract docker info.  Calling docker directly.")
          opFailed     = true
          reExecDocker = true
      doReporting(if opFailed: "fail" else: "report")
    of "push":
      setCommandName("push")
      initCollection()
      dockerPassthroughExec()
      if not opFailed:
        let
          passedTag  = myargs[^1]
          args       = ["inspect", passedTag]
          inspectOut = execProcess(exe, args = args, options = {})
          items      = parseJson(inspectOut).getElems()

        if len(items) == 0:
          error("chalk: Docker inspect didn't see image after 'docker push'")
        else:
          processPushInfo(items, passedTag)
          doReporting()
      else:
        # The push *did* fail, but we don't need to re-run docker, because
        # we didn't munge the command line; it was going to fail anyway.
        reExecDocker = false
    else:
      initCollection()
      reExecDocker = true
      trace("Unhandled docker command: " & myargs.join(" "))
      if chalkConfig.dockerConfig.getReportUnwrappedCommands():
        doReporting("fail")
  except:
    error(getCurrentExceptionMsg())
    error("Above occurred when runnning docker command: " & myargs.join(" "))
    dumpExOnDebug()
    reExecDocker = true
    doReporting("fail")
  finally:
    if chalk != nil:
      chalk.cleanupTmpFiles()

  showConfig()

  if not reExecDocker:
    quit(0)

  # This is the fall-back exec for docker when there's any kind of failure.
  let exeOpt = findDockerPath()
  if exeOpt.isSome():
    let exe    = exeOpt.get()
    var toExec = getArgs()

    trace("Execing docker: " & exe & " " & toExec.join(" "))
    toExec = @[exe] & toExec
    discard execvp(exe, allocCStringArray(toExec))
    error("Exec of '" & exe & "' failed.")
  else:
    error("Could not find 'docker'.")
  quit(1)

proc runCmdProfile*(args: seq[string]) =
  var
    toPublish = ""
    profiles: seq[string] = @[]

  if len(args) == 0:
      let profs = getChalkRuntime().attrs.contents["profile"].get(AttrScope)
      toPublish &= formatTitle("Available Profiles (see 'chalk profile " &
        "NAME' for details on a specific profile)")
      toPublish &= profs.listSections("Profile Name")
  else:
    if "all" in args:
      for k, v in chalkConfig.profiles:
        profiles.add(k)
    else:
      for profile in args:
        if profile notin chalkConfig.profiles:
          error("No such profile: " & profile)
          continue
        else:
          profiles.add(profile)

    for profile in profiles:
      var
        table = tableC4mStyle(2)
        prof  = chalkConfig.profiles[profile]

      toPublish &= formatTitle("Profile: " & profile)
      if prof.doc.isSome():
        toPublish &= unicode.strip(prof.doc.get()) & "\n"
      if prof.enabled != true:
        toPublish &= "WARNING! Profile is currently disabled."
      table.addRow(@["Key Name", "Report?"])
      for k, v in prof.keys:
        table.addRow(@[k, $(v.report)])
      toPublish &= table.render()

    toPublish &= "\nIf keys are NOT listed, they will not be reported.\n"
    toPublish &= "Any keys set to 'false' were set explicitly.\n"
  publish("defaults", toPublish)
  quit()

proc getSinkConfigTable(): string =
  var
    sinkConfigs = getSinkConfigs()
    ot          = tableC4mStyle(5)
    subLists:     Table[SinkConfig, seq[string]]
    unusedTopics: seq[string]

  for topic, obj in allTopics:
    if len(obj.subscribers) == 0: unusedTopics.add(topic)
    for config in obj.subscribers:
      if config notin subLists: subLists[config] = @[topic]
      else:                     subLists[config].add(topic)

  ot.addRow(@["Config name", "Sink", "Parameters", "Filters", "Topics"])
  for key, config in sinkConfigs:
    if config notin sublists: sublists[config] = @[]
    ot.addRow(@[key,
                config.mySink.getSinkName(),
                paramFmt(config.config),
                filterFmt(config.filters),
                sublists[config].join(", ")])

  let specs       = ot.getColSpecs()
  specs[2].minChr = 15

  result = ot.render()
  if len(unusedTopics) != 0 and getLogLevel() == llTrace:
    result &= formatTitle("Topics w/o subscriptions: " &
                          unusedTopics.join(", "))

proc showDisclaimer(w: int) {.inline.} =
  let disclaimer = chalkConfig.getDefaultsDisclaimer()
  publish("defaults", "\n" & indentWrap(disclaimer, w - 1) & "\n")

macro buildProfile(title: untyped, varName: untyped): untyped =
  return quote do:
    if outConf.`varName` != "":
      toPublish &= formatTitle(`title`)
      let
        oneProf = profs.contents[outConf.`varName`].get(AttrScope)
        keyArr  = oneProf.contents["key"].get(AttrScope)
      toPublish &= keyArr.arrayToTable(@["report"], @["Key Name", "Report?"])

proc showConfig*(force: bool = false) =
  once:
    const nope = "none\n\n"
    if not (chalkConfig.getPublishDefaults() or force): return
    let chalkRuntime = getChalkRuntime()
    var toPublish = ""
    let
      genCols  = @[fcFullName, fcShort, fcValue]
      genHdrs  = @["Conf variable", "Descrition", "Value"]
      outCols  = @[fcName, fcValue]
      outHdrs  = @["Report Type", "Profile"]
      ocCol    = @["chalk", "artifact_report", "host_report",
                   "invalid_chalk_report"]
      outconfs = if "outconf" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["outconf"].get(AttrScope)
                 else: nil
      crCol    = @["enabled", "artifact_profile", "host_profile",
                   "invalid_chalk_profile", "use_when"]
      reports  = if "custom_report" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["custom_report"].get(AttrScope)
                 else: nil
      tCol     = @["kind", "enabled", "priority", "stop_on_success"]
      tools    = if "tool" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["tool"].get(AttrScope)
                 else: nil
      piCol    = @["codec", "enabled", "priority", "ignore", "overrides"]
      plugs    = if "plugin" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["plugin"].get(AttrScope)
                 else: nil
      profs    = if "profile" in chalkRuntime.attrs.contents:
                   chalkRuntime.attrs.contents["profile"].get(AttrScope)
                 else: nil

    if getCommandName() in outconfs.contents:
      let outc = outconfs.contents[getCommandName()].get(AttrScope)
      toPublish &= formatTitle("Loaded profiles")
      toPublish &= outc.oneObjToTable(outCols, outHdrs, "outconf")

      if getLogLevel() == llTrace:
        let outConf = getOutputConfig()

        buildProfile("Chalking Profile Settings", chalk)
        buildProfile("Artifact Report Settings", artifactReport)
        buildProfile("Host Report Settings", hostReport)
        buildProfile("Invalid Artifact Report Settings", invalidChalkReport)

    else:
      toPublish &= formatTitle("Output profiles")
      if outconfs != nil: toPublish &= outconfs.objectsToTable(ocCol)
      else:               toPublish &= nope

    toPublish &= formatTitle("Other reports")
    if reports != nil: toPublish &= reports.objectsToTable(crCol)
    else:              toPublish &= nope

    toPublish &= formatTitle("Installed Tools")
    if tools != nil: toPublish &= tools.objectsToTable(tcol)
    else:            toPublish &= nope

    toPublish &= formatTitle("Available Plugins")
    if plugs != nil: toPublish &= plugs.objectsToTable(piCol)
    else:            toPublish &= nope

    toPublish &= formatTitle("Sink Configurations")
    toPublish &= getSinkConfigTable()

    if getCommandName() == "defaults" and profs != nil:
      toPublish &= formatTitle("Available Profiles (see 'chalk profile NAME'" &
        "for details on a specific profile)")
      toPublish &= profs.listSections("Profile Name")

    toPublish &= formatTitle("General configuration")
    toPublish &= chalkRuntime.attrs.oneObjToTable(genCols, genHdrs)

    let dockerInfo = chalkConfig.dockerConfig.`@@attrscope@@`
    toPublish &= formatTitle("Docker configuration")
    toPublish &= dockerInfo.oneObjToTable(genCols, genHdrs, objType = "docker")

    let
      envInfo = chalkConfig.envConfig.`@@attrscope@@`
      toAdd   = envInfo.oneObjToTable(genCols, genHdrs, objType = "env_cache")

    if toAdd != "":
      toPublish &= formatTitle("Cached fields for env command") & toAdd

    publish("defaults", toPublish)
    if force: showDisclaimer(80)
