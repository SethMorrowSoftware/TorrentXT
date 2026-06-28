script "quickShareApp"

-- torrent-quickshare.livecodescript - the SIMPLEST possible TorrentXT demo:
-- drag a file onto the window, get a short code, send the code to a friend;
-- they paste it in and the file transfers straight from your machine to theirs.
-- No server, no upload, no size limit - it is plain peer-to-peer BitTorrent with
-- the DHT finding the peers, wrapped in a one-card stack.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI and starts a
-- TorrentXT session. Needs only the loaded org.openxtalk.library.torrent.
--
-- THE DEMO (two machines, both running this stack):
--   1. On machine A, drag a file onto the drop area (or click it to choose one).
--      A 40-character SHARE CODE appears. Click Copy and send it to machine B.
--   2. On machine B, paste the code into "Receive a file" and click Download.
--   3. The file transfers A -> B while A keeps this window open. Watch the
--      Transfers list fill in on both ends.
-- The code is the torrent's content address (its info-hash): it both names the
-- file and lets the DHT introduce the two machines, so no tracker or server is
-- needed. Keep the sending window open until your friend has the whole file.
--
-- Single-thread playbook: a 250 ms poll drains events and a 1 s loop repaints the
-- Transfers list. The heavy bytes move on libtorrent's own threads, never script.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sPolling          -- "true" while the poll/repaint loops are armed
local sShareCode        -- the most recent file's share code (info-hash hex)

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   qsBuild
   qsStart
end openStack

on closeStack
   qsStop
end closeStack

-- ---- OS file drag-and-drop ---------------------------------------------------
-- These bubble up from whatever control is under the pointer to this stack
-- script, so a drop anywhere on the window works. Click-to-choose (the drop
-- area is also a button) is the guaranteed fallback if a platform does not
-- deliver OS file drops.
on dragEnter
   set the acceptDrop to true
   if there is a field "qsDrop" then
      set the backgroundColor of field "qsDrop" to "225,238,255"
   end if
end dragEnter

on dragMove
   set the acceptDrop to true
end dragMove

on dragLeave
   if there is a field "qsDrop" then
      set the backgroundColor of field "qsDrop" to "245,247,250"
   end if
end dragLeave

on dragDrop
   local tFiles
   if there is a field "qsDrop" then
      set the backgroundColor of field "qsDrop" to "245,247,250"
   end if
   put the dragData["files"] into tFiles
   if tFiles is empty then
      pass dragDrop
   end if
   -- one file at a time keeps the demo simple; the first dropped item wins
   qsShareFile (line 1 of tFiles)
end dragDrop

on mouseUp
   switch the short name of the target
      case "qsDrop"
         qsBrowseFile
         break
      case "qsCopy"
         qsCopyCode
         break
      case "qsGet"
         qsGetFile
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- ---- self-building UI (idempotent) -------------------------------------------
command qsBuild
   if there is a field "qsLog" then
      exit qsBuild
   end if
   lock screen
   set the width of this stack to 620
   set the height of this stack to 610
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - Quick Share"
   -- title band
   qsLabel "qsTitle", "  Quick Share - send a file with a code", "0,0,620,40", 15
   set the opaque of field "qsTitle" to true
   set the backgroundColor of field "qsTitle" to "44,90,160"
   set the foregroundColor of field "qsTitle" to "255,255,255"
   set the textStyle of field "qsTitle" to "bold"
   qsLabel "qsTagline", "Send a file straight to a friend with a short code. No server, no size limit, no upload first - peer-to-peer.", "24,50,596,72", 10
   set the foregroundColor of field "qsTagline" to "90,96,105"
   -- SEND: the drop area + the resulting code
   qsField "qsDrop", "24,84,596,196", true
   set the opaque of field "qsDrop" to true
   set the backgroundColor of field "qsDrop" to "245,247,250"
   set the borderWidth of field "qsDrop" to 1
   set the threeD of field "qsDrop" to false
   set the borderColor of field "qsDrop" to "175,185,200"
   set the textAlign of field "qsDrop" to "center"
   set the textSize of field "qsDrop" to 13
   set the foregroundColor of field "qsDrop" to "90,96,105"
   set the text of field "qsDrop" to (return & return & "Drag a file here to share" & return & return & "(or click to choose a file)")
   qsLabel "qsSharing", "", "24,202,596,222", 10
   set the textStyle of field "qsSharing" to "bold"
   qsLabel "qsCodeCap", "Your share code - give this to your friend:", "24,228,596,246", 10
   qsField "qsCode", "24,248,490,282", true
   set the textFont of field "qsCode" to "Courier"
   set the textSize of field "qsCode" to 14
   set the opaque of field "qsCode" to true
   set the backgroundColor of field "qsCode" to "255,250,225"
   qsButton "qsCopy", "Copy", "500,250,596,280"
   -- RECEIVE: paste a code, download
   qsSection "qsRecvSec", "Receive a file", "24,298,596,320"
   qsLabel "qsRecvCap", "Paste a code a friend sent you, then click Download:", "24,326,596,344", 10
   qsField "qsRecvCode", "24,348,490,380", false
   set the textFont of field "qsRecvCode" to "Courier"
   set the textSize of field "qsRecvCode" to 11
   qsButton "qsGet", "Download", "500,348,596,380"
   -- TRANSFERS: see it working
   qsSection "qsXferSec", "Transfers", "24,396,596,418"
   qsLabel "qsXferHead", "Name" & tab & "Direction" & tab & "Progress", "24,422,596,440", 9
   set the tabStops of field "qsXferHead" to "210,330"
   set the textFont of field "qsXferHead" to "Courier"
   set the textSize of field "qsXferHead" to 9
   qsList "qsXfers", "24,442,596,524", false
   set the tabStops of field "qsXfers" to "210,330"
   set the textFont of field "qsXfers" to "Courier"
   set the textSize of field "qsXfers" to 10
   qsLabel "qsStatus", "", "24,528,596,548", 10
   set the foregroundColor of field "qsStatus" to "90,96,105"
   -- a small activity log
   qsList "qsLog", "24,554,596,600", true
   set the textSize of field "qsLog" to 9
   qsAddTips
   unlock screen
