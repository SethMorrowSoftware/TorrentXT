script "torrentClient"

-- torrent-client.livecodescript - a self-building, MULTI-TORRENT TorrentXT client
-- demo. Add magnets / .torrent files, create + seed a folder, and manage several
-- torrents at once (pause / resume / recheck / reannounce / remove) from a live
-- table, with session totals and an event log.
--
-- HOW TO USE: open OXT, make a stack with one card, paste THIS into the STACK
-- script (Object > Stack Script), then close+reopen the stack. It builds its own
-- UI and starts a TorrentXT session automatically. It needs only the loaded
-- org.openxtalk.library.torrent library - no helper stack, no manual UI.
--
-- Design notes (mirrors the single-thread playbook):
--   * one poll loop (250 ms) drains events with a single btPoll round-trip;
--   * one low-rate table refresh (800 ms) enumerates the torrents and repaints;
--   * gigabytes stay engine<->disk - only small status records cross the FFI.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sLineHandles      -- array: table line number -> torrent handle (per refresh)
local sPolling          -- "true" while the drain loop is armed

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   tcBuildUI
   tcEnsureSession
end openStack

on closeStack
   tcShutdown
end closeStack

-- ---- button routing (every control lives in this one stack script) -----------
on mouseUp
   switch the short name of the target
      case "tcAdd"
         tcAddInput
         break
      case "tcAddFile"
         tcAddTorrentFile
         break
      case "tcSeed"
         tcCreateAndSeed
         break
      case "tcPause"
         tcControlSelected "pause"
         break
      case "tcResume"
         tcControlSelected "resume"
         break
      case "tcRecheck"
         tcControlSelected "recheck"
         break
      case "tcReannounce"
         tcControlSelected "reannounce"
         break
      case "tcRemove"
         tcControlSelected "remove"
         break
      case "tcRemoveData"
         tcControlSelected "removeData"
         break
      case "tcApplyLimit"
         tcApplyUpLimit
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- ---- self-building UI (idempotent: re-opening does not duplicate) ------------
command tcBuildUI
   if there is a field "tcTorrents" then
      exit tcBuildUI
   end if
   lock screen
   set the width of this stack to 820
   set the height of this stack to 620
   tcMakeLabel "tcTitle", "TorrentXT Client - multi-torrent demo", "16,8,560,30", 16
   -- add row: the input accepts a magnet:, an http(s) .torrent URL, a local
   -- .torrent file path, or a 40-char info-hash; "Open .torrent" browses for a file
   tcMakeField "tcInput", "16,40,556,66", false
   tcMakeButton "tcAdd", "Add", "564,40,652,66"
   tcMakeButton "tcAddFile", "Open .torrent", "660,40,804,66"
   -- save + seed row
   tcMakeLabel "tcSaveLabel", "Save to:", "16,74,66,94", 11
   tcMakeField "tcSavePath", "70,72,556,96", false
   tcMakeButton "tcSeed", "Create + Seed Folder", "564,72,804,96"
   -- table header + selectable list
   tcMakeLabel "tcHeader", \
      "#" & tab & "Name" & tab & "State" & tab & "%" & tab & "Down" & tab & "Up" & tab & "Peers" & tab & "Size", \
      "16,104,804,122", 10
   tcMakeList "tcTorrents", "16,124,804,386", false
   set the tabStops of field "tcHeader" to "26,250,360,410,490,560,620"
   set the tabStops of field "tcTorrents" to "26,250,360,410,490,560,620"
   -- per-torrent controls (act on the selected row)
   tcMakeButton "tcPause", "Pause", "16,392,104,418"
   tcMakeButton "tcResume", "Resume", "108,392,196,418"
   tcMakeButton "tcRecheck", "Recheck", "200,392,288,418"
   tcMakeButton "tcReannounce", "Reannounce", "292,392,402,418"
   tcMakeButton "tcRemove", "Remove", "406,392,494,418"
   tcMakeButton "tcRemoveData", "Remove + Data", "498,392,620,418"
   -- a small bit of "more control": a global upload cap (handy when seeding)
   tcMakeLabel "tcLimitLabel", "Up KB/s (0=off):", "16,426,128,446", 11
   tcMakeField "tcUpLimit", "132,424,196,448", false
   tcMakeButton "tcApplyLimit", "Apply", "204,424,276,448"
   tcMakeLabel "tcTotals", "", "300,426,804,446", 11
   -- event log
   tcMakeList "tcLog", "16,454,804,604", true
   -- defaults
   put tcDefaultSavePath() into field "tcSavePath"
   put empty into field "tcInput"
   put "0" into field "tcUpLimit"
   unlock screen
   tcLogMsg "Client built. Add accepts a magnet, a .torrent path, an http(s) .torrent URL, or an info-hash."
   tcLogMsg "Or click Open .torrent to browse, or Create + Seed a folder. Manage several at once in the table."
