script "enetSelfTest"

-- enet-selftest.livecodescript - a self-building RUNTIME harness that drives
-- the enetxt public API end to end in OXT and reports PASS / FAIL per
-- handler. This is the OXT-pass companion to the C++ smoke test: the smoke
-- test proves the shim against ENet in CI; this proves the .lcb BINDING (the
-- foreign-decl signatures, the record walkers, the buffer round-trips)
-- actually runs - the one layer CI cannot reach, since OXT has no headless
-- way to compile or run .lcb.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK
-- script (Object > Stack Script), then close+reopen. It builds its own UI,
-- runs the synchronous checks, then a LIVE LOOPBACK (a server host and a
-- client host in this one process, 127.0.0.1), message round-trips, and
-- teardown - and shows a green/red list. Needs the installed
-- org.openxtalk.library.enet extension.
--
-- The LCS lessons this file was written under (CLAUDE.md gotchas 9-10): no
-- braces, no subscripted function results, array emptiness by counting keys,
-- binary payloads built with numToByte (string literals have no escapes),
-- byte-exact compares under caseSensitive, and zero-argument calls BARE in
-- statement position.

-- ---- state -------------------------------------------------------------------
local sTotal, sPassed, sFailed
local sResultText       -- the accumulated PASS/FAIL/section lines
local sServer, sClient  -- the two loopback hosts
local sClientPeer       -- client side: handle from enConnect
local sServerPeer       -- server side: handle born in its enetConnect event
local sGotEcho          -- "true" once the client received the echo
local sGotUnseq         -- "true" once the client received the channel-1 line
local sGotBinary        -- the binary payload the server received (a Data)
local sSentBinary       -- what the client sent (kept for byte-exact compare)
local sSawServerDisc    -- "true" once the server drained enetDisconnect
local sDeadline         -- the async phase's drop-dead time (ms clock)
local sPhase            -- "", "connecting", "messaging", "binary", "closing", "done"

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
   set the title of this stack to "enetxt - API Self-Test"
   stMakeLabel "stTitle", "  enetxt - API Self-Test", "0,0,660,30", 15
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
   local tPS, tHS, tBig
   put 0 into sTotal
   put 0 into sPassed
   put 0 into sFailed
   put empty into sResultText
   put empty into sPhase

   stSection "lifecycle & diagnostics"
   stAssert "enInitialize returns 0", enInitialize() is 0
   stAssert "enInitialize idempotent", enInitialize() is 0
   stAssert "enLibraryVersion names enet", enLibraryVersion() begins with "enet "
   enClearError
   stAssert "enLastError empty after clear", enLastError() is empty

   stSection "stale handles are harmless no-ops"
   stAssert "enSend(0) errors", enSend(0, 0, stTinyData(), 0) < 0
   stAssert "enDisconnect(0) errors", enDisconnect(0, 0) < 0
   put enPeerStatus(0) into tPS
   stAssert "enPeerStatus(0) empty", the number of lines of the keys of tPS is 0
   put enHostStatus(0) into tHS
   stAssert "enHostStatus(0) empty", the number of lines of the keys of tHS is 0
   stAssert "enHostDestroy(0) is a no-op 0", enHostDestroy(0) is 0
   stAssert "enConnect on stale host is 0", enConnect(0, "127.0.0.1", 1, 1, 0) is 0
   stAssert "enFlush(0) errors", enFlush(0) < 0

   stSection "loopback: hosts + connect (async)"
   put enHostCreateServer("127.0.0.1", 27098, 8, 2, 0, 0) into sServer
   stAssert "server host created", sServer > 0
   put enHostCreateClient(1, 2, 0, 0) into sClient
   stAssert "client host created", sClient > 0
   put enConnect(sClient, "127.0.0.1", 27098, 2, 42) into sClientPeer
   stAssert "enConnect returns a peer handle", sClientPeer > 0
   stAssert "send on out-of-range channel is -3", enSend(sClientPeer, 5, stTinyData(), 0) is -3
   -- the budget: one byte over must refuse with -4, never truncate
   put stRepeatByte(65, 60001) into tBig
   stAssert "send over the budget is -4", enSend(sClientPeer, 0, tBig, 0) is -4

   put empty into sServerPeer
   put empty into sGotEcho
   put empty into sGotUnseq
   put empty into sGotBinary
   put empty into sSentBinary
   put empty into sSawServerDisc
   put "connecting" into sPhase
   put the milliseconds + 15000 into sDeadline
   stShow
   send "stPump" to me in 33 milliseconds
end stRun