end qsBuild

command qsLabel pName, pText, pRect, pSize
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
end qsLabel

command qsSection pName, pText, pRect
   qsLabel pName, ("  " & pText), pRect, 11
   set the opaque of field pName to true
   set the backgroundColor of field pName to "210,216,226"
   set the foregroundColor of field pName to "30,40,60"
   set the textStyle of field pName to "bold"
end qsSection

command qsField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end qsField

command qsButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end qsButton

command qsList pName, pRect, pIsLog
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
end qsList

command qsAddTips
   set the tooltip of field "qsDrop" to "Drag a file here, or click to choose one, to share it."
   set the tooltip of field "qsCode" to "Your file's share code. Click Copy and send it to your friend."
   set the tooltip of button "qsCopy" to "Copy the share code to the clipboard."
   set the tooltip of field "qsRecvCode" to "Paste the code a friend gave you here."
   set the tooltip of button "qsGet" to "Download the file for that code into your Quick Share folder."
   set the tooltip of field "qsXfers" to "Files you are sending and receiving, with live progress."
end qsAddTips

-- ---- session + loops ---------------------------------------------------------
command qsStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      qsLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      put 0 into sSession
      exit qsStart
   end if
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   put "true" into sPolling
   qsLog "Ready. Drag a file to share it, or paste a code to download. Give the network a few seconds first."
   send "qsPollOnce" to me in 0 milliseconds
   send "qsDashOnce" to me in 800 milliseconds
end qsStart

command qsStop
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
end qsStop

command qsPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit qsPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit qsPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      qsHandleEvent tEvent
   end repeat
   send "qsPollOnce" to me in 250 milliseconds
end qsPollOnce

command qsDashOnce
   if sPolling is not "true" then
      exit qsDashOnce
   end if
   qsRefreshXfers
   send "qsDashOnce" to me in 1000 milliseconds
end qsDashOnce

-- ---- sending: turn a dropped/chosen file into a seeded torrent + a code ------
command qsShareFile pPath
   local tData, tH, tHash, tParent, tName
   if sSession is 0 then
      qsLog "No session - reopen the stack."
      exit qsShareFile
   end if
   if pPath is empty then
      exit qsShareFile
   end if
   -- separator-agnostic: normalise to "/" so the parent split works on Windows too
   replace "\" with "/" in pPath
   if the last char of pPath is "/" then
      delete the last char of pPath
   end if
   if there is no file pPath and there is no folder pPath then
      qsLog "Could not find that file:" && pPath
      exit qsShareFile
   end if
   set the itemDelimiter to "/"
   put the last item of pPath into tName
   put item 1 to -2 of pPath into tParent
   if tParent is empty then
      put "/" into tParent
   end if
   qsLog "Packaging" && quote & tName & quote & "..."
   -- create the torrent (auto piece size, a public tracker to help) and seed it
   put btCreateTorrent(pPath, 0, 0, qsTracker()) into tData
   if tData is empty then
      qsLog "Could not package that file:" && btLastError()
      exit qsShareFile
   end if
   put btAddTorrentFile(sSession, tData, tParent) into tH
   if tH is 0 then
      qsLog "Could not start sharing:" && btLastError()
      exit qsShareFile
   end if
   put btInfoHash(tH) into tHash
   if tHash is empty then
      qsLog "Almost - the code is not ready yet. Drop the file again in a moment."
      exit qsShareFile
   end if
   put tHash into sShareCode
   set the text of field "qsCode" to tHash
   set the text of field "qsSharing" to ("Sharing " & quote & tName & quote & " - keep this window open so your friend can download.")
   qsLog "Got a code for" && quote & tName & quote & ". Click Copy and send it to your friend."
end qsShareFile

command qsBrowseFile
   answer file "Choose a file to share:"
   if it is empty then
      exit qsBrowseFile
   end if
   qsShareFile it
