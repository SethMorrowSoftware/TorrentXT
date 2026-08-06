script "dataChannelSelfTest"

-- datachannel-selftest.livecodescript - a self-building RUNTIME harness that
-- drives the DataChannelXT public API end to end in OXT and reports PASS /
-- FAIL per handler. This is the OXT-pass companion to the C++ smoke test: the
-- smoke test proves the shim against libdatachannel in CI; this proves the
-- .lcb BINDING (the foreign-decl signatures, the record walkers, the buffer
-- round-trips) actually runs - the one layer CI cannot reach, since OXT has
-- no headless way to compile or run .lcb.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK
-- script (Object > Stack Script), then close+reopen. It builds its own UI,
-- runs the synchronous checks, then a LIVE LOOPBACK (two in-process peers,
-- script-shuttled signaling, a real DTLS/SCTP association on this machine),
-- message round-trips, and teardown - and shows a green/red list. Needs the
-- installed org.openxtalk.library.datachannel extension.
--
-- WHAT IT CHECKS: every public handler returns a sane value; stale handles
-- are harmless; the loopback connects; text and binary messages round-trip
-- byte-for-byte; the drain's arrays carry the documented keys; close/free/
-- cleanup are idempotent. The async phase has a deadline - a machine that
-- blocks ALL UDP (even to itself) fails the loopback section with a note
-- rather than hanging.

-- ---- state -------------------------------------------------------------------
local sTotal, sPassed, sFailed
local sResultText       -- the accumulated PASS/FAIL/section lines
local sPeerA, sPeerB    -- the loopback peers
local sChanA, sChanB    -- A's channel; B's (learned from dcChannelIncoming)
local sAOpen, sBOpen    -- "true" once each side's channel open arrived
local sGotText          -- the text B received
local sGotBytes         -- the binary payload A received back (a Data)
local sSentBytes        -- the binary payload B sent (kept for byte-exact compare)
local sDeadline         -- the async phase's drop-dead time (ms clock)
local sPhase            -- "", "opening", "messaging", "done"

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   stBuild
   stRun
end openStack

on closeStack
   stCleanup
end closeStack

on mouseUp
   if the short name of the target is "stRerun" then
      stCleanup
      stRun
   else
      pass mouseUp
   end if
end mouseUp

-- ---- self-building UI (idempotent) -------------------------------------------
command stBuild
   if there is a field "stResults" then
      exit stBuild
   end if
   lock screen
   set the width of this stack to 660
   set the height of this stack to 620
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "DataChannelXT - API Self-Test"
   stMakeLabel "stTitle", "  DataChannelXT - API Self-Test", "0,0,660,30", 15
   set the opaque of field "stTitle" to true
   set the backgroundColor of field "stTitle" to "44,90,160"
   set the foregroundColor of field "stTitle" to "255,255,255"
   set the textStyle of field "stTitle" to "bold"
   stMakeLabel "stSummary", "Running...", "16,38,520,66", 13
   set the textStyle of field "stSummary" to "bold"
   stMakeButton "stRerun", "Re-run", "566,38,644,64"
   stMakeList "stResults", "16,72,644,604"
   set the textFont of field "stResults" to "Courier"
   set the textSize of field "stResults" to 11
   unlock screen
end stBuild

command stMakeLabel pName, pText, pRect, pSize
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
end stMakeLabel

command stMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end stMakeButton

command stMakeList pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
end stMakeList

-- ---- assertion plumbing ------------------------------------------------------
command stAssert pName, pPass
   add 1 to sTotal
   if pPass then
      add 1 to sPassed
      put "PASS  " & pName & return after sResultText
   else
      add 1 to sFailed
      put "FAIL  " & pName & return after sResultText
   end if
end stAssert

command stSection pTitle
   put return & "== " & pTitle & " ==" & return after sResultText
end stSection

command stNote pText
   put "      " & pText & return after sResultText
end stNote

command stShow
   put sResultText into field "stResults"
   put sPassed & " passed, " & sFailed & " failed, " & sTotal & " total" into field "stSummary"
   if sPhase is "done" then
      if sFailed is 0 then
         set the foregroundColor of field "stSummary" to "20,120,40"
      else
         set the foregroundColor of field "stSummary" to "170,30,30"
      end if
   end if
end stShow

