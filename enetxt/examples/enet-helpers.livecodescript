script "enetHelpers"

-- enet-helpers.livecodescript - the script-side poll dispatcher and sugar for
-- enetxt. Insert this script into the message path (e.g. `start using stack
-- "enetHelpers"` or as a behavior) so any stack can drive ENet with plain
-- event handlers instead of a manual poll loop.
--
-- THE MODEL, which this loop embodies: PUMP OR NOTHING. ENet has no threads;
-- connects, sends, retransmissions, pings, and receives ALL progress inside
-- enPoll. So this timer loop is not a convenience - it is the transport's
-- heartbeat, and its interval is the latency floor (16-33 ms feels real-time;
-- 100+ ms is fine for chat-grade traffic). One enPoll call per host per tick
-- drains every pending event in ONE FFI round-trip.
--
-- Unlike the datachannel sibling, polling here is PER HOST (an app can run a
-- server host and a client host at once - the LAN chat demo does). Register
-- each host with enStartPolling; each tick services every registered host and
-- dispatches its events to the target:
--   enetConnect     pEvent["host"], ["peer"], ["address"], ["data"]
--   enetDisconnect  pEvent["host"], ["peer"], ["data"]
--   enetReceive     pEvent["host"], ["peer"], ["channel"], ["payload"] (Data)
--   enetError       pEvent["host"], ["error"] (+["peer"] when known)
-- plus a catch-all "enetEvent" fired for EVERY event.

-- script-local poll state (declared at top; LiveCode Script script-locals)
local sPollHosts        -- comma list of host handles being pumped
local sPollTarget       -- object that receives the semantic event messages
local sPollInterval     -- milliseconds between drains (the latency knob)
local sPolling          -- "true" while the timer loop is armed

-- enStartPolling HOST, TARGET, INTERVALMS
-- Add HOST to the pump set and (first call) arm the loop. TARGET empty means
-- the current card; INTERVALMS defaults to 33 (about 30 Hz). One target and
-- one interval serve every registered host (last caller wins).
command enStartPolling pHost, pTarget, pIntervalMs
   if pHost is empty or pHost is 0 then
      exit enStartPolling
   end if
   if pHost is not among the items of sPollHosts then
      if sPollHosts is empty then
         put pHost into sPollHosts
      else
         put comma & pHost after sPollHosts
      end if
   end if
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
   if sPolling is not "true" then
      put "true" into sPolling
      send "enetPollOnce" to me in 0 milliseconds
   end if
end enStartPolling

-- enStopPolling [HOST]
-- Remove one host from the pump set, or stop everything when HOST is empty.
-- Stopping the pump FREEZES the transport for the remaining app lifetime
-- (nothing progresses unpumped) - stop only what you are done with.
command enStopPolling pHost
   local tI, tNew
   if pHost is empty then
      put empty into sPollHosts
      put "false" into sPolling
      exit enStopPolling
   end if
   put empty into tNew
   repeat for each item tI in sPollHosts
      if tI is not pHost then
         if tNew is empty then
            put tI into tNew
         else
            put comma & tI after tNew
         end if
      end if
   end repeat
   put tNew into sPollHosts
   if sPollHosts is empty then
      put "false" into sPolling
   end if
end enStopPolling

-- One pump pass: enPoll each registered host, dispatch each event by name,
-- then reschedule.
command enetPollOnce
   local tHost, tEvents, tEvent, tName
   if sPolling is not "true" then
      exit enetPollOnce
   end if
   repeat for each item tHost in sPollHosts
      put enPoll(tHost) into tEvents
      repeat for each element tEvent in tEvents
         put tEvent["name"] into tName
         if tName is not empty then
            dispatch tName to sPollTarget with tEvent
         end if
         -- also fire a catch-all so one handler can observe the whole stream
         dispatch "enetEvent" to sPollTarget with tEvent
      end repeat
   end repeat
   send "enetPollOnce" to me in (sPollInterval) milliseconds
end enetPollOnce

-- enStateName N -- map a kPeerState* value (enPeerStatus "state") to a label.
function enStateName pState
   switch pState
      case 0
         return "disconnected"
      case 1
      case 2
      case 3
      case 4
         return "connecting"
      case 5
         return "connected"
      case 6
      case 7
      case 8
         return "disconnecting"
      case 9
         return "zombie"
      default
         return "unknown"
   end switch
end enStateName

-- enFormatBytes N -- a small humaniser for dashboards (KiB/MiB/GiB).
function enFormatBytes pBytes
   local tUnits, tVal, tI
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB,TiB" into tUnits
   put pBytes into tVal
   put 1 into tI
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   set the itemDelimiter to comma
   return (the round of (tVal * 10) / 10) && (item tI of tUnits)
end enFormatBytes
