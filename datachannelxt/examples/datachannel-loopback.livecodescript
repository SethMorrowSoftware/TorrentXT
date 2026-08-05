script "DataChannelLoopback"

-- datachannel-loopback.livecodescript - the zero-infrastructure first-run
-- demo for DataChannelXT: TWO WebRTC peers living in ONE stack, their
-- signaling shuttled directly in script (no server, no network beyond the
-- machine itself), one data channel between them, and a chat pane for each.
-- It proves the whole pipeline - offer/answer, ICE, DTLS, SCTP, the channel,
-- both message kinds - before you ever build real signaling.
--
-- WHAT TO LOOK AT: the dcLocalDescription / dcLocalCandidate handlers ARE a
-- complete signaling implementation - each one just delivers the artifact to
-- the OTHER peer. In a real app, replace those two `dcSetRemoteDescription` /
-- `dcAddRemoteCandidate` calls with "send it to the far machine somehow"
-- (TorrentXT DHT rendezvous, a paste, anything) and the rest is identical.
--
-- USAGE: put this script and the DataChannelXT extension in place, then:
--     start using stack "dataChannelHelpers"   -- the poll dispatcher
--     go stack "DataChannelLoopback"           -- builds its UI on first open
-- Click "Connect", watch the states walk to connected + open, then type in
-- either pane's field and press Return.
--
-- The UI is SELF-BUILDING and idempotent (the family pattern): opening the
-- stack creates the controls once; a rebuild is guarded by an existence check.

local sPeerA          -- peer handle A (the offerer)
local sPeerB          -- peer handle B (the answerer)
local sChanA          -- A's channel handle (created -> triggers the offer)
local sChanB          -- B's channel handle (learned from dcChannelIncoming)

on openStack
   buildLoopbackUi
   dcStartPolling the long id of this card, 33
end openStack

on closeStack
   dcStopPolling
   dcCleanup()
end closeStack

-- ---------------------------------------------------------------- the UI --

command buildLoopbackUi
   if there is a field "statusA" then
      exit buildLoopbackUi
   end if
   lock screen
   set the width of this stack to 640
   set the height of this stack to 460
   set the name of this card to "loopback"

   create button "Connect"
   set the rect of button "Connect" to 20,16,140,44

   create button "Disconnect"
   set the rect of button "Disconnect" to 150,16,280,44

   create field "statusA"
   set the rect of field "statusA" to 20,56,310,84
   set the lockText of field "statusA" to true
   put "A: idle" into field "statusA"

   create field "statusB"
   set the rect of field "statusB" to 330,56,620,84
   set the lockText of field "statusB" to true
   put "B: idle" into field "statusB"

   create field "logA"
   set the rect of field "logA" to 20,94,310,380
   set the lockText of field "logA" to true

   create field "logB"
   set the rect of field "logB" to 330,94,620,380
   set the lockText of field "logB" to true

   create field "sayA"
   set the rect of field "sayA" to 20,390,310,418

   create field "sayB"
   set the rect of field "sayB" to 330,390,620,418

   unlock screen
end buildLoopbackUi

-- ------------------------------------------------------------- lifecycle --

on mouseUp
   switch the short name of the target
      case "Connect"
         connectLoopback
         break
      case "Disconnect"
         disconnectLoopback
         break
   end switch
   pass mouseUp
end mouseUp

command connectLoopback
   if sPeerA is not empty and sPeerA is not 0 then
      exit connectLoopback -- already connected
   end if
   -- loopback needs no ICE servers: host candidates carry it
   put dcCreatePeer("") into sPeerA
   put dcCreatePeer("") into sPeerB
   if sPeerA is 0 or sPeerB is 0 then
      answer "DataChannelXT could not create a peer:" && dcLastError()
      exit connectLoopback
   end if
   -- creating the first channel starts the negotiation; everything else
   -- arrives as events below
   put dcCreateChannel(sPeerA, "loopback-chat") into sChanA
   put empty into sChanB
   put "A: connecting..." into field "statusA"
   put "B: waiting for offer..." into field "statusB"
