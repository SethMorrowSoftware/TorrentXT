script "torrentTestClient"

-- torrent-test-client.livecodescript - a SELF-BUILDING TorrentXT test client.
--
-- HOW TO USE:
--   1. Open the LiveCode/OXT IDE, make a new stack with one card.
--   2. Paste THIS ENTIRE script into the STACK script (Object > Stack Script).
--   3. Re-open the card (navigate away and back, or close/reopen the stack).
--      The script builds its own UI the first time the card opens and starts a
--      TorrentXT session automatically.
--   4. Paste a magnet URI into the top field, set a save folder, click "Add".
--
-- It is fully self-contained: the poll dispatcher, the event handling, the
-- dashboard and the UI are all inlined here, so you do NOT need the separate
-- torrent-helpers script. It calls only the public bt* API from the loaded
-- org.openxtalk.library.torrent library.
--
-- If the session fails to start, the log tells you the native library is
-- missing: build torrentxt.dll and place it with
--   python3 tools/package-extension.py --platform-id x86_64-win32 --lib <path>
-- (see docs/building.md), or install the packaged extension.

-- ---- stack-local state (the whole stack shares these) -----------------------
local sSession        -- the live session handle (0/empty = none)
local sActiveTorrent  -- the torrent we track in the dashboard
local sPolling        -- "true" while the drain timer loop is armed

-- ---- entry point: build + start when the card (re)opens --------------------
on openCard
   ttInit
   pass openCard
end openCard

on closeStack
   ttShutdown
   pass closeStack
end closeStack

command ttInit
   ttBuildUI
   ttEnsureSession
end ttInit

-- ---- self-building UI -------------------------------------------------------
-- Creates the controls the first time only (idempotent: re-opening the card
-- does not duplicate them).
command ttBuildUI
   if there is a field "ttLog" then
      exit ttBuildUI
   end if
   lock screen
   ttMakeField "ttMagnet", "20,40,600,66", false
   ttMakeField "ttSavePath", "20,74,600,100", false
   ttMakeButton "ttAdd", "Add Magnet", "20,110,140,142"
   ttMakeButton "ttStart", "Start", "150,110,250,142"
   ttMakeButton "ttStop", "Stop", "260,110,360,142"
   ttMakeButton "ttPause", "Pause", "370,110,470,142"
   ttMakeButton "ttResume", "Resume", "480,110,600,142"
   ttMakeField "ttStatus", "20,152,600,178", true
   ttMakeField "ttLog", "20,188,600,470", true
   set the vScrollbar of field "ttLog" to true
   put empty into field "ttMagnet"
   put ttDefaultSavePath() into field "ttSavePath"
   put empty into field "ttStatus"
   put empty into field "ttLog"
   unlock screen
   ttLogMsg "TorrentXT test client built. Paste a magnet above, set a save folder, click Add."
end ttBuildUI

command ttMakeField pName, pRect, pLocked
   if there is no field pName then
      create field pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end ttMakeField

command ttMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end ttMakeButton

function ttDefaultSavePath
   local tBase
   put specialFolderPath("desktop") into tBase
   if tBase is empty then
      put specialFolderPath("documents") into tBase
   end if
   return tBase & "/torrentxt-downloads"
end ttDefaultSavePath

-- ---- button routing ---------------------------------------------------------
on mouseUp
   switch the short name of the target
      case "ttAdd"
         ttAddMagnet
         break
      case "ttStart"
         ttEnsureSession
         break
      case "ttStop"
         ttShutdown
         ttLogMsg "Session stopped."
         break
      case "ttPause"
         if sActiveTorrent is not empty then
            btPause sActiveTorrent
            ttLogMsg "Paused."
         end if
         break
      case "ttResume"
         if sActiveTorrent is not empty then
            btResume sActiveTorrent
            ttLogMsg "Resumed."
         end if
         break
   end switch
end mouseUp

-- ---- session lifecycle ------------------------------------------------------
command ttEnsureSession
   local tErr
   if sSession is not empty and sSession is not 0 then
      exit ttEnsureSession
   end if
   try
      btStartSession
      put the result into sSession
   catch tErr
      ttLogMsg "Could not start TorrentXT:" && tErr
      ttLogMsg "The native library is missing. Place torrentxt.dll in src/code/x86_64-win32/ (see docs/building.md)."
      put 0 into sSession
      exit ttEnsureSession
   end try
   if sSession is 0 or sSession is empty then
      ttLogMsg "btStartSession returned 0:" && btLastError()
      put 0 into sSession
      exit ttEnsureSession
   end if
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   ttLogMsg "Session started (handle" && sSession & "). DHT/LSD on."
   put "true" into sPolling
   send "ttPollOnce" to me in 0 milliseconds
   send "ttRefreshDashboard" to me in 500 milliseconds
