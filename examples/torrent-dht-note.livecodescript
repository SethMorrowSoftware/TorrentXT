script "dhtNoteDemo"

-- torrent-dht-note.livecodescript - a self-building TorrentXT demo of the BEP44
-- DHT as a CONTENT-ADDRESSED store (immutable items). One of the small DHT
-- key-value demos; see also torrent-dht-channel.livecodescript (mutable items).
--
-- HOW TO USE: open OXT, make a stack with one card, paste THIS into the STACK
-- script (Object > Stack Script), then close+reopen the stack. It builds its own
-- UI and starts a TorrentXT session. Needs only the loaded
-- org.openxtalk.library.torrent library (v3+, which has the btDht* item calls).
--
-- WHAT IT SHOWS: "pin a note, share the code." Pin a short note (<= 1000 bytes)
-- to the DHT and get back a 40-character target hash - its content address.
-- Anyone (here, or on another machine) who has that code can fetch the exact
-- bytes back. The value cannot be changed; the code only ever matches that data.
-- The DHT is asynchronous and best-effort, so the value comes back as an EVENT a
-- few seconds later (and only once the DHT has peers), drained by the poll loop.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sPolling          -- "true" while the event poll is armed

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   dnBuild
   dnStart
end openStack

on closeStack
   dnStop
end closeStack

on mouseUp
   switch the short name of the target
      case "dnPin"
         dnPin
         break
      case "dnCopy"
         dnCopyCode
         break
      case "dnFetch"
         dnFetch
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- ---- self-building UI (idempotent) -------------------------------------------
command dnBuild
   if there is a field "dnLog" then
      exit dnBuild
   end if
   lock screen
   set the width of this stack to 600
   set the height of this stack to 540
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - DHT Note"
   dnMakeLabel "dnTitle", "  TorrentXT - DHT Immutable Note", "0,0,600,30", 15
   set the opaque of field "dnTitle" to true
   set the backgroundColor of field "dnTitle" to "44,90,160"
   set the foregroundColor of field "dnTitle" to "255,255,255"
   set the textStyle of field "dnTitle" to "bold"
   dnMakeLabel "dnIntro", "Pin a short note to the DHT and get a share code (its content address). Anyone with the code can fetch the exact bytes back - no server.", "16,38,584,74", 10
   dnMakeLabel "dnNoteLabel", "Note to pin (<= 1000 bytes):", "16,80,584,98", 11
   dnMakeField "dnNote", "16,100,584,178", false
   dnMakeButton "dnPin", "Pin to DHT", "16,186,150,212"
   dnMakeLabel "dnBytes", "0 bytes", "160,190,584,210", 10
   dnMakeLabel "dnCodeLabel", "Share code (give this to anyone to fetch the note):", "16,222,584,240", 11
   dnMakeField "dnCode", "16,242,470,266", true
   dnMakeButton "dnCopy", "Copy code", "478,242,584,266"
   dnMakeLabel "dnFetchLabel", "Fetch a code:", "16,278,584,296", 11
   dnMakeField "dnTarget", "16,298,470,322", false
   dnMakeButton "dnFetch", "Fetch", "478,298,584,322"
   dnMakeLabel "dnResultLabel", "Fetched value:", "16,334,584,352", 11
   dnMakeField "dnResult", "16,354,584,412", true
   dnMakeLabel "dnLogLabel", "Activity:", "16,420,584,438", 11
   dnMakeList "dnLog", "16,440,584,528"
   set the textFont of field "dnCode" to "Courier"
   set the textFont of field "dnTarget" to "Courier"
   unlock screen
end dnBuild

command dnMakeLabel pName, pText, pRect, pSize
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
end dnMakeLabel

command dnMakeField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end dnMakeField

command dnMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end dnMakeButton

command dnMakeList pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
end dnMakeList

