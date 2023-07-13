## Defines most of the types used throughout the chalk code base,
## except the config-file related types, which are auto-generated by
## con4m, and live in configs/con4mconfig.nim (and are included
## through config.nim)
##
## :Author: John Viega (john@crashoverride.com)
## :Copyright: 2022, 2023, Crash Override, Inc.

import c4autoconf, streams, tables, options, nimutils, sugar

type
  ChalkDict* = OrderedTableRef[string, Box]
  ## The chalk info for a single artifact.
  ChalkObj* = ref object
    fullpath*:      string      ## The path to the artifact.
    cachedHash*:    string      ## Cached 'ending' hash
    cachedPreHash*: string      ## Cached 'unchalked' hash
    collectedData*: ChalkDict   ## What we're adding during insertion.
    extract*:       ChalkDict   ## What we extracted, or nil if no extract.
    opFailed*:      bool
    marked*:        bool
    embeds*:        seq[ChalkObj]
    stream*:        FileStream  # Plugins by default use file streams; we
    startOffset*:   int         # keep state fields for that to bridge between
    endOffset*:     int         # extract and write. If the plugin needs to do
                                # something else, use the cache field
                                # below, instead.
    err*:           seq[string] ## runtime logs for chalking are filtered
                                ## based on the "chalk log level". They
                                ## end up here, until the end of chalking
                                ## where, they get added to ERR_INFO, if
                                ## any.  To disable, simply set the chalk
                                ## log level to 'none'.
    cache*:         RootRef     ## Generic pointer a codec can use to
                                ## store any state it might want to stash.
    myCodec*:       Codec
    auxPaths*:      seq[string] ## File-system references for this
                                ## artifact, when the fullpath isn't a
                                ## file system reference.  For
                                ## example, in a docker container,
                                ## this can contain the context
                                ## directory and the docker file.

  Plugin* = ref object of RootObj
    name*:       string
    configInfo*: PluginSpec

  Codec* = ref object of Plugin
    searchPath*: seq[string]

  KeyType* = enum KtChalkableHost, KtChalk, KtNonChalk, KtHostOnly

  CollectionCtx* = ref object
    currentErrorObject*: Option[ChalkObj]
    allChalks*:          seq[ChalkObj]
    unmarked*:           seq[string]
    report*:             Box
    postprocessor*:      (CollectionCtx) -> void

var
  ctxStack            = seq[CollectionCtx](@[])
  collectionCtx       = CollectionCtx()
  hostInfo*           = ChalkDict()
  subscribedKeys*     = Table[string, bool]()
  systemErrors*       = seq[string](@[])
  selfChalk*          = ChalkObj(nil)
  selfID*             = Option[string](none(string))
  canSelfInject*      = true

# All of these things have to be here for stupid dependency reasons.
proc pushCollectionCtx*(callback: (CollectionCtx) -> void): CollectionCtx =
  ctxStack.add(collectionCtx)
  collectionCtx = CollectionCtx(postprocessor: callback)
  result        = collectionCtx
proc popCollectionCtx*() =
  if len(ctxStack) != 0: collectionCtx = ctxStack.pop()
proc inSubscan*(): bool =
  return len(ctxStack) != 0
proc getCurrentCollectionCtx*(): CollectionCtx = collectionCtx
proc getErrorObject*(): Option[ChalkObj] = collectionCtx.currentErrorObject
proc setErrorObject*(o: ChalkObj) =
  collectionCtx.currentErrorObject = some(o)
proc clearErrorObject*() =
  collectionCtx.currentErrorObject = none(ChalkObj)
proc getAllChalks*(): seq[ChalkObj] = collectionCtx.allChalks
proc addToAllChalks*(o: ChalkObj) =
  collectionCtx.allChalks.add(o)
proc setAllChalks*(s: seq[ChalkObj]) =
  collectionCtx.allChalks = s
proc removeFromAllChalks*(o: ChalkObj) =
  if o in collectionCtx.allChalks:
    collectionCtx.allChalks.del(collectionCtx.allChalks.find(o))
proc getUnmarked*(): seq[string] = collectionCtx.unmarked
proc addUnmarked*(s: string) =
  collectionCtx.unmarked.add(s)
proc isMarked*(chalk: ChalkObj): bool {.inline.} = return chalk.marked
proc newChalk*(stream: FileStream, loc: string): ChalkObj =
  result = ChalkObj(fullpath:      loc,
                    collectedData: ChalkDict(),
                    opFailed:      false,
                    stream:        stream,
                    extract:       nil)
  setErrorObject(result)

proc idFormat*(rawHash: string): string =
  let s = base32vEncode(rawHash)
  s[0 ..< 6] & "-" & s[6 ..< 10] & "-" & s[10 ..< 14] & "-" & s[14 ..< 20]

template hashFmt*(s: string): string =
  s.toHex().toLowerAscii()

when hostOs == "macosx":
  {.emit: """
#include <unistd.h>
#include <libproc.h>

   char *c_get_app_fname(char *buf) {
     proc_pidpath(getpid(), buf, PROC_PIDPATHINFO_MAXSIZE); // 4096
     return buf;
   }
   """.}

  proc cGetAppFilename(x: cstring): cstring {.importc: "c_get_app_fname".}

  proc betterGetAppFileName(): string =
    var x: array[4096, byte]

    return $(cGetAppFilename(cast[cstring](addr x[0])))

elif hostOs == "linux":
  {.emit: """
#include <unistd.h>

   char *c_get_app_fname(char *buf) {
   char proc_path[128];
   snprintf(proc_path, 128, "/proc/%d/exe", getpid());
   readlink(proc_path, buf, 4096);
   return buf;
   }
   """.}

  proc cGetAppFilename(x: cstring): cstring {.importc: "c_get_app_fname".}

  proc betterGetAppFileName(): string =
    var x: array[4096, byte]

    return $(cGetAppFilename(cast[cstring](addr x[0])))
else:
  template betterGetAppFileName(): string = getAppFileName()


template getMyAppPath*(): string =


  when hostOs == "macosx":
    if chalkConfig == nil:
      betterGetAppFileName()
    else:
      chalkConfig.getSelfLocation().getOrElse(betterGetAppFileName())
  else:
    betterGetAppFileName()