end ttEnsureSession

command ttShutdown
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   put empty into sActiveTorrent
end ttShutdown

-- ---- add a magnet -----------------------------------------------------------
command ttAddMagnet
   local tMagnet, tPath, tHandle
   if sSession is 0 or sSession is empty then
      ttLogMsg "No session - click Start first."
      exit ttAddMagnet
   end if
   put field "ttMagnet" into tMagnet
   put field "ttSavePath" into tPath
   if tMagnet is empty then
      ttLogMsg "Paste a magnet URI into the top field first."
      exit ttAddMagnet
   end if
   btAddMagnet sSession, tMagnet, tPath
   put the result into tHandle
   if tHandle is 0 then
      ttLogMsg "Add failed:" && btLastError()
   else
      put tHandle into sActiveTorrent
      ttLogMsg "Added torrent (handle" && tHandle & "). Fetching metadata..."
   end if
end ttAddMagnet

-- ---- the poll dispatcher (inlined; one FFI round-trip per drain) ------------
command ttPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit ttPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit ttPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      ttHandleEvent tEvent
   end repeat
   send "ttPollOnce" to me in 250 milliseconds
end ttPollOnce

command ttHandleEvent pEvent
   switch pEvent["name"]
      case "torrentAdded"
         ttLogMsg "added:" && pEvent["torrent"]
         break
      case "metadataReceived"
         ttLogMsg "metadata:" && pEvent["torrentName"]
         break
      case "pieceFinished"
         -- too frequent to log each piece; the dashboard shows progress
         break
      case "torrentFinished"
         ttLogMsg "FINISHED torrent" && pEvent["torrent"]
         break
      case "torrentError"
         ttLogMsg "torrent error:" && pEvent["errorMessage"]
         break
      case "stateChanged"
         ttLogMsg "state ->" && ttStateName(pEvent["state"])
         break
      case "trackerReply"
         ttLogMsg "tracker" && pEvent["tracker"] && "- peers" && pEvent["numPeers"]
         break
      case "resumeDataReady"
         ttLogMsg "resume data ready (" & the number of bytes in pEvent["resumeData"] & " bytes)"
         break
      default
         ttLogMsg "event:" && pEvent["name"]
         break
   end switch
end ttHandleEvent

-- ---- low-rate dashboard (the cheap way to show progress) -------------------
command ttRefreshDashboard
   local tS, tPct, tLine
   if sSession is 0 or sSession is empty then
      exit ttRefreshDashboard
   end if
   if sActiveTorrent is not empty then
      put btTorrentStatus(sActiveTorrent) into tS
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      put tS["name"] & " - " & ttStateName(tS["state"]) & " - " & tPct & "%" into tLine
      put tLine & " - down " & ttFmtBytes(tS["downloadRate"]) & "/s - up " & \
         ttFmtBytes(tS["uploadRate"]) & "/s - peers " & tS["numPeers"] into field "ttStatus"
   end if
   send "ttRefreshDashboard" to me in 500 milliseconds
end ttRefreshDashboard

-- ---- small helpers ----------------------------------------------------------
command ttLogMsg pMsg
   if there is no field "ttLog" then
      exit ttLogMsg
   end if
   put the time & " - " & pMsg & return after field "ttLog"
   set the vScroll of field "ttLog" to the formattedHeight of field "ttLog"
end ttLogMsg

function ttStateName pState
   switch pState
      case 1
         return "checking"
      case 2
         return "fetching metadata"
      case 3
         return "downloading"
      case 4
         return "finished"
      case 5
         return "seeding"
      case 7
         return "checking resume"
      default
         return "queued"
   end switch
end ttStateName

function ttFmtBytes pBytes
   local tUnits, tVal, tI
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB,TiB" into tUnits
   put pBytes into tVal
   put 1 into tI
   set the itemDelimiter to comma
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   return (the round of (tVal * 10) / 10) && (item tI of tUnits)
end ttFmtBytes
