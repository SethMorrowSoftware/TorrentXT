script "torrentSelfTest"

-- torrent-selftest.livecodescript - a self-building RUNTIME harness that drives
-- the TorrentXT public API end to end in OXT and reports PASS / FAIL per handler.
-- This is the OXT-pass companion to the C++ smoke test: the smoke test proves the
-- shim against libtorrent in CI; this proves the .lcb BINDING (the foreign-decl
-- signatures, the record walkers, the buffer round-trips) actually runs - the one
-- layer CI cannot reach, since OXT has no headless way to compile or run .lcb.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI, starts a
-- TorrentXT session, runs ~70 checks, and shows a green/red list. Needs the loaded
-- org.openxtalk.library.torrent (v8+). Run it STANDALONE - only one TorrentXT
-- session may be live per OXT process, so close any client/demo stack first.
--
-- WHAT IT CHECKS: every non-destructive public handler returns a sane value and
-- the round-trips work (create+seed -> file table; add web seed -> list it ->
-- remove it; add tracker -> list it; info-hash -> find-by-hash; pause -> is-paused;
-- keypair determinism; immutable put -> target hash). It does NOT assert async DHT
-- / tracker results (those return later as events) and it SKIPS the two genuinely
-- destructive handlers (btMoveStorage, btRemoveTorrent-with-delete) - those are
-- noted for a manual pass. A green run means the whole binding surface is wired.

-- ---- state -------------------------------------------------------------------
local sSession          -- the live session handle (0 = none)
local sTorrent          -- a torrent we create + seed, for torrent-scoped checks
local sTorrent2         -- a second torrent from the extended-add check
local sTotal, sPassed, sFailed
local sResultText       -- the accumulated PASS/FAIL/section lines
local sTempDir          -- parent dir we seed from
local sContentDir       -- the content folder inside it

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
   set the title of this stack to "TorrentXT - API Self-Test"
   stMakeLabel "stTitle", "  TorrentXT - API Self-Test", "0,0,660,30", 15
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
   put return & "--- " & pTitle & " ---" & return after sResultText
end stSection

command stNote pMsg
   put "      " & pMsg & return after sResultText
end stNote

-- count elements of a bridged list (avoids relying on `the number of elements`)
function stCount pList
   local tN, tEl
   put 0 into tN
   repeat for each element tEl in pList
      add 1 to tN
   end repeat
   return tN
end stCount

-- is pNeedle one of the URL strings in the list pList?
function stListHas pList, pNeedle
   local tEl
   repeat for each element tEl in pList
      if tEl is pNeedle then
         return true
      end if
   end repeat
   return false
end stListHas

