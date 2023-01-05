import strformat, strutils, tables, options, algorithm, os, streams, sugar
import macros
import con4m, con4m/st, con4m/eval, nimutils, nimutils/box
include errors
include configs/baseconfig    # Gives us the variable baseConfig
include configs/defaultconfig # Gives us defaultConfig
include configs/con4mconfig   # gives us the variable samiConfig, which is
                              # a con4m configuration object.
                              # this needs to happen before we include types.
include types

const allowedCmds = ["inject", "extract", "defaults", "configDump"]
const validLogLevels = ["none", "error", "warn", "info", "trace"]
 
proc getOutputConfig*(): TableRef[string, SamiOutputSection] =
  return samiConfig.output

proc getOutputSecret*(s: SamiOutputSection): Option[string] =
  return s.secret

proc getOutputUserId*(s: SamiOutputSection): Option[string] =
  return s.userId

proc getOutputFilename*(s: SamiOutputSection): Option[string] =
  return s.filename

proc getOutputDstUri*(s: SamiOutputSection): Option[string] =
  return s.dstUri

proc getOutputRegion*(s: SamiOutputSection): Option[string] =
  return s.region

proc getOutputCommand*(s: SamiOutputSection): Option[seq[string]] =
  return s.command

proc getOutputAuxId*(s: SamiOutputSection): Option[string] =
  return s.auxid

proc getConfigErrors*(): Option[seq[string]] =
  if ctxSamiConf.errors.len() != 0:
    return some(ctxSamiConf.errors)

proc getConfigPath*(): seq[string] =
  return samiConfig.configPath

proc setConfigPath*(val: seq[string]) =
  discard ctxSamiConf.setOverride("config_path", pack(val))
  samiConfig.configPath = val

proc getConfigFileName*(): string =
  return samiConfig.configFileName

proc setConfigFileName*(val: string) =
  discard ctxSamiConf.setOverride("config_filename", pack(val))
  samiConfig.configFileName = val

proc getDefaultCommand*(): Option[string] =
  return samiConfig.defaultCommand

proc getCanDump(): bool =
  return samiConfig.canDump
  
proc getCanLoad(): bool =
  return samiConfig.canLoad
  
proc getColor*(): bool =
  return samiConfig.color

proc setColor*(val: bool) =
  discard ctxSamiConf.setOverride("color", pack(val))
  samiConfig.color = val

proc getLogLevel*(): string =
  return samiConfig.logLevel

proc setLogLevel*(val: string) =
  discard ctxSamiConf.setOverride("log_level", pack(val))
  samiConfig.logLevel = val

proc getDryRun*(): bool =
  return samiConfig.dryRun

proc setDryRun*(val: bool) =
  discard ctxSamiConf.setOverride("dry_run", pack(val))
  samiConfig.dryRun = val

proc getArtifactSearchPath*(): seq[string] =
  return samiConfig.artifactSearchPath

proc setArtifactSearchPath*(val: seq[string]) =

  samiConfig.artifactSearchPath = @[]

  for item in val:
    samiConfig.artifactSearchPath.add(item.resolvePath())

  discard ctxSamiConf.setOverride("artifact_search_path", pack(val))

proc getRecursive*(): bool =
  return samiConfig.recursive

proc setRecursive*(val: bool) =
  discard ctxSamiConf.setOverride("recursive", pack(val))
  samiConfig.recursive = val

proc getAllowExternalConfig*(): bool =
  return samiConfig.allowExternalConfig

proc getExtractionOutputHandlers*(): seq[string] =
  return samiConfig.extractionOutputHandlers

proc getInjectionPrevSamiOutputHandlers*(): seq[string] =
  return samiConfig.injectionPrevSamiOutputHandlers

proc getInjectionOutputHandlers*(): seq[string] =
  return samiConfig.injectionOutputHandlers

proc getDeletionOutputHandlers*(): seq[string] =
  return samiConfig.deletionOutputHandlers

