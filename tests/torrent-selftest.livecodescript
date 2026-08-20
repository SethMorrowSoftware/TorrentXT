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
-- TorrentXT session, runs 96 checks, and shows a green/red list. Needs the loaded
-- org.openxtalk.library.torrent (v8+; the current ABI is v11). Run it STANDALONE -
-- only one TorrentXT session may be live per OXT process, so close any client/demo
-- stack first.
--
-- COVERAGE NOTE (honest): the harness now reaches the v9-v11 surface too -
-- btDhtBep44SignBuf, btDhtPutSigned, btDhtGetPeers, btAddInfohash, btMapPort /
-- btUnmapPort, and btRp1Enable / btRp1SetToken / btRp1Send / btRp1Poll - in the
-- signed-puts section below. What it can assert there is the non-destructive,
-- single-process half: determinism, fail-closed rejection, and clean handling
-- of "no mapper" / "no peer". A real rp1 message exchange needs two machines
-- (examples/torrent-rp1-chat.livecodescript), and the DHT results arrive later
-- as events. Native coverage lives in tests/torrent_smoke_test.cpp and
-- rp1_integration_test.cpp; this file proves the .lcb wrappers, and AN ENGINE
-- HAS NOW RUN IT: on 2026-08-10 every check in this file executed green on a
-- real OXT engine - 96 checks, zero failures, twice in one day - folded into
-- the suite selftest (tests/suite-selftest.livecodescript at the repository
-- root), which carries this harness verbatim with only btStartSession rewired
-- to share the suite's single session. That includes the whole v9-v11 surface
-- (btDhtGetPeers, btAddInfohash, btMapPort/btUnmapPort, btRp1Enable/
-- btRp1SetToken/btRp1Send/btRp1Poll), which had been static since it landed.
-- The 2026-08-08 suite pass had already observed the session lifecycle and
-- the signed-put path, including btDhtPutSigned accepting a SodiumXT
-- signature and REFUSING one made for another seq. A standalone paste of THIS
-- file has still not happened and is no longer load-bearing; run it standalone
-- only to chase something the folded run reported.
--
-- WHAT IT CHECKS: every non-destructive public handler returns a sane value and
-- the round-trips work (create+seed -> file table; add web seed -> list it ->
-- remove it; add tracker -> list it; info-hash -> find-by-hash; pause -> is-paused;
-- keypair determinism; immutable put -> target hash). It does NOT assert async DHT
-- / tracker results (those return later as events) and it SKIPS the two genuinely
-- destructive handlers (btMoveStorage, btRemoveTorrent-with-delete) - those are
-- noted for a manual pass. A green run means the whole binding surface is wired.

-- STATUS: last run GREEN in the 2026-08-17 engine pass (Windows x86_64, NT 10.0, OXT 9.6.3) - 101/101, folded into
-- tests/suite-selftest.livecodescript. One torrent session per process
-- (runbook trap 5.1): close other torrent stacks before running it.
constant kStTitle = "TorrentXT - API Self-Test"
constant kStWidth = 660
constant kStHeight = 620

-- ---- state -------------------------------------------------------------------
local sSession          -- the live session handle (0 = none)
local sTorrent          -- a torrent we create + seed, for torrent-scoped checks
local sTorrent2         -- a second torrent from the extended-add check
local sTorrent3         -- a third, from the plain btAddMagnet check beside it
local sTempDir          -- parent dir we seed from
local sContentDir       -- the content folder inside it

-- ---- the scaffolding (carried) ----------------------------------------------
-- ==== SUITE HARNESS SCAFFOLD v1 BEGIN (verbatim copy; master: tools/harness-scaffold.livecodescript; gate: tools/check-harness-scaffold-drift.py) ====
-- The harness scaffolding as one carried block: counters, the window, the
-- assertion plumbing, the report surface. The adopting harness declares
-- kStTitle/kStWidth/kStHeight above this block, owns openStack/stRun/
-- stCleanup, calls stResetCounters first in stRun and stReportDone when
-- the run completes. Do not edit this block in place: change the master
-- and re-carry it.
local sTotal, sPassed, sFailed, sSkipped
local sResultText          -- the accumulated PASS/FAIL/SKIP/section lines
local sStRunDone           -- "true" once the run finished (drives the color)

