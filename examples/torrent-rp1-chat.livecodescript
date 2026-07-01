script "rp1ChatApp"

-- torrent-rp1-chat.livecodescript - a two-machine test harness for the rp1
-- custom BEP10 extension (the Riptide transport). It is the smallest thing that
-- exercises the WHOLE peer-wire path end to end:
--
--   btRp1Enable      -> turn the rp1 extension on for the session
--   btAddInfohash    -> join a metadata-less "phantom swarm" at a room id
--   btDhtAnnounce    -> advertise ourselves at that id so the other side finds us
--   (DHT rendezvous)  the two phantom swarms auto-connect peer to peer
--   rp1Handshake     -> each side learns the other is rp1-capable
--   btRp1Send /      -> opaque bytes travel under the rp1 extension id, with NO
--   rp1Message          tracker, NO server, and NO content
--
-- This is a PLAINTEXT chat on purpose: the point is to watch the transport work,
-- so what crosses the wire is exactly what you type. Riptide layers its crypto
-- (SodiumXT sxSecretStream) on top of this same btRp1Send/rp1Message channel; the
-- transport under test here is identical.
--
-- HOW TO TEST (two machines, ideally on different networks):
--   1. Install the TorrentXT extension on both, paste this script into a stack,
--      and reopen the stack (that fires openStack and builds the UI).
--   2. On BOTH sides type the SAME room name (any shared phrase) and click Join.
--   3. Give the DHT a few seconds to introduce the peers. When you see
--      "Peer N is rp1-capable" on both sides, type a message and Send.
--   4. The message appears on the other machine. That round trip is the proof.
--
-- One live peer is required to see anything, which is why this ships as a demo to
-- run on the engine rather than a unit test: the native framing and control paths
-- are covered by tests/torrent_smoke_test.cpp, but the actual peer exchange only
-- happens between two running instances.

-- Bump when the generated UI changes so a saved stack rebuilds its controls.
constant kRcUiVersion = "rp1-ui-2026-07"

-- ---- script-local state (declared at top) ------------------------------------
local sSession        -- the live session handle (0/empty = none)
local sPolling        -- "true" while the poll loops are armed
local sRoomId         -- the 40-hex rendezvous id we joined (empty = not joined)
local sTorrent        -- the phantom-swarm torrent handle
local sPeers          -- array peerId -> "1" for rp1-capable connected peers

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   rcBuild
   rcStart
end openStack

on closeStack
   rcStop
end closeStack

on mouseUp
   switch the short name of the target
      case "rcJoin"
         rcJoin
         break
      case "rcSend"
         rcSendMessage
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- Enter in the message box sends; Enter in the room box joins.
on returnInField
   switch the short name of the target
      case "rcMsg"
         rcSendMessage
         break
      case "rcRoom"
         rcJoin
         break
      default
         pass returnInField
   end switch
end returnInField

-- ---- self-building UI (idempotent; rebuilds on a version bump) ----------------
command rcBuild
   if the uUiVersion of this stack is kRcUiVersion and there is a field "rcMsg" then
      exit rcBuild
   end if
   rcClearGeneratedUI
   lock screen
   set the width of this stack to 560
   set the height of this stack to 576
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - rp1 chat (transport test)"
   -- title band
   rcLabel "rcTitle", "  rp1 chat - serverless peer-to-peer over a phantom swarm", "0,0,560,40", 14
   set the opaque of field "rcTitle" to true
   set the backgroundColor of field "rcTitle" to "44,90,160"
   set the foregroundColor of field "rcTitle" to "255,255,255"
   set the textStyle of field "rcTitle" to "bold"
   rcLabel "rcTagline", "Type the SAME room name on two machines and Join. No tracker, no server, no content - the DHT introduces you and messages ride the rp1 BEP10 extension.", "16,46,544,84", 10
   set the foregroundColor of field "rcTagline" to "90,96,105"
   -- room + name + join
   rcLabel "rcRoomCap", "Room (a shared phrase, or a 40-hex id):", "16,90,360,110", 10
   rcField "rcRoom", "16,112,400,138", false
   rcButton "rcJoin", "Join", "410,110,544,140"
   rcLabel "rcNameCap", "Your name:", "16,146,120,166", 10
   rcField "rcName", "120,144,300,168", false
   -- status
   rcLabel "rcStatus", "Not joined.", "16,176,544,196", 10
   set the foregroundColor of field "rcStatus" to "90,96,105"
   -- combined event + chat log
   rcList "rcLog", "16,204,544,516"
   set the textSize of field "rcLog" to 11
   -- message box + send
   rcField "rcMsg", "16,524,420,552", false
   rcButton "rcSend", "Send", "430,522,544,554"
   rcAddTips
   set the uUiVersion of this stack to kRcUiVersion
   unlock screen