proc getAllKeys*(): seq[string] =
  result = @[]

  for key, val in samiConfig.key:
    result.add(key)

proc getKeySpec*(name: string): Option[SamiKeySection] =
  if name in samiConfig.key:
    return some(samiConfig.key[name])

proc getOrderedKeys*(): seq[string] =
  let keys = getAllKeys()

  var list: seq[(int, string)] = @[]

  for key in keys:
    let spec = getKeySpec(key).get()
    list.add((spec.outputOrder, key))

  list.sort()

  for (priority, key) in list:
    result.add(key)

proc getCustomKeys*(name: string): seq[string] =
  result = @[]

  for key, val in samiConfig.key:
    if not val.system:
      result.add(key)

proc getPluginConfig*(name: string): Option[SamiPluginSection] =
  if name in samiConfig.plugin:
    return some(samiConfig.plugin[name])

proc getRequired*(key: SamiKeySection): bool =
  return key.required

proc getMissingAction*(key: SamiKeySection): string =
  return key.missingAction

proc getSystem*(key: SamiKeySection): bool =
  return key.system

proc getSquash*(key: SamiKeySection): bool =
  return key.squash

proc getStandard*(key: SamiKeySection): bool =
  return key.standard

proc getMustForce*(key: SamiKeySection): bool =
  return key.mustForce

proc getSkip*(key: SamiKeySection): bool =
  return key.skip

proc getInRef*(key: SamiKeySection): bool =
  return key.inRef

proc getOutputOrder*(key: SamiKeySection): int =
  return key.outputOrder

proc getSince*(key: SamiKeySection): Option[string] =
  return key.since

proc getType*(key: SamiKeySection): string =
  return key.`type`

proc getValue*(key: SamiKeySection): Option[Box] =
  return key.value

proc getDocString*(key: SamiKeySection): Option[string] =
  return key.docString

proc getPriority*(plugin: SamiPluginSection): int =
  return plugin.priority

proc getCodec*(plugin: SamiPluginSection): bool =
  return plugin.codec

proc getEnabled*(plugin: SamiPluginSection): bool =
  return plugin.enabled

proc getKeys*(plugin: SamiPluginSection): seq[string] =
  return plugin.keys

proc getOverrides*(plugin: SamiPluginSection):
                 Option[TableRef[string, int]] =
  return plugin.overrides

proc getIgnore*(plugin: SamiPluginSection): Option[seq[string]] =
  return plugin.ignore

proc getDocString*(plugin: SamiPluginSection): Option[string] =
  return plugin.docstring

proc getCommand*(plugin: SamiPluginSection): Option[string] =
  return plugin.command

proc getCommandPlugins*(): seq[(string, string)] =
  for name, plugin in samiConfig.plugin:
    if (not plugin.command.isSome()) or (not plugin.enabled):
      continue
    result.add((name, plugin.command.get()))

proc getOutputPointers*(): bool =
  let contents = samiConfig.key["SAMI_PTR"]

  if getInjectionOutputHandlers().len() == 0:
    return false

  if contents.getValue().isSome() and not contents.getSkip():
    return true

  return false

proc `$`*(plugin: SamiPluginSection): string =
  var overrideStr, ignoreStr: string

  let optO = plugin.getOverrides()

  if optO.isNone():
    overrideStr = "<none>"
  else:
    var l: seq[string]
    for key, val in optO.get():
      l.add(fmt"{key} : {val}")
    overrideStr = l.join(", ")

  let optI = plugin.getIgnore()

  if optI.isNone():
    ignoreStr = "<none>"
  else:
    ignoreStr = optI.get().join(", ")


  return fmt"""  default priority:      {plugin.getPriority()}
  is codec:              {plugin.getCodec()}
  is enabled:            {plugin.getEnabled()}
  keys handled:          {plugin.getKeys().join(", ")}
  priority overrides:    {overrideStr}
  ignore:                {ignoreStr}
  doc string:            {getOrElse(plugin.docstring, "<none>")}
  external impl command: {plugin.command}
"""