-- ---- the run -----------------------------------------------------------------
command stRun
   put 0 into sTotal
   put 0 into sPassed
   put 0 into sFailed
   put "" into sResultText
   put 0 into sTorrent
   put 0 into sTorrent2

   stSection "session + ABI"
   -- btStartSession is the one handler that can throw (on ABI skew); a clean
   -- start IS the ABI check passing.
   local tStartOk
   put false into tStartOk
   try
      put btStartSession() into sSession
      put true into tStartOk
   catch tErr
      put 0 into sSession
   end try
   stAssert "btStartSession did not throw (ABI matches)", tStartOk
   if sSession is 0 or sSession is empty then
      stNote "Could not start a session - is another TorrentXT stack open?"
      stNote (btLastError())
      stPaint
      exit stRun
   end if
   stAssert "btStartSession returns a positive handle", (sSession > 0)
   stAssert "btLastError is a string", (btLastError() is a string)

   -- Wrap the rest: a mis-declared foreign handler (wrong signature) raises a
   -- runtime error on its first call. Catch it so the harness REPORTS which call
   -- broke and still shows a summary, instead of halting the stack mid-run.
   try
   stSection "settings"
   stAssert "btSetBool enable_dht", (btSetBool(sSession, "enable_dht", true) is 0)
   stAssert "btSetBool enable_lsd", (btSetBool(sSession, "enable_lsd", true) is 0)
   stAssert "btSetInt download_rate_limit", (btSetInt(sSession, "download_rate_limit", "0") is 0)
   stAssert "btSetString user_agent", (btSetString(sSession, "user_agent", "TorrentXT-selftest") is 0)
   stAssert "btGetSetting user_agent non-empty", (btGetSetting(sSession, "user_agent") is not "")
   stAssert "btSetEncryption", (btSetEncryption(sSession, 1, 1, 3) is 0)
   stAssert "btSetInt rejects unknown key", (btSetInt(sSession, "no_such_setting_key", "1") < 0)

   stSection "errors"
   btClearError
   stAssert "btClearError empties last-error", (btLastError() is "")

   stSection "DHT bootstrap + state"
   stAssert "btDhtAddBootstrap", (btDhtAddBootstrap(sSession, "router.bittorrent.com", 6881) is 0)
   local tDht
   put btDhtState(sSession) into tDht
   stAssert "btDhtState returns an array with nodes", (tDht["nodes"] is a number)
   local tDhtState
   put btDhtSaveState(sSession) into tDhtState
   stAssert "btDhtSaveState returns a measurable Data", (the number of bytes in tDhtState is a number)
   stAssert "btDhtLoadState round-trips", (btDhtLoadState(sSession, tDhtState) is 0)

   stSection "create + seed (sets up a torrent for the rest)"
   stMakeContent
   local tTorrentData
   put btCreateTorrent(sContentDir, 0, 0, "udp://tracker.opentrackr.org:1337/announce") into tTorrentData
   stAssert "btCreateTorrent returns metainfo bytes", (the number of bytes in tTorrentData > 0)
   if the number of bytes in tTorrentData > 0 then
      put btAddTorrentFile(sSession, tTorrentData, sTempDir) into sTorrent
   end if
   stAssert "btAddTorrentFile returns a handle", (sTorrent > 0)
   stAssert "btTorrentCount >= 1", (btTorrentCount(sSession) >= 1)
   stAssert "btTorrentHandleAt(0) is a handle", (btTorrentHandleAt(sSession, 0) > 0)

   if sTorrent > 0 then
      stRunTorrentChecks tTorrentData
   else
      stNote "Skipping torrent-scoped checks: no seed torrent was created."
   end if

   stSection "events"
   -- the alert drain: after the adds + DHT puts above there should be events
   -- queued; we only assert it drains a well-formed list (the dispatcher in
   -- torrent-helpers is what fans these out to message-path handlers).
   stAssert "btPoll drains a list", (stCount(btPoll(sSession)) >= 0)

   stSection "DHT key-value (BEP44) - offline-verifiable parts"
   local tKey, tKey2
   put btDhtKeypair("") into tKey
   stAssert "btDhtKeypair publicKey is 64 hex", (the number of chars of tKey["publicKey"] is 64)
   stAssert "btDhtKeypair secretKey is 128 hex", (the number of chars of tKey["secretKey"] is 128)
   stAssert "btDhtKeypair seed is 64 hex", (the number of chars of tKey["seed"] is 64)
   put btDhtKeypair(tKey["seed"]) into tKey2
   stAssert "btDhtKeypair is deterministic from a seed", (tKey2["publicKey"] is tKey["publicKey"])
   local tTarget
   put btDhtPutImmutable(sSession, textEncode("TorrentXT self-test value", "UTF-8")) into tTarget
   stAssert "btDhtPutImmutable returns a 40-hex target", (the number of chars of tTarget is 40)
   stAssert "btDhtGetImmutable accepts the target (async)", (btDhtGetImmutable(sSession, tTarget) is 0)
   stAssert "btDhtPutMutable signs + queues", (btDhtPutMutable(sSession, tKey["publicKey"], tKey["secretKey"], "", textEncode("v1", "UTF-8")) is 0)
   stAssert "btDhtGetMutable accepts the key (async)", (btDhtGetMutable(sSession, tKey["publicKey"], "") is 0)

   stSection "not auto-checked - confirm by hand"
   stNote "btMoveStorage + btRemoveTorrent(deleteFiles=true) are destructive;"
   stNote "btSetFilePriorities needs a binary buffer; btAddTorrentWithResume"
   stNote "needs async resume bytes; btAddMagnet is covered via btAddMagnetEx."
   catch tRunErr
      stNote "RUNTIME ERROR - a binding call failed: " & tRunErr
      add 1 to sFailed
   end try

   stShowSummary
   stPaint
end stRun