-- The platform's own terminal face (the demo kit's uiMonoFont, by value).
function stMonoFont
   if the platform is "MacOS" then
      return "Menlo"
   else if the platform is "Win32" then
      return "Consolas"
   end if
   return "DejaVu Sans Mono"
end stMonoFont

-- ---- the window (idempotent; the fold drops this half) -----------------------
command stBuild
   -- the guard is on a control this VERSION of the scaffold adds, so a stack
   -- built by an older scaffold rebuilds once and picks up the new layout
   -- (the builders re-rect existing controls by name; nothing needs deleting)
   if there is a button "stCopy" then
      exit stBuild
   end if
   lock screen
   set the width of this stack to kStWidth
   set the height of this stack to kStHeight
   set the backgroundColor of this card to "240,242,246"
   set the title of this stack to kStTitle
   stMakeLabel "stTitle", "  " & kStTitle, "0,0," & kStWidth & ",30", 15
   set the opaque of field "stTitle" to true
   set the backgroundColor of field "stTitle" to "44,90,160"
   set the foregroundColor of field "stTitle" to "255,255,255"
   set the textStyle of field "stTitle" to "bold"
   stMakeLabel "stSummary", "Running...", "16,38," & (kStWidth - 200) & ",66", 13
   set the textStyle of field "stSummary" to "bold"
   stMakeButton "stCopy", "Copy results", (kStWidth - 184) & ",38," & (kStWidth - 100) & ",64"
   stMakeButton "stRerun", "Re-run", (kStWidth - 94) & ",38," & (kStWidth - 16) & ",64"
   stMakeList "stResults", "16,72," & (kStWidth - 16) & "," & (kStHeight - 16)
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
   set the threeD of field pName to false
   set the borderWidth of field pName to 1
   set the borderColor of field pName to "225,229,236"
   set the opaque of field pName to true
   set the backgroundColor of field pName to "255,255,255"
   set the textSize of field pName to 11
   set the textFont of field pName to stMonoFont()
end stMakeList

-- ---- assertion plumbing (this half folds into the suite harness) -------------
command stResetCounters
   put 0 into sTotal
   put 0 into sPassed
   put 0 into sFailed
   put 0 into sSkipped
   put empty into sResultText
   put empty into sStRunDone
end stResetCounters

command stAssert pName, pOk
   add 1 to sTotal
   if pOk then
      add 1 to sPassed
      put "PASS  " & pName & return after sResultText
   else
      add 1 to sFailed
      put "FAIL  " & pName & return after sResultText
   end if
end stAssert

-- A SKIP is a first-class outcome, not a silent gap: it counts, it names
-- itself, and it says what would make it run.
command stSkip pName, pReason
   add 1 to sTotal
   add 1 to sSkipped
   put "SKIP  " & pName & "  (" & pReason & ")" & return after sResultText
end stSkip

command stSection pTitle
   put return & "== " & pTitle & " ==" & return after sResultText
end stSection

-- A section that threw is a FAIL, never a skip: a skip means "this piece is
-- not here", and something that blew up very much is.
command stSectionFailed pWhich, pError
   stAssert pWhich & " section ran to completion", false
   stNote "it raised:" && pError
   stNote "the other sections still ran; this one is a defect to report"
end stSectionFailed

command stNote pText
   put "      " & pText & return after sResultText
end stNote

-- THE REPORT IS A LIVE SURFACE, so its text is ambiguous by construction:
-- sResultText grows as the run goes, the async harnesses re-render it every
-- tick, and an unfinished report simply STOPS - with no marker, at whatever
-- section the pump had reached. That reads exactly like a hang. It cost a
-- round trip on the 2026-08-19 suite pass: a fully green run came back ending
-- mid-CROSS-section, and nothing in the pasted text could tell an early Copy
-- from a stalled pump. The async deadline is FORTY SECONDS (kStDeadlineMs in
-- the suite core), and the list stops visibly growing long before it expires,
-- so "it looks finished" is the normal state of a run that is not. Every
-- render of the report goes through here, so that state can never be silent
-- again - on screen or on the clipboard.
function stReportText
   if sStRunDone is "true" then
      return sResultText
   end if
   return sResultText \
         & "      ----------------------------------------------------" & return \
         & "      RUN NOT FINISHED - this is NOT the end of the report." & return \
         & "      An async section is still running. Wait for the SUMMARY" & return \
         & "      section at the bottom, then Copy." & return