proc valueToString(b: Box): string {.inline.} =
  return $(b)

proc `$`*(key: SamiKeySection): string =
  var valstr = "<none>"

  if key.value.isSome():
    valstr = valueToString(key.value.get())

  return fmt"""  standard:           {key.standard}
  required:           {key.required}
  missing action:     {key.missingAction}
  system:             {key.system}
  squash:             {key.squash}  
  force required:     {key.mustForce}
  skip:               {key.skip}
  first spec version: {getOrElse(key.since, "<none>")}
  output order:       {key.outputOrder}
  content type:       {key.`type`}
  value:              {valstr}
  doc string:         {getOrElse(key.docstring, "<none>")}
"""

macro condOutputHandlerFormatStr(sym: untyped, prefix: string): string =
  let fieldAsStr = newLit(sym.strVal)
  
  result = quote do:
    let optEntry = dottedLookup(attrs, @["output", s, `fieldAsStr`])
    let locked = if optEntry.isSome(): optEntry.get().locked else: false

    if o.`sym`.isSome() or not locked:
      if o.`sym`.isSome(): `prefix` & o.`sym`.get() & "\n"
      else: `prefix` & "<none>\n"
    else:
      ""

macro condOutputHandlerFormatStrSeq(sym: untyped, prefix: string): string =
  let fieldAsStr = newLit(sym.strVal)
  
  result = quote do:
    let optEntry = dottedLookup(attrs, @["output", s, `fieldAsStr`])
    let locked = if optEntry.isSome(): optEntry.get().locked else: false

    if o.`sym`.isSome() or not locked:
      if o.`sym`.isSome(): `prefix` & join(o.`sym`.get(), " ") & "\n"
      else: `prefix` & "<none>\n"
    else:
      ""
        
proc `$`*(o: SamiOutputSection, s: string): string =
  let
    attrs = ctxSamiConf.st

  result  = condOutputHandlerFormatStr(filename, "  file name:       ")
  result &= condOutputHandlerFormatStrSeq(command, "  command:         ")
  result &= condOutputHandlerFormatStr(dst_uri, "  destination URI: ")
  result &= condOutputHandlerFormatStr(region, "  region:          ")
  result &= condOutputHandlerFormatStr(userid, "  IAM user:        ")
  result &= condOutputHandlerFormatStr(secret, "  secret:          ")

proc `$`*(c: SamiConfig): string =
  var configKeys, configPlugins, configOuts: seq[string]

  for key, val in c.key:
    configKeys.add(key)
    configKeys.add($(val))

  for plugin, val in c.plugin:
    configPlugins.add(plugin)
    configPlugins.add($(val))

  for confOut, val in c.output:
    if confOut == "stdout":
      configOuts.insert(`$`(val, confOut), 0)
      configOuts.insert(confOut, 0)
    else:
      configOuts.add(confOut)
      configOuts.add(`$`(val, confOut))

  return fmt"""config search path:        {c.configPath.join(":")}
config filename:           {c.configFilename}
config default command:    {getOrElse(samiConfig.defaultCommand, "<none>")}
color:                     {c.color}
log level:                 {c.logLevel}
dry run:                   {c.dryRun}
artifact search path:      {c.artifactSearchPath.join(":")}
recursive artifact search: {c.recursive}
Configured SAMI keys:
{configKeys.join("\n")}

Configured Plugins:
{configPlugins.join("\n")}

Configured Ouput Hooks:
{configOuts.join("\n")}
extraction hooks:       {c.extractionOutputHandlers.join(", ")}
prev sami out hooks:    {c.injectionPrevSamiOutputHandlers.join(", ")}
new sami out hooks:     {c.injectionOutputHandlers.join(", ")}
"""

proc showConfig*() =
  stderr.writeLine($(samiConfig))
  stderr.writeLine("""
Use 'dumpConfig' to export the embedded configuration file to disk,
and 'loadConfig' to load one.""")