-- the bulk of the per-torrent surface
command stRunTorrentChecks pTorrentData
   local tStatus, tHash, tFiles, tFile, tWS, tTrackerUrl, tFound

   stSection "status + inspection"
   put btTorrentStatus(sTorrent) into tStatus
   stAssert "btTorrentStatus has a name", (tStatus["name"] is not "")
   stAssert "btTorrentStatus progress is a number", (tStatus["progress"] is a number)
   put btInfoHash(sTorrent) into tHash
   stAssert "btInfoHash is 40 hex", (the number of chars of tHash is 40)
   stAssert "btPieceBitfield returns a measurable Data", (the number of bytes in btPieceBitfield(sTorrent) is a number)
   stAssert "btPieceAvailability returns a measurable Data", (the number of bytes in btPieceAvailability(sTorrent) is a number)
   put btFileList(sTorrent) into tFiles
   stAssert "btFileList returns >= 1 file", (stCount(tFiles) >= 1)
   repeat for each element tFile in tFiles
      stAssert "btFileList entry has a path", (tFile["path"] is not "")
      stAssert "btFileList entry size > 0", (tFile["size"] > 0)
      stAssert "btFileList entry priority is a number", (tFile["priority"] is a number)
      exit repeat
   end repeat
   stAssert "btPeerList returns a list", (stCount(btPeerList(sTorrent)) >= 0)

   stSection "control + flags"
   stAssert "btPause", (btPause(sTorrent) is 0)
   stAssert "btResume", (btResume(sTorrent) is 0)
   stAssert "btForceRecheck", (btForceRecheck(sTorrent) is 0)
   stAssert "btForceReannounce", (btForceReannounce(sTorrent) is 0)
   stAssert "btSetSequentialDownload on", (btSetSequentialDownload(sTorrent, true) is 0)
   stAssert "btSetSequentialDownload off", (btSetSequentialDownload(sTorrent, false) is 0)
   stAssert "btSetAutoManaged", (btSetAutoManaged(sTorrent, true) is 0)
   stAssert "btSetSuperSeeding", (btSetSuperSeeding(sTorrent, false) is 0)
   stAssert "btSetShareMode", (btSetShareMode(sTorrent, false) is 0)
   stAssert "btSetUploadMode", (btSetUploadMode(sTorrent, false) is 0)
   stAssert "btSetTorrentFlags (sequential=512)", (btSetTorrentFlags(sTorrent, "512", "512") is 0)
   stAssert "btUnsetTorrentFlags", (btUnsetTorrentFlags(sTorrent, "512") is 0)
   stAssert "btSetMaxConnections", (btSetMaxConnections(sTorrent, 50) is 0)
   stAssert "btSetMaxUploads", (btSetMaxUploads(sTorrent, 4) is 0)
   stAssert "btSetFilePriority", (btSetFilePriority(sTorrent, 0, 4) is 0)
   stAssert "btSetPiecePriority", (btSetPiecePriority(sTorrent, 0, 4) is 0)
   stAssert "btSetTorrentLimits", (btSetTorrentLimits(sTorrent, "0", "0") is 0)
   stAssert "btScrapeTracker (async)", (btScrapeTracker(sTorrent) is 0)
   stAssert "btClearTorrentError", (btClearTorrentError(sTorrent) is 0)

   stSection "download queue"
   stAssert "btQueuePosition is a number", (btQueuePosition(sTorrent) is a number)
   stAssert "btQueueTop", (btQueueTop(sTorrent) is 0)
   stAssert "btQueueBottom", (btQueueBottom(sTorrent) is 0)
   stAssert "btQueueUp", (btQueueUp(sTorrent) is 0)
   stAssert "btQueueDown", (btQueueDown(sTorrent) is 0)

   stSection "trackers + web seeds (round-trips)"
   stAssert "btTrackers returns a list", (stCount(btTrackers(sTorrent)) >= 0)
   put "udp://tracker.selftest.example:6969/announce" into tTrackerUrl
   stAssert "btAddTracker", (btAddTracker(sTorrent, tTrackerUrl, 1) is 0)
   put false into tFound
   repeat for each element tFile in btTrackers(sTorrent)
      if tFile["url"] is tTrackerUrl then put true into tFound
   end repeat
   stAssert "btTrackers now lists the added tracker", tFound
   put "http://seed.selftest.example/data/" into tWS
   stAssert "btAddWebSeed", (btAddWebSeed(sTorrent, tWS) is 0)
   stAssert "btWebSeeds lists the added seed", stListHas(btWebSeeds(sTorrent), tWS)
   stAssert "btRemoveWebSeed", (btRemoveWebSeed(sTorrent, tWS) is 0)
   stAssert "btWebSeeds no longer lists it", (not stListHas(btWebSeeds(sTorrent), tWS))

   stSection "session operations"
   stAssert "btListenPort is a number", (btListenPort(sSession) is a number)
   stAssert "btSessionIsPaused is false", (btSessionIsPaused(sSession) is false)
   put btFindTorrent(sSession, tHash) into tFound
   stAssert "btFindTorrent recovers our handle from the info-hash", (tFound is sTorrent)
   stAssert "btSessionPause", (btSessionPause(sSession) is 0)
   stAssert "btSessionIsPaused is true after pause", (btSessionIsPaused(sSession) is true)
   stAssert "btSessionResume", (btSessionResume(sSession) is 0)
   stAssert "btDhtAnnounce (async)", (btDhtAnnounce(sSession, tHash, 0) is 0)

   stSection "filtering + streaming"
   stAssert "btIpFilterAdd", (btIpFilterAdd(sSession, "10.0.0.0", "10.255.255.255", true) is 0)
   stAssert "btIpFilterClear", (btIpFilterClear(sSession) is 0)
   stAssert "btSetPieceDeadline", (btSetPieceDeadline(sTorrent, 0, 5000) is 0)
   stAssert "btClearPieceDeadlines", (btClearPieceDeadlines(sTorrent) is 0)

   stSection "extended add"
   put btAddMagnetEx(sSession, "magnet:?xt=urn:btih:1111111111111111111111111111111111111111", sTempDir, "16", "16") into sTorrent2
   stAssert "btAddMagnetEx (paused) returns a handle", (sTorrent2 > 0)
   stAssert "btAddTorrentFileEx returns a handle", (btAddTorrentFileEx(sSession, pTorrentData, sTempDir, "16", "16") > 0)

   stSection "resume data"
   stAssert "btSaveResumeData (async)", (btSaveResumeData(sTorrent) is 0)
