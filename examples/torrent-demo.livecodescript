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
   -- btStartSession verifies the ABI internally and refuses a 2nd session.
   btStartSession
   put the result into sSession
   if sSession is 0 then
      answer "TorrentXT failed to start:" && btLastError()
      exit openStack
   end if
   -- a couple of sane defaults; keys map to libtorrent settings_pack names
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   -- drive events to this card; 250 ms drain is plenty for a UI
   btStartPolling sSession, the long id of this card, 250
   -- low-rate dashboard refresh (<= 4 Hz), the cheap way to show progress
   send "refreshDashboard" to me in 500 milliseconds
end openStack

on closeStack
   -- MUST shut down explicitly: there is no deterministic extension-unload hook
   -- (plan §4.2). Stop polling first, then pause/flush/destroy the session.
   btStopPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   put empty into sActiveTorrent
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
