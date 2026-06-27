script "dhtChannelDemo"

-- torrent-dht-channel.livecodescript - a self-building TorrentXT demo of the
-- BEP44 DHT MUTABLE items: publish signed, updatable values under an identity
-- you own, and look up anyone's latest value by their public key. See also
-- torrent-dht-note.livecodescript (immutable / content-addressed items).
--
-- HOW TO USE: paste into a one-card stack's STACK script, then close+reopen.
-- Needs only the loaded org.openxtalk.library.torrent library (v3+).
--
-- WHAT IT SHOWS: "a mailbox the world can read but only you can write." On first
-- run it generates an ed25519 identity and remembers it across launches (the seed
-- is stored in a stack custom property - fine for a demo, not secure storage).
-- You publish a small value (<= 1000 bytes) under your public key; anyone who
-- knows that key fetches your LATEST value, with its version (seq). Only your
-- private key can update it. A magnet link fits easily in 1000 bytes, so this is
-- the "publish a pointer to my current content" / rendezvous primitive: put a
-- magnet here, and readers fetch your key -> get the magnet -> btAddMagnet it.
--
-- NB: only ONE TorrentXT session can be live per OXT process, so to see one
-- machine publish and ANOTHER read, run this stack on two machines and exchange
-- public keys. On a single machine you can publish then Fetch-mine to round-trip.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sPolling          -- "true" while the event poll is armed
local sPub              -- our public key (hex) - shareable
local sSec              -- our secret key (hex) - kept in script only, never shown

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   dcBuild
   dcStart
end openStack

on closeStack
   dcStop
end closeStack

on mouseUp
   switch the short name of the target
      case "dcPublish"
         dcPublish
         break
      case "dcFetch"
         dcFetch
         break
      case "dcMine"
         dcFetchMine
         break
      case "dcCopy"
         dcCopyKey
         break
      case "dcNew"
         dcNewIdentity
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- ---- self-building UI (idempotent) -------------------------------------------
command dcBuild
   if there is a field "dcLog" then
      exit dcBuild
   end if
   lock screen
   set the width of this stack to 600
   set the height of this stack to 560
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - DHT Channel"
   dcMakeLabel "dcTitle", "  TorrentXT - DHT Mutable Channel", "0,0,600,30", 15
   set the opaque of field "dcTitle" to true
   set the backgroundColor of field "dcTitle" to "44,90,160"
   set the foregroundColor of field "dcTitle" to "255,255,255"
   set the textStyle of field "dcTitle" to "bold"
   dcMakeLabel "dcIntro", "Publish signed, updatable values under an ed25519 key you own. Anyone with your public key reads your latest value; only you can change it.", "16,38,584,74", 10
   dcMakeLabel "dcMyKeyLabel", "Your identity (public key) - share it so others can read your channel:", "16,80,584,98", 11
   dcMakeField "dcMyKey", "16,100,420,124", true
   dcMakeButton "dcCopy", "Copy", "428,100,506,124"
   dcMakeButton "dcNew", "New", "510,100,584,124"
   dcMakeLabel "dcValueLabel", "Publish a value (<= 1000 bytes; a magnet link fits):", "16,132,584,150", 11
   dcMakeField "dcValue", "16,152,490,204", false
   dcMakeButton "dcPublish", "Publish", "498,152,584,178"
   dcMakeLabel "dcLookupLabel", "Look up a public key:", "16,214,584,232", 11
   dcMakeField "dcLookup", "16,234,400,258", false
   dcMakeButton "dcFetch", "Fetch latest", "408,234,496,258"
   dcMakeButton "dcMine", "Fetch mine", "500,234,584,258"
   dcMakeLabel "dcResultLabel", "Latest value:", "16,270,584,288", 11
   dcMakeField "dcResult", "16,290,584,348", true
   dcMakeLabel "dcResultMeta", "", "16,352,584,370", 10
   dcMakeLabel "dcLogLabel", "Activity:", "16,376,584,394", 11
   dcMakeList "dcLog", "16,396,584,548"
   set the textFont of field "dcMyKey" to "Courier"
   set the textFont of field "dcLookup" to "Courier"
   -- a 64-hex key needs a small fixed-width size to sit on one line
   set the textSize of field "dcMyKey" to 9
   set the textSize of field "dcLookup" to 9
   unlock screen
end dcBuild

command dcMakeLabel pName, pText, pRect, pSize
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
end dcMakeLabel

command dcMakeField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end dcMakeField

command dcMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end dcMakeButton

command dcMakeList pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
end dcMakeList

-- ---- session, identity, event poll -------------------------------------------
command dcStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      dcLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      put 0 into sSession
      exit dcStart
   end if
   btSetBool sSession, "enable_dht", true
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   dcEnsureIdentity
   dcLog "Session ready. The DHT is bootstrapping - give it a few seconds before publishing or fetching."
   put "true" into sPolling
   send "dcPollOnce" to me in 250 milliseconds
