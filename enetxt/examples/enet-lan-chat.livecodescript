script "EnetLanChat"

-- enet-lan-chat.livecodescript - the Part III.7 milestone-3 demo: a LAN chat
-- that exercises the whole enetxt surface in the smallest useful app. One
-- machine clicks HOST (it becomes the server and a chatter); others enter its
-- ip[:port] and JOIN. The server relays every line to every peer with ONE
-- enBroadcast; presence (joins/leaves, with addresses) rides the
-- enetConnect/enetDisconnect events; the status line shows live peer count
-- and (clients) the RTT from enPeerStatus.
--
-- What to look at as a template:
--   * PUMP OR NOTHING - enStartPolling arms the heartbeat; nothing in ENet
--     progresses without it. 33 ms here (real-time feel).
--   * The server is ALSO a client of itself logically: its own lines go
--     straight to the log and out via enBroadcast; client lines go enSendText
--     to the server, which relays them.
--   * Channel 0 carries chat (reliable); the connect data carries a tiny
--     protocol version so mismatched builds refuse loudly.
--   * closeStack calls enDeinitialize - the one mandatory teardown (bare
--     command form: OXT cannot compile a zero-argument `name()` statement).
--
-- HOW TO TEST (two+ machines on a LAN, or two stacks on one machine):
--   1. Install the enetxt extension on both. Open enet-helpers and this
--      script as stacks ("start using stack" the helpers first).
--   2. Machine A clicks Host. Machine B types A's ip (port defaults to
--      27099) and clicks Join. Chat.

-- Bump when the generated UI changes so a saved stack rebuilds its controls.
constant kEcUiVersion = "enetchat-ui-2026-08"
-- The connect-data protocol version: the server refuses a mismatch loudly
-- instead of garbling. Bump when the wire meaning of messages changes.
constant kEcProto = 1
constant kEcPort = 27099

-- ---- script-local state (declared at top) ------------------------------------
local sHost             -- our ENet host handle (server or client; 0/empty = none)
local sIsServer         -- "true" when we hosted
local sServerPeer       -- client role: the peer handle to the server
local sPeers            -- server role: array peer -> display address
local sReady            -- "true" once hosting/joined and (client) connected

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   ecBuild
   ecStart
end openStack

on closeStack
   ecStop
end closeStack

on mouseUp
   switch the short name of the target
      case "ecHost"
         ecHost
         break
      case "ecJoin"
         ecJoin
         break
      case "ecLeave"
         ecLeave
         break
      case "ecSend"
         ecSendLine
         break
      default
         pass mouseUp
   end switch
end mouseUp

on returnInField
   switch the short name of the target
      case "ecMsg"
         ecSendLine
         break
      case "ecAddr"
         ecJoin
         break
      default
         pass returnInField
   end switch
end returnInField

-- ---- self-building UI (idempotent; rebuilds on a version bump) ----------------
command ecBuild
   if the uEcUiVersion of this stack is kEcUiVersion and there is a field "ecMsg" then
      exit ecBuild
   end if
   ecClearGeneratedUI
   lock screen
   set the width of this stack to 560
   set the height of this stack to 600
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "enetxt - LAN chat"
   ecLabel "ecTitle", "  enetxt LAN chat - reliable UDP, one broadcast, zero servers to run", "0,0,560,40", 14
   set the opaque of field "ecTitle" to true
   set the backgroundColor of field "ecTitle" to "44,90,160"
   set the foregroundColor of field "ecTitle" to "255,255,255"
   set the textStyle of field "ecTitle" to "bold"
   ecLabel "ecTagline", "One machine Hosts; everyone else Joins its address. Lines relay through the host over reliable channel 0; joins and leaves announce themselves.", "16,46,544,84", 10
   set the foregroundColor of field "ecTagline" to "90,96,105"
   -- host / join row
   ecButton "ecHost", "Host (port 27099)", "16,92,180,122"
   ecLabel "ecAddrCap", "or join host at ip[:port]:", "190,96,350,116", 10
   ecField "ecAddr", "190,118,470,144", false
   ecButton "ecJoin", "Join", "476,116,544,146"
   -- name + leave
   ecLabel "ecNameCap", "Your name:", "16,152,100,172", 10
   ecField "ecName", "100,150,280,174", false
   ecButton "ecLeave", "Leave", "416,148,544,176"
   -- status
   ecLabel "ecStatus", "Not connected.", "16,184,544,204", 10
   set the foregroundColor of field "ecStatus" to "90,96,105"
   -- log + message box
   ecList "ecLog", "16,212,544,540"
   set the textSize of field "ecLog" to 11
   ecField "ecMsg", "16,548,420,576", false
   ecButton "ecSend", "Send", "430,546,544,578"
   set the uEcUiVersion of this stack to kEcUiVersion
   unlock screen