end qsBrowseFile

command qsCopyCode
   if field "qsCode" is empty then
      qsLog "Share a file first to get a code."
      exit qsCopyCode
   end if
   set the clipboardData["text"] to field "qsCode"
   qsLog "Code copied. Send it to your friend by email, chat, anywhere."
end qsCopyCode

-- ---- receiving: a code becomes a download ------------------------------------
command qsGetFile
   local tCode, tMag, tH
   if sSession is 0 then
      qsLog "No session - reopen the stack."
      exit qsGetFile
   end if
   put qsTrim(field "qsRecvCode") into tCode
   if tCode is empty then
      qsLog "Paste a code from your friend first."
      exit qsGetFile
   end if
   -- accept a full magnet link, or a bare 40-hex (v1) / 64-hex (v2) info-hash
   if tCode begins with "magnet:" then
      put tCode into tMag
   else
      put toLower(tCode) into tCode
      if the number of chars of tCode is not 40 and the number of chars of tCode is not 64 then
         qsLog "That does not look like a share code (it should be 40 characters)."
         exit qsGetFile
      end if
      put "magnet:?xt=urn:btih:" & tCode & "&tr=" & qsTracker() into tMag
   end if
   put btAddMagnet(sSession, tMag, qsSaveFolder()) into tH
   if tH is 0 then
      qsLog "Could not start the download:" && btLastError()
      exit qsGetFile
   end if
   put empty into field "qsRecvCode"
   qsLog "Downloading to" && qsSaveFolder() & ". Watch the Transfers list - your friend must be online."
end qsGetFile

-- ---- transfers view + events -------------------------------------------------
command qsRefreshXfers
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tLineNum, tD, tNodes, tStat
   if sSession is 0 or sSession is empty then
      exit qsRefreshXfers
   end if
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put 0 into tLineNum
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      put qsTrunc(tS["name"], 26) & tab & qsRole(tS["state"]) & tab & qsBar(tPct) & return after tRows
      add tS["downloadRate"] to tDown
      add tS["uploadRate"] to tUp
   end repeat
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   if tLineNum is 0 then
      put "   Nothing yet. Drag a file to share, or paste a code to download." into tRows
   end if
   lock screen
   set the text of field "qsXfers" to tRows
   unlock screen
   put btDhtState(sSession) into tD
   put tD["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("Connected - DHT: " & tNodes & " nodes") into tStat
   else
      put "Connecting to the network..." into tStat
   end if
   put tStat & "        sending " & (qsBytes(tUp) & "/s") & "    receiving " & (qsBytes(tDown) & "/s") into field "qsStatus"
end qsRefreshXfers

command qsHandleEvent pEvent
   switch pEvent["name"]
      case "torrentAdded"
         qsRefreshXfers
         break
      case "metadataReceived"
         qsLog "Got the details for" && pEvent["torrentName"] & " - downloading the file now..."
         break
      case "torrentFinished"
         qsLog "Download complete. Saved in" && qsSaveFolder() & "."
         qsRefreshXfers
         break
      default
         break
   end switch
end qsHandleEvent

-- ---- small helpers -----------------------------------------------------------
function qsTracker
   return "udp://tracker.opentrackr.org:1337/announce"
end qsTracker

function qsSaveFolder
   local tBase, tErr
   put specialFolderPath("documents") into tBase
   if tBase is empty then
      put specialFolderPath("desktop") into tBase
   end if
   put tBase & "/TorrentXT Quick Share" into tBase
   if there is no folder tBase then
      try
         create folder tBase
      catch tErr
      end try
   end if
   return tBase
end qsSaveFolder

-- map a libtorrent state to a plain-language direction for the demo
function qsRole pState
   switch pState
      case 3
         return "receiving"
      case 4
      case 5
         return "sending"
      case 1
      case 2
      case 7
         return "preparing"
      default
         return "waiting"
   end switch
end qsRole

-- a 10-segment ASCII progress bar, e.g. [####------] 42%  (monospaced field)
function qsBar pPct
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
end qsBar

function qsBytes pBytes
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
end qsBytes

function qsTrunc pText, pLen
   if the number of chars of pText <= pLen then
      return pText
   end if
   return (char 1 to (pLen - 1) of pText) & "..."
end qsTrunc

function qsTrim pText
   local tT
   put pText into tT
   repeat while tT begins with space or tT begins with tab or tT begins with return
      delete char 1 of tT
   end repeat
   repeat while tT ends with space or tT ends with tab or tT ends with return
      delete the last char of tT
   end repeat
   return tT
end qsTrim

command qsLog pMsg
   if there is no field "qsLog" then
      exit qsLog
   end if
   put the time & "  " & pMsg & return after field "qsLog"
   if the number of lines of field "qsLog" > 200 then
      delete line 1 to (the number of lines of field "qsLog" - 200) of field "qsLog"
   end if
   set the vScroll of field "qsLog" to the formattedHeight of field "qsLog"
end qsLog
