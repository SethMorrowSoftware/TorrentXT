script "torrentClient"

-- torrent-client.livecodescript - a self-building, MULTI-TORRENT TorrentXT client
-- demo. Add magnets / .torrent files / URLs / info-hashes, create + seed a
-- folder, and manage several torrents at once from a live table.
--
-- HOW TO USE: open OXT, make a stack with one card, paste THIS into the STACK
-- script (Object > Stack Script), then close+reopen the stack. It builds its own
-- UI and starts a TorrentXT session automatically. Needs only the loaded
-- org.openxtalk.library.torrent library - no helper stack, no manual UI.
--
-- Features: smart Add (magnet / http(s) .torrent / local .torrent / 40-hex
-- info-hash) with DUPLICATE DETECTION; per-torrent Pause/Resume/Recheck/
-- Reannounce/Remove(+Data), Open Folder, Copy Magnet, Save Resume; session
-- Pause All / Resume All; a global upload cap; a live table; a detail line
-- (info-hash, save path, ETA, seeds); session totals incl. DHT nodes; an
-- event log.
--
-- Design (single-thread playbook): one 250 ms poll loop drains events with a
-- single btPoll; one 800 ms refresh enumerates the torrents and repaints. The
-- refresh is split into tcRefreshOnce (repaint) + tcRefreshLoop (repaint then
-- reschedule) so calling it from an event NEVER spawns a second timer chain.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sLineHandles      -- array: table line number -> torrent handle (per refresh)
local sPolling          -- "true" while the loops are armed

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
      case "tcOpenFolder"
         tcOpenFolder
         break
      case "tcCopyMagnet"
         tcCopyMagnet
         break
      case "tcSaveResume"
         tcSaveResume
         break
      case "tcPauseAll"
         tcAllTorrents "pause"
         break
      case "tcResumeAll"
         tcAllTorrents "resume"
         break
      case "tcApplyLimit"
         tcApplyUpLimit
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- double-click a row opens that torrent's download folder
on mouseDoubleUp
   if the short name of the target is "tcTorrents" then
      tcOpenFolder
   else
      pass mouseDoubleUp
   end if
end mouseDoubleUp