end ecBuild

command ecClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of fields of this card down to 1
      if the short name of field tI of this card begins with "ec" then
         delete field tI of this card
      end if
   end repeat
   repeat with tI = the number of buttons of this card down to 1
      if the short name of button tI of this card begins with "ec" then
         delete button tI of this card
      end if
   end repeat
   unlock screen
end ecClearGeneratedUI

command ecLabel pName, pText, pRect, pSize
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
end ecLabel

command ecField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end ecField

command ecButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end ecButton

command ecList pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
   set the listBehavior of field pName to false
end ecList

-- ---- startup / teardown ------------------------------------------------------
command ecStart
   local tR
   -- probe the extension with a guarded call; fail closed with a clear
   -- message when it is missing (the family's cryptoXT pattern)
   try
      put enInitialize() into tR
   catch tErr
      ecLog "The enetxt extension is not installed (org.openxtalk.library.enet) - install it and reopen this stack."
      ecSetStatus "Extension missing - see the log."
      exit ecStart
   end try
   if tR is not 0 then
      ecLog "enetxt failed to initialise:" && enLastError()
      exit ecStart
   end if
   ecLog "Ready (" & enLibraryVersion() & "). Host a room or Join one."
   send "ecDashOnce" to me in 800 milliseconds
end ecStart

command ecStop
   if sHost is not empty and sHost is not 0 then
      enHostDestroy sHost
   end if
   put empty into sHost
   put empty into sServerPeer
   put empty into sPeers
   put "false" into sReady
   try
      enStopPolling
   catch tErr
      -- helpers stack already gone; nothing was polling
   end try
   -- the one mandatory teardown: destroys any surviving hosts and releases
   -- the socket layer (bare command form - see the header comment)
   enDeinitialize
end ecStop

-- ---- host / join / leave -----------------------------------------------------
command ecHost
   if sHost is not empty and sHost is not 0 then
      ecLog "Already hosting or joined - Leave first."
      exit ecHost
   end if
   put enHostCreateServer("", kEcPort, 32, 2, 0, 0) into sHost
   if sHost is 0 or sHost is empty then
      ecLog "Could not host (port in use?):" && enLastError()
      put empty into sHost
      exit ecHost
   end if
   put "true" into sIsServer
   put empty into sPeers
   put "true" into sReady
   enStartPolling sHost, the long id of this card, 33
   ecLog "Hosting on port" && kEcPort & ". Others: enter this machine's ip and Join."
end ecHost

command ecJoin
   local tAddr, tHost, tPort
   if sHost is not empty and sHost is not 0 then
      ecLog "Already hosting or joined - Leave first."
      exit ecJoin
   end if
   put ecTrim(the text of field "ecAddr") into tAddr
   if tAddr is empty then
      ecLog "Enter the host's ip (or ip:port) first."
      exit ecJoin
   end if
   set the itemDelimiter to ":"
   put item 1 of tAddr into tHost
   if the number of items of tAddr > 1 then
      put item 2 of tAddr into tPort
   else
      put kEcPort into tPort
   end if
   if tPort is not a number then
      put kEcPort into tPort
   end if
   put enHostCreateClient(1, 2, 0, 0) into sHost
   if sHost is 0 or sHost is empty then
      ecLog "Could not create a client host:" && enLastError()
      put empty into sHost
      exit ecJoin
   end if
   put "false" into sIsServer
   put enConnect(sHost, tHost, tPort, 2, kEcProto) into sServerPeer
   if sServerPeer is 0 or sServerPeer is empty then
      ecLog "Could not start connecting:" && enLastError()
      enHostDestroy sHost
      put empty into sHost
      exit ecJoin
   end if
   enStartPolling sHost, the long id of this card, 33
   ecLog "Connecting to" && tHost & ":" & tPort & "..."
end ecJoin

command ecLeave
   if sHost is empty or sHost is 0 then
      exit ecLeave
   end if
   -- polite goodbye when we are a connected client; the host just vanishes
   -- (its peers all see enetDisconnect within their timeout)
   if sIsServer is not "true" and sServerPeer is not empty and sServerPeer is not 0 then
      enDisconnect sServerPeer, 0
      enFlush sHost
   end if
   enStopPolling sHost
   enHostDestroy sHost
   put empty into sHost
   put empty into sServerPeer
   put empty into sPeers
   put "false" into sReady
   ecLog "Left."
   ecSetStatus "Not connected."
end ecLeave

-- ---- events (dispatched by enet-helpers) -------------------------------------

on enetConnect pEvent
   if sIsServer is "true" then
      -- refuse a protocol mismatch loudly instead of garbling later
      if pEvent["data"] is not kEcProto then
         ecLog "* refused a peer with protocol" && pEvent["data"] && "(we speak" && kEcProto & ")"
         enDisconnectNow pEvent["peer"], 0
         exit enetConnect
      end if
      put pEvent["address"] into sPeers[pEvent["peer"]]
      ecLog "* " & pEvent["address"] && "joined (" & the number of keys of sPeers & " here)"
      ecRelay "* " & pEvent["address"] && "joined"
   else
      put "true" into sReady
      ecLog "* connected - say something!"
   end if
end enetConnect

on enetDisconnect pEvent
   if sIsServer is "true" then
      if pEvent["peer"] is among the keys of sPeers then
         ecLog "* " & sPeers[pEvent["peer"]] && "left"
         ecRelay "* " & sPeers[pEvent["peer"]] && "left"
         delete variable sPeers[pEvent["peer"]]
      end if
   else
      put "false" into sReady
      ecLog "* disconnected from the host"
      ecSetStatus "Not connected."
   end if
end enetDisconnect

on enetReceive pEvent
   local tLine
   put textDecode(pEvent["payload"], "utf-8") into tLine
   if sIsServer is "true" then
      -- a client's line: show it here and relay to everyone (including the
      -- sender - the echo doubles as their delivery receipt)
      ecLog tLine
      ecRelay tLine
   else
      ecLog tLine
   end if