end tcBuildUI

command tcMakeLabel pName, pText, pRect, pSize
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the borderWidth of field pName to 0
   set the opaque of field pName to false
   set the textSize of field pName to pSize
   put pText into field pName
end tcMakeLabel

command tcMakeField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end tcMakeField

command tcMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end tcMakeButton

command tcMakeList pName, pRect, pIsLog
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
   if pIsLog then
      set the listBehavior of field pName to false
   else
      set the listBehavior of field pName to true
   end if
end tcMakeList

-- ---- session lifecycle (adopts a still-live session, like the demo) ----------
command tcEnsureSession
   local tErr, tRemembered
   if sSession is not empty and sSession is not 0 then
      exit tcEnsureSession
   end if
   put the uSession of this stack into tRemembered
   if tRemembered is a number and tRemembered > 0 \
         and btSetBool(tRemembered, "enable_dht", true) is 0 then
      put tRemembered into sSession
      tcLogMsg "Re-adopted the still-live session (handle" && sSession & ")."
   else
      try
         btStartSession
         put the result into sSession
      catch tErr
         tcLogMsg "Could not start TorrentXT:" && tErr
         put 0 into sSession
         exit tcEnsureSession
      end try
      if sSession is 0 or sSession is empty then
         tcLogMsg "btStartSession returned 0:" && btLastError()
         put 0 into sSession
         set the uSession of this stack to empty
         exit tcEnsureSession
      end if
      btSetBool sSession, "enable_dht", true
      set the uSession of this stack to sSession
   end if
   btSetBool sSession, "enable_lsd", true
   tcLogMsg "Session ready (handle" && sSession & "). DHT/LSD on."
   put "true" into sPolling
   send "tcPollOnce" to me in 0 milliseconds
   send "tcRefresh" to me in 600 milliseconds
end tcEnsureSession

command tcShutdown
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   set the uSession of this stack to empty
end tcShutdown

function tcHaveSession
   if sSession is 0 or sSession is empty then
      tcLogMsg "No session - reopen the stack to start one."
      return false
   end if
   return true
end tcHaveSession

-- ---- add / seed --------------------------------------------------------------
-- The one Add field accepts whatever you paste: a magnet: link, an http(s) URL to
-- a .torrent, a local .torrent file path, or a bare 40-char info-hash. We sniff
-- the input and route to btAddMagnet or btAddTorrentFile accordingly.
command tcAddInput
   local tInput, tData, tH
   if not tcHaveSession() then
      exit tcAddInput
   end if
   put tcTrim(field "tcInput") into tInput
   if tInput is empty then
      tcLogMsg "Paste a magnet, a .torrent path, an http(s) .torrent URL, or an info-hash."
      exit tcAddInput
   end if
   if tInput begins with "magnet:" then
      tcReportAdd btAddMagnet(sSession, tInput, field "tcSavePath"), "magnet"
   else if tInput begins with "http://" or tInput begins with "https://" then
      tcLogMsg "Downloading .torrent from" && tInput && "..."
      put url tInput into tData
      if the result is not empty or tData is empty then
         tcLogMsg "Download failed:" && the result
      else
         tcReportAdd btAddTorrentFile(sSession, tData, field "tcSavePath"), ".torrent (URL)"
      end if
   else if there is a file tInput then
      put url ("binfile:" & tInput) into tData
      if tData is empty then
         tcLogMsg "Could not read" && tInput
      else
         tcReportAdd btAddTorrentFile(sSession, tData, field "tcSavePath"), ".torrent file"
      end if
   else if matchText(tInput, "^[0-9A-Fa-f]{40}$") then
      tcReportAdd btAddMagnet(sSession, ("magnet:?xt=urn:btih:" & tInput), field "tcSavePath"), "info-hash"
   else
      tcLogMsg "Unrecognized input - use a magnet:, an http(s) .torrent URL, a .torrent file path, or a 40-char info-hash."
   end if