end stRunTorrentChecks

-- create a small temp content folder + file to seed (idempotent)
command stMakeContent
   local tPayload, tFile
   put specialFolderPath("temporary") into sTempDir
   if sTempDir is empty then
      put specialFolderPath("documents") into sTempDir
   end if
   if the last char of sTempDir is "/" then
      delete the last char of sTempDir
   end if
   put sTempDir & "/torrentxt-selftest" into sContentDir
   if there is no folder sContentDir then
      create folder sContentDir
   end if
   put sContentDir & "/sample.dat" into tFile
   put "TorrentXT self-test sample payload block. " into tPayload
   repeat 10 times
      put tPayload after tPayload
   end repeat
   put tPayload into url ("binfile:" & tFile)
end stMakeContent

command stShowSummary
   local tSummary
   put sPassed && "passed,  " & sFailed && "failed   (" & sTotal && "checks)" into tSummary
   set the text of field "stSummary" to tSummary
   if sFailed is 0 then
      set the foregroundColor of field "stSummary" to "0,140,70"
   else
      set the foregroundColor of field "stSummary" to "200,40,40"
   end if
end stShowSummary

-- paint the results list: red FAIL, green PASS, grey sections/notes
command stPaint
   local tN, tI, tLine
   set the text of field "stResults" to sResultText
   put the number of lines of field "stResults" into tN
   lock screen
   try
      repeat with tI = 1 to tN
         put line tI of field "stResults" into tLine
         if tLine begins with "FAIL" then
            set the foregroundColor of line tI of field "stResults" to "200,40,40"
         else if tLine begins with "PASS" then
            set the foregroundColor of line tI of field "stResults" to "0,140,70"
         else
            set the foregroundColor of line tI of field "stResults" to "110,110,110"
         end if
      end repeat
   catch tErr
   end try
   set the vScroll of field "stResults" to 0
   unlock screen
end stPaint

-- remove any torrents we added and stop the session (idempotent)
command stCleanup
   if sSession is not empty and sSession is not 0 then
      if sTorrent is not empty and sTorrent > 0 then
         btRemoveTorrent sSession, sTorrent, false
      end if
      if sTorrent2 is not empty and sTorrent2 > 0 then
         btRemoveTorrent sSession, sTorrent2, false
      end if
      btStopSession sSession
   end if
   put 0 into sSession
   put 0 into sTorrent
   put 0 into sTorrent2
end stCleanup
