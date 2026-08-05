script "dataChannelHelpers"

-- datachannel-helpers.livecodescript - the script-side poll dispatcher and
-- sugar for DataChannelXT. Insert this script into the message path (e.g.
-- `start using stack "dataChannelHelpers"` or as a behavior) so any stack can
-- drive WebRTC data channels with plain event handlers instead of a manual
-- poll loop.
--
-- The model (carried from TorrentXT/ShowControl): the engine NEVER calls back
-- into script. libdatachannel fires its callbacks on its own threads; the
-- native shim queues every event; we drain that queue on a timer with ONE FFI
-- round-trip (dcPoll), then `send` one semantic message per event. Throughput
-- and event integrity are independent of the poll cadence - only worst-case
-- latency scales with it - so the interval is a documented latency/CPU knob.
-- Data channels are REAL-TIME transport: poll at 16-33 ms for a live feel
-- (games, cursors), 100+ ms for chat-grade traffic.
--
-- The messages dispatched to the target (each with the event array as its
-- parameter; keys per docs/api-reference.md):
--   dcLocalDescription  pEvent["peer"], ["sdp"], ["sdpType"] - SHIP THESE to
--   dcLocalCandidate    pEvent["candidate"], ["mid"]           the far peer
--   dcStateChange       pEvent["state"] (see dcStateName below)
--   dcGatheringStateChange  pEvent["state"]
--   dcChannelIncoming   pEvent["channel"], ["label"], ["protocol"]
--   dcChannelOpen       pEvent["channel"] - NOW you can send
--   dcChannelClosed     pEvent["channel"]
--   dcMessage           pEvent["text"] (a text send) OR ["payload"] (binary)
--   dcChannelError      pEvent["error"]
--   dcBufferedLow       pEvent["channel"] - resume sending (backpressure)
--   dcQueueOverflow     pEvent["dropped"] - the app stopped polling too long
-- plus a catch-all "dataChannelEvent" fired for EVERY event.

-- script-local poll state (declared at top; LiveCode Script script-locals)
local sPollTarget       -- object that receives the semantic event messages
local sPollInterval     -- milliseconds between drains (the latency/CPU knob)
local sPolling          -- "true" while the timer loop is armed

-- dcStartPolling TARGET, INTERVALMS
-- Begin draining events and dispatching them to TARGET. If TARGET is empty,
-- events go to the current card. INTERVALMS defaults to 33 (about 30 Hz -
-- real-time feel without measurable CPU cost).
command dcStartPolling pTarget, pIntervalMs
   if pTarget is empty then
      put the long id of this card into sPollTarget
   else
      put pTarget into sPollTarget
   end if
   if pIntervalMs is empty or pIntervalMs is not a number or pIntervalMs < 1 then
      put 33 into sPollInterval
   else
      put pIntervalMs into sPollInterval
   end if
   put "true" into sPolling
   -- kick the loop immediately; it reschedules itself
   send "dcChannelPollOnce" to me in 0 milliseconds
end dcStartPolling

-- Stop the timer loop. Safe to call when not polling. (This stops DELIVERY
-- only - the native queue keeps buffering, bounded, until you poll again or
-- call dcCleanup.)
command dcStopPolling
   put "false" into sPolling
end dcStopPolling

-- One drain pass: pull all pending events with a single dcPoll, dispatch
-- each, then reschedule.
command dcChannelPollOnce
   local tEvents, tEvent, tName
   if sPolling is not "true" then
      exit dcChannelPollOnce
   end if
   put dcPoll() into tEvents
   repeat for each element tEvent in tEvents
      put tEvent["name"] into tName
      if tName is not empty then
         dispatch tName to sPollTarget with tEvent
      end if
      -- also fire a catch-all so one handler can observe the whole stream
      dispatch "dataChannelEvent" to sPollTarget with tEvent
   end repeat
   -- reschedule (the native queue keeps buffering between drains)
   send "dcChannelPollOnce" to me in (sPollInterval) milliseconds
end dcChannelPollOnce

-- dcStateName N -- map a kPeerState* int to a label for status displays.
function dcStateName pState
   switch pState
      case 0
         return "new"
      case 1
         return "connecting"
      case 2
         return "connected"
      case 3
         return "disconnected"
      case 4
         return "failed"
      case 5
         return "closed"
      default
         return "unknown"
   end switch
end dcStateName

-- dcGatheringName N -- map a kGathering* int to a label.
function dcGatheringName pState
   switch pState
      case 0
         return "new"
      case 1
         return "gathering"
      case 2
         return "complete"
      default
         return "unknown"
   end switch
end dcGatheringName

-- dcFormatBytes N -- a small humaniser for buffered-amount displays.
function dcFormatBytes pBytes
   local tUnits, tVal, tI
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB" into tUnits
   put pBytes into tVal
   put 1 into tI
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   set the itemDelimiter to comma
   return (the round of (tVal * 10) / 10) && (item tI of tUnits)
end dcFormatBytes