-- ---- session + event poll ----------------------------------------------------
command dnStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      dnLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      put 0 into sSession
      exit dnStart
   end if
   btSetBool sSession, "enable_dht", true
   -- seed the DHT so it bootstraps reliably on first run
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   dnLog "Session ready. The DHT is bootstrapping - give it a few seconds of peers before a Fetch will find anything."
   put "true" into sPolling
   send "dnPollOnce" to me in 250 milliseconds
end dnStart

command dnStop
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
end dnStop

command dnPollOnce
   local tEvents, tEvent, tBytes
   if sPolling is not "true" then
      exit dnPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit dnPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      dnHandleEvent tEvent
   end repeat
   -- keep the live byte-count fresh, but only repaint it when it changes
   put (the number of bytes in textEncode(field "dnNote", "UTF-8")) && "bytes" into tBytes
   if the text of field "dnBytes" is not tBytes then
      set the text of field "dnBytes" to tBytes
   end if
   send "dnPollOnce" to me in 250 milliseconds
end dnPollOnce

-- ---- actions -----------------------------------------------------------------
command dnPin
   local tData, tTarget
   if sSession is 0 then
      dnLog "No session."
      exit dnPin
   end if
   put textEncode(field "dnNote", "UTF-8") into tData
   if the number of bytes in tData is 0 then
      dnLog "Type a note first."
      exit dnPin
   end if
   if the number of bytes in tData > 1000 then
      dnLog "Too big:" && (the number of bytes in tData) && "bytes (max 1000)."
      exit dnPin
   end if
   -- the target hash comes back immediately; the store itself confirms via event
   put btDhtPutImmutable(sSession, tData) into tTarget
   if tTarget is empty then
      dnLog "Pin failed:" && btLastError()
      exit dnPin
   end if
   put tTarget into field "dnCode"
   put tTarget into field "dnTarget"    -- pre-fill Fetch so you can round-trip it
   dnLog "Pinned" && (the number of bytes in tData) && "bytes. Share code:" && tTarget
end dnPin

command dnCopyCode
   if field "dnCode" is empty then
      dnLog "Pin a note first."
      exit dnCopyCode
   end if
   set the clipboardData["text"] to field "dnCode"
   dnLog "Copied the share code to the clipboard."
end dnCopyCode

command dnFetch
   local tTarget, tR
   if sSession is 0 then
      dnLog "No session."
      exit dnFetch
   end if
   put dnTrim(field "dnTarget") into tTarget
   if the number of chars of tTarget is not 40 then
      dnLog "Paste a 40-character share code into Fetch first."
      exit dnFetch
   end if
   put btDhtGetImmutable(sSession, tTarget) into tR
   if tR is not 0 then
      dnLog "Fetch failed:" && btLastError()
      exit dnFetch
   end if
   dnLog "Looking up" && tTarget & "... (the value returns as an event)"
end dnFetch

-- ---- events (drained by the poll loop) ---------------------------------------
command dnHandleEvent pEvent
   switch pEvent["name"]
      case "dhtImmutableItem"
         set the text of field "dnResult" to textDecode(pEvent["value"], "UTF-8")
         dnLog "Fetched the value for" && pEvent["target"] & "."
         break
      case "dhtPut"
         dnLog "Stored on" && pEvent["numSuccess"] && "DHT node(s)."
         break
      default
         break
   end switch
end dnHandleEvent

-- ---- helpers -----------------------------------------------------------------
command dnLog pMsg
   if there is no field "dnLog" then
      exit dnLog
   end if
   put the time & "  " & pMsg & return after field "dnLog"
   if the number of lines of field "dnLog" > 200 then
      delete line 1 to (the number of lines of field "dnLog" - 200) of field "dnLog"
   end if
   set the vScroll of field "dnLog" to the formattedHeight of field "dnLog"
end dnLog

function dnTrim pText
   local tT
   put pText into tT
   repeat while tT begins with space or tT begins with tab or tT begins with return
      delete char 1 of tT
   end repeat
   repeat while tT ends with space or tT ends with tab or tT ends with return
      delete the last char of tT
   end repeat
   return tT
end dnTrim