-- ---- the run -----------------------------------------------------------------
command stRun
   local tPair
   put 0 into sTotal
   put 0 into sPassed
   put 0 into sFailed
   put empty into sResultText
   put empty into sPhase

   stSection "lifecycle & diagnostics"
   stAssert "dcInit returns 0", dcInit() is 0
   stAssert "dcInit idempotent", dcInit() is 0
   stAssert "dcLibraryVersion mentions libdatachannel", dcLibraryVersion() contains "libdatachannel"
   dcClearError
   stAssert "dcLastError empty after clear", dcLastError() is empty

   stSection "stale handles are harmless no-ops"
   stAssert "dcClosePeer(0) errors", dcClosePeer(0) < 0
   stAssert "dcPeerState(0) is -1", dcPeerState(0) is -1
   stAssert "dcGatheringState(0) is -1", dcGatheringState(0) is -1
   stAssert "dcLocalDescription(0) empty", dcLocalDescription(0) is empty
   -- an Array crosses from LCB; LiveCode Script has NO `{}` literal, and a
   -- bare `is empty` on an array is vacuously true (arrays stringify to
   -- empty) - so emptiness is asserted by counting keys of a LOCAL (a
   -- function result cannot be subscripted or keyed directly in LCS either)
   put dcSelectedCandidatePair(0) into tPair
   stAssert "dcSelectedCandidatePair(0) empty", the number of lines of the keys of tPair is 0
   stAssert "dcCreateChannel(0) is 0", dcCreateChannel(0, "x") is 0
   stAssert "dcSendText(0) errors", dcSendText(0, "x") < 0
   stAssert "dcChannelLabel(0) empty", dcChannelLabel(0) is empty
   stAssert "dcChannelStreamId(0) is -1", dcChannelStreamId(0) is -1
   stAssert "dcChannelIsOpen(0) is false", dcChannelIsOpen(0) is false
   stAssert "dcChannelPeer(0) is 0", dcChannelPeer(0) is 0
   stAssert "dcBufferedAmount(0) is -1", dcBufferedAmount(0) is -1
   dcFreePeer(0)      -- must not crash
   dcFreeChannel(0)   -- must not crash
   stAssert "dcFreePeer/dcFreeChannel(0) survived", true
   stAssert "dcSendText(0) left a last-error", dcLastError() is not empty
   dcClearError

   stSection "loopback: create + negotiate (async)"
   put dcCreatePeer("") into sPeerA
   put dcCreatePeer("") into sPeerB
   stAssert "dcCreatePeer A > 0", sPeerA > 0
   stAssert "dcCreatePeer B > 0", sPeerB > 0
   stAssert "peers distinct", sPeerA is not sPeerB
   stAssert "new peer state is new/connecting", dcPeerState(sPeerA) >= 0
   put dcCreateChannel(sPeerA, "selftest") into sChanA
   stAssert "dcCreateChannel > 0", sChanA > 0
   stAssert "dcChannelPeer maps back", dcChannelPeer(sChanA) is sPeerA
   put empty into sChanB
   put empty into sAOpen
   put empty into sBOpen
   put empty into sGotText
   put empty into sGotBytes
   put empty into sSentBytes
   put "opening" into sPhase
   put the milliseconds + 20000 into sDeadline
   stShow
   send "stPump" to me in 33 milliseconds
end stRun