var onceLockBuiltinKeys = false

proc lockBuiltinKeys*() =
  if onceLockBuiltinKeys:
    return
  else:
    onceLockBuiltinKeys = true
  for key in getAllKeys():
    let
      prefix = "key." & key
      stdOpt = getConfigVar(ctxSamiConf, prefix & ".standard")

    if stdOpt.isNone(): continue
    
    let
      std = stdOpt.get()
      sys = getConfigVar(ctxSamiConf, prefix & ".system").get()

    if unpack[bool](std):
      discard ctxSamiConf.lockConfigVar(prefix & ".required")
      discard ctxSamiConf.lockConfigVar(prefix & ".system")
      discard ctxSamiConf.lockConfigVar(prefix & ".type")
      discard ctxSamiConf.lockConfigVar(prefix & ".standard")
      discard ctxSamiConf.lockConfigVar(prefix & ".since")
      discard ctxSamiConf.lockConfigVar(prefix & ".output_order")

    if unpack[bool](sys):
      discard ctxSamiConf.lockConfigVar(prefix & ".missing_action")
      discard ctxSamiConf.lockConfigVar(prefix & ".value")

  # These are locks of invalid fields for specific output handlers.
  # Note that all of these lock calls could go away if con4m gets a
  # locking syntax.
  discard ctxSamiConf.lockConfigVar("output.stdout.filename")
  discard ctxSamiConf.lockConfigVar("output.stdout.command")
  discard ctxSamiConf.lockConfigVar("output.stdout.dst_uri")
  discard ctxSamiConf.lockConfigVar("output.stdout.region")
  discard ctxSamiConf.lockConfigVar("output.stdout.userid")
  discard ctxSamiConf.lockConfigVar("output.stdout.secret")        

  discard ctxSamiConf.lockConfigVar("output.local_file.command")
  discard ctxSamiConf.lockConfigVar("output.local_file.dst_uri")
  discard ctxSamiConf.lockConfigVar("output.local_file.region")
  discard ctxSamiConf.lockConfigVar("output.local_file.userid")
  discard ctxSamiConf.lockConfigVar("output.local_file.secret")

  discard ctxSamiConf.lockConfigVar("output.s3.filename")
  discard ctxSamiConf.lockConfigVar("output.s3.command")
  
# This should eventually move to evaluation callbacks.  They can give
# better error messages more easily.
# TODO: should also validate that all plugin keys are spec'd.
proc doAdditionalValidation*() =
  if samiConfig.defaultCommand.isSome() and
    not (samiConfig.defaultCommand.get() in allowedCmds):
    warn(fmt"Default command {samiConfig.defaultCommand.get()} " &
          "not recognized (ignored)")

    # This dance needs to be automated by con4m.  Note that we are
    # only making a copy of the entry here, so after we edit we need
    # to re-set it.
    var entry = ctxSamiConf.st.entries["default_command"]
    entry.value = none(Box)
    ctxSamiConf.st.entries["default_command"] = entry
    samiConfig.defaultCommand = none(string)

  if not (samiConfig.logLevel in validLogLevels):
    warn(fmt"Log level {samiConfig.logLevel} not recognized. " &
         "Defaulting to 'warn'")
    var entry = ctxSamiConf.st.entries["log_level"]
    entry.value = some(pack("warn"))
    ctxSamiConf.st.entries["log_level"] = entry
    samiConfig.logLevel = "warn"

  # Take any paths and turn them into absolute paths.
  for i in 0 ..< len(samiConfig.artifactSearchPath):
    samiConfig.artifactSearchPath[i] =
      samiConfig.artifactSearchPath[i].resolvePath()

  for i in 0 ..< len(samiConfig.configPath):
    samiConfig.configPath[i] = samiConfig.configPath[i].resolvePath()

  # Now, lock a bunch of fields.
  lockBuiltinKeys()

