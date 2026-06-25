script "torrentHelpers"

-- torrent-helpers.livecodescript - the script-side poll dispatcher and sugar
-- for TorrentXT (plan section 3). Insert this script into the message path (e.g.
-- `start using stack "torrentHelpers"` or as a behavior) so any stack can drive
-- the engine with plain event handlers instead of a manual poll loop.
--
-- The model (plan section 3, carried verbatim from ShowControl): the engine NEVER
-- calls back into script. libtorrent buffers every event on its own threads;
-- we drain that buffer on a timer with ONE FFI round-trip (btPoll), then `send`
-- one semantic message per event. Throughput and event integrity are
-- independent of the poll cadence - only worst-case latency scales with it - so
-- the interval is a documented latency/CPU knob (250 ms is plenty for a UI;
-- tighten only for very smooth live dashboards).

-- script-local poll state (declared at top; LiveCode Script script-locals)
local sPollSession      -- the session handle currently being polled (0/empty = none)
local sPollTarget       -- object that receives the semantic event messages
local sPollInterval     -- milliseconds between drains (the latency/CPU knob)
local sPolling          -- "true" while the timer loop is armed

-- btStartPolling SESSION, TARGET, INTERVALMS
-- Begin draining SESSION's events and dispatching them to TARGET. If TARGET is
-- empty, events go to the current card. INTERVALMS defaults to 250.
command btStartPolling pSession, pTarget, pIntervalMs
   put pSession into sPollSession
   if pTarget is empty then
      put the long id of this card into sPollTarget
   else
      put pTarget into sPollTarget
   end if
   if pIntervalMs is empty or pIntervalMs is not a number or pIntervalMs < 1 then
      put 250 into sPollInterval
   else
      put pIntervalMs into sPollInterval
   end if
   put "true" into sPolling
   -- kick the loop immediately; it reschedules itself
   send "btTorrentPollOnce" to me in 0 milliseconds
end btStartPolling

-- Stop the timer loop. Safe to call when not polling.
command btStopPolling
   put "false" into sPolling
end btStopPolling

-- One drain pass: pull all pending events with a single btPoll, dispatch each,
-- then reschedule. btPoll returns a list of event arrays (see the key list in
-- docs/api-reference.md); each array carries a "name" (the semantic message)
-- and a "torrent" handle plus event-specific keys.
command btTorrentPollOnce
   local tEvents, tEvent, tName
   if sPolling is not "true" then
      exit btTorrentPollOnce
   end if
   if sPollSession is empty or sPollSession is 0 then
      exit btTorrentPollOnce
   end if
   put btPoll(sPollSession) into tEvents
   repeat for each element tEvent in tEvents
      put tEvent["name"] into tName
      if tName is not empty then
         dispatch tName to sPollTarget with tEvent
      end if
      -- also fire a catch-all so one handler can observe the whole stream
      dispatch "torrentEvent" to sPollTarget with tEvent
   end repeat
   -- reschedule (libtorrent keeps buffering between drains)
   send "btTorrentPollOnce" to me in (sPollInterval) milliseconds
end btTorrentPollOnce

-- btFormatBytes N -- a small humaniser for dashboards (KiB/MiB/GiB).
function btFormatBytes pBytes
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
end btFormatBytes

-- btStateName N -- map a libtorrent torrent_status::state_t int to a label.
function btStateName pState
   switch pState
      case 1
         return "checking"
      case 2
         return "fetching metadata"
      case 3
         return "downloading"
      case 4
         return "finished"
      case 5
         return "seeding"
      case 7
         return "checking resume"
      default
         return "queued"
   end switch
end btStateName