-- ---- self-building UI (idempotent: re-opening does not duplicate) ------------
command tcBuildUI
   if there is a field "tcTorrents" then
      exit tcBuildUI
   end if
   lock screen
   set the width of this stack to 860
   set the height of this stack to 712
   tcMakeLabel "tcTitle", "TorrentXT Client - multi-torrent demo", "16,8,600,30", 16
   -- add row
   tcMakeField "tcInput", "16,38,560,64", false
   tcMakeButton "tcAdd", "Add", "568,38,650,64"
   tcMakeButton "tcAddFile", "Open .torrent", "658,38,844,64"
   -- save + seed row
   tcMakeLabel "tcSaveLabel", "Save to:", "16,72,66,92", 11
   tcMakeField "tcSavePath", "70,70,560,94", false
   tcMakeButton "tcSeed", "Create + Seed Folder", "568,70,844,94"
   -- table header + selectable list (double-click a row to open its folder)
   tcMakeLabel "tcHeader", \
      "#" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Down" & tab & "Up" & tab & "Peers" & tab & "Size", \
      "16,102,844,120", 10
   tcMakeList "tcTorrents", "16,122,844,358", false
   set the tabStops of field "tcHeader" to "26,250,350,510,590,670,720"
   set the tabStops of field "tcTorrents" to "26,250,350,510,590,670,720"
   -- a fixed-width font lets the inline progress bars and the right-hand byte
   -- columns line up cleanly; OXT falls back gracefully if Courier is absent.
   set the textFont of field "tcHeader" to "Courier"
   set the textFont of field "tcTorrents" to "Courier"
   set the textSize of field "tcHeader" to 11
   set the textSize of field "tcTorrents" to 11
   -- a pale selection color keeps the state-colored row text legible when a row
   -- is hilited; the default system hilite is too dark for the colored text.
   set the hiliteColor of field "tcTorrents" to "200,221,242"
   -- per-torrent controls (row 1)
   tcMakeButton "tcPause", "Pause", "16,364,104,390"
   tcMakeButton "tcResume", "Resume", "108,364,196,390"
   tcMakeButton "tcRecheck", "Recheck", "200,364,288,390"
   tcMakeButton "tcReannounce", "Reannounce", "292,364,402,390"
   tcMakeButton "tcRemove", "Remove", "406,364,494,390"
   tcMakeButton "tcRemoveData", "Remove + Data", "498,364,620,390"
   -- per-torrent + session controls (row 2)
   tcMakeButton "tcOpenFolder", "Open Folder", "16,396,120,422"
   tcMakeButton "tcCopyMagnet", "Copy Magnet", "124,396,228,422"
   tcMakeButton "tcSaveResume", "Save Resume", "232,396,336,422"
   tcMakeButton "tcPauseAll", "Pause All", "360,396,448,422"
   tcMakeButton "tcResumeAll", "Resume All", "452,396,540,422"
   -- settings: a global upload cap (handy when seeding)
   tcMakeLabel "tcLimitLabel", "Up KB/s (0=off):", "560,400,672,420", 11
   tcMakeField "tcUpLimit", "676,398,740,422", false
   tcMakeButton "tcApplyLimit", "Apply", "748,398,820,422"
   -- detail line for the selected torrent, then session totals
   tcMakeLabel "tcDetail", "Select a torrent to see its details.", "16,430,844,450", 10
   tcMakeLabel "tcTotals", "", "16,454,844,474", 11
   -- event log
   tcMakeList "tcLog", "16,480,844,702", true
   -- defaults
   put tcDefaultSavePath() into field "tcSavePath"
   put empty into field "tcInput"
   put "0" into field "tcUpLimit"
   unlock screen
   tcLogMsg "Client built. Add takes a magnet, a .torrent path, an http(s) .torrent URL, or a 40-hex info-hash."
   tcLogMsg "Duplicates are detected. Double-click a row to open its folder. Create + Seed a folder to seed."
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
   -- seed the DHT with well-known routers so it bootstraps reliably on first run
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   tcLogMsg "Session ready (handle" && sSession & "). DHT/LSD on, routers seeded."
   put "true" into sPolling
   send "tcPollOnce" to me in 0 milliseconds
   send "tcRefreshLoop" to me in 600 milliseconds
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

-- ---- add (smart input + duplicate detection) ---------------------------------
-- The one Add field accepts whatever you paste: a magnet: link, an http(s) URL
-- to a .torrent, a local .torrent file path, or a bare 40-char info-hash. We
-- sniff it, refuse a duplicate (same info-hash already in the session), and
-- otherwise route to btAddMagnet / btAddTorrentFile.
command tcAddInput
   local tInput, tData, tHash, tDup
   if not tcHaveSession() then
      exit tcAddInput
   end if
   put tcTrim(field "tcInput") into tInput
   if tInput is empty then
      tcLogMsg "Paste a magnet, a .torrent path, an http(s) .torrent URL, or an info-hash."
      exit tcAddInput
   end if
   if tInput begins with "magnet:" then
      put tcDupCheck(tcMagnetHash(tInput)) into tDup
      if tDup is 0 then
         tcReportAdd btAddMagnet(sSession, tInput, field "tcSavePath"), "magnet"
      end if
   else if tInput begins with "http://" or tInput begins with "https://" then
      tcLogMsg "Downloading .torrent from" && tInput && "..."
      put url tInput into tData
      if the result is not empty then
         tcLogMsg "Download failed:" && the result
      else if tData is empty then
         tcLogMsg "Download returned no data from" && tInput
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
      put tcDupCheck(toLower(tInput)) into tDup
      if tDup is 0 then
         tcReportAdd btAddMagnet(sSession, ("magnet:?xt=urn:btih:" & tInput), field "tcSavePath"), "info-hash"
      end if
   else
      tcLogMsg "Unrecognized input - use a magnet:, an http(s) .torrent URL, a .torrent file path, or a 40-char info-hash."
   end if
