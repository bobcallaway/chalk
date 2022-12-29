import types
import config
import plugins
import resources
import io/tojson
import output

import os
import strutils
import options
import strformat
import streams
import nativesockets

proc doExtraction*(onBehalfOfInjection: bool) =
  # This function will extract SAMIs, leaving them in SAMI
  # objects inside the codecs.  That way, the inject command
  # can reuse this code.
  #
  # TODO: need to validate extracted SAMIs.
  # Also TODO, we will be adding output plugins very soon.
  var
    exclusions: seq[string]
    codecInfo: seq[Codec]
    ctx: FileStream
    path: string
    filePath: string
    numExtractions = 0

  var artifactPath = getArtifactSearchPath()

  for (_, name, plugin) in getCodecsByPriority():
    let codec = cast[Codec](plugin)
    trace(fmt"Asking codec '{name}' to scan for SAMIs.")
    codec.doScan(artifactPath, exclusions, getRecursive())
    codecInfo.add(codec)

  trace("Beginning extraction attempts for any found SAMIs")

  try:
    for codec in codecInfo:
      for sami in codec.samis:
        var comma, primaryJson, embededJson: string

        if sami.samiIsEmpty():
          inform(fmtInfoNoExtract.fmt())
          continue
        if sami.samiHasExisting():
          let
            p = sami.primary
            s = p.samiFields.get()
          primaryJson = s.foundToJson()
          forceInform(fmtInfoYesExtract.fmt())
        else:
          inform(fmtInfoNoPrimary.fmt())

        for (key, pt) in sami.embeds:
          let
            embstore = pt.samiFields.get()
            keyJson = strValToJson(key)
            valJson = embstore.foundToJson()

          if not onBehalfOfInjection and not getDryRun():
            embededJson = embededJson & kvPairJFmt.fmt()
            comma = comfyItemSep

        embededJson = jsonArrFmt % [embededJson]

        numExtractions += 1

        if not getDryRun():
          let absPath = absolutePath(sami.fullpath)
          handleOutput(logTemplate % [absPath, getHostName(),
                                    primaryJson, embededJson],
                       if onBehalfOfInjection: OutCtxInjectPrev
                       else: OutCtxExtract)
  except:
    # TODO: do better here.
    # echo getStackTrace()
    # raise
    warn(getCurrentExceptionMsg() &
         " (likely a bad SAMI embed; ignored)")
  finally:
    trace(fmt"Completed {numExtractions} extractions.")
    if ctx != nil:
      ctx.close()
      try:
        moveFile(path, filepath)
      except:
        removeFile(path)
        raise