end tcAddInput

-- Shared reporting for every add path: log + clear the field + repaint on success.
command tcReportAdd pHandle, pKind
   if pHandle is 0 then
      tcLogMsg "Add failed (" & pKind & "):" && btLastError()
   else
      tcLogMsg "Added" && pKind && "(handle" && pHandle & ")."
      put empty into field "tcInput"
      tcRefresh
   end if
end tcReportAdd

command tcAddTorrentFile
   local tFile, tData, tH
   if not tcHaveSession() then
      exit tcAddTorrentFile
   end if
   answer file "Choose a .torrent file to add:"
   put it into tFile
   if tFile is empty then
      exit tcAddTorrentFile
   end if
   put url ("binfile:" & tFile) into tData
   if tData is empty then
      tcLogMsg "Could not read" && tFile
      exit tcAddTorrentFile
   end if
   put btAddTorrentFile(sSession, tData, field "tcSavePath") into tH
   if tH is 0 then
      tcLogMsg "Add failed:" && btLastError()
   else
      tcLogMsg "Added .torrent (handle" && tH & ")."
      tcRefresh
   end if
end tcAddTorrentFile

-- Build a .torrent from a folder, then add it pointing at that folder's PARENT so
-- libtorrent rechecks the existing files, finds them complete, and seeds.
command tcCreateAndSeed
   local tPath, tData, tParent, tH
   if not tcHaveSession() then
      exit tcCreateAndSeed
   end if
   answer folder "Choose a folder to create a torrent from and seed:"
   put it into tPath
   if tPath is empty then
      exit tcCreateAndSeed
   end if
   tcLogMsg "Creating torrent for" && tPath && "..."
   put btCreateTorrent(tPath, 0, 0) into tData
   if tData is empty then
      tcLogMsg "Create failed:" && btLastError()
      exit tcCreateAndSeed
   end if
   set the itemDelimiter to "/"
   put item 1 to -2 of tPath into tParent
   put btAddTorrentFile(sSession, tData, tParent) into tH
   if tH is 0 then
      tcLogMsg "Seed-add failed:" && btLastError()
   else
      tcLogMsg "Seeding" && tPath && "(handle" && tH & "). It rechecks the files, then seeds."
      tcRefresh
   end if
end tcCreateAndSeed

-- ---- per-torrent control (on the selected table row) -------------------------
command tcControlSelected pAction
   local tH
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent in the table first."
      exit tcControlSelected
   end if
   switch pAction
      case "pause"
         btPause tH
         tcLogMsg "Paused torrent" && tH
         break
      case "resume"
         btResume tH
         tcLogMsg "Resumed torrent" && tH
         break
      case "recheck"
         btForceRecheck tH
         tcLogMsg "Rechecking torrent" && tH
         break
      case "reannounce"
         btForceReannounce tH
         tcLogMsg "Reannounced torrent" && tH
         break
      case "remove"
         btRemoveTorrent sSession, tH, false
         tcLogMsg "Removed torrent" && tH && "(kept files)"
         break
      case "removeData"
         btRemoveTorrent sSession, tH, true
         tcLogMsg "Removed torrent" && tH && "AND deleted its files"
         break
   end switch
   tcRefresh
end tcControlSelected

function tcSelectedHandle
   local tNum
   put item 1 of (the hilitedLines of field "tcTorrents") into tNum
   if tNum is empty or tNum is not a number then
      return 0
   end if
   if sLineHandles[tNum] is empty then
      return 0
   end if
   return sLineHandles[tNum]
end tcSelectedHandle

command tcApplyUpLimit
   local tKB
   if not tcHaveSession() then
      exit tcApplyUpLimit
   end if
   put field "tcUpLimit" into tKB
   if tKB is empty or tKB is not a number then
      put 0 into tKB
   end if
   -- value crosses as a STRING (settings can be 64-bit); 0 == unlimited
   btSetInt sSession, "upload_rate_limit", (trunc(tKB * 1024) & "")
   tcLogMsg "Upload limit set to" && tKB && "KB/s"
end tcApplyUpLimit

-- ---- the poll loop (one FFI drain per pass) ----------------------------------
command tcPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit tcPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit tcPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      tcHandleEvent tEvent
   end repeat
   send "tcPollOnce" to me in 250 milliseconds