end tcAddInput

command tcAddTorrentFile
   local tFile, tData
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
   else
      tcReportAdd btAddTorrentFile(sSession, tData, field "tcSavePath"), ".torrent file"
   end if
end tcAddTorrentFile

-- Build a .torrent from a folder, then add it pointing at that folder's PARENT
-- so libtorrent rechecks the existing files, finds them complete, and seeds.
command tcCreateAndSeed
   local tPath, tData, tParent, tTrackers
   if not tcHaveSession() then
      exit tcCreateAndSeed
   end if
   answer folder "Choose a folder to create a torrent from and seed:"
   put it into tPath
   if tPath is empty then
      exit tcCreateAndSeed
   end if
   -- optional announce URLs (one per line). Blank = trackerless, DHT-only
   -- seeding, which works because this client runs the DHT; a tracker just
   -- adds another way for peers to find the swarm.
   ask "Tracker announce URLs to embed (one per line; blank = DHT-only):" \
      with "udp://tracker.opentrackr.org:1337/announce"
   put it into tTrackers
   tcLogMsg "Creating torrent for" && tPath && "..."
   put btCreateTorrent(tPath, 0, 0, tTrackers) into tData
   if tData is empty then
      tcLogMsg "Create failed:" && btLastError()
      exit tcCreateAndSeed
   end if
   -- compute the folder's PARENT, separator-agnostically: answer folder returns
   -- back-slash paths on Windows, where splitting on "/" alone would leave tPath
   -- unchanged and break the save-path -> existing-files mapping (seeding fails).
   replace "\" with "/" in tPath
   if the last char of tPath is "/" then
      delete the last char of tPath
   end if
   set the itemDelimiter to "/"
   put item 1 to -2 of tPath into tParent
   if tParent is empty then
      put "/" into tParent
   end if
   tcReportAdd btAddTorrentFile(sSession, tData, tParent), "seed of" && tPath
end tcCreateAndSeed

-- Look for an existing torrent with this (v1, hex) info-hash. If found, select it
-- and return its handle; else return 0. "" hash -> 0 (cannot pre-check).
function tcDupCheck pHash
   local tH
   put tcFindByHash(pHash) into tH
   if tH is not 0 then
      tcLogMsg "Already in the list (handle" && tH & ") - selecting it."
      tcSelectHandle tH
      put empty into field "tcInput"
   end if
   return tH
end tcDupCheck

function tcFindByHash pHash
   local tCount, tI, tH
   if pHash is empty then
      return 0
   end if
   put btTorrentCount(sSession) into tCount
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is not 0 and toLower(btInfoHash(tH)) is toLower(pHash) then
         return tH
      end if
   end repeat
   return 0
end tcFindByHash

-- Extract the btih info-hash from a magnet URI ("" if absent / non-btih).
function tcMagnetHash pMagnet
   local tOff, tRest
   put offset("urn:btih:", pMagnet) into tOff
   if tOff is 0 then
      return ""
   end if
   put char (tOff + 9) to -1 of pMagnet into tRest   -- after "urn:btih:"
   put offset("&", tRest) into tOff
   if tOff > 0 then
      put char 1 to (tOff - 1) of tRest into tRest
   end if
   return toLower(tRest)
end tcMagnetHash

-- Shared reporting for every add path: log + clear the field + repaint on success.
command tcReportAdd pHandle, pKind
   if pHandle is 0 then
      tcLogMsg "Add failed (" & pKind & "):" && btLastError()
   else
      tcLogMsg "Added" && pKind && "(handle" && pHandle & ")."
      put empty into field "tcInput"
      tcRefreshOnce
   end if
end tcReportAdd