end connectLoopback

command disconnectLoopback
   if sPeerA is not empty and sPeerA is not 0 then
      dcFreePeer(sPeerA)
   end if
   if sPeerB is not empty and sPeerB is not 0 then
      dcFreePeer(sPeerB)
   end if
   put empty into sPeerA
   put empty into sPeerB
   put empty into sChanA
   put empty into sChanB
   put "A: idle" into field "statusA"
   put "B: idle" into field "statusB"
end disconnectLoopback

-- ------------------------------------------------- signaling, in miniature --
-- These two handlers ARE the signaling layer. Loopback edition: hand each
-- artifact straight to the other peer. Real edition: transmit it instead.

on dcLocalDescription pEvent
   local tDest
   put otherPeer(pEvent["peer"]) into tDest
   if tDest is not empty then
      dcSetRemoteDescription tDest, pEvent["sdp"], pEvent["sdpType"]
      logLine pEvent["peer"], "-> shipped" && pEvent["sdpType"]
   end if
end dcLocalDescription

on dcLocalCandidate pEvent
   local tDest
   put otherPeer(pEvent["peer"]) into tDest
   if tDest is not empty then
      dcAddRemoteCandidate tDest, pEvent["candidate"], pEvent["mid"]
   end if
end dcLocalCandidate

function otherPeer pPeer
   if pPeer is sPeerA then
      return sPeerB
   else if pPeer is sPeerB then
      return sPeerA
   end if
   return empty
end otherPeer

-- ---------------------------------------------------------------- events --

on dcStateChange pEvent
   local tLabel
   put dcStateName(pEvent["state"]) into tLabel
   if pEvent["peer"] is sPeerA then
      put "A:" && tLabel into field "statusA"
   else if pEvent["peer"] is sPeerB then
      put "B:" && tLabel into field "statusB"
   end if
end dcStateChange

on dcChannelIncoming pEvent
   -- B learns its channel handle here (A made its own with dcCreateChannel)
   if pEvent["peer"] is sPeerB then
      put pEvent["channel"] into sChanB
      logLine sPeerB, "incoming channel" && quote & pEvent["label"] & quote
   end if
end dcChannelIncoming

on dcChannelOpen pEvent
   logLine dcChannelPeer(pEvent["channel"]), "channel open - say something!"
end dcChannelOpen

on dcChannelClosed pEvent
   logLine dcChannelPeer(pEvent["channel"]), "channel closed"
end dcChannelClosed

on dcMessage pEvent
   -- text sends arrive under "text"; binary sends under "payload" (a Data)
   if pEvent["text"] is not empty then
      logLine pEvent["peer"], "received:" && pEvent["text"]
   else
      logLine pEvent["peer"], "received" && the number of bytes in pEvent["payload"] && "binary bytes"
   end if
end dcMessage

on dcChannelError pEvent
   logLine pEvent["peer"], "ERROR:" && pEvent["error"]
end dcChannelError

-- ------------------------------------------------------------------ chat --

on returnInField
   local tShort, tText
   put the short name of the target into tShort
   put the text of the target into tText
   if tText is empty then
      exit returnInField
   end if
   if tShort is "sayA" then
      if sChanA is not empty and dcChannelIsOpen(sChanA) then
         dcSendText(sChanA, tText)
         logLine sPeerA, "sent:" && tText
         put empty into field "sayA"
      end if
   else if tShort is "sayB" then
      if sChanB is not empty and dcChannelIsOpen(sChanB) then
         dcSendText(sChanB, tText)
         logLine sPeerB, "sent:" && tText
         put empty into field "sayB"
      end if
   end if
end returnInField

command logLine pPeer, pLine
   local tField
   if pPeer is sPeerA then
      put "logA" into tField
   else if pPeer is sPeerB then
      put "logB" into tField
   else
      exit logLine
   end if
   put pLine & return after field tField
   -- keep the tail visible without an every-event relayout storm
   set the vScroll of field tField to the formattedHeight of field tField
end logLine