end rcBuild

command rcClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of fields of this card down to 1
      if the short name of field tI of this card begins with "rc" then
         delete field tI of this card
      end if
   end repeat
   repeat with tI = the number of buttons of this card down to 1
      if the short name of button tI of this card begins with "rc" then
         delete button tI of this card
      end if
   end repeat
   unlock screen
end rcClearGeneratedUI

command rcLabel pName, pText, pRect, pSize
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
end rcLabel

command rcField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end rcField

command rcButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end rcButton

command rcList pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
   set the listBehavior of field pName to false
end rcList

command rcAddTips
   set the tooltip of field "rcRoom" to "A phrase both sides share becomes the rendezvous id (its SHA-1). Or paste a 40-hex id directly."
   set the tooltip of button "rcJoin" to "Join the phantom swarm for this room and start looking for peers."
   set the tooltip of field "rcName" to "A display name prepended to your messages."
   set the tooltip of field "rcMsg" to "Type a message and press Enter (or Send) to broadcast it to every rp1 peer in the room."
end rcAddTips

-- ---- session + poll loops ----------------------------------------------------
command rcStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      rcLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      put 0 into sSession
      exit rcStart
   end if
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   -- turn on rp1 BEFORE adding the swarm, so the swarm advertises the extension
   btRp1Enable sSession
   put "true" into sPolling
   put empty into sPeers
   rcLog "Ready. Type a room name and Join. Then wait for the DHT to find a peer."
   send "rcPollOnce" to me in 0 milliseconds
   send "rcDashOnce" to me in 800 milliseconds
end rcStart

command rcStop
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   put empty into sRoomId
   put empty into sPeers
end rcStop

-- Join a room: derive the 40-hex rendezvous id, add the phantom swarm, and
-- announce ourselves so the other side's DHT lookup finds us.
command rcJoin
   local tRoom, tName
   if sSession is 0 or sSession is empty then
      rcLog "No session; cannot join."
      exit rcJoin
   end if
   put rcTrim(the text of field "rcRoom") into tRoom
   if tRoom is empty then
      rcLog "Type a room name first."
      exit rcJoin
   end if
   put rcRoomId(tRoom) into sRoomId
   -- a phantom swarm has no real data; any valid save path will do
   put rcSaveFolder() into tName
   put btAddInfohash(sSession, sRoomId, tName) into sTorrent
   if sTorrent is 0 or sTorrent is empty then
      rcLog "Could not join the room:" && btLastError()
      exit rcJoin
   end if
   -- advertise ourselves at the id right away (the torrent also announces on its
   -- own DHT schedule; this just makes the first meeting faster)
   btDhtAnnounce sSession, sRoomId, 0
   put empty into sPeers
   rcLog "Joined room" && tRoom & "  (id" && sRoomId & ")."
   rcLog "Waiting for a peer... give the DHT a few seconds."
end rcJoin

command rcPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit rcPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit rcPollOnce
   end if
   -- drain the normal event stream (DHT/torrent) for status...
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      if tEvent["name"] is "dhtBootstrap" then
         rcLog "DHT is up."
      end if
   end repeat
   -- ...and the rp1 event stream (peer up/down, handshake, message)
   put btRp1Poll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      rcHandleRp1 tEvent
   end repeat
   send "rcPollOnce" to me in 200 milliseconds
end rcPollOnce