end stReportText

command stShow
   put stReportText() into field "stResults"
   put sPassed & " passed, " & sFailed & " failed, " & sSkipped & " skipped, " \
         & sTotal & " total" into field "stSummary"
   if sStRunDone is "true" then
      if sFailed is 0 then
         set the foregroundColor of field "stSummary" to "23,128,63"
      else
         set the foregroundColor of field "stSummary" to "176,58,46"
      end if
   end if
end stShow

-- paint the results list: red FAIL, green PASS, amber SKIP, muted the rest
command stPaint
   local tN, tI, tLine, tErr
   put the number of lines of field "stResults" into tN
   lock screen
   try
      repeat with tI = 1 to tN
         put line tI of field "stResults" into tLine
         if tLine begins with "FAIL" then
            set the foregroundColor of line tI of field "stResults" to "176,58,46"
         else if tLine begins with "PASS" then
            set the foregroundColor of line tI of field "stResults" to "23,128,63"
         else if tLine begins with "SKIP" then
            set the foregroundColor of line tI of field "stResults" to "150,110,40"
         else
            set the foregroundColor of line tI of field "stResults" to "138,146,158"
         end if
      end repeat
   catch tErr
   end try
   set the vScroll of field "stResults" to 0
   unlock screen
end stPaint

-- The run's one epilogue: mark done, render, paint. Synchronous harnesses
-- call this at the end of stRun; async ones from the tick that ends the run.
command stReportDone
   put "true" into sStRunDone
   stShow
   stPaint
end stReportDone

command stCopyResults
   -- The whole point of the button: the maintainer pastes the run back
   -- verbatim into the OXT-pass record, so nobody has to retype a result.
   -- It copies stReportText(), not sResultText, so an early copy carries its
   -- own "not finished" trailer into the record - and says so here too,
   -- because the one moment a maintainer is looking at this window is the
   -- moment the dialog appears.
   --
   -- The COUNTS ride along, ahead of the lines. They live in their own field
   -- (stSummary) and used to be left behind, so the runbook taught a message
   -- box incantation to fetch them by hand - one more step between a finished
   -- run and a recorded one, at the exact moment the operator is done. A
   -- report with no totals cannot be checked against the next run's.
   local tError
   try
      set the clipboardData["text"] to sPassed & " passed, " & sFailed \
            & " failed, " & sSkipped & " skipped, " & sTotal & " total" \
            & return & return & stReportText()
      if sStRunDone is "true" then
         answer "Results copied to the clipboard."
      else
         answer "Copied - but the run has NOT finished. An async section is" \
               && "still going; wait for the SUMMARY section, then copy again."
      end if
   catch tError
      answer "Could not reach the clipboard:" && tError
   end try
end stCopyResults

on closeStack
   stCleanup
end closeStack

on mouseUp
   if the short name of the target is "stRerun" then
      stCleanup
      stRun
   else if the short name of the target is "stCopy" then
      stCopyResults
   else
      pass mouseUp
   end if
end mouseUp
-- ==== SUITE HARNESS SCAFFOLD v1 END ====

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   stBuild
   stRun
