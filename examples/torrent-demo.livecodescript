script "torrentDemo"

-- torrent-demo.livecodescript - the smallest end-to-end TorrentXT app: start a
-- session, add a magnet, watch progress via the poll dispatcher, finish, and
-- (critically) shut the session down on close. Attach as a stack script over a
-- card holding fields "magnet", "savepath", "status" and a button per command.
--
-- Pair this with torrent-helpers.livecodescript in the message path
-- (`start using stack "torrentHelpers"`), which supplies btStartPolling and the
-- semantic dispatch.

local sSession          -- the one live session handle
local sActiveTorrent    -- the torrent we are tracking in the dashboard

-- ------------------------------------------------------------ lifecycle
on openStack
   -- The native library stays loaded across stack opens and permits only ONE live
   -- session (there is no deterministic unload hook - plan section 4.2). So
   -- re-opening this stack without a clean close would otherwise hit "a session is
   -- already live". ensureSession adopts the session we started last time instead
   -- of blindly starting a second one.
   ensureSession
   if sSession is empty or sSession is 0 then
      exit openStack
   end if
   -- drive events to this card; 250 ms drain is plenty for a UI
   btStartPolling sSession, the long id of this card, 250
   -- low-rate dashboard refresh (<= 4 Hz), the cheap way to show progress
   send "refreshDashboard" to me in 500 milliseconds
end openStack

-- Acquire THE session: reuse the one we remember if it is still live in the
-- loaded library, otherwise start a fresh one. The handle is kept in the stack
-- custom property `uSession` so it survives a script-local reset (e.g. an edit +
-- recompile that does not fire closeStack). A remembered handle is probed with a
-- cheap setting write - btSetBool returns 0 only for a live session - so a stale
-- handle from a previous IDE run is harmlessly rejected and we start clean.
command ensureSession
   local tRemembered
   put the uSession of this stack into tRemembered
   if tRemembered is a number and tRemembered > 0 \
         and btSetBool(tRemembered, "enable_dht", true) is 0 then
      put tRemembered into sSession
   else
      btStartSession  -- verifies the ABI; returns 0 + sets btLastError on failure
      put the result into sSession
      if sSession is 0 then
         answer "TorrentXT failed to start:" && btLastError()
         set the uSession of this stack to empty
         exit ensureSession
      end if
      btSetBool sSession, "enable_dht", true
      set the uSession of this stack to sSession
   end if
   -- a sane default that is cheap to (re)assert whether adopted or fresh
   btSetBool sSession, "enable_lsd", true
end ensureSession

on closeStack
   -- MUST shut down explicitly: there is no deterministic extension-unload hook
   -- (plan section 4.2). Stop polling first, then pause/flush/destroy the session,
   -- and forget the remembered handle so the next open starts clean.
   btStopPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   put empty into sActiveTorrent
   set the uSession of this stack to empty
end closeStack

-- ------------------------------------------------------------ commands
command addMagnet
   local tHandle
   if sSession is 0 or sSession is empty then
      answer "No session."
      exit addMagnet
   end if
   btAddMagnet sSession, field "magnet", field "savepath"
   put the result into tHandle
   if tHandle is 0 then
      answer "Add failed:" && btLastError()
   else
      put tHandle into sActiveTorrent
      put "Added; fetching metadata..." into field "status"
   end if
end addMagnet

command pauseActive
   if sActiveTorrent is not empty then
      btPause sActiveTorrent
   end if
end pauseActive

command resumeActive
   if sActiveTorrent is not empty then
      btResume sActiveTorrent
   end if
end resumeActive

-- ------------------------------------------------------------ event handlers
-- (these names are the semantic messages the poll dispatcher sends)
on metadataReceived pEvent
   put "Metadata:" && pEvent["torrentName"] into field "status"
end metadataReceived

on torrentFinished pEvent
   put "Finished torrent" && pEvent["torrent"] into field "status"
end torrentFinished

on torrentError pEvent
   put "Error:" && pEvent["errorMessage"] into field "status"
end torrentError

-- ------------------------------------------------------------ dashboard
-- The right way to show progress: a low-rate poll of the one-call status
-- snapshot, NOT a redraw per pieceFinished event (single-thread playbook).
command refreshDashboard
   local tStatus, tPct, tLine
   if sActiveTorrent is not empty then
      put btTorrentStatus(sActiveTorrent) into tStatus
      put (the round of (tStatus["progress"] * 1000) / 10) into tPct
      put tStatus["name"] && "-" && btStateName(tStatus["state"]) into tLine
      put tLine & " - " & tPct & "% - down" && btFormatBytes(tStatus["downloadRate"]) & "/s" \
         into field "status"
   end if
   if sSession is not empty and sSession is not 0 then
      send "refreshDashboard" to me in 500 milliseconds
   end if
end refreshDashboard