proc loadEmbeddedConfig(selfSamiOpt: Option[SamiDict],
                        dieIfInvalid = true): bool =
  var
    confString: string
    validEmbedded: bool

  if selfSamiOpt.isNone():
    validEmbedded = false
    confString = defaultConfig
  else:
    let selfSami = selfSamiOpt.get()
  
    # We extracted a SAMI object from our own executable.  Check for an
    # X_SAMI_CONFIG key, and if there is one, run that configuration
    # file, before loading any on-disk configuration file.
    if not selfSami.contains("X_SAMI_CONFIG"):
      trace("Embedded self-SAMI does not contain a configuration.")
      confString = defaultConfig
      validEmbedded = false
    else:
      confString = unpack[string](selfSami["X_SAMI_CONFIG"])
      validEmbedded = true

  let
    confStream = newStringStream(confString)
    res = ctxSamiConf.stackConfig(confStream, "<embedded>")

  if res.isNone():
    if dieIfInvalid:
      error("Embeeded configuration is invalid. Use 'setconf' command to fix")
    else:
      validEmbedded = false
  else:
    validEmbedded = true

  if not validEmbedded: return false

  samiConfig = ctxSamiConf.loadSamiConfig()
  doAdditionalValidation()
  trace("Loaded embedded configuration file")
  return true

proc handleConfigDump*(selfSami: Option[SamiDict], argv: seq[string]) =
  let confValid = loadEmbeddedConfig(selfSami, dieIfInvalid = false)
  if not getCanDump():
    error("Dumping embedded config is disabled.")
    quit()
  else:
    if len(argv) > 1:
      error("configDump requires at most one parameter")
      quit()

    let
      outfile = if len(argv) == 0 or resolvePath(argv[0]) == resolvePath("."):
                  "sami.conf.dump"
                else: resolvePath(argv[0])
      toDump = if selfSami.isSome(): unpack[string](selfSami.get()["X_SAMI_CONFIG"])
               else: defaultConfig
               
    try:
      var f = newFileStream(outfile, fmWrite)
      if f == nil:
        error(fmt"Could not write to: {outfile} ({getCurrentExceptionMsg()})")
        quit()
      f.write(toDump)
      f.close()
    except:
      error(fmt"Could not write to: {outfile} ({getCurrentExceptionMsg()})")
      quit()

    stderr.writeLine(fmt"Dumped configuration to: {outfile}")
    quit()

proc quitIfCantChangeEmbeddedConfig*(selfSami: Option[SamiDict]) =
  discard loadEmbeddedConfig(selfSami, dieIfInvalid = false)
  if not getCanLoad():
    error("Loading a new embedded config is diabled.")
    quit()

proc loadUserConfigFile*(selfSami: Option[SamiDict]) =
  discard loadEmbeddedConfig(selfSami)

  if not getAllowExternalConfig():
    return
    
  var
    path = getConfigPath()
    filename = getConfigFileName() # the base file name.
    fname: string                  # configPath / baseFileName
    loaded: bool = false

  for dir in path:
    fname = dir.joinPath(filename)
    if fname.fileExists():
      break
    trace(fmt"No configuration file found in {dir}.")

  if fname != "":
    trace(fmt"Loading config file: {fname}")
    try:
      let res = ctxSamiConf.stackConfig(fname)
      if res.isNone():
        error(fmt"{fname}: invalid configuration not loaded.")

        if ctxSamiConf.errors.len() != 0:
          for err in ctxSamiConf.errors:
            error(err)

        quit()
      else:
        loaded = true
      
    except Con4mError: # config not present:
      inform(fmt"{fname}: config file not found.")

  samiConfig = ctxSamiConf.loadSamiConfig()
  doAdditionalValidation()

  if loaded:
    trace(fmt"Loaded configuration file: {fname}")
  else:
    trace("Running without a config file.")

var selfInjection = false

proc getSelfInjecting*(): bool =
  return selfInjection
    