end openStack










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
   local tRunErr -- a REFERENCED catch variable must be declared: undeclared, strict OXT throws a second error that masks the real one (checker check 15)
   stResetCounters
   put 0 into sTorrent
   put 0 into sTorrent2
   put 0 into sTorrent3

   stSection "session + ABI"
   -- btStartSession is the one handler that can throw (on ABI skew); a clean
   -- start IS the ABI check passing.
   local tStartOk, tNewSession
   put false into tStartOk
   -- RELEASE A SESSION THIS HARNESS ITSELF LEFT BEHIND, before asking for one.
   -- TorrentXT allows exactly ONE session per process, the latch is in the C
   -- shim, and the only key is the integer handle - nothing exported can free a
   -- session you can no longer name. So a run that died before its teardown
   -- orphans it for the whole engine launch. Safe to repeat and safe when
   -- TorrentXT is absent: btStopSession on a stale handle is a documented
   -- no-op, and the try covers the absent case.
   try
      if sSession is not empty and sSession > 0 then
         btStopSession sSession
      end if
   catch tErr
      -- TorrentXT absent, or already released; nothing to free.
   end try
   put 0 into sSession
   -- START INTO A TEMPORARY. This used to be `put btStartSession() into
   -- sSession`, which on a REFUSAL wrote 0 over a still-live handle in the same
   -- statement - destroying the only key to the very session it had just been
   -- refused, and guaranteeing that every later run in this launch would be
   -- refused too. Commit to sSession only on success.
   try
      put btStartSession() into tNewSession
      put true into tStartOk
   catch tErr
      put 0 into tNewSession
   end try
   if tNewSession is not empty and tNewSession > 0 then
      put tNewSession into sSession
   end if
   stAssert "btStartSession did not throw (ABI matches)", tStartOk
   if sSession is 0 or sSession is empty then
      -- NAME BOTH CAUSES. The shim cannot tell them apart and neither can this
      -- harness, so asserting the one it cannot know sent operators hunting for
      -- a window that was not open. See OXT-PASS-RUNBOOK trap 5.1.1.
      stNote "Could not start a session. Either another TorrentXT stack owns it"
      stNote "(close that stack and re-run), or an earlier run in THIS engine"
      stNote "launch lost its handle - quit and relaunch OXT."
      stNote (btLastError())
      stPaint
      exit stRun
   end if
   stAssert "btStartSession returns a positive handle", (sSession > 0)
   -- NB: LiveCode's `is a <type>` only knows number/integer/boolean/point/rect/
   -- date/color - there is NO `is a string`. Test btLastError by clearing it and
   -- confirming it reads back empty (exercises btClearError + btLastError).
   btClearError
   stAssert "btLastError is empty after btClearError", (btLastError() is empty)

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

   stSection "signed puts, rendezvous, NAT mapping, rp1 (the v9-v11 surface)"
   -- btDhtBep44SignBuf hands back the EXACT bytes libtorrent signs, so a
   -- signature can be produced off-box (a hardware key, another machine) and
   -- fed to btDhtPutSigned. It is a pure function of (salt, seq, value), so
   -- determinism is the property worth pinning; byte-exact compares need
   -- caseSensitive, since `is` would otherwise fold 0x41 onto 0x61.
   local tBuf, tBuf2, tBufSeq2
   put btDhtBep44SignBuf("", "1", textEncode("signed-v1", "UTF-8")) into tBuf
   stAssert "btDhtBep44SignBuf returns bytes", (the number of bytes of tBuf > 0)
   put btDhtBep44SignBuf("", "1", textEncode("signed-v1", "UTF-8")) into tBuf2
   set the caseSensitive to true
   stAssert "btDhtBep44SignBuf is deterministic", (tBuf is tBuf2)
   put btDhtBep44SignBuf("", "2", textEncode("signed-v1", "UTF-8")) into tBufSeq2
   stAssert "a different seq changes the signing buffer", (tBufSeq2 is not tBuf)
   -- Fail closed on a signature that is not even hex, rather than queueing a
   -- garbage item into the DHT.
   stAssert "btDhtPutSigned rejects a malformed signature", \
      (btDhtPutSigned(sSession, tKey["publicKey"], "", "1", textEncode("signed-v1", "UTF-8"), "not-a-signature") < 0)
   -- Classic BEP5 rendezvous: any 40-hex id is legal, it need not name a real
   -- torrent - that is what makes it a presence primitive.
   stAssert "btDhtGetPeers accepts a rendezvous id (async)", \
      (btDhtGetPeers(sSession, tTarget) is 0)
   -- A phantom swarm: joined by info-hash with no metadata, which is where the
   -- rp1 peer-wire transport meets its peers.
   local tPhantom
   put btAddInfohash(sSession, tTarget, sTempDir) into tPhantom
   stAssert "btAddInfohash joins a metadata-less swarm", (tPhantom > 0)
   -- NAT mapping is best-effort by nature: 0 means "no mapper active"
   -- (UPnP/NAT-PMP off, or a router that will not play), which is a legitimate
   -- outcome on a CI box or a locked-down LAN, not a failure. Either way it
   -- must not throw, and unmapping must tolerate whatever it returns.
   local tMapId
   put btMapPort(sSession, 0, btListenPort(sSession), true) into tMapId
   stAssert "btMapPort returns a mapping id or 0 (no mapper)", (tMapId >= 0)
   stAssert "btUnmapPort tolerates that id", (btUnmapPort(sSession, tMapId) >= 0)
   stAssert "btUnmapPort on a stale id is a harmless no-op", \
      (btUnmapPort(sSession, 999999) >= 0)
   -- rp1: enable the extension, set a token, drain. A send with no connected
   -- peer must fail cleanly (there is nobody to send to), never crash.
   stAssert "btRp1Enable turns the extension on", (btRp1Enable(sSession) is 0)
   stAssert "btRp1SetToken accepts a token", \
      (btRp1SetToken(sSession, textEncode("selftest-token", "UTF-8")) is 0)
   stAssert "btRp1Poll drains a list", (stCount(btRp1Poll(sSession)) >= 0)
   stAssert "btRp1Send to a non-peer fails cleanly", \
      (btRp1Send(sSession, 999999, textEncode("nobody is listening", "UTF-8")) < 0)

   -- The three handlers this section used to wave at as "confirm by hand".
   -- The excuses were about the SUCCESS path and were read as if they covered
   -- the whole handler: the shim checks the handle (or the session, or the
   -- buffer) FIRST and returns a code before it can move a byte, so every one
   -- of them has a refusal leg that is safe, offline and deterministic. That
   -- distinction is exactly what the 2026-08-17 coverage-gate fix surfaced -
   -- until then this NOTE was the only surviving mention of all three, and the
   -- gate counted a sentence saying they were untested as proof they were.
   stSection "destructive + buffer handlers: the refusal legs"
   -- btx_move_storage returns BTX_ERR_BAD_HANDLE before h.move_storage() runs,
   -- so a stale id relocates nothing. Destructive on a LIVE handle only.
   stAssert "btMoveStorage on a stale id refuses, moving nothing", \
      (btMoveStorage(999999, sTempDir) is -2)
   -- Non-empty Data so the .lcb does NOT short-circuit: this proves the
   -- foreign call ran and the shim rejected the handle, not that we skipped it.
   stAssert "btSetFilePriorities on a stale id refuses", \
      (btSetFilePriorities(999999, textEncode("0", "UTF-8")) is -2)
   -- read_resume_data uses the ec-overload, so garbage sets an error code
   -- rather than throwing. 0 is "no torrent added".
   stAssert "btAddTorrentWithResume refuses garbage resume bytes", \
      (btAddTorrentWithResume(sSession, textEncode("not-bencoded", "UTF-8"), \
         sTempDir) is 0)
   -- ...and 0 alone cannot tell a refusal from the empty-Data short-circuit
   -- that never calls the shim at all, so pin the shim's own message.
   stAssert "...and says why (the shim ran, it did not short-circuit)", \
      (btLastError() contains "invalid resume data")

   stSection "not auto-checked - confirm by hand"
   stNote "btRemoveTorrent(deleteFiles=true) deletes real files: manual only."
   catch tRunErr
      stNote "RUNTIME ERROR - a binding call failed: " & tRunErr
      add 1 to sFailed
   end try

   stReportDone
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
   -- btAddMagnet is the plain form of the Ex call below. It used to be listed
   -- in the hand-check note at the end of this file as "covered via
   -- btAddMagnetEx", which is an argument about SHAPE, not a test: the two
   -- take different argument counts, so the plain form's own marshalling was
   -- never exercised anywhere. The 2026-08-17 coverage-gate fix - which stopped
   -- counting a name inside a string literal as a call - is what surfaced that,
   -- because the note was the only surviving mention.
   put btAddMagnet(sSession, "magnet:?xt=urn:btih:2222222222222222222222222222222222222222", sTempDir) into sTorrent3
   stAssert "btAddMagnet returns a handle", (sTorrent3 > 0)
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



-- remove any torrents we added and stop the session (idempotent)
command stCleanup
   if sSession is not empty and sSession is not 0 then
      if sTorrent is not empty and sTorrent > 0 then
         btRemoveTorrent sSession, sTorrent, false
      end if
      if sTorrent2 is not empty and sTorrent2 > 0 then
         btRemoveTorrent sSession, sTorrent2, false
      end if
      if sTorrent3 is not empty and sTorrent3 > 0 then
         btRemoveTorrent sSession, sTorrent3, false
      end if
      btStopSession sSession
   end if
   put 0 into sSession
   put 0 into sTorrent
   put 0 into sTorrent2
   put 0 into sTorrent3
end stCleanup