-- One poll pass of the async phase; reschedules itself until done/deadline.
command stPump
   local tEvents, tEvent, tDest, tPair
   if sPhase is "done" or sPhase is empty then
      exit stPump
   end if
   put dcPoll() into tEvents
   repeat for each element tEvent in tEvents
      -- the in-script signaling shuttle (the whole point of the loopback)
      if tEvent["name"] is "dcLocalDescription" then
         put stOtherPeer(tEvent["peer"]) into tDest
         if tDest is not empty then
            dcSetRemoteDescription tDest, tEvent["sdp"], tEvent["sdpType"]
         end if
      else if tEvent["name"] is "dcLocalCandidate" then
         put stOtherPeer(tEvent["peer"]) into tDest
         if tDest is not empty then
            dcAddRemoteCandidate tDest, tEvent["candidate"], tEvent["mid"]
         end if
      else if tEvent["name"] is "dcChannelIncoming" then
         if tEvent["peer"] is sPeerB then
            put tEvent["channel"] into sChanB
         end if
      else if tEvent["name"] is "dcChannelOpen" then
         if tEvent["channel"] is sChanA then
            put "true" into sAOpen
         else if sChanB is not empty and tEvent["channel"] is sChanB then
            put "true" into sBOpen
         end if
      else if tEvent["name"] is "dcMessage" then
         if tEvent["text"] is not empty then
            put tEvent["text"] into sGotText
         else
            put tEvent["payload"] into sGotBytes
         end if
      end if
   end repeat

   if sPhase is "opening" then
      if sAOpen is "true" and sBOpen is "true" then
         stAssert "loopback connected + both channels open", true
         stAssert "incoming label is selftest", dcChannelLabel(sChanB) is "selftest"
         stAssert "peer A connected", dcPeerState(sPeerA) is 2
         stAssert "dcChannelIsOpen(A)", dcChannelIsOpen(sChanA) is true
         stAssert "stream id assigned", dcChannelStreamId(sChanA) >= 0
         stAssert "negotiated max message > 0", dcChannelMaxMessage(sChanA) > 0
         stAssert "buffered amount >= 0", dcBufferedAmount(sChanA) >= 0
         -- keyed access needs a local (LCS cannot subscript a function result)
         put dcSelectedCandidatePair(sPeerA) into tPair
         stAssert "selected pair has localCandidate", tPair["localCandidate"] is not empty
         stAssert "dcSendText returns 0", dcSendText(sChanA, "hello oxt") is 0
         put "messaging" into sPhase
      end if
   else if sPhase is "messaging" then
      -- a distinct phase per step, so a slow delivery cannot re-fire the send
      -- (and re-count the assertions) on every 33 ms pump pass
      if sGotText is not empty then
         stAssert "text arrived intact", sGotText is "hello oxt"
         -- REAL embedded NUL/0x01 bytes (LCS string literals have no escape
         -- syntax - a "\0" would be two ordinary characters), so this proves
         -- a Data crosses unmangled, not merely that ASCII survives
         put textEncode("binary", "UTF-8") & numToByte(0) & textEncode("byte", "UTF-8") \
               & numToByte(1) & textEncode("round-trip", "UTF-8") into sSentBytes
         stAssert "dcSendData returns 0", dcSendData(sChanB, sSentBytes) is 0
         put "binary-wait" into sPhase
      end if
   else if sPhase is "binary-wait" then
      if sGotBytes is not empty then
         -- byte-exact: `is` is case-insensitive by default, which would let
         -- 0x41 match 0x61 inside binary data
         set the caseSensitive to true
         stAssert "binary arrived byte-for-byte (incl. NUL)", sGotBytes is sSentBytes
         stFinish
         exit stPump
      end if
   end if

   if the milliseconds > sDeadline then
      stAssert "async loopback finished before the deadline", false
      stNote "UDP to this machine's own address may be blocked; see docs."
      stFinish
      exit stPump
   end if
   stShow
   send "stPump" to me in 33 milliseconds
end stPump

function stOtherPeer pPeer
   if pPeer is sPeerA then
      return sPeerB
   else if pPeer is sPeerB then
      return sPeerA
   end if
   return empty
end stOtherPeer

command stFinish
   stSection "teardown"
   stAssert "dcCloseChannel returns 0", dcCloseChannel(sChanA) is 0
   dcFreeChannel(sChanA)
   dcFreeChannel(sChanA)   -- double free: no-op
   stAssert "double dcFreeChannel survived", true
   dcFreePeer(sPeerA)
   dcFreePeer(sPeerB)
   dcFreePeer(sPeerA)      -- double free: no-op
   stAssert "freed peer answers -1", dcPeerState(sPeerA) is -1
   stAssert "dcCleanup returns 0", dcCleanup() is 0
   stAssert "dcCleanup idempotent", dcCleanup() is 0
   put empty into sPeerA
   put empty into sPeerB
   put "done" into sPhase
   stShow
end stFinish

command stCleanup
   put "done" into sPhase
   if sPeerA is not empty and sPeerA is not 0 then
      dcFreePeer(sPeerA)
   end if
   if sPeerB is not empty and sPeerB is not 0 then
      dcFreePeer(sPeerB)
   end if
   put empty into sPeerA
   put empty into sPeerB
   dcCleanup()
end stCleanup