end dcStart

-- Re-derive our keypair from a remembered seed, or make a new identity the first
-- time and remember its seed for next launch.
command dcEnsureIdentity
   local tKey, tSeed
   put the uDhtSeed of this stack into tSeed
   if tSeed is not empty then
      put btDhtKeypair(tSeed) into tKey
   else
      put btDhtKeypair("") into tKey
      set the uDhtSeed of this stack to tKey["seed"]
   end if
   put tKey["publicKey"] into sPub
   put tKey["secretKey"] into sSec
   set the text of field "dcMyKey" to sPub
end dcEnsureIdentity

command dcStop
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
end dcStop

command dcPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit dcPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit dcPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      dcHandleEvent tEvent
   end repeat
   send "dcPollOnce" to me in 250 milliseconds
end dcPollOnce

-- ---- actions -----------------------------------------------------------------
command dcPublish
   local tData, tR
   if sSession is 0 then
      dcLog "No session."
      exit dcPublish
   end if
   put textEncode(field "dcValue", "UTF-8") into tData
   if the number of bytes in tData is 0 then
      dcLog "Type a value to publish first."
      exit dcPublish
   end if
   if the number of bytes in tData > 1000 then
      dcLog "Too big:" && (the number of bytes in tData) && "bytes (max 1000)."
      exit dcPublish
   end if
   -- signed and sequence-bumped in the native layer; confirms via a dhtPut event
   put btDhtPutMutable(sSession, sPub, sSec, "", tData) into tR
   if tR is not 0 then
      dcLog "Publish failed:" && btLastError()
      exit dcPublish
   end if
   dcLog "Publishing" && (the number of bytes in tData) && "bytes under your key... (confirms as an event)"
end dcPublish

command dcFetch
   local tKey, tR
   if sSession is 0 then
      dcLog "No session."
      exit dcFetch
   end if
   put dcTrim(field "dcLookup") into tKey
   if the number of chars of tKey is not 64 then
      dcLog "Paste a 64-character public key into the lookup field first."
      exit dcFetch
   end if
   put btDhtGetMutable(sSession, tKey, "") into tR
   if tR is not 0 then
      dcLog "Fetch failed:" && btLastError()
      exit dcFetch
   end if
   dcLog "Looking up the latest value under" && (char 1 to 12 of tKey) & "... (returns as an event)"
end dcFetch

command dcFetchMine
   set the text of field "dcLookup" to sPub
   dcFetch
end dcFetchMine

command dcCopyKey
   if sPub is empty then
      exit dcCopyKey
   end if
   set the clipboardData["text"] to sPub
   dcLog "Copied your public key to the clipboard - share it so others can read your channel."
end dcCopyKey

command dcNewIdentity
   local tKey
   answer "Generate a NEW identity? Values published under your current key become unreachable to anyone using the old key." with "Cancel" or "New identity"
   if it is not "New identity" then
      exit dcNewIdentity
   end if
   put btDhtKeypair("") into tKey
   set the uDhtSeed of this stack to tKey["seed"]
   put tKey["publicKey"] into sPub
   put tKey["secretKey"] into sSec
   set the text of field "dcMyKey" to sPub
   dcLog "New identity:" && sPub
end dcNewIdentity

-- ---- events (drained by the poll loop) ---------------------------------------
command dcHandleEvent pEvent
   local tMeta
   switch pEvent["name"]
      case "dhtMutableItem"
         set the text of field "dcResult" to textDecode(pEvent["value"], "UTF-8")
         put "version (seq):" && pEvent["seq"] into tMeta
         if pEvent["authoritative"] is "1" then
            put tMeta && "- authoritative" into tMeta
         end if
         set the text of field "dcResultMeta" to tMeta
         dcLog "Got latest (seq" && pEvent["seq"] & ") under" && (char 1 to 12 of pEvent["publicKey"]) & "."
         break
      case "dhtPut"
         dcLog "Published to" && pEvent["numSuccess"] && "DHT node(s)."
         break
      default
         break
   end switch
end dcHandleEvent

-- ---- helpers -----------------------------------------------------------------
command dcLog pMsg
   if there is no field "dcLog" then
      exit dcLog
   end if
   put the time & "  " & pMsg & return after field "dcLog"
   if the number of lines of field "dcLog" > 200 then
      delete line 1 to (the number of lines of field "dcLog" - 200) of field "dcLog"
   end if
   set the vScroll of field "dcLog" to the formattedHeight of field "dcLog"
end dcLog

function dcTrim pText
   local tT
   put pText into tT
   repeat while tT begins with space or tT begins with tab or tT begins with return
      delete char 1 of tT
   end repeat
   repeat while tT ends with space or tT ends with tab or tT ends with return
      delete the last char of tT
   end repeat
   return tT
end dcTrim