-- One pump pass over BOTH hosts; reschedules itself until done/deadline.
-- (The selftest drives enPoll directly - the helpers stack is exercised by
-- the demo; here the binding itself is under test.)
command stPump
   local tEvents, tEvent, tPS
   if sPhase is "done" or sPhase is empty then
      exit stPump
   end if
   put enPoll(sServer) into tEvents
   repeat for each element tEvent in tEvents
      stHandleServer tEvent
   end repeat
   put enPoll(sClient) into tEvents
   repeat for each element tEvent in tEvents
      stHandleClient tEvent
   end repeat

   if sPhase is "connecting" then
      if sServerPeer is not empty and sGotEcho is empty then
         -- connected both ways; the message flow was kicked in the handlers
         put "messaging" into sPhase
      end if
   else if sPhase is "messaging" then
      if sGotEcho is "true" and sGotUnseq is "true" then
         stAssert "echo + broadcast both arrived", true
         -- peer status while connected
         put enPeerStatus(sClientPeer) into tPS
         stAssert "peer state is connected (5)", tPS["state"] is 5
         stAssert "peer status names the server port", tPS["address"] is "127.0.0.1:27098"
         stAssert "tuning setters return 0", enSetPeerPingInterval(sClientPeer, 250) is 0
         -- binary with REAL embedded NUL/0x01 bytes, byte-exact both ways
         put textEncode("bin", "utf-8") & numToByte(0) & numToByte(1) \
               & textEncode("tail", "utf-8") into sSentBinary
         stAssert "enSend binary returns 0", enSend(sClientPeer, 1, sSentBinary, 0) is 0
         put "binary" into sPhase
      end if
   else if sPhase is "binary" then
      if sGotBinary is not empty then
         set the caseSensitive to true
         stAssert "binary arrived byte-for-byte (incl. NUL)", sGotBinary is sSentBinary
         stAssert "enDisconnect returns 0", enDisconnect(sClientPeer, 7) is 0
         put "closing" into sPhase
      end if
   else if sPhase is "closing" then
      if sSawServerDisc is "true" then
         stFinish
         exit stPump
      end if
   end if

   if the milliseconds > sDeadline then
      stAssert "async loopback finished before the deadline", false
      stNote "UDP to 127.0.0.1 may be blocked on this machine; see docs."
      stFinish
      exit stPump
   end if
   stShow
   send "stPump" to me in 33 milliseconds
end stPump

command stHandleServer pEvent
   local tR
   switch pEvent["name"]
      case "enetConnect"
         put pEvent["peer"] into sServerPeer
         stAssert "server enetConnect carries data 42", pEvent["data"] is 42
         stAssert "server enetConnect names an address", pEvent["address"] begins with "127.0.0.1:"
         break
      case "enetReceive"
         if pEvent["channel"] is 0 then
            -- the hello: echo it back reliably + a channel-1 broadcast
            stAssert "hello payload intact", textDecode(pEvent["payload"], "utf-8") is "hello enet"
            put enSendText(sServerPeer, 0, "echo!", 0) into tR
            stAssert "server echo send returns 0", tR is 0
            put enBroadcastText(sServer, 1, "fanout", 2) into tR
            stAssert "server broadcast returns 0", tR is 0
         else
            -- the binary phase payload arrives on channel 1
            put pEvent["payload"] into sGotBinary
         end if
         break
      case "enetDisconnect"
         put "true" into sSawServerDisc
         stAssert "server enetDisconnect carries data 7", pEvent["data"] is 7
         break
   end switch
end stHandleServer

command stHandleClient pEvent
   local tR
   switch pEvent["name"]
      case "enetConnect"
         stAssert "client enetConnect names the enConnect handle", pEvent["peer"] is sClientPeer
         put enSendText(sClientPeer, 0, "hello enet", 0) into tR
         stAssert "client hello send returns 0", tR is 0
         break
      case "enetReceive"
         if textDecode(pEvent["payload"], "utf-8") is "echo!" then
            put "true" into sGotEcho
            stAssert "echo on channel 0", pEvent["channel"] is 0
         else if textDecode(pEvent["payload"], "utf-8") is "fanout" then
            put "true" into sGotUnseq
            stAssert "broadcast on channel 1", pEvent["channel"] is 1
         end if
         break
   end switch
end stHandleClient

command stFinish
   local tPS
   stSection "retirement + teardown"
   put enPeerStatus(sClientPeer) into tPS
   stAssert "client peer retired after disconnect", the number of lines of the keys of tPS is 0
   stAssert "enHostDestroy(server) is 0", enHostDestroy(sServer) is 0
   stAssert "double destroy is a no-op 0", enHostDestroy(sServer) is 0
   stAssert "enHostDestroy(client) is 0", enHostDestroy(sClient) is 0
   stAssert "enDeinitialize returns 0", enDeinitialize() is 0
   stAssert "extra deinitialize is a no-op 0", enDeinitialize() is 0
   put empty into sServer
   put empty into sClient
   put "done" into sPhase
   stShow
end stFinish

command stCleanup
   put "done" into sPhase
   if sServer is not empty and sServer is not 0 then
      enHostDestroy sServer
   end if
   if sClient is not empty and sClient is not 0 then
      enHostDestroy sClient
   end if
   put empty into sServer
   put empty into sClient
   -- bare command form: OXT cannot compile a zero-argument name() statement;
   -- guarded so closing a stack whose extension is missing (the run already
   -- threw loudly at enInitialize) cannot throw a second time from closeStack
   try
      enDeinitialize
   catch tErr
      -- extension not installed; nothing to release
   end try
end stCleanup

-- ---- small helpers -----------------------------------------------------------
-- One byte of payload (enSend needs a Data; "x" as a literal would be text).
function stTinyData
   return textEncode("x", "utf-8")
end stTinyData

-- pCount copies of byte pCode, built without string-escape folklore.
function stRepeatByte pCode, pCount
   local tOne, tOut, tI
   put numToByte(pCode) into tOne
   put empty into tOut
   -- double up to size, then trim: O(log n) concatenations, not 60001
   put tOne into tOut
   repeat while the number of bytes in tOut < pCount
      put tOut & tOut into tOut
   end repeat
   return byte 1 to pCount of tOut
end stRepeatByte