end tcPollOnce

command tcHandleEvent pEvent
   switch pEvent["name"]
      case "torrentAdded"
         tcLogMsg "+ added torrent" && pEvent["torrent"]
         tcRefresh
         break
      case "metadataReceived"
         tcLogMsg "  metadata:" && pEvent["torrentName"]
         tcRefresh
         break
      case "torrentFinished"
         tcLogMsg "* FINISHED torrent" && pEvent["torrent"] && "- now seeding"
         tcRefresh
         break
      case "torrentError"
         tcLogMsg "! error:" && pEvent["errorMessage"]
         break
      case "trackerReply"
         tcLogMsg "  tracker" && pEvent["tracker"] && "- peers" && pEvent["numPeers"]
         break
      default
         -- stateChanged / pieceFinished etc. are reflected in the table, not logged
         break
   end switch
end tcHandleEvent

-- ---- the low-rate dashboard: enumerate every torrent and repaint the table ---
command tcRefresh
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tSelH, tSelLine, tNewMap, tLineNum
   if sSession is 0 or sSession is empty then
      exit tcRefresh
   end if
   put tcSelectedHandle() into tSelH      -- remember the selection across the rebuild
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put empty into tNewMap
   put 0 into tLineNum
   put empty into tSelLine
   repeat with tI from 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put tH into tNewMap[tLineNum]
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      put tLineNum & tab & tcTrunc(tS["name"], 36) & tab & tcStateName(tS["state"]) & tab & \
          tPct & "%" & tab & tcFmtBytes(tS["downloadRate"]) & tab & tcFmtBytes(tS["uploadRate"]) & tab & \
          tS["numPeers"] & tab & tcFmtBytes(tS["totalSize"]) & return after tRows
      add tS["downloadRate"] to tDown
      add tS["uploadRate"] to tUp
      if tSelH is not 0 and tH is tSelH then
         put tLineNum into tSelLine
      end if
   end repeat
   put tNewMap into sLineHandles
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   set the text of field "tcTorrents" to tRows
   if tSelLine is not empty then
      set the hilitedLines of field "tcTorrents" to tSelLine
   end if
   put tLineNum && "torrents     down" && tcFmtBytes(tDown) & "/s     up" && tcFmtBytes(tUp) & "/s" \
      into field "tcTotals"
   send "tcRefresh" to me in 800 milliseconds
end tcRefresh

-- ---- small helpers -----------------------------------------------------------
function tcStateName pState
   switch pState
      case 1
         return "checking"
      case 2
         return "metadata"
      case 3
         return "downloading"
      case 4
         return "finished"
      case 5
         return "seeding"
      case 7
         return "check-resume"
      default
         return "queued"
   end switch
end tcStateName

function tcFmtBytes pBytes
   local tUnits, tVal, tI
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB,TiB" into tUnits
   set the itemDelimiter to comma
   put pBytes into tVal
   put 1 into tI
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   return (the round of (tVal * 10) / 10) && (item tI of tUnits)
end tcFmtBytes

function tcTrunc pText, pLen
   if the number of chars of pText <= pLen then
      return pText
   end if
   return (char 1 to (pLen - 1) of pText) & "..."
end tcTrunc

-- Strip leading/trailing whitespace (a paste often carries a trailing newline);
-- internal characters are preserved, so file paths with spaces survive.
function tcTrim pStr
   local tWS
   put space & tab & numToChar(10) & numToChar(13) into tWS
   repeat while pStr is not empty and (char 1 of pStr) is in tWS
      delete char 1 of pStr
   end repeat
   repeat while pStr is not empty and (the last char of pStr) is in tWS
      delete the last char of pStr
   end repeat
   return pStr
end tcTrim

function tcDefaultSavePath
   local tBase
   put specialFolderPath("desktop") into tBase
   if tBase is empty then
      put specialFolderPath("documents") into tBase
   end if
   return tBase & "/torrentxt-downloads"
end tcDefaultSavePath

command tcLogMsg pMsg
   if there is no field "tcLog" then
      exit tcLogMsg
   end if
   put the time & "  " & pMsg & return after field "tcLog"
   set the vScroll of field "tcLog" to the formattedHeight of field "tcLog"
end tcLogMsg