-- ---- per-torrent control (on the selected table row) -------------------------
command tcControlSelected pAction
   local tH, tLine, tLeft
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent in the table first."
      exit tcControlSelected
   end if
   put item 1 of (the hilitedLines of field "tcTorrents") into tLine
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
         answer "Delete the downloaded files for torrent" && tH & "?" with "Cancel" or "Delete"
         if it is not "Delete" then
            exit tcControlSelected
         end if
         btRemoveTorrent sSession, tH, true
         tcLogMsg "Removed torrent" && tH && "AND deleted its files"
         break
   end switch
   tcRefreshOnce
   -- after a removal the row indices shift; keep a neighbouring row selected so
   -- the per-torrent buttons stay live and the user keeps their place.
   if pAction is "remove" or pAction is "removeData" then
      put the number of lines of field "tcTorrents" into tLeft
      if tLeft > 0 then
         if tLine is not a number then
            put 1 into tLine
         end if
         if tLine > tLeft then
            put tLeft into tLine
         end if
         if tLine < 1 then
            put 1 into tLine
         end if
         set the hilitedLines of field "tcTorrents" to tLine
         tcEnableControls true
         tcUpdateDetail tcSelectedHandle()
      end if
   end if
end tcControlSelected

-- Pause or resume every torrent in the session.
command tcAllTorrents pAction
   local tCount, tI, tH
   if not tcHaveSession() then
      exit tcAllTorrents
   end if
   put btTorrentCount(sSession) into tCount
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is not 0 then
         if pAction is "pause" then
            btPause tH
         else
            btResume tH
         end if
      end if
   end repeat
   tcLogMsg (pAction & "d") && "all" && tCount && "torrents."
   tcRefreshOnce
end tcAllTorrents

-- Open the selected torrent's download folder in the OS file manager.
command tcOpenFolder
   local tH, tS, tPath
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcOpenFolder
   end if
   put btTorrentStatus(tH) into tS
   put tS["savePath"] into tPath
   if tPath is empty then
      tcLogMsg "No save path for that torrent yet."
      exit tcOpenFolder
   end if
   launch document tPath
   tcLogMsg "Opening folder" && tPath
end tcOpenFolder

-- Copy a magnet link for the selected torrent (built from its info-hash) to the
-- clipboard - handy to share or re-add.
command tcCopyMagnet
   local tH, tHash, tS, tName, tMag
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcCopyMagnet
   end if
   put btInfoHash(tH) into tHash
   if tHash is empty then
      tcLogMsg "No info-hash yet (metadata still pending)."
      exit tcCopyMagnet
   end if
   put "magnet:?xt=urn:btih:" & tHash into tMag
   put btTorrentStatus(tH) into tS
   put tS["name"] into tName
   if tName is not empty then
      put tMag & "&dn=" & urlEncode(tName) into tMag
   end if
   set the clipboardData["text"] to tMag
   tcLogMsg "Copied magnet to clipboard:" && tMag
end tcCopyMagnet

-- Ask libtorrent to flush resume data for the selected torrent; it arrives
-- asynchronously as a resumeDataReady event (logged below).
command tcSaveResume
   local tH
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcSaveResume
   end if
   btSaveResumeData tH
   tcLogMsg "Requested resume data for torrent" && tH && "(arrives as a resumeDataReady event)."
end tcSaveResume

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

-- Select the table row that maps to pHandle (after a refresh rebuilds the map).
command tcSelectHandle pHandle
   local tKey, tFound
   tcRefreshOnce
   put 0 into tFound
   repeat for each key tKey in sLineHandles
      if sLineHandles[tKey] is pHandle then
         put tKey into tFound
         exit repeat
      end if
   end repeat
   if tFound > 0 then
      set the hilitedLines of field "tcTorrents" to tFound
   end if
end tcSelectHandle