end enetReceive

on enetError pEvent
   ecLog "* transport error:" && pEvent["error"]
end enetError

-- ---- sending -----------------------------------------------------------------
command ecSendLine
   local tBody, tName, tLine, tR
   put ecTrim(the text of field "ecMsg") into tBody
   if tBody is empty then
      exit ecSendLine
   end if
   if sHost is empty or sHost is 0 then
      ecLog "Host or Join first."
      exit ecSendLine
   end if
   put ecTrim(the text of field "ecName") into tName
   if tName is empty then
      put "me" into tName
   end if
   put tName & ": " & tBody into tLine
   if sIsServer is "true" then
      ecLog tLine
      ecRelay tLine
   else
      if sReady is not "true" then
         ecLog "Not connected yet."
         exit ecSendLine
      end if
      put enSendText(sServerPeer, 0, tLine, 0) into tR -- 0 = reliable
      if tR is not 0 then
         ecLog "Send failed (" & tR & "):" && enLastError()
         exit ecSendLine
      end if
   end if
   set the text of field "ecMsg" to ""
end ecSendLine

-- Server fanout: ONE broadcast reaches every connected peer.
command ecRelay pLine
   if sIsServer is "true" and sHost is not empty and sHost is not 0 then
      enBroadcastText sHost, 0, pLine, 0 -- 0 = reliable
   end if
end ecRelay

-- ---- the 1 Hz dashboard ------------------------------------------------------
command ecDashOnce
   local tStatus, tPS
   if sHost is empty or sHost is 0 then
      send "ecDashOnce" to me in 1000 milliseconds
      exit ecDashOnce
   end if
   if sIsServer is "true" then
      ecSetStatus "Hosting on port" && kEcPort && "-" && the number of keys of sPeers && "peer(s)"
   else
      put enPeerStatus(sServerPeer) into tPS
      if tPS["state"] is 5 then
         ecSetStatus "Connected -" && tPS["rtt"] & " ms rtt -" && tPS["address"]
      else
         ecSetStatus "Peer state:" && enStateName(tPS["state"])
      end if
   end if
   send "ecDashOnce" to me in 1000 milliseconds
end ecDashOnce

-- ---- small helpers -----------------------------------------------------------
command ecSetStatus pText
   if there is a field "ecStatus" then
      set the text of field "ecStatus" to pText
   end if
end ecSetStatus

command ecLog pMsg
   if there is no field "ecLog" then
      exit ecLog
   end if
   put pMsg & return after field "ecLog"
   set the vscroll of field "ecLog" to the formattedHeight of field "ecLog"
end ecLog

function ecTrim pText
   return word 1 to -1 of pText
end ecTrim
