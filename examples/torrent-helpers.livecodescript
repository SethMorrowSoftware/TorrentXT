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
-- empty, events go to the current card. INTERVALMS defaults to 250. Calling it
-- again while polling re-points the session, target and interval (last caller
-- wins); it does NOT arm a second chain.
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
   -- Arm the chain ONCE - the guard enet-helpers has carried since it was
   -- written, and the one this file lacked. A second chain does not duplicate
   -- EVENTS: each pass drains the whole alert queue in one btPoll (and one
   -- btRp1Poll), so the second chain mostly finds it empty. What doubles,
   -- permanently, is the FFI drain RATE and the timer churn - and neither
   -- chain can be stood down on its own, because both read this one flag.
   if sPolling is not "true" then
      put "true" into sPolling
      -- kick the loop immediately; it reschedules itself
      send "btTorrentPollOnce" to me in 0 milliseconds
   end if
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
   -- ALSO drain the rp1 extension's own event stream (peer up/down, handshake,
   -- message). It is a SEPARATE queue from btPoll and returns empty when rp1 is
   -- not enabled on the session, so this is a harmless no-op for normal apps and
   -- gives rp1 apps the same dispatch-by-name flow (rp1PeerConnected, rp1Handshake,
   -- rp1Message, rp1PeerDisconnected).
   put btRp1Poll(sPollSession) into tEvents
   repeat for each element tEvent in tEvents
      put tEvent["name"] into tName
      if tName is not empty then
         dispatch tName to sPollTarget with tEvent
      end if
      dispatch "torrentEvent" to sPollTarget with tEvent
   end repeat
   -- reschedule (libtorrent keeps buffering between drains)
   send "btTorrentPollOnce" to me in (sPollInterval) milliseconds
end btTorrentPollOnce

-- btFormatBytes N -- a small humaniser for dashboards (KiB/MiB/GiB).
function btFormatBytes pBytes
   local tUnits, tVal, tI, tSavedDelim, tOut
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB,TiB" into tUnits
   put pBytes into tVal
   put 1 into tI
   -- TWO reads need the comma, not one: the loop guard COUNTS the units and
   -- the return picks one. The `set` used to sit BETWEEN them, so the guard
   -- counted under whatever delimiter was in force rather than the one this
   -- data is written in - and under any delimiter but comma that string is a
   -- ONE-item list, so the loop never runs and a gigabyte reports itself in
   -- bytes. Set once before the FIRST read; restore before returning, since a
   -- humaniser has no business changing its caller's delimiter (the family's
   -- LCS gotcha: itemDelimiter is global mutable state - set it immediately
   -- before use, and put back what you found). Not a precaution: holde-em's
   -- v0.15 audit found three real leaks of exactly this shape - heStackFolder
   -- returning with the delimiter left at a slash, heSwapExt at a dot - and
   -- answered all three with save-and-restore.
   put the itemDelimiter into tSavedDelim
   set the itemDelimiter to comma
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   put (the round of (tVal * 10) / 10) && (item tI of tUnits) into tOut
   set the itemDelimiter to tSavedDelim
   return tOut
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