command tcApplyUpLimit
   local tKB
   if not tcHaveSession() then
      exit tcApplyUpLimit
   end if
   put tcTrim(field "tcUpLimit") into tKB
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
         tcRefreshOnce
         break
      case "metadataReceived"
         -- the event now carries the resolved name directly (F_EVT_NAME); fall
         -- back to a status lookup if an older native lib leaves it empty.
         if pEvent["torrentName"] is not empty then
            tcLogMsg "  metadata received:" && pEvent["torrentName"]
         else
            tcLogMsg "  metadata received:" && tcTorrentName(pEvent["torrent"])
         end if
         tcRefreshOnce
         break
      case "torrentFinished"
         tcLogMsg "* FINISHED:" && tcTorrentName(pEvent["torrent"]) && "- now seeding"
         tcRefreshOnce
         break
      case "torrentError"
         tcLogMsg "! error:" && pEvent["errorMessage"]
         break
      case "trackerReply"
         tcLogMsg "  tracker" && pEvent["tracker"] && "- peers" && pEvent["numPeers"]
         break
      case "resumeDataReady"
         tcLogMsg "  resume data ready for torrent" && pEvent["torrent"] && \
            "(" & (the number of bytes in pEvent["resumeData"]) && "bytes)"
         break
      case "dhtBootstrap"
         tcLogMsg "  DHT bootstrapped."
         break
      default
         -- stateChanged / pieceFinished etc. are reflected in the table, not logged
         break
   end switch
end tcHandleEvent

-- ---- the low-rate dashboard --------------------------------------------------
-- tcRefreshLoop reschedules itself; tcRefreshOnce just repaints. Direct callers
-- (adds, controls, events) use tcRefreshOnce so they never start a 2nd timer.
command tcRefreshLoop
   if sPolling is not "true" then
      exit tcRefreshLoop
   end if
   tcRefreshOnce
   send "tcRefreshLoop" to me in 800 milliseconds
end tcRefreshLoop