proc setupSelfInjection*(filename: string) =
  var newCon4m: string
  
  selfInjection = true

  setArtifactSearchPath(@[resolvePath(getAppFileName())])

  # The below protection is easily thwarted, especially since SAMI is open
  # source.  So we don't try to guard against it too much.
  #
  # Particularly, we'd happily inject a SAMI into a copy of the SAMI
  # executable via just standard injection, which would allow us to
  # nuke any policy that locks loading.
  #
  # Given that it's open source, no need to try to run an arms race;
  # the feature is here more to ensure there are clear operational
  # controls.
  
  if not getCanLoad():
    error("Loading embedded configurations not supported.")
    quit()
    
  if filename == "default":
    newCon4m = defaultConfig
    if getDryRun():
      forceInform("Would install the default configuration file.")
      quit()
    else:
      inform("Installing the default confiuration file.")
  else:
    let f = newFileStream(resolvePath(filename))
    if f == nil:
      error(fmt"{filename}: could not open configuration file")
      quit()
    try:
      newCon4m = f.readAll()
      f.close()
    except:
      error(fmt"{filename}: could not read configuration file")
      quit()

    inform(fmt"{filename}: Validating configuration.")
    
    # Now we need to validate the config, without stacking it over our
    # existing configuration. We really want to know that the file
    # will not only be a valid con4m file, but that it will meet the
    # SAMI spec.
    #
    # The only way we can be reasonably sure it will load is by running it 
    # once, as the spec validation check requires seeing the final 
    # configuration state.
    #
    # But, since configs are code that could have conditionals, evaluating
    # isn't going to tell us whether the spec we're loading is ALWYS going to
    # meet the spec, and has the unfortunate consequence of executing any
    # side-effects that the code might have, which isn't ideal. 
    #
    # Still, that's the best we can reasonably do, so we're going to go ahead 
    # and evaluate the thing once to give ourselves the best shot of detecting 
    # any errors early.  Since con4m is fully statically type checked, that
    # does provide us a reasonable amount of confidence; the only issues we
    # might have in the field are:
    #
    # 1) Spec validation failures when different conditional branches are taken.
    # 2) Runtime errors, like index-out-of-bounds errors.
    #
    # To do this check, we first re-load the base configuration in a new
    # universe, so that our checking doesn't conflict with our current
    # configuration.
    #
    # Then, we nick the (read-only) schema spec and function table from the 
    # current configuration universe, to make sure we can properly check 
    # anything in the new configuration file.
    #
    # Finally, in that new universe, we "stack" the new config over the newly
    # loaded base configuration.  The stack operation fully checks everything, 
    # so if it doesn't error, then we know the new config file is good enough, 
    # and we should load it.
    try:
      var 
        tree = parse(newStringStream(baseConfig), "baseconfig")
        opt = tree.evalTree()
        testState = opt.get()
        testStream = newStringStream(newCon4m)
      testState.spec = ctxSamiConf.spec
      testState.funcTable = ctxSamiConf.funcTable
      if testState.stackConfig(testStream, filename).isNone():
        error(fmt"{filename}: invalid configuration.")
        if testState.errors.len() != 0:
          for err in testState.errors:
            error(err)
        quit()
    except:
      error("Could not load config file: {getExceptionMessage()}")
      quit()
      
    trace(fmt"{filename}: Configuration successfully validated.")

    if getDryRun():
      forceInform("The provided configuration file would be loaded.")
      quit()
      
    # Now we're going to set up the injection properly solely by
    # tinkering with the config state.
    #
    # While we will leave any injection handlers in place, we will
    # NOT use a SAMI pointer.
    #
    # These keys we are requesting are all in the base config, so
    # these lookups won't fail.
    var samiPtrKey = getKeySpec("SAMI_PTR").get()
    samiPtrKey.value = none(Box)

    var xSamiConfKey = getKeySpec("X_SAMI_CONFIG").get()
    xSamiConfKey.value = some(pack(newCon4m))
    
proc getConfigState*(): ConfigState =
  return ctxSamiConf    
  