-- One rp1 event. The peer id is stable for the connection's lifetime, so we key
-- our send list on it and clear it on disconnect.
command rcHandleRp1 pEvent
   local tName, tPeer, tMsg
   put pEvent["name"] into tName
   put pEvent["peer"] into tPeer
   switch tName
      case "rp1PeerConnected"
         rcLog "* peer" && tPeer && "connected (" & pEvent["endpoint"] & ")"
         break
      case "rp1Handshake"
         if pEvent["supportsRp1"] is "1" then
            put "1" into sPeers[tPeer]
            rcLog "* peer" && tPeer && "is rp1-capable - you can chat now"
         else
            rcLog "* peer" && tPeer && "is not rp1-capable (ignored)"
         end if
         break
      case "rp1Message"
         put textDecode(pEvent["payload"], "utf-8") into tMsg
         rcChatLine tMsg
         break
      case "rp1PeerDisconnected"
         delete variable sPeers[tPeer]
         rcLog "* peer" && tPeer && "left"
         break
   end switch
end rcHandleRp1

-- Broadcast the message box to every rp1-capable peer in the room.
command rcSendMessage
   local tBody, tName, tLine, tPeer, tSent
   if sSession is 0 or sSession is empty then
      exit rcSendMessage
   end if
   put rcTrim(the text of field "rcMsg") into tBody
   if tBody is empty then
      exit rcSendMessage
   end if
   if the number of keys of sPeers is 0 then
      rcLog "No rp1 peers yet - wait for a handshake before sending."
      exit rcSendMessage
   end if
   put rcTrim(the text of field "rcName") into tName
   if tName is empty then
      put "me" into tName
   end if
   put tName & ": " & tBody into tLine
   put 0 into tSent
   repeat for each key tPeer in sPeers
      btRp1Send sSession, tPeer, textEncode(tLine, "utf-8")
      add 1 to tSent
   end repeat
   rcChatLine ("You: " & tBody)
   set the text of field "rcMsg" to ""
end rcSendMessage

command rcDashOnce
   local tDht, tCount
   if sPolling is not "true" then
      exit rcDashOnce
   end if
   put the number of keys of sPeers into tCount
   if sRoomId is empty then
      set the text of field "rcStatus" to "Not joined."
   else
      put btDhtState(sSession) into tDht
      set the text of field "rcStatus" to ("In a room - rp1 peers:" && tCount && "- DHT nodes:" && tDht["nodes"])
   end if
   send "rcDashOnce" to me in 1000 milliseconds
end rcDashOnce

-- ---- small helpers -----------------------------------------------------------
-- A received chat line (bold-ish marker so it stands out from system "*" lines).
command rcChatLine pText
   if there is no field "rcLog" then
      exit rcChatLine
   end if
   put pText & return after field "rcLog"
   set the vscroll of field "rcLog" to the formattedHeight of field "rcLog"
end rcChatLine

command rcLog pMsg
   if there is no field "rcLog" then
      exit rcLog
   end if
   put pMsg & return after field "rcLog"
   set the vscroll of field "rcLog" to the formattedHeight of field "rcLog"
end rcLog

-- Turn a room phrase into a 40-hex rendezvous id. A value that is ALREADY a
-- 40-hex id is used verbatim (so two power users can share a raw id); anything
-- else is hashed with SHA-1 to 20 bytes (matching how a phantom-swarm id is
-- "any 20 bytes"). Both sides must derive the SAME id, so the rule is fixed.
function rcRoomId pRoom
   if the length of pRoom is 40 and matchText(pRoom, "^[0-9a-fA-F]{40}$") then
      return toLower(pRoom)
   end if
   return rcToHex(sha1Digest(pRoom))
end rcRoomId

-- Lower-case hex of a binary string, using only basic byte ops (no dependency on
-- binaryEncode format codes, which vary).
function rcToHex pData
   local tHex, tI, tByte, tDigits
   put "0123456789abcdef" into tDigits
   put "" into tHex
   repeat with tI = 1 to the number of bytes in pData
      put byteToNum(byte tI of pData) into tByte
      put char ((tByte div 16) + 1) of tDigits after tHex
      put char ((tByte mod 16) + 1) of tDigits after tHex
   end repeat
   return tHex
end rcToHex

-- A folder for the phantom swarm's (nonexistent) content. Nothing is written
-- there; libtorrent just needs a valid save path for the add.
function rcSaveFolder
   local tBase
   put specialFolderPath("temporary") & "/TorrentXT-rp1" into tBase
   if there is no folder tBase then
      create folder tBase
   end if
   return tBase
end rcSaveFolder

function rcTrim pText
   return word 1 to -1 of pText
end rcTrim