command tcRefreshOnce
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tSelH, tSelLine, tNewMap, tLineNum, tNodes, tDht
   local tColors, tErr
   if sSession is 0 or sSession is empty then
      exit tcRefreshOnce
   end if
   -- collapse the whole rebuild (text + per-line colors + hilite + totals) into
   -- a single repaint; without this the list visibly flickers on every poll.
   lock screen
   put tcSelectedHandle() into tSelH      -- remember the selection across the rebuild
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put empty into tNewMap
   put 0 into tLineNum
   put empty into tSelLine
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put tH into tNewMap[tLineNum]
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      put tcStateColor(tS["state"], tS["error"]) into tColors[tLineNum]
      put tLineNum & tab & tcTrunc(tS["name"], 28) & tab & tcStateName(tS["state"]) & tab & \
          tcProgressBar(tPct) & tab & (tcFmtBytes(tS["downloadRate"]) & "/s") & tab & \
          (tcFmtBytes(tS["uploadRate"]) & "/s") & tab & \
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
   -- color each row by state (green=seeding/done, blue=downloading,
   -- amber=checking, gray=paused/queued, red=error). Wrapped so a platform that
   -- dislikes per-line coloring still shows the table, just monochrome.
   try
      repeat with tI = 1 to tLineNum
         set the foregroundColor of line tI of field "tcTorrents" to tColors[tI]
      end repeat
   catch tErr
   end try
   -- per-torrent buttons are usable only when a row is selected
   tcEnableControls (tSelLine is not empty)
   -- DHT status: show the real routing-table node count from the shim's
   -- session_stats. This client always enables DHT at startup, so a 0 count just
   -- means it is still bootstrapping into the swarm (the count climbs within a
   -- few seconds of the first add).
   put btDhtState(sSession) into tS
   put tS["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("DHT:" && tNodes && "nodes") into tDht
   else
      put "DHT: on" into tDht
   end if
   put tLineNum && "torrents     down" && tcFmtBytes(tDown) & "/s     up" && tcFmtBytes(tUp) & "/s" \
      && "    " & tDht into field "tcTotals"
   tcUpdateDetail tSelH
   unlock screen
end tcRefreshOnce

-- A one-line detail readout for the selected torrent: info-hash, save path, ETA,
-- seeds. Shows off the richer btTorrentStatus / btInfoHash fields.
command tcUpdateDetail pHandle
   local tS, tLine
   if pHandle is 0 then
      put "Select a torrent to see its details." into field "tcDetail"
      exit tcUpdateDetail
   end if
   put btTorrentStatus(pHandle) into tS
   put "hash:" && tcShortHash(btInfoHash(pHandle)) && "|  save:" && tS["savePath"] \
      && "|  ETA:" && tcFmtEta(tS["eta"]) && "|  seeds:" && tS["numSeeds"] \
      && "|  done:" && tcFmtBytes(tS["totalDone"]) into tLine
   if tS["error"] is not empty then
      put tLine && "|  ERROR:" && tS["error"] into tLine
   end if
   put tLine into field "tcDetail"
end tcUpdateDetail

-- Resolve a torrent's display name (falls back to "torrent N" before metadata).
function tcTorrentName pHandle
   local tS
   if pHandle is 0 or pHandle is empty then
      return "?"
   end if
   put btTorrentStatus(pHandle) into tS
   if tS["name"] is empty then
      return ("torrent" && pHandle)
   end if
   return tS["name"]
end tcTorrentName

-- Enable/disable the nine per-torrent control buttons in one pass.
command tcEnableControls pOn
   local tBtn
   set the itemDelimiter to comma
   repeat for each item tBtn in "tcPause,tcResume,tcRecheck,tcReannounce,tcRemove,tcRemoveData,tcOpenFolder,tcCopyMagnet,tcSaveResume"
      set the disabled of button tBtn to (not pOn)
   end repeat
end tcEnableControls

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

-- A compact 10-segment ASCII progress bar, e.g. [#######---] 72.5%. Fixed width
-- so it lines up in the monospaced table; trunc (not round) of the tenths keeps
-- the bar from reading "full" until a torrent is genuinely at 100%.
function tcProgressBar pPct
   local tFilled
   put trunc(pPct / 10) into tFilled
   if tFilled < 0 then
      put 0 into tFilled
   end if
   if tFilled > 10 then
      put 10 into tFilled
   end if
   return "[" & (char 1 to tFilled of "##########") & \
      (char 1 to (10 - tFilled) of "----------") & "]" && pPct & "%"
end tcProgressBar

-- Row text color by torrent state (the numeric state from the status record),
-- with any error overriding everything to red. Mirrors tcStateName's numbering.
function tcStateColor pState, pError
   if pError is not empty then
      return "200,40,40"
   end if
   switch pState
      case 4
      case 5
         return "0,140,70"
      case 3
         return "30,90,200"
      case 1
      case 2
      case 7
         return "190,130,0"
      default
         return "110,110,110"
   end switch
end tcStateColor

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

function tcFmtEta pSecs
   local tMin, tHrs
   if pSecs is empty or pSecs is not a number or pSecs <= 0 then
      return "-"
   end if
   if pSecs < 60 then
      return pSecs & "s"
   end if
   put trunc(pSecs / 60) into tMin
   if tMin < 60 then
      return tMin & "m"
   end if
   put trunc(tMin / 60) into tHrs
   return tHrs & "h" && (tMin mod 60) & "m"
end tcFmtEta

function tcShortHash pHash
   if pHash is empty then
      return "(pending)"
   end if
   if the number of chars of pHash > 14 then
      return (char 1 to 10 of pHash) & "..." & (char -4 to -1 of pHash)
   end if
   return pHash
end tcShortHash

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
   -- keep the log bounded so a long-running session never bloats the field;
   -- rebuilding a huge field on every append is the kind of O(N) interpreter
   -- cost the performance playbook warns about.
   if the number of lines of field "tcLog" > 250 then
      delete line 1 to (the number of lines of field "tcLog" - 250) of field "tcLog"
   end if
   set the vScroll of field "tcLog" to the formattedHeight of field "tcLog"
end tcLogMsg
