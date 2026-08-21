script "torrentClient"

-- torrent-client.livecodescript - a self-building, MULTI-TORRENT TorrentXT client
-- demo. Add magnets / .torrent files / URLs / info-hashes, create + seed a
-- folder, and manage several torrents at once from a live table.
--
-- HOW TO USE: open OXT, make a stack with one card, paste THIS into the STACK
-- script (Object > Stack Script), then close+reopen the stack. It builds its own
-- UI and starts a TorrentXT session automatically. Needs only the loaded
-- org.openxtalk.library.torrent library - no helper stack, no manual UI.
--
-- SAVING AS A STANDALONE: standalone-ready - the UI self-builds in preOpenStack
-- every launch (nothing needs to persist in the stackfile), and quitting is
-- caught by shutdownRequest so the session shuts down cleanly and settings are
-- saved even on Cmd-Q / Dock quit. In the builder include ONLY
-- org.openxtalk.library.torrent (no optional extensions here - this client has
-- no encryption features). The remembered save path, upload cap, and window
-- height persist to a small per-user prefs file (NOT the stackfile), so they
-- survive across runs and as a packaged app.
--
-- Layout (modern-client style, fits inside a 720p screen): a smart Add row, a
-- single compact toolbar of actions, the torrent table, a one-line detail strip,
-- and a bottom PANEL with Files / Peers / Trackers / Log tabs, over a status bar.
--
-- Features: smart Add (magnet / http(s) .torrent / local .torrent / 40-hex
-- info-hash) with DUPLICATE DETECTION, or just DRAG a .torrent / magnet onto the
-- window; per-torrent Pause/Resume/Recheck/Reannounce/Remove(+Data), Open Folder,
-- Copy Magnet, Save Resume; a live INSPECTOR for the selected torrent with
-- Files / Peers / Trackers tabs (double-click a file to set skip/normal/high
-- priority) plus a Log tab; a Stream toggle (sequential download) and queue
-- Up/Down; session Pause All / Resume All; a global upload cap; a live
-- colour-coded table with inline progress bars; keyboard shortcuts (Enter adds,
-- Space toggles pause/resume, Delete removes); a detail strip with share ratio; a
-- status bar with a state breakdown, rates, and ratio; remembered settings + a
-- resizable window; a self-rebuild on script update (kUiVersion); and a "What is
-- this?" help dialog.
--
-- Design (single-thread playbook): one 250 ms poll loop drains events with a
-- single btPoll; one 800 ms refresh enumerates the torrents and repaints. The
-- refresh is split into tcRefreshOnce (repaint) + tcRefreshLoop (repaint then
-- reschedule) so calling it from an event NEVER spawns a second timer chain.
--
-- HONESTY (the suite convention): the torrent surface this client drives is
-- engine-proven (the member selftest and demo passes recorded in
-- torrentxt/CLAUDE.md), but THIS stack's UI was unified onto the suite kit
-- 2026-08-14 - the rebuilt chrome and layout are verified statically; needs
-- an OXT re-pass.
--
-- THE LOOK is the suite UI kit, carried verbatim between the marker lines
-- (master: tools/ui-kit.livecodescript; the drift gate holds every copy
-- byte-identical). Change the look in the master, never here.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sLineHandles      -- array: table line number -> torrent handle (per refresh)
local sPolling          -- "true" while the loops are armed
local sPanelTab         -- active bottom-panel tab: "files"/"peers"/"trackers"/"log"
local sSeqOn            -- array: torrent handle -> "true" while sequential is on
-- Clipboard auto-detect: an addable link (magnet / .torrent URL / info-hash) on
-- the clipboard pre-fills the Add box at open + on refocus. Each value is
-- offered exactly once so a declined suggestion never nags.
local sClipSuggested    -- the last clipboard text already offered (or dismissed)
-- Watchdogs (fleet-audit fix): a magnet add can legitimately wait forever for
-- metadata (the peer may be offline until tomorrow), and a resume-data request
-- is answered asynchronously or not at all - so neither wait is aborted, but
-- each gets ONE spoken diagnosis once its window passes. Keyed by handle;
-- cleared by the satisfying event, or when the torrent is removed.
local sMetaWait         -- array: handle -> ms clock when a magnet-style add started
local sMetaHinted       -- array: handle -> "true" once the no-metadata hint was given
local sResumeWait       -- array: handle -> ms clock when resume data was requested
local sResumeHinted     -- array: handle -> "true" once the no-resume-data hint was given

-- The user-facing release version: shown in the OS title bar and the startup
-- log line, so a bug report always says which build it came from.
constant kTcAppVersion = "1.0.0"

-- Bump when the generated UI changes; tcBuildUI rebuilds the controls on a
-- mismatch so updating the script in a SAVED stack picks up the new layout
-- instead of keeping the old controls (and dead buttons) around.
constant kUiVersion = "client-kit2-1"
-- prefs file header: 8-byte magic + 1-byte mode. The client keeps no secrets, so
-- it only ever writes mode "P" (plain); the format matches the channels demo.
constant kPrefMagic = "BTXPREF1"
-- watchdog windows, in seconds (see the sMetaWait comment above): how long a
-- metadata-less magnet / an unanswered resume-data request waits before the
-- one-time diagnosis line is logged. The waits themselves continue.
constant kTcMetaHintSecs = 60
constant kTcResumeHintSecs = 30

-- ---- adopter-owned colors ------------------------------------------------------
-- Everything the suite UI kit owns (page, cards, inks, field lines) comes from
-- the carried block below; only the colors the kit does NOT own stay here: the
-- table/header chrome and the per-row state colors (aligned across the family:
-- accent blue = active). Literal RGB strings only (OXT constants must be
-- literal + declared before first use).
constant kClrHeadBg = "233,236,242"     -- table + inspector column-header fill
constant kClrHeadInk = "70,80,96"       -- column-header text
constant kClrStatusBg = "233,236,242"   -- status bar fill
constant kClrRowSeed = "23,128,63"      -- seeding / finished
constant kClrRowDown = "43,108,196"     -- downloading (the shared accent)
constant kClrRowWait = "150,110,40"     -- checking / queued / connecting
constant kClrRowIdle = "120,128,140"    -- paused / idle
constant kClrRowErr = "176,58,46"       -- errored

-- ==== SUITE UI KIT v2 BEGIN (verbatim copy; master: tools/ui-kit.livecodescript; gate: tools/check-ui-kit-drift.py) ====
-- The family look as one carried block: the kit owns colors, chrome, and
-- control construction; the adopting demo owns layout (explicit rects) and
-- logic. Builders are idempotent (create-if-missing), so a rebuild on
-- reopen is safe. Do not edit this block in place: change the master and
-- re-carry it.
constant kUiBg = "240,242,246"
constant kUiCard = "255,255,255"
constant kUiCardLine = "225,229,236"
constant kUiAccent = "44,90,160"
constant kUiAccentText = "255,255,255"
constant kUiAccentSub = "199,216,241"
constant kUiInk = "28,34,46"
constant kUiInkSoft = "95,104,118"
constant kUiMuted = "138,146,158"
constant kUiOk = "23,128,63"
constant kUiWarn = "150,110,40"
constant kUiBad = "176,58,46"
constant kUiFieldLine = "203,210,222"
constant kUiCodeBg = "244,246,250"
constant kUiCodeLine = "210,217,229"

-- The platform's own terminal face for codes, keys, tables and logs, so
-- the monospace surfaces look native instead of typewriter-Courier. A
-- missing face substitutes the engine default - a soft, safe failure.
function uiMonoFont
   if the platform is "MacOS" then
      return "Menlo"
   else if the platform is "Win32" then
      return "Consolas"
   end if
   return "DejaVu Sans Mono"
end uiMonoFont

-- The window chrome every adopter shares: stack size, page ground, the
-- title band, and the one status line under it (write it with uiStatus).
-- pBandH is optional (default 30); a taller band leaves room for an
-- adopter's tagline or status pill, placed by the adopter.
command uiChrome pTitle, pWidth, pHeight, pBandH
   local tFH
   if pBandH is empty then
      put 30 into pBandH
   end if
   set the width of this stack to pWidth
   set the height of this stack to pHeight
   set the backgroundColor of this card to kUiBg
   set the title of this stack to pTitle
   uiGfx "uiBand", "0,0," & pWidth & "," & pBandH
   set the style of graphic "uiBand" to "rectangle"
   set the filled of graphic "uiBand" to true
   set the backgroundColor of graphic "uiBand" to kUiAccent
   set the lineSize of graphic "uiBand" to 0
   uiLabel "uiTitle", "  " & pTitle, "0,0," & pWidth & "," & pBandH, 15
   set the foregroundColor of field "uiTitle" to kUiAccentText
   set the textStyle of field "uiTitle" to "bold"
   -- center the title on the band midline by MEASURED height (never guess
   -- font metrics - the family's OXT passes clipped hand-sized labels)
   put the formattedHeight of field "uiTitle" into tFH
   if tFH > 0 and tFH < pBandH then
      set the height of field "uiTitle" to tFH
      set the top of field "uiTitle" to ((pBandH - tFH) div 2)
   end if
   uiLabel "uiStatus", empty, "16," & (pBandH + 4) & "," & (pWidth - 16) & "," & (pBandH + 22), 11
end uiChrome

-- The status line, colored by what it reports: "ok", "warn", "bad", or
-- anything else for neutral/muted. Demos route probe results through this
-- so a stack that cannot run says so in red, at the top, immediately.
command uiStatus pText, pKind
   -- PIN THE STACK, THEN CHECK THE FIELD EXISTS. Both halves were missing and
   -- both are load-bearing on a TIMER-driven call.
   --
   -- An unqualified `field "uiStatus"` resolves against the DEFAULTSTACK, not
   -- against the stack whose script is running. Inside openStack those are the
   -- same thing, which is why every demo's startup status line always worked.
   -- A handler arriving from `send ... in` has no such guarantee: with a second
   -- stack in front, the write lands in the wrong stack or resolves to nothing.
   --
   -- THE PIN RESTS ON THE DOCUMENTED RESOLUTION RULE, NOT ON A THROW WE SAW.
   -- This comment used to cite enet-lan-chat's once-a-second dashboard throwing
   -- "Chunk: error in object expression" REPEATEDLY on 2026-08-18, and dht-chat
   -- hiding the same fault behind a guard. Neither half held up: that throw was
   -- the ARGUMENT at the call site (`the number of keys of sPeers`, which does
   -- not parse - OXT-ENGINE-NOTES 1.7) and never reached uiStatus at all, and
   -- the guard credited to the kit was dht-chat's own wxSetStatus wrapper - the
   -- master had no existence check until the same commit that added this pin.
   -- What a guarded call site WOULD do if the defaultStack diverged is fail
   -- silently, which is the argument for a gate rather than for more guards.
   -- See OXT-ENGINE-NOTES 5.3, now classed DOCUMENTED.
   --
   -- The pin is holde-em's idiom, engine-proven there, and its comment names
   -- this exact hazard. The existence check stays as well: a demo may call the
   -- status line before its chrome is built, and a cosmetic line must never
   -- take down a poll chain.
   set the defaultStack to the short name of this stack
   if there is no field "uiStatus" then
      exit uiStatus
   end if
   put pText into field "uiStatus"
   if pKind is "ok" then
      set the foregroundColor of field "uiStatus" to kUiOk
   else if pKind is "warn" then
      set the foregroundColor of field "uiStatus" to kUiWarn
   else if pKind is "bad" then
      set the foregroundColor of field "uiStatus" to kUiBad
   else
      set the foregroundColor of field "uiStatus" to kUiInkSoft
   end if
end uiStatus

-- A static caption at a FIXED rect (idempotent, borderless, transparent).
-- Use uiWrap instead when the text may wrap or the exact height matters.
command uiLabel pName, pText, pRect, pSize
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the borderWidth of field pName to 0
   set the opaque of field pName to false
   set the threeD of field pName to false
   set the textSize of field pName to pSize
   set the foregroundColor of field pName to kUiInk
   put pText into field pName
end uiLabel

-- A caption FIT to its measured text height (top pinned). The fit does
-- double duty: it prevents clipping (hand-sized rects clipped text on a
-- real Windows pass), and it makes `the height of field` equal the TEXT
-- height, which midline centering relies on. GUARD: only resize on a sane
-- measurement - a 0/blank formattedHeight (possible before the window is
-- fully realized) would collapse the label. Empty labels are skipped
-- (they receive their text later).
command uiWrap pName, pText, pRect, pSize
   local tOldDelim, tTop, tFH
   uiLabel pName, pText, pRect, pSize
   if pText is not empty then
      put the itemDelimiter into tOldDelim
      set the itemDelimiter to comma
      put item 2 of pRect into tTop
      set the itemDelimiter to tOldDelim
      put the formattedHeight of field pName into tFH
      if tFH > 0 then
         set the height of field pName to tFH
         set the top of field pName to tTop
      end if
   end if
end uiWrap

-- A small, muted caption (hints, toggle descriptions, empty states).
command uiCap pName, pText, pRect
   uiWrap pName, pText, pRect, 10
   set the foregroundColor of field pName to kUiMuted
end uiCap

-- A numbered bold section header with a hairline divider placed below the
-- label's ACTUAL (fit-to-text) bottom, so it tracks the real header
-- height on any platform's line metrics.
command uiSection pName, pText, pRect
   local tOldDelim, tL, tR, tB
   uiWrap pName, pText, pRect, 13
   set the textStyle of field pName to "bold"
   put the itemDelimiter into tOldDelim
   set the itemDelimiter to comma
   put item 1 of pRect into tL
   put item 3 of pRect into tR
   set the itemDelimiter to tOldDelim
   put the bottom of field pName into tB
   uiGfx (pName & "Line"), (tL & comma & (tB + 1) & comma & tR & comma & (tB + 2))
   set the style of graphic (pName & "Line") to "rectangle"
   set the filled of graphic (pName & "Line") to true
   set the backgroundColor of graphic (pName & "Line") to kUiCardLine
   set the lineSize of graphic (pName & "Line") to 0
end uiSection

-- A one-line entry field, mono and flat ("modern input" chrome instead of
-- the engine's sunken-3D default), because hex, addresses and paths are
-- what this suite's demos edit.
command uiInput pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to false
   set the traversalOn of field pName to true
   set the threeD of field pName to false
   set the borderWidth of field pName to 1
   set the borderColor of field pName to kUiFieldLine
   set the opaque of field pName to true
   set the backgroundColor of field pName to kUiCard
   -- 4-item margins form ONLY: OXT ignored the single-number form on a
   -- real engine pass
   set the margins of field pName to "6,6,6,6"
   set the textSize of field pName to 11
   set the textFont of field pName to uiMonoFont()
end uiInput

-- A read-only output/log area: mono, flat, scrolling, hairline-bordered.
command uiArea pName, pRect
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the traversalOn of field pName to false
   set the threeD of field pName to false
   set the borderWidth of field pName to 1
   set the borderColor of field pName to kUiCardLine
   set the opaque of field pName to true
   set the backgroundColor of field pName to kUiCard
   set the margins of field pName to "6,6,6,6"
   set the vScrollbar of field pName to true
   set the textSize of field pName to 10
   set the textFont of field pName to uiMonoFont()
end uiArea

-- A row-selectable table: uiArea plus list behavior and tab stops
-- ("230,340"-style comma lists). Pair it with a uiLabel header carrying
-- the same tabStops, set by the adopter.
command uiTable pName, pRect, pTabStops
   uiArea pName, pRect
   set the listBehavior of field pName to true
   if pTabStops is not empty then
      set the tabStops of field pName to pTabStops
   end if
end uiTable

command uiButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end uiButton

-- A script-managed checkbox: autoHilite OFF because the family drives
-- toggle state from script locals (a mode the environment cannot honour
-- must never stay silently armed - the quickshare pill lesson), so the
-- hilite is set explicitly by the adopter's state machine.
command uiCheckbox pName, pLabel, pRect
   uiButton pName, pLabel, pRect
   set the style of button pName to "checkbox"
   set the autoHilite of button pName to false
end uiCheckbox

-- Create-or-reuse a named graphic: the chrome layer (cards, pills,
-- dividers, drop targets). Created BEFORE the controls that sit on it, so
-- it stays behind them in z-order. roundRect + antialiased by default;
-- callers restyle.
command uiGfx pName, pRect
   if there is no graphic pName then
      create graphic
      set the name of the last graphic to pName
   end if
   set the rect of graphic pName to pRect
   set the style of graphic pName to "roundRect"
   set the antialiased of graphic pName to true
end uiGfx

-- A dashboard card: a rounded, hairline-bordered, softly shadowed panel
-- placed BEHIND a group of controls. It only groups visually; clicks on
-- it fall through to the adopter's `default: pass mouseUp`.
command uiPanel pName, pRect
   local tShadow, tErr
   uiGfx pName, pRect
   set the roundRadius of graphic pName to 14
   set the filled of graphic pName to true
   set the backgroundColor of graphic pName to kUiCard
   set the lineSize of graphic pName to 1
   -- a graphic strokes its outline in the foregroundColor; borderColor is
   -- set too so whichever the engine honours, the hairline lands
   set the foregroundColor of graphic pName to kUiCardLine
   set the borderColor of graphic pName to kUiCardLine
   -- soft drop shadow is an LC-9-era feature, so it is a PURE
   -- enhancement: an engine without it just skips it (the try) and the
   -- hairline still separates the card from the page
   try
      put "90,98,114" into tShadow["color"]
      put 30 into tShadow["opacity"]
      put 10 into tShadow["size"]
      put 0 into tShadow["spread"]
      put 2 into tShadow["distance"]
      put 90 into tShadow["angle"]
      set the dropShadow of graphic pName to tShadow
   catch tErr
   end try
end uiPanel

-- A status pill: rounded chip + centered label, colored by state kind -
-- "ok" green, "wait" amber, "bad" red, anything else the muted on-band
-- blue. The adopter repaints it from ONE place so its handlers cannot
-- disagree about the colors (the nocloud Tor-pill discipline).
command uiPill pName, pText, pRect, pKind
   local tOldDelim, tTop, tBot, tFH
   put the itemDelimiter into tOldDelim
   set the itemDelimiter to comma
   put item 2 of pRect into tTop
   put item 4 of pRect into tBot
   set the itemDelimiter to tOldDelim
   uiGfx (pName & "Bg"), pRect
   set the roundRadius of graphic (pName & "Bg") to (tBot - tTop)
   set the filled of graphic (pName & "Bg") to true
   set the lineSize of graphic (pName & "Bg") to 0
   if pKind is "ok" then
      set the backgroundColor of graphic (pName & "Bg") to "205,240,214"
   else if pKind is "wait" then
      set the backgroundColor of graphic (pName & "Bg") to "250,240,199"
   else if pKind is "bad" then
      set the backgroundColor of graphic (pName & "Bg") to "243,215,213"
   else
      set the backgroundColor of graphic (pName & "Bg") to "31,64,116"
   end if
   uiLabel pName, pText, pRect, 10
   set the textAlign of field pName to "center"
   if pKind is "ok" then
      set the foregroundColor of field pName to "22,101,52"
   else if pKind is "wait" then
      set the foregroundColor of field pName to "133,98,14"
   else if pKind is "bad" then
      set the foregroundColor of field pName to "135,44,38"
   else
      set the foregroundColor of field pName to kUiAccentSub
   end if
   -- center the label on the chip midline by measured height
   put the formattedHeight of field pName into tFH
   if tFH > 0 and tFH < (tBot - tTop) then
      set the height of field pName to tFH
      set the top of field pName to (tTop + ((tBot - tTop - tFH) div 2))
   end if
end uiPill

-- Click-to-copy feedback: flash the button's label to "Copied!" for
-- 1200 ms, then restore the real label (stashed in uRealLabel).
command uiCopyFlash pBtn
   if there is no button pBtn then
      exit uiCopyFlash
   end if
   if the uRealLabel of button pBtn is empty then
      set the uRealLabel of button pBtn to the label of button pBtn
   end if
   set the label of button pBtn to "Copied!"
   send ("uiCopyFlashReset" && quote & pBtn & quote) to me in 1200 milliseconds
end uiCopyFlash

command uiCopyFlashReset pBtn
   -- Pinned for the same reason uiStatus is: this one arrives 1200ms later by
   -- `send`, so the defaultStack is whatever is current THEN, not the stack
   -- that flashed the button. Its existence guard means the failure is silent
   -- rather than loud - the label just never comes back, or comes back on
   -- another stack's button - which is why it needed finding rather than
   -- reporting itself.
   set the defaultStack to the short name of this stack
   if there is no button pBtn then
      exit uiCopyFlashReset
   end if
   if the uRealLabel of button pBtn is not empty then
      set the label of button pBtn to the uRealLabel of button pBtn
   end if
end uiCopyFlashReset

-- The honesty/custody footer every demo carries: what the stack is, what
-- it is not, and its engine-evidence state.
command uiFooter pText, pRect
   uiWrap "uiFooter", pText, pRect, 11
   set the textStyle of field "uiFooter" to "italic"
   set the foregroundColor of field "uiFooter" to kUiMuted
end uiFooter
-- ==== SUITE UI KIT v2 END ====

-- ---- lifecycle ---------------------------------------------------------------
-- Build in preOpenStack, BEFORE the window is shown, so a first open (or a
-- kUiVersion rebuild) never flashes an unstyled or mis-sized window; the
-- session then starts in openStack once the window is up. tcPrefLoad must run
-- first (tcBuildUI reads the remembered save path / cap / height). The pair is
-- ALSO run first in openStack (belt and suspenders): OXT sends openStack - but
-- NOT preOpenStack - when the stack SCRIPT is (re)compiled (the paste-into-
-- stack-script flow), so building only here would arm the refresh loop against
-- a UI that was never built. Both are idempotent, so preOpenStack builds it
-- flash-free and openStack's calls no-op.
on preOpenStack
   tcPrefLoad
   tcBuildUI
end preOpenStack

on openStack
   tcPrefLoad
   tcBuildUI
   tcEnsureSession
   -- LAST, not first: the check reads the state tcEnsureSession establishes.
   tcScRun
end openStack

on closeStack
   tcShutdown
end closeStack

-- A standalone quits via shutdownRequest (Cmd-Q / Alt-F4 / Dock quit) WITHOUT
-- a guaranteed closeStack first - and tcShutdown is where the session is stopped
-- (pause -> flush resume data -> join threads) and settings are saved. It is
-- idempotent, so arriving here after closeStack already ran is a safe no-op.
on shutdownRequest
   tcShutdown
   pass shutdownRequest
end shutdownRequest

on resumeStack
   -- the window came back to the front: a magnet / info-hash may be waiting on
   -- the clipboard (the common "copy a magnet, switch to the client" flow)
   tcClipboardSuggest
   pass resumeStack
end resumeStack

-- the window is vertically resizable; reflow the table/log and remember the size
on resizeStack
   tcRelayout
   set the uHeight of this stack to the height of this stack
end resizeStack

-- ---- button routing (every control lives in this one stack script) -----------
on mouseUp
   switch the short name of the target
      case "tcAdd"
         tcAddInput
         break
      case "tcAddFile"
         tcAddTorrentFile
         break
      case "tcBrowse"
         tcBrowseSave
         break
      case "tcSeed"
         tcCreateAndSeed
         break
      case "tcPause"
         tcControlSelected "pause"
         break
      case "tcResume"
         tcControlSelected "resume"
         break
      case "tcRecheck"
         tcControlSelected "recheck"
         break
      case "tcReannounce"
         tcControlSelected "reannounce"
         break
      case "tcRemove"
         tcControlSelected "remove"
         break
      case "tcRemoveData"
         tcControlSelected "removeData"
         break
      case "tcOpenFolder"
         tcOpenFolder
         break
      case "tcCopyMagnet"
         tcCopyMagnet
         break
      case "tcSaveResume"
         tcSaveResume
         break
      case "tcPauseAll"
         tcAllTorrents "pause"
         break
      case "tcResumeAll"
         tcAllTorrents "resume"
         break
      case "tcApplyLimit"
         tcApplyUpLimit
         break
      case "tcTabFiles"
         tcSetTab "files"
         break
      case "tcTabPeers"
         tcSetTab "peers"
         break
      case "tcTabTrackers"
         tcSetTab "trackers"
         break
      case "tcTabLog"
         tcSetTab "log"
         break
      case "tcStream"
         tcStreamToggle
         break
      case "tcQUp"
         tcQueue "up"
         break
      case "tcQDown"
         tcQueue "down"
         break
      case "tcHelp"
         tcHelp
         break
      case "tcTorrents"
         -- selecting a row should refill the inspector + detail immediately,
         -- not wait for the next 800 ms refresh
         tcOnSelect
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- double-click a table row opens that torrent's download folder; double-click a
-- file in the inspector (Files tab) cycles its download priority.
on mouseDoubleUp
   switch the short name of the target
      case "tcTorrents"
         tcOpenFolder
         break
      case "tcInspect"
         if sPanelTab is "files" then
            tcCycleFilePriority
         end if
         break
      default
         pass mouseDoubleUp
   end switch
end mouseDoubleUp

-- Enter/Return in the Add field adds the torrent.
on returnInField
   if the short name of the target is "tcInput" then
      tcAddInput
   else
      pass returnInField
   end if
end returnInField

on enterInField
   if the short name of the target is "tcInput" then
      tcAddInput
   else
      pass enterInField
   end if
end enterInField

-- Table shortcuts: Space toggles pause/resume, Delete/Backspace removes. Scoped
-- to when the TABLE itself has focus and a row is selected, so they never disturb
-- typing in the Add / Save-path / limit fields.
on rawKeyDown pKey
   if the focusedObject is not the long id of field "tcTorrents" then
      pass rawKeyDown
   end if
   if tcSelectedHandle() is 0 then
      pass rawKeyDown
   end if
   switch pKey
      case 32            -- space
         tcToggleSelected
         break
      case 65288         -- backspace
      case 65535         -- forward delete
         tcControlSelected "remove"
         break
      default
         pass rawKeyDown
   end switch
end rawKeyDown

-- ---- drag-and-drop add (drop a .torrent file or a magnet onto the window) ----
-- We must signal willingness to accept the drop during dragEnter/dragMove (by
-- setting the acceptDrop), or the drop never arrives. We take either dropped
-- files or dropped text (a magnet / URL / info-hash) and route it through the
-- same smart Add path as the input box.
on dragEnter
   if the dragData["files"] is not empty or the dragData["text"] is not empty then
      set the acceptDrop to true
   end if
end dragEnter

on dragMove
   if the dragData["files"] is not empty or the dragData["text"] is not empty then
      set the acceptDrop to true
   end if
end dragMove

on dragDrop
   local tFiles, tText
   put the dragData["files"] into tFiles
   put the dragData["text"] into tText
   if tFiles is not empty then
      -- one torrent per drop: take the first file and let tcAddInput sniff it
      put line 1 of tFiles into field "tcInput"
      tcAddInput
   else if tText is not empty then
      put tcTrim(tText) into field "tcInput"
      tcAddInput
   end if
end dragDrop

-- ---- self-building UI (idempotent: re-opening does not duplicate) ------------
command tcBuildUI
   -- Rebuild when the script's UI version changed, so updating the script in a
   -- SAVED stack picks up the new inspector layout instead of leaving the old
   -- controls (and dead buttons) behind. A normal re-open with a matching
   -- version - and the inspector already present - is a fast no-op.
   if the uUiVersion of this stack is kUiVersion and there is a field "tcInspect" then
      exit tcBuildUI
   end if
   tcClearGeneratedUI
   lock screen
   -- the kit chrome: band + the one status line at 860x640 (the gate-readable
   -- default). The stack stays vertically RESIZABLE: lock the width, remember
   -- the user's height across runs, and let the table + the bottom panel share
   -- the extra vertical space (see resizeStack / tcRelayout).
   uiChrome "TorrentXT Client", 860, 640
   -- the OS title bar carries the release version (bug reports name the build)
   set the title of this stack to ("TorrentXT Client " & kTcAppVersion)
   set the minWidth of this stack to 860
   set the maxWidth of this stack to 860
   set the minHeight of this stack to 500
   if the uHeight of this stack is a number and the uHeight of this stack >= 500 then
      set the height of this stack to (the uHeight of this stack)
   end if
   -- the band tagline, placed by the adopter on the kit's band (right-aligned,
   -- centered on the 30px band midline by MEASURED height - never guess metrics)
   uiWrap "tcSubtitle", "BitTorrent for OpenXTalk - powered by libtorrent", "440,4,844,26", 10
   set the foregroundColor of field "tcSubtitle" to kUiAccentSub
   set the textAlign of field "tcSubtitle" to "right"
   set the top of field "tcSubtitle" to (15 - ((the height of field "tcSubtitle") div 2))
   -- add row: the smart input + the two add buttons (below the kit status line)
   uiInput "tcInput", "16,56,560,78"
   uiButton "tcAdd", "Add", "568,56,650,78"
   uiButton "tcAddFile", "Open .torrent", "658,56,844,78"
   -- save + seed row, with the global upload cap tucked on the right
   uiWrap "tcSaveLabel", "Save to:", "16,84,62,102", 10
   set the foregroundColor of field "tcSaveLabel" to kUiInkSoft
   uiInput "tcSavePath", "66,82,392,104"
   uiButton "tcBrowse", "Browse...", "396,82,468,104"
   uiButton "tcSeed", "Create + Seed", "472,82,604,104"
   uiWrap "tcLimitLabel", "Up KB/s:", "616,84,684,102", 10
   set the foregroundColor of field "tcLimitLabel" to kUiInkSoft
   uiInput "tcUpLimit", "688,82,740,104"
   uiButton "tcApplyLimit", "Apply", "744,82,816,104"
   -- a single compact toolbar of per-torrent + session actions (modern-client
   -- style; the full names live in the tooltips). Three visual clusters: torrent
   -- state, then torrent info, then session-wide.
   uiButton "tcPause", "Pause", "16,108,80,130"
   uiButton "tcResume", "Resume", "82,108,146,130"
   uiButton "tcRecheck", "Recheck", "148,108,218,130"
   uiButton "tcReannounce", "Announce", "220,108,298,130"
   uiButton "tcRemove", "Remove", "300,108,366,130"
   uiButton "tcRemoveData", "Remove+Data", "368,108,464,130"
   uiButton "tcOpenFolder", "Open", "474,108,534,130"
   uiButton "tcCopyMagnet", "Magnet", "536,108,600,130"
   uiButton "tcSaveResume", "Save Res", "602,108,674,130"
   uiButton "tcPauseAll", "Pause All", "684,108,760,130"
   uiButton "tcResumeAll", "Resume All", "762,108,844,130"
   -- table header + selectable table (double-click a row to open its folder).
   -- The header is a styled uiWrap carrying the same tab stops as the table.
   uiWrap "tcHeader", \
      "#" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Down" & tab & "Up" & tab & "Peers" & tab & "Size", \
      "16,134,844,150", 10
   uiTable "tcTorrents", "16,152,844,384", "26,250,350,510,590,670,720"
   set the tabStops of field "tcHeader" to "26,250,350,510,590,670,720"
   -- the tab stops are absolute pixels tuned for 11px mono, so pin the size
   -- (uiTable's default is 10); the header matches the table's face.
   set the textFont of field "tcHeader" to uiMonoFont()
   set the textSize of field "tcHeader" to 11
   set the textSize of field "tcTorrents" to 11
   -- a pale selection color keeps the state-colored row text legible when a row
   -- is hilited; the default system hilite is too dark for the colored text.
   set the hiliteColor of field "tcTorrents" to "200,221,242"
   -- a styled header bar frames the table
   set the opaque of field "tcHeader" to true
   set the backgroundColor of field "tcHeader" to kClrHeadBg
   set the foregroundColor of field "tcHeader" to kClrHeadInk
   set the textStyle of field "tcHeader" to "bold"
   -- detail strip for the selected torrent (just under the table)
   uiWrap "tcDetail", "Select a torrent to see its details.", "16,388,844,406", 10
   set the foregroundColor of field "tcDetail" to kUiInkSoft
   -- ---- bottom panel: Files / Peers / Trackers / Log + per-torrent actions ----
   -- a tab row, a column header, and one of two stacked fields shown per tab (the
   -- inspector list, or the event log). tcRelayout positions all of these; the
   -- rects here are placeholders. The active tab is shown by disabling its button.
   uiButton "tcTabFiles", "Files", "16,410,80,432"
   uiButton "tcTabPeers", "Peers", "82,410,146,432"
   uiButton "tcTabTrackers", "Trackers", "148,410,222,432"
   uiButton "tcTabLog", "Log", "224,410,280,432"
   uiButton "tcStream", "Stream: off", "300,410,396,432"
   uiButton "tcQUp", "Q Up", "400,410,452,432"
   uiButton "tcQDown", "Q Down", "456,410,520,432"
   uiButton "tcHelp", "What is this?", "760,410,844,432"
   uiWrap "tcInspectHdr", \
      "Name" & tab & "Size" & tab & "Progress" & tab & "Priority", "16,436,844,454", 10
   set the opaque of field "tcInspectHdr" to true
   set the backgroundColor of field "tcInspectHdr" to kClrHeadBg
   set the foregroundColor of field "tcInspectHdr" to kClrHeadInk
   set the textStyle of field "tcInspectHdr" to "bold"
   set the textFont of field "tcInspectHdr" to uiMonoFont()
   set the textSize of field "tcInspectHdr" to 11
   -- the inspector list and the event log share the SAME region; tcSetTab shows
   -- one and hides the other, so the Log reads as just another tab. Tab stops
   -- are per-tab (tcSetTab sets them), so the table is built without any.
   uiTable "tcInspect", "16,456,844,584", empty
   set the textSize of field "tcInspect" to 11
   set the hiliteColor of field "tcInspect" to "200,221,242"
   uiArea "tcLog", "16,456,844,584"
   set the foregroundColor of field "tcLog" to kUiInkSoft
   -- session status bar pinned along the bottom edge (totals live here; the
   -- kit's uiStatus line under the band carries session health)
   uiWrap "tcTotals", "", "16,590,844,610", 10
   set the opaque of field "tcTotals" to true
   set the backgroundColor of field "tcTotals" to kClrStatusBg
   set the foregroundColor of field "tcTotals" to kUiInk
   set the textStyle of field "tcTotals" to "bold"
   -- the honesty footer, pinned under the status bar by tcRelayout
   uiFooter \
         "Multi-torrent client demo over TorrentXT (libtorrent). The torrent" \
         & " surface is engine-proven; this kit-unified UI needs an OXT" \
         & " re-pass.", \
         "16,614,844,632"
   -- defaults (restore the remembered save path + upload cap if present)
   if the uSavePath of this stack is not empty then
      put the uSavePath of this stack into field "tcSavePath"
   else
      put tcDefaultSavePath() into field "tcSavePath"
   end if
   put empty into field "tcInput"
   if the uUpLimit of this stack is not empty then
      put the uUpLimit of this stack into field "tcUpLimit"
   else
      put "0" into field "tcUpLimit"
   end if
   -- tooltips: an affordance hint on every control
   set the tooltip of field "tcInput" to "Paste a magnet link, an http(s) .torrent URL, a local .torrent path, or a 40-char info-hash"
   set the tooltip of button "tcAdd" to "Add the torrent in the box (or press Enter)"
   set the tooltip of button "tcAddFile" to "Choose a .torrent file from disk"
   set the tooltip of field "tcSavePath" to "Folder where downloads are saved"
   set the tooltip of button "tcBrowse" to "Choose the download folder"
   set the tooltip of button "tcSeed" to "Build a .torrent from a folder and start seeding it"
   set the tooltip of button "tcPause" to "Pause the selected torrent (or press Space)"
   set the tooltip of button "tcResume" to "Resume the selected torrent (or press Space)"
   set the tooltip of button "tcRecheck" to "Re-verify the selected torrent's files on disk"
   set the tooltip of button "tcReannounce" to "Re-announce the selected torrent to its trackers"
   set the tooltip of button "tcRemove" to "Remove the selected torrent, keeping files (or press Delete)"
   set the tooltip of button "tcRemoveData" to "Remove the selected torrent AND delete its files"
   set the tooltip of button "tcOpenFolder" to "Open the selected torrent's folder (or double-click a row)"
   set the tooltip of button "tcCopyMagnet" to "Copy a magnet link for the selected torrent"
   set the tooltip of button "tcSaveResume" to "Flush fast-resume data for the selected torrent"
   set the tooltip of button "tcPauseAll" to "Pause every torrent"
   set the tooltip of button "tcResumeAll" to "Resume every torrent"
   set the tooltip of field "tcUpLimit" to "Global upload cap in KB/s (0 = unlimited)"
   set the tooltip of button "tcApplyLimit" to "Apply the upload cap"
   set the tooltip of field "tcTorrents" to "Select a torrent. Space pauses/resumes, Delete removes, double-click opens its folder."
   set the tooltip of button "tcTabFiles" to "Show the selected torrent's files (double-click a file to change its priority)"
   set the tooltip of button "tcTabPeers" to "Show the peers connected for the selected torrent"
   set the tooltip of button "tcTabTrackers" to "Show the trackers for the selected torrent"
   set the tooltip of button "tcTabLog" to "Show the event log"
   set the tooltip of button "tcStream" to "Toggle sequential (streaming) download for the selected torrent"
   set the tooltip of button "tcQUp" to "Move the selected torrent up in the priority queue"
   set the tooltip of button "tcQDown" to "Move the selected torrent down in the priority queue"
   set the tooltip of button "tcHelp" to "What this client can do"
   set the tooltip of field "tcInspect" to "Files / Peers / Trackers for the selected torrent. On Files, double-click a row to cycle priority."
   tcSetTab "files"
   set the uUiVersion of this stack to kUiVersion
   tcRelayout
   unlock screen
   tcLogMsg "TorrentXT Client " & kTcAppVersion & " built. Add takes a magnet, a .torrent path, an http(s) .torrent URL, or a 40-hex info-hash."
   tcLogMsg "Duplicates are detected. Double-click a row to open its folder. Create + Seed a folder to seed."
   tcLogMsg "Pick a torrent, then use the Files / Peers / Trackers tabs below. Drag a .torrent or magnet onto the window to add it."
end tcBuildUI

-- The label/input/table/button builders that used to live here collapsed onto
-- the suite UI kit above (uiWrap/uiInput/uiTable/uiArea/uiButton/uiGfx/
-- uiMonoFont/uiCopyFlash); only the genuinely client-local layout helpers
-- below survive.

-- Reflow the two resizable list regions (the torrent table and the bottom panel)
-- plus the detail strip, tab row, panel header, status bar, and footer for the
-- current height. The width is locked, so only vertical space is shared: the
-- table and the panel split the free height 50/50. Everything else - the 152px
-- fixed top block (kit band + status line + add/save/toolbar rows + header),
-- the 18px detail strip, the tab row, the panel header, the status bar, the
-- footer, the gaps, and an 8px margin - is fixed. The inspector list and the
-- log occupy the SAME panel rect (tcSetTab shows one). Called on build +
-- resize; no-op until the UI exists. tcTotals gates "ready".
command tcRelayout
   local tH, tRight, tAvail, tY, tTableH, tPanelH
   if there is no field "tcTotals" then
      exit tcRelayout
   end if
   put the height of this stack into tH
   put (the width of this stack) - 16 into tRight
   -- table + panel share whatever is left after the fixed chrome (276px total:
   -- the 152px top block, an 18px detail strip, a 24px tab row, an 18px panel
   -- header, a 20px status bar, an 18px footer, the inter-region gaps, and an
   -- 8px bottom margin). The floor is 224 so the whole layout still fits the
   -- 500px minHeight exactly (276 + 224 = 500).
   put (tH - 276) into tAvail
   if tAvail < 224 then
      put 224 into tAvail
   end if
   put the round of (tAvail * 0.5) into tTableH
   put tAvail - tTableH into tPanelH
   -- top-to-bottom cursor from the fixed table top
   put 152 into tY
   set the rect of field "tcTorrents" to ("16," & tY & comma & tRight & comma & (tY + tTableH))
   put tY + tTableH + 4 into tY                 -- gap, then the detail strip
   set the rect of field "tcDetail" to ("16," & tY & comma & tRight & comma & (tY + 18))
   put tY + 22 into tY                          -- below the detail strip + gap
   tcRowTop "tcTabFiles,tcTabPeers,tcTabTrackers,tcTabLog,tcStream,tcQUp,tcQDown,tcHelp", tY
   put tY + 26 into tY                          -- below the tab row
   set the rect of field "tcInspectHdr" to ("16," & tY & comma & tRight & comma & (tY + 18))
   put tY + 18 into tY                          -- below the panel header
   set the rect of field "tcInspect" to ("16," & tY & comma & tRight & comma & (tY + tPanelH))
   set the rect of field "tcLog" to ("16," & tY & comma & tRight & comma & (tY + tPanelH))
   put tY + tPanelH + 4 into tY                 -- gap, then the status bar
   set the rect of field "tcTotals" to ("16," & tY & comma & tRight & comma & (tY + 20))
   put tY + 24 into tY                          -- gap, then the honesty footer
   -- move only the TOP (uiFooter is height-fit to its text; a rect set would
   -- re-clip it). Guarded: an old saved stack relayouts before its rebuild.
   if there is a field "uiFooter" then
      set the top of field "uiFooter" to tY
   end if
end tcRelayout

-- Move a comma-list of buttons to a common top (x / width / height preserved).
command tcRowTop pNames, pTop
   local tBtn
   set the itemDelimiter to comma
   repeat for each item tBtn in pNames
      set the top of button tBtn to pTop
   end repeat
end tcRowTop

-- ---- session lifecycle (adopts a still-live session, like the demo) ----------
command tcEnsureSession
   local tErr, tRemembered
   if sSession is not empty and sSession is not 0 then
      exit tcEnsureSession
   end if
   put the uSession of this stack into tRemembered
   if tRemembered is a number and tRemembered > 0 \
         and btSetBool(tRemembered, "enable_dht", true) is 0 then
      put tRemembered into sSession
      tcLogMsg "Re-adopted the still-live session (handle" && sSession & ")."
   else
      try
         btStartSession
         put the result into sSession
      catch tErr
         tcLogMsg "Could not start TorrentXT:" && tErr
         uiStatus "TorrentXT did not load - see the log.", "bad"
         put 0 into sSession
         exit tcEnsureSession
      end try
      if sSession is 0 or sSession is empty then
         tcLogMsg "btStartSession returned 0:" && btLastError()
         uiStatus "No session (another TorrentXT stack open?) - see the log.", "bad"
         put 0 into sSession
         set the uSession of this stack to empty
         exit tcEnsureSession
      end if
      btSetBool sSession, "enable_dht", true
      set the uSession of this stack to sSession
   end if
   btSetBool sSession, "enable_lsd", true
   -- seed the DHT with well-known routers so it bootstraps reliably on first run
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   tcLogMsg "Session ready (handle" && sSession & "). DHT/LSD on, routers seeded."
   uiStatus "Session ready - DHT bootstrapping...", "ok"
   put "true" into sPolling
   -- an addable magnet / info-hash may already be on the clipboard
   tcClipboardSuggest
   send "tcPollOnce" to me in 0 milliseconds
   send "tcRefreshLoop" to me in 600 milliseconds
end tcEnsureSession

command tcShutdown
   local tErr
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      -- try-guarded: shutdownRequest can arrive while the engine is already
      -- tearing extensions down, and quitting with the extension gone must
      -- not throw (an uncaught error here would abort the quit path and skip
      -- the prefs save below)
      try
         btStopSession sSession
      catch tErr
      end try
   end if
   put empty into sSession
   set the uSession of this stack to empty
   -- remember the user's settings for next launch
   if there is a field "tcSavePath" then
      set the uSavePath of this stack to tcTrim(field "tcSavePath")
      set the uUpLimit of this stack to tcTrim(field "tcUpLimit")
   end if
   tcPrefSave      -- mirror settings to the external prefs file (standalone-safe)
end tcShutdown

-- ---- persistence: settings survive in an external file -----------------------
-- A standalone cannot save its own mainstack, so the remembered save path, upload
-- cap, and window height would reset each launch. We mirror them to one plaintext
-- file in a per-user folder (no secrets here, so no encryption), hydrated on open
-- and written on close + on each settings change. Same file format as the channels
-- demo, mode "P" only.
function tcPrefFile
   local tBase, tErr
   put specialFolderPath("preferences") into tBase
   if tBase is empty or there is no folder tBase then
      put specialFolderPath("application data") into tBase
   end if
   if tBase is empty or there is no folder tBase then
      put specialFolderPath("documents") into tBase
   end if
   put tBase & "/TorrentXT" into tBase
   if there is no folder tBase then
      try
         create folder tBase
      catch tErr
      end try
   end if
   return tBase & "/client.prefs"
end tcPrefFile

command tcPrefLoad
   local tPath, tRaw, tA, tErr
   put tcPrefFile() into tPath
   if there is no file tPath then
      exit tcPrefLoad
   end if
   put url ("binfile:" & tPath) into tRaw
   if (the number of bytes in tRaw) < 9 then
      exit tcPrefLoad
   end if
   if textDecode(byte 1 to 9 of tRaw, "ASCII") is not (kPrefMagic & "P") then
      exit tcPrefLoad
   end if
   try
      put arrayDecode(byte 10 to -1 of tRaw) into tA
   catch tErr
      exit tcPrefLoad
   end try
   set the uSavePath of this stack to tA["uSavePath"]
   set the uUpLimit of this stack to tA["uUpLimit"]
   set the uHeight of this stack to tA["uHeight"]
end tcPrefLoad

command tcPrefSave
   local tA, tPath
   put the uSavePath of this stack into tA["uSavePath"]
   put the uUpLimit of this stack into tA["uUpLimit"]
   put the uHeight of this stack into tA["uHeight"]
   put tcPrefFile() into tPath
   put textEncode(kPrefMagic & "P", "ASCII") & arrayEncode(tA) into url ("binfile:" & tPath)
end tcPrefSave

function tcHaveSession
   if sSession is 0 or sSession is empty then
      tcLogMsg "No session - reopen the stack to start one."
      return false
   end if
   return true
end tcHaveSession

-- ---- clipboard auto-detect (the copy-a-magnet -> switch-to-client flow) -------
-- Does this text LOOK like something the Add box accepts? A magnet: link, an
-- http(s) .torrent URL, or a bare 40/64-hex info-hash. (A local .torrent PATH is
-- deliberately excluded - a random path on the clipboard is not a torrent intent.)
function tcLooksAddable pText
   local tHex, tI
   if pText begins with "magnet:" then
      return true
   end if
   if (pText begins with "http://" or pText begins with "https://") \
         and pText ends with ".torrent" then
      return true
   end if
   if the number of chars of pText is 40 or the number of chars of pText is 64 then
      put toLower(pText) into tHex
      repeat with tI = 1 to the number of chars of tHex
         if char tI of tHex is not in "0123456789abcdef" then
            return false
         end if
      end repeat
      return true
   end if
   return false
end tcLooksAddable

-- If the clipboard holds an addable item and the Add box is empty, pre-fill it
-- (never auto-add - the user still clicks Add / presses Enter, and duplicate
-- detection runs then). Runs at open and on resumeStack. Polite: never
-- overwrites what you typed, and offers each clipboard value only once. The
-- read is try-guarded (the clipboard can fail transiently on Windows).
command tcClipboardSuggest
   local tClip, tErr
   if there is no field "tcInput" then
      exit tcClipboardSuggest
   end if
   put "" into tClip
   try
      put tcTrim(the clipboardData["text"]) into tClip
   catch tErr
      exit tcClipboardSuggest
   end try
   if tClip is empty or tClip is sClipSuggested then
      exit tcClipboardSuggest
   end if
   put tClip into sClipSuggested   -- one offer per value, even if declined
   if not tcLooksAddable(tClip) then
      exit tcClipboardSuggest
   end if
   if tcTrim(field "tcInput") is not empty then
      exit tcClipboardSuggest
   end if
   put tClip into field "tcInput"
   tcLogMsg "Found an addable link on your clipboard - it is in the Add box; click Add (or press Enter) to start it."
end tcClipboardSuggest

-- ---- add (smart input + duplicate detection) ---------------------------------
-- The one Add field accepts whatever you paste: a magnet: link, an http(s) URL
-- to a .torrent, a local .torrent file path, or a bare 40-char info-hash. We
-- sniff it, refuse a duplicate (same info-hash already in the session), and
-- otherwise route to btAddMagnet / btAddTorrentFile.
command tcAddInput
   local tInput, tData, tHash, tDup
   if not tcHaveSession() then
      exit tcAddInput
   end if
   put tcTrim(field "tcInput") into tInput
   if tInput is empty then
      tcLogMsg "Paste a magnet, a .torrent path, an http(s) .torrent URL, or an info-hash."
      exit tcAddInput
   end if
   if tInput begins with "magnet:" then
      put tcDupCheck(tcMagnetHash(tInput)) into tDup
      if tDup is 0 then
         tcReportAdd btAddMagnet(sSession, tInput, field "tcSavePath"), "magnet"
      end if
   else if tInput begins with "http://" or tInput begins with "https://" then
      tcLogMsg "Downloading .torrent from" && tInput && "..."
      put url tInput into tData
      if the result is not empty then
         tcLogMsg "Download failed:" && the result
      else if tData is empty then
         tcLogMsg "Download returned no data from" && tInput
      else
         tcReportAdd btAddTorrentFile(sSession, tData, field "tcSavePath"), ".torrent (URL)"
      end if
   else if there is a file tInput then
      put url ("binfile:" & tInput) into tData
      if tData is empty then
         tcLogMsg "Could not read" && tInput
      else
         tcReportAdd btAddTorrentFile(sSession, tData, field "tcSavePath"), ".torrent file"
      end if
   else if matchText(tInput, "^[0-9A-Fa-f]{40}$") then
      put tcDupCheck(toLower(tInput)) into tDup
      if tDup is 0 then
         tcReportAdd btAddMagnet(sSession, ("magnet:?xt=urn:btih:" & tInput), field "tcSavePath"), "info-hash"
      end if
   else
      tcLogMsg "Unrecognized input - use a magnet:, an http(s) .torrent URL, a .torrent file path, or a 40-char info-hash."
   end if
end tcAddInput

command tcAddTorrentFile
   local tFile, tData
   if not tcHaveSession() then
      exit tcAddTorrentFile
   end if
   answer file "Choose a .torrent file to add:"
   put it into tFile
   if tFile is empty then
      exit tcAddTorrentFile
   end if
   put url ("binfile:" & tFile) into tData
   if tData is empty then
      tcLogMsg "Could not read" && tFile
   else
      tcReportAdd btAddTorrentFile(sSession, tData, field "tcSavePath"), ".torrent file"
   end if
end tcAddTorrentFile

-- Build a .torrent from a folder, then add it pointing at that folder's PARENT
-- so libtorrent rechecks the existing files, finds them complete, and seeds.
command tcCreateAndSeed
   local tPath, tData, tParent, tTrackers
   if not tcHaveSession() then
      exit tcCreateAndSeed
   end if
   answer folder "Choose a folder to create a torrent from and seed:"
   put it into tPath
   if tPath is empty then
      exit tcCreateAndSeed
   end if
   -- optional announce URLs (one per line). Blank = trackerless, DHT-only
   -- seeding, which works because this client runs the DHT; a tracker just
   -- adds another way for peers to find the swarm.
   ask "Tracker announce URLs to embed (one per line; blank = DHT-only):" \
      with "udp://tracker.opentrackr.org:1337/announce"
   put it into tTrackers
   tcLogMsg "Creating torrent for" && tPath && "..."
   put btCreateTorrent(tPath, 0, 0, tTrackers) into tData
   if tData is empty then
      tcLogMsg "Create failed:" && btLastError()
      exit tcCreateAndSeed
   end if
   -- compute the folder's PARENT, separator-agnostically: answer folder returns
   -- back-slash paths on Windows, where splitting on "/" alone would leave tPath
   -- unchanged and break the save-path -> existing-files mapping (seeding fails).
   replace "\" with "/" in tPath
   if the last char of tPath is "/" then
      delete the last char of tPath
   end if
   set the itemDelimiter to "/"
   put item 1 to -2 of tPath into tParent
   if tParent is empty then
      put "/" into tParent
   end if
   tcReportAdd btAddTorrentFile(sSession, tData, tParent), "seed of" && tPath
end tcCreateAndSeed

-- Pick the download folder with the native chooser; update the field and
-- remember it for next launch.
command tcBrowseSave
   answer folder "Choose the download folder:"
   if it is empty then
      exit tcBrowseSave
   end if
   put it into field "tcSavePath"
   set the uSavePath of this stack to it
   tcPrefSave
   tcLogMsg "Save folder set to" && it
end tcBrowseSave

-- Look for an existing torrent with this (v1, hex) info-hash. If found, select it
-- and return its handle; else return 0. "" hash -> 0 (cannot pre-check).
function tcDupCheck pHash
   local tH
   put tcFindByHash(pHash) into tH
   if tH is not 0 then
      tcLogMsg "Already in the list (handle" && tH & ") - selecting it."
      tcSelectHandle tH
      put empty into field "tcInput"
   end if
   return tH
end tcDupCheck

function tcFindByHash pHash
   local tCount, tI, tH
   if pHash is empty then
      return 0
   end if
   put btTorrentCount(sSession) into tCount
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is not 0 and toLower(btInfoHash(tH)) is toLower(pHash) then
         return tH
      end if
   end repeat
   return 0
end tcFindByHash

-- Extract the btih info-hash from a magnet URI ("" if absent / non-btih).
function tcMagnetHash pMagnet
   local tOff, tRest
   put offset("urn:btih:", pMagnet) into tOff
   if tOff is 0 then
      return ""
   end if
   put char (tOff + 9) to -1 of pMagnet into tRest   -- after "urn:btih:"
   put offset("&", tRest) into tOff
   if tOff > 0 then
      put char 1 to (tOff - 1) of tRest into tRest
   end if
   return toLower(tRest)
end tcMagnetHash

-- Shared reporting for every add path: log + clear the field + repaint on success.
command tcReportAdd pHandle, pKind
   if pHandle is 0 then
      tcLogMsg "Add failed (" & pKind & "):" && btLastError()
   else
      tcLogMsg "Added" && pKind && "(handle" && pHandle & ")."
      -- a magnet-style add has no metadata yet and can wait forever (dead
      -- magnet, cold DHT): arm the one-shot 60 s diagnosis for it. Cleared by
      -- the metadataReceived event, or when the torrent is removed. A .torrent
      -- add carries its metadata, so it never arms this.
      if pKind is "magnet" or pKind is "info-hash" then
         put the milliseconds into sMetaWait[pHandle]
         delete variable sMetaHinted[pHandle]
      end if
      put empty into field "tcInput"
      tcRefreshOnce
   end if
end tcReportAdd

-- Drop a removed torrent's pending watchdog entries, so a handle that is gone
-- can never produce a late diagnosis line about a torrent nobody can see.
command tcForgetWatchdogs pHandle
   delete variable sMetaWait[pHandle]
   delete variable sMetaHinted[pHandle]
   delete variable sResumeWait[pHandle]
   delete variable sResumeHinted[pHandle]
end tcForgetWatchdogs

-- ---- per-torrent control (on the selected table row) -------------------------
command tcControlSelected pAction
   local tH, tLine, tLeft, tR
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent in the table first."
      exit tcControlSelected
   end if
   put item 1 of (the hilitedLines of field "tcTorrents") into tLine
   -- every control call captures `the result` (bt* commands report 0 / a
   -- negative error there): the old unconditional lines claimed "Paused"
   -- for a refused call on a stale handle, which is the kind of false log
   -- line a bug report then chases.
   switch pAction
      case "pause"
         btPause tH
         put the result into tR
         if tR is not empty and tR < 0 then
            tcLogMsg "! pause failed for torrent" && tH & ":" && btLastError()
         else
            tcLogMsg "Paused torrent" && tH
         end if
         break
      case "resume"
         btResume tH
         put the result into tR
         if tR is not empty and tR < 0 then
            tcLogMsg "! resume failed for torrent" && tH & ":" && btLastError()
         else
            tcLogMsg "Resumed torrent" && tH
         end if
         break
      case "recheck"
         btForceRecheck tH
         put the result into tR
         if tR is not empty and tR < 0 then
            tcLogMsg "! recheck failed for torrent" && tH & ":" && btLastError()
         else
            tcLogMsg "Rechecking torrent" && tH
         end if
         break
      case "reannounce"
         btForceReannounce tH
         put the result into tR
         if tR is not empty and tR < 0 then
            tcLogMsg "! reannounce failed for torrent" && tH & ":" && btLastError()
         else
            tcLogMsg "Reannounced torrent" && tH
         end if
         break
      case "remove"
         btRemoveTorrent sSession, tH, false
         put the result into tR
         if tR is not empty and tR < 0 then
            tcLogMsg "! remove failed for torrent" && tH & ":" && btLastError()
         else
            tcLogMsg "Removed torrent" && tH && "(kept files)"
            tcForgetWatchdogs tH
         end if
         break
      case "removeData"
         answer "Delete the downloaded files for torrent" && tH & "?" with "Cancel" or "Delete"
         if it is not "Delete" then
            exit tcControlSelected
         end if
         btRemoveTorrent sSession, tH, true
         put the result into tR
         if tR is not empty and tR < 0 then
            tcLogMsg "! remove+data failed for torrent" && tH & ":" && btLastError()
         else
            tcLogMsg "Removed torrent" && tH && "AND deleted its files"
            tcForgetWatchdogs tH
         end if
         break
   end switch
   tcRefreshOnce
   -- after a removal the row indices shift; keep a neighbouring row selected so
   -- the per-torrent buttons stay live and the user keeps their place.
   if pAction is "remove" or pAction is "removeData" then
      put btTorrentCount(sSession) into tLeft
      if tLeft > 0 then
         if tLine is not a number then
            put 1 into tLine
         end if
         if tLine > tLeft then
            put tLeft into tLine
         end if
         if tLine < 1 then
            put 1 into tLine
         end if
         set the hilitedLines of field "tcTorrents" to tLine
         tcEnableControls true
         tcUpdateDetail tcSelectedHandle()
      end if
   end if
end tcControlSelected

-- Space-bar handler: pause a running torrent, resume a paused one.
command tcToggleSelected
   local tH, tS
   put tcSelectedHandle() into tH
   if tH is 0 then
      exit tcToggleSelected
   end if
   put btTorrentStatus(tH) into tS
   if tS["isPaused"] is "1" then
      btResume tH
      tcLogMsg "Resumed torrent" && tH
   else
      btPause tH
      tcLogMsg "Paused torrent" && tH
   end if
   tcRefreshOnce
end tcToggleSelected

-- Pause or resume every torrent in the session.
command tcAllTorrents pAction
   local tCount, tI, tH
   if not tcHaveSession() then
      exit tcAllTorrents
   end if
   put btTorrentCount(sSession) into tCount
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is not 0 then
         if pAction is "pause" then
            btPause tH
         else
            btResume tH
         end if
      end if
   end repeat
   tcLogMsg (pAction & "d") && "all" && tCount && "torrents."
   tcRefreshOnce
end tcAllTorrents

-- Open the selected torrent's download folder in the OS file manager.
command tcOpenFolder
   local tH, tS, tPath
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcOpenFolder
   end if
   put btTorrentStatus(tH) into tS
   put tS["savePath"] into tPath
   if tPath is empty then
      tcLogMsg "No save path for that torrent yet."
      exit tcOpenFolder
   end if
   launch document tPath
   tcLogMsg "Opening folder" && tPath
end tcOpenFolder

-- Copy a magnet link for the selected torrent (built from its info-hash) to the
-- clipboard - handy to share or re-add.
command tcCopyMagnet
   local tH, tHash, tS, tName, tMag
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcCopyMagnet
   end if
   put btInfoHash(tH) into tHash
   if tHash is empty then
      tcLogMsg "No info-hash yet (metadata still pending)."
      exit tcCopyMagnet
   end if
   put "magnet:?xt=urn:btih:" & tHash into tMag
   put btTorrentStatus(tH) into tS
   put tS["name"] into tName
   if tName is not empty then
      put tMag & "&dn=" & urlEncode(tName) into tMag
   end if
   set the clipboardData["text"] to tMag
   uiCopyFlash "tcCopyMagnet"
   tcLogMsg "Copied magnet to clipboard:" && tMag
end tcCopyMagnet

-- Ask libtorrent to flush resume data for the selected torrent; it arrives
-- asynchronously as a resumeDataReady event (logged below).
command tcSaveResume
   local tH
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcSaveResume
   end if
   btSaveResumeData tH
   -- the reply is an async resumeDataReady event, and libtorrent can simply
   -- never send one (metadata-less or errored torrent): arm the one-shot 30 s
   -- diagnosis so the silence is named instead of waited on forever
   put the milliseconds into sResumeWait[tH]
   delete variable sResumeHinted[tH]
   tcLogMsg "Requested resume data for torrent" && tH && "(arrives as a resumeDataReady event)."
end tcSaveResume

function tcSelectedHandle
   local tNum
   put item 1 of (the hilitedLines of field "tcTorrents") into tNum
   if tNum is empty or tNum is not a number then
      return 0
   end if
   if sLineHandles[tNum] is empty then
      return 0
   end if
   return sLineHandles[tNum]
end tcSelectedHandle

-- Select the table row that maps to pHandle (after a refresh rebuilds the map).
command tcSelectHandle pHandle
   local tKey, tFound
   tcRefreshOnce
   put 0 into tFound
   repeat for each key tKey in sLineHandles
      if sLineHandles[tKey] is pHandle then
         put tKey into tFound
         exit repeat
      end if
   end repeat
   if tFound > 0 then
      set the hilitedLines of field "tcTorrents" to tFound
   end if
end tcSelectHandle

command tcApplyUpLimit
   local tKB
   if not tcHaveSession() then
      exit tcApplyUpLimit
   end if
   put tcTrim(field "tcUpLimit") into tKB
   if tKB is empty or tKB is not a number then
      put 0 into tKB
   end if
   -- value crosses as a STRING (settings can be 64-bit); 0 == unlimited
   btSetInt sSession, "upload_rate_limit", (trunc(tKB * 1024) & "")
   set the uUpLimit of this stack to tKB
   tcPrefSave
   tcLogMsg "Upload limit set to" && tKB && "KB/s"
end tcApplyUpLimit

-- ---- the poll loop (one FFI drain per pass) ----------------------------------
command tcPollOnce
   local tEvents, tEvent
   -- pin the stack: a `send ... in` tick has no defaultStack guarantee, and every
   -- control this reaches is named unqualified (OXT-ENGINE-NOTES 5.3)
   set the defaultStack to the short name of this stack
   if sPolling is not "true" then
      exit tcPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit tcPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      tcHandleEvent tEvent
   end repeat
   send "tcPollOnce" to me in 250 milliseconds
end tcPollOnce

command tcHandleEvent pEvent
   local tHandle
   switch pEvent["name"]
      case "torrentAdded"
         tcLogMsg "+ added torrent" && pEvent["torrent"]
         tcRefreshOnce
         break
      case "metadataReceived"
         -- the metadata watchdog is satisfied; forget its pending entry
         put pEvent["torrent"] into tHandle
         delete variable sMetaWait[tHandle]
         delete variable sMetaHinted[tHandle]
         -- the event now carries the resolved name directly (F_EVT_NAME); fall
         -- back to a status lookup if an older native lib leaves it empty.
         if pEvent["torrentName"] is not empty then
            tcLogMsg "  metadata received:" && pEvent["torrentName"]
         else
            tcLogMsg "  metadata received:" && tcTorrentName(pEvent["torrent"])
         end if
         tcRefreshOnce
         break
      case "torrentFinished"
         tcLogMsg "* FINISHED:" && tcTorrentName(pEvent["torrent"]) && "- now seeding"
         tcRefreshOnce
         break
      case "torrentError"
         tcLogMsg "! error:" && pEvent["errorMessage"]
         break
      case "trackerReply"
         tcLogMsg "  tracker" && pEvent["tracker"] && "- peers" && pEvent["numPeers"]
         break
      case "resumeDataReady"
         -- the resume-data watchdog is satisfied; forget its pending entry
         put pEvent["torrent"] into tHandle
         delete variable sResumeWait[tHandle]
         delete variable sResumeHinted[tHandle]
         tcLogMsg "  resume data ready for torrent" && pEvent["torrent"] && \
            "(" & (the number of bytes in pEvent["resumeData"]) && "bytes)"
         break
      case "dhtBootstrap"
         tcLogMsg "  DHT bootstrapped."
         break
      default
         -- stateChanged / pieceFinished etc. are reflected in the table, not logged
         break
   end switch
end tcHandleEvent

-- ---- the low-rate dashboard --------------------------------------------------
-- tcRefreshLoop reschedules itself; tcRefreshOnce just repaints. Direct callers
-- (adds, controls, events) use tcRefreshOnce so they never start a 2nd timer.
command tcRefreshLoop
   -- pin the stack: a `send ... in` tick has no defaultStack guarantee, and every
   -- control this reaches is named unqualified (OXT-ENGINE-NOTES 5.3)
   set the defaultStack to the short name of this stack
   if sPolling is not "true" then
      exit tcRefreshLoop
   end if
   tcRefreshOnce
   send "tcRefreshLoop" to me in 800 milliseconds
end tcRefreshLoop

command tcRefreshOnce
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tSelH, tSelLine, tNewMap, tLineNum, tNodes, tDht
   local tColors, tErr
   local tSeed, tDl, tPause, tCheck, tAllUp, tAllDown, tRatio, tSummary2
   local tNow, tWaitKey
   if sSession is 0 or sSession is empty then
      exit tcRefreshOnce
   end if
   -- defensive: never touch the table before the UI is built (a stale refresh
   -- tick could otherwise arrive between session start and build - see openStack)
   if there is no field "tcTorrents" then
      exit tcRefreshOnce
   end if
   -- collapse the whole rebuild (text + per-line colors + hilite + totals) into
   -- a single repaint; without this the list visibly flickers on every poll.
   lock screen
   put tcSelectedHandle() into tSelH      -- remember the selection across the rebuild
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put 0 into tSeed
   put 0 into tDl
   put 0 into tPause
   put 0 into tCheck
   put 0 into tAllUp
   put 0 into tAllDown
   put empty into tNewMap
   put 0 into tLineNum
   put empty into tSelLine
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put tH into tNewMap[tLineNum]
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      put tcStateColor(tS["state"], tS["error"]) into tColors[tLineNum]
      put tLineNum & tab & tcTrunc(tS["name"], 28) & tab & tcStateName(tS["state"]) & tab & \
          tcProgressBar(tPct) & tab & (tcFmtBytes(tS["downloadRate"]) & "/s") & tab & \
          (tcFmtBytes(tS["uploadRate"]) & "/s") & tab & \
          tS["numPeers"] & tab & tcFmtBytes(tS["totalSize"]) & return after tRows
      add tS["downloadRate"] to tDown
      add tS["uploadRate"] to tUp
      -- session tallies: one mutually-exclusive state bucket + all-time bytes
      if tS["isPaused"] is "1" then
         add 1 to tPause
      else if tS["isSeeding"] is "1" then
         add 1 to tSeed
      else if tS["state"] is 3 then
         add 1 to tDl
      else
         add 1 to tCheck
      end if
      add tS["allTimeUpload"] to tAllUp
      add tS["allTimeDownload"] to tAllDown
      if tSelH is not 0 and tH is tSelH then
         put tLineNum into tSelLine
      end if
   end repeat
   put tNewMap into sLineHandles
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   set the text of field "tcTorrents" to tRows
   if tLineNum is 0 then
      set the text of field "tcTorrents" to \
         "No torrents yet - paste a magnet or .torrent above, or Create + Seed a folder."
      set the foregroundColor of line 1 of field "tcTorrents" to kUiMuted
   end if
   if tSelLine is not empty then
      set the hilitedLines of field "tcTorrents" to tSelLine
   end if
   -- color each row by state (green=seeding/done, blue=downloading,
   -- amber=checking, gray=paused/queued, red=error). Wrapped so a platform that
   -- dislikes per-line coloring still shows the table, just monochrome.
   try
      repeat with tI = 1 to tLineNum
         set the foregroundColor of line tI of field "tcTorrents" to tColors[tI]
      end repeat
   catch tErr
   end try
   -- per-torrent buttons are usable only when a row is selected
   tcEnableControls (tSelLine is not empty)
   -- DHT status: show the real routing-table node count from the shim's
   -- session_stats. This client always enables DHT at startup, so a 0 count just
   -- means it is still bootstrapping into the swarm (the count climbs within a
   -- few seconds of the first add).
   put btDhtState(sSession) into tS
   put tS["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("DHT:" && tNodes && "nodes") into tDht
   else
      put "DHT: on" into tDht
   end if
   -- session summary: state breakdown + aggregate rates + share ratio + DHT
   put tcRatio(tAllUp, tAllDown) into tRatio
   put "(" & tSeed && "seeding," && tDl && "dl," && tPause && "paused" into tSummary2
   if tCheck > 0 then
      put tSummary2 & "," && tCheck && "checking" into tSummary2
   end if
   put tSummary2 & ")" into tSummary2
   put tLineNum && "torrents" && tSummary2 && " down" && (tcFmtBytes(tDown) & "/s") \
      && " up" && (tcFmtBytes(tUp) & "/s") && " ratio" && tRatio && "  " & tDht into field "tcTotals"
   -- the kit's headline status carries session health; the totals bar above
   -- keeps the numbers (green only once the DHT actually has nodes)
   if tNodes is a number and tNodes > 0 then
      uiStatus ("Session live -" && tDht), "ok"
   else
      uiStatus ("Session live -" && tDht && "- bootstrapping..."), empty
   end if
   tcUpdateDetail tSelH
   tcUpdateStreamButton tSelH
   tcUpdatePanel
   unlock screen
   -- the metadata / resume-data watchdogs (armed in tcReportAdd / tcSaveResume):
   -- one spoken diagnosis per pending entry once its window passes; nothing is
   -- removed and both waits continue - the peer may simply be offline. One
   -- clock read serves both scans (single-thread playbook).
   put the milliseconds into tNow
   repeat for each key tWaitKey in sMetaWait
      if sMetaHinted[tWaitKey] is not "true" and (tNow - sMetaWait[tWaitKey]) > (kTcMetaHintSecs * 1000) then
         put "true" into sMetaHinted[tWaitKey]
         tcLogMsg "* still no metadata for" && tcTorrentName(tWaitKey) && "after" && kTcMetaHintSecs && "s - dead magnet? DHT still bootstrapping (watch the node count)? UDP blocked? Still trying."
      end if
   end repeat
   repeat for each key tWaitKey in sResumeWait
      if sResumeHinted[tWaitKey] is not "true" and (tNow - sResumeWait[tWaitKey]) > (kTcResumeHintSecs * 1000) then
         put "true" into sResumeHinted[tWaitKey]
         tcLogMsg "* no resumeDataReady for" && tcTorrentName(tWaitKey) && "after" && kTcResumeHintSecs && "s - libtorrent never answers for a metadata-less or errored torrent; Save Res again to retry."
      end if
   end repeat
end tcRefreshOnce

-- A one-line detail readout for the selected torrent: info-hash, save path, ETA,
-- seeds. Shows off the richer btTorrentStatus / btInfoHash fields.
command tcUpdateDetail pHandle
   local tS, tLine
   if pHandle is 0 then
      put "Select a torrent to see its details." into field "tcDetail"
      exit tcUpdateDetail
   end if
   put btTorrentStatus(pHandle) into tS
   put "hash:" && tcShortHash(btInfoHash(pHandle)) && "|  save:" && tS["savePath"] \
      && "|  ETA:" && tcFmtEta(tS["eta"]) && "|  seeds:" && tS["numSeeds"] \
      && "|  peers:" && tS["numPeers"] \
      && "|  ratio:" && tcRatio(tS["allTimeUpload"], tS["allTimeDownload"]) \
      && "|  done:" && tcFmtBytes(tS["totalDone"]) into tLine
   if tS["error"] is not empty then
      put tLine && "|  ERROR:" && tS["error"] into tLine
   end if
   put tLine into field "tcDetail"
end tcUpdateDetail

-- Resolve a torrent's display name (falls back to "torrent N" before metadata).
function tcTorrentName pHandle
   local tS
   if pHandle is 0 or pHandle is empty then
      return "?"
   end if
   put btTorrentStatus(pHandle) into tS
   if tS["name"] is empty then
      return ("torrent" && pHandle)
   end if
   return tS["name"]
end tcTorrentName

-- Enable/disable the per-torrent control buttons in one pass (they act on the
-- selected row, so they are live only while a row is selected). The inspector
-- tab buttons are NOT in this set - they stay clickable so you can switch tabs
-- and read the "select a torrent" hint even with nothing selected.
command tcEnableControls pOn
   local tBtn
   set the itemDelimiter to comma
   repeat for each item tBtn in "tcPause,tcResume,tcRecheck,tcReannounce,tcRemove,tcRemoveData,tcOpenFolder,tcCopyMagnet,tcSaveResume,tcStream,tcQUp,tcQDown"
      set the disabled of button tBtn to (not pOn)
   end repeat
end tcEnableControls

-- ---- the live inspector (Files / Peers / Trackers tabs) ----------------------
-- Delete every generated control (named "tc...") top-down, so a kUiVersion bump
-- can rebuild the UI from scratch in a SAVED stack without leaving stale controls
-- behind. Controls the user added (not named "tc...") are left untouched.
command tcClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of fields of this card down to 1
      if the short name of field tI of this card begins with "tc" then
         delete field tI of this card
      end if
   end repeat
   repeat with tI = the number of buttons of this card down to 1
      if the short name of button tI of this card begins with "tc" then
         delete button tI of this card
      end if
   end repeat
   -- migration: a stack saved by a pre-kit version carries a tc-prefixed
   -- title-band graphic (tcTitleBg); the kit's own ui* controls are reused
   -- idempotently and are never cleared here
   repeat with tI = the number of graphics of this card down to 1
      if the short name of graphic tI of this card begins with "tc" then
         delete graphic tI of this card
      end if
   end repeat
   unlock screen
end tcClearGeneratedUI

-- Refill the inspector + detail + control state the instant the table selection
-- changes, instead of waiting for the next 800 ms refresh tick.
command tcOnSelect
   local tH
   put tcSelectedHandle() into tH
   tcEnableControls (tH is not 0)
   tcUpdateStreamButton tH
   tcUpdateDetail tH
   tcUpdatePanel
end tcOnSelect

-- Switch the bottom panel to a tab. The active tab's button is disabled so it
-- reads as "current". The Log tab shows the event-log field in the same region;
-- the data tabs show the inspector list with a per-tab header + tab stops (tab
-- stops are absolute pixels and must stay inside the field), then repaint.
command tcSetTab pTab
   put pTab into sPanelTab
   set the disabled of button "tcTabFiles" to (pTab is "files")
   set the disabled of button "tcTabPeers" to (pTab is "peers")
   set the disabled of button "tcTabTrackers" to (pTab is "trackers")
   set the disabled of button "tcTabLog" to (pTab is "log")
   if pTab is "log" then
      set the tabStops of field "tcInspectHdr" to empty
      put "  Event log" into field "tcInspectHdr"
      set the visible of field "tcInspect" to false
      set the visible of field "tcLog" to true
      set the vScroll of field "tcLog" to the formattedHeight of field "tcLog"
      exit tcSetTab
   end if
   set the visible of field "tcLog" to false
   set the visible of field "tcInspect" to true
   switch pTab
      case "peers"
         set the tabStops of field "tcInspectHdr" to "210,370,450,530"
         set the tabStops of field "tcInspect" to "210,370,450,530"
         put "Peer" & tab & "Client" & tab & "Down" & tab & "Up" & tab & "Have" into field "tcInspectHdr"
         break
      case "trackers"
         set the tabStops of field "tcInspectHdr" to "470,520"
         set the tabStops of field "tcInspect" to "470,520"
         put "Tracker" & tab & "Tier" & tab & "Status" into field "tcInspectHdr"
         break
      default          -- "files"
         set the tabStops of field "tcInspectHdr" to "360,450,580"
         set the tabStops of field "tcInspect" to "360,450,580"
         put "Name" & tab & "Size" & tab & "Progress" & tab & "Priority" into field "tcInspectHdr"
         break
   end switch
   tcUpdatePanel
end tcSetTab

-- Repaint the inspector for the selected torrent + active tab. ONE FFI call for
-- the selected torrent only (btFileList / btPeerList / btTrackers returns the
-- whole table in a single round-trip), so it stays cheap on the 800 ms refresh.
command tcUpdatePanel
   local tH, tList, tRow, tOut, tPct, tLine, tColors, tErr, tKeepLine, tStatus
   if there is no field "tcInspect" then
      exit tcUpdatePanel
   end if
   if sPanelTab is "log" then
      exit tcUpdatePanel        -- the Log tab is up; the inspector is hidden
   end if
   put tcSelectedHandle() into tH
   if tH is 0 then
      set the text of field "tcInspect" to "Select a torrent above to inspect its files, peers, and trackers."
      set the foregroundColor of line 1 of field "tcInspect" to kUiMuted
      exit tcUpdatePanel
   end if
   put item 1 of (the hilitedLines of field "tcInspect") into tKeepLine
   put "" into tOut
   put 0 into tLine
   put empty into tColors
   switch sPanelTab
      case "peers"
         put btPeerList(tH) into tList
         repeat for each element tRow in tList
            add 1 to tLine
            put tcTrunc(tRow["endpoint"], 26) & tab & tcTrunc(tRow["client"], 22) & tab & \
               (tcFmtBytes(tRow["downRate"]) & "/s") & tab & \
               (tcFmtBytes(tRow["upRate"]) & "/s") & tab & \
               (the round of (tRow["progress"] * 100)) & "%" & return after tOut
         end repeat
         if tLine is 0 then
            put "No peers connected yet (still finding the swarm)." into tOut
         end if
         break
      case "trackers"
         put btTrackers(tH) into tList
         repeat for each element tRow in tList
            add 1 to tLine
            if tRow["verified"] is "1" then
               put "working" into tStatus
            else
               put "pending" into tStatus
            end if
            put tcTrunc(tRow["url"], 62) & tab & tRow["tier"] & tab & tStatus & return after tOut
         end repeat
         if tLine is 0 then
            put "No trackers - this torrent relies on DHT / PEX / LSD." into tOut
         end if
         break
      default          -- "files"
         put btFileList(tH) into tList
         repeat for each element tRow in tList
            add 1 to tLine
            if tRow["size"] is a number and tRow["size"] > 0 then
               put (the round of (tRow["progress"] / tRow["size"] * 100)) into tPct
            else
               put 0 into tPct
            end if
            put tcFileLabel(tRow["path"], 44) & tab & tcFmtBytes(tRow["size"]) & tab & \
               tcProgressBar(tPct) & tab & tcPrioText(tRow["priority"]) & return after tOut
            -- grey out skipped files, green completed ones; default otherwise
            if tRow["priority"] is 0 then
               put kUiMuted into tColors[tLine]
            else if tPct >= 100 then
               put kClrRowSeed into tColors[tLine]
            end if
         end repeat
         if tLine is 0 then
            put "No file list yet (metadata still pending)." into tOut
         end if
         break
   end switch
   if the last char of tOut is return then
      delete the last char of tOut
   end if
   set the text of field "tcInspect" to tOut
   -- re-apply per-line colours (files tab only); wrapped so a platform that
   -- dislikes per-line colouring still shows the list, just monochrome.
   try
      repeat for each key tLine in tColors
         set the foregroundColor of line tLine of field "tcInspect" to tColors[tLine]
      end repeat
   catch tErr
   end try
   -- keep the file row the user was on selected across the repaint
   if tKeepLine is a number and tKeepLine >= 1 \
         and tKeepLine <= the number of lines of field "tcInspect" then
      set the hilitedLines of field "tcInspect" to tKeepLine
   end if
end tcUpdatePanel

-- Double-clicking a file row cycles its priority skip -> normal -> high -> skip.
-- The file index is the (1-based) line minus one; libtorrent indexes from 0.
command tcCycleFilePriority
   local tH, tLine, tIdx, tList, tRow, tI, tCur, tNext
   put tcSelectedHandle() into tH
   if tH is 0 then
      exit tcCycleFilePriority
   end if
   put item 1 of (the hilitedLines of field "tcInspect") into tLine
   if tLine is not a number or tLine < 1 then
      exit tcCycleFilePriority
   end if
   put tLine - 1 into tIdx
   put btFileList(tH) into tList
   put 0 into tI
   put -1 into tCur
   repeat for each element tRow in tList
      add 1 to tI
      if tI is tLine then
         put tRow["priority"] into tCur
         exit repeat
      end if
   end repeat
   if tCur is -1 then
      exit tcCycleFilePriority      -- the click was past the end of the list
   end if
   if tCur is 0 then
      put 4 into tNext              -- skip -> normal
   else if tCur < 7 then
      put 7 into tNext              -- low / normal -> high
   else
      put 0 into tNext              -- high -> skip
   end if
   btSetFilePriority tH, tIdx, tNext
   tcLogMsg "File" && tIdx & ": priority ->" && tcPrioText(tNext)
   tcUpdatePanel
   set the hilitedLines of field "tcInspect" to tLine
end tcCycleFilePriority

-- Toggle sequential (streaming) download for the selected torrent. The per-
-- torrent state lives in sSeqOn so the button label + behaviour stay in sync.
command tcStreamToggle
   local tH, tOn
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcStreamToggle
   end if
   if sSeqOn[tH] is "true" then
      put false into tOn
   else
      put true into tOn
   end if
   btSetSequentialDownload tH, tOn
   if tOn then
      put "true" into sSeqOn[tH]
      tcLogMsg "Streaming (sequential) ON for torrent" && tH && "- pieces fill front-to-back."
   else
      put "false" into sSeqOn[tH]
      tcLogMsg "Streaming (sequential) OFF for torrent" && tH
   end if
   tcUpdateStreamButton tH
end tcStreamToggle

-- Reflect the selected torrent's streaming state on the toggle button's label.
command tcUpdateStreamButton pHandle
   if there is no button "tcStream" then
      exit tcUpdateStreamButton
   end if
   if pHandle is not 0 and pHandle is not empty and sSeqOn[pHandle] is "true" then
      set the label of button "tcStream" to "Stream: ON"
   else
      set the label of button "tcStream" to "Stream: off"
   end if
end tcUpdateStreamButton

-- Move the selected torrent up / down libtorrent's download queue (which
-- torrents get to run when the active-torrent limit is reached).
command tcQueue pDir
   local tH
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent first."
      exit tcQueue
   end if
   if pDir is "up" then
      btQueueUp tH
      tcLogMsg "Moved torrent" && tH && "up in the queue."
   else
      btQueueDown tH
      tcLogMsg "Moved torrent" && tH && "down in the queue."
   end if
   tcRefreshOnce
end tcQueue

-- A short overview dialog (the "What is this?" button).
command tcHelp
   answer "TorrentXT Client - a multi-torrent BitTorrent client in pure xTalk." & return & return & \
      "ADD: paste a magnet, an http(s) .torrent URL, a local .torrent path, or a 40-hex info-hash - or just drag a .torrent / magnet onto the window." & return & return & \
      "INSPECT: select a torrent, then use the Files / Peers / Trackers / Log tabs in the bottom panel. On Files, double-click a row to cycle its priority (skip -> normal -> high); skipped files are not downloaded." & return & return & \
      "STREAM turns on sequential download so a media file fills front-to-back. Q Up / Q Down reorder which torrents run first." & return & return & \
      "Shortcuts: Space pauses/resumes, Delete removes, double-click a row opens its folder." \
      with "OK"
end tcHelp

-- ---- small helpers -----------------------------------------------------------
function tcStateName pState
   switch pState
      case 1
         return "checking"
      case 2
         return "metadata"
      case 3
         return "downloading"
      case 4
         return "finished"
      case 5
         return "seeding"
      case 7
         return "check-resume"
      default
         return "queued"
   end switch
end tcStateName

-- A compact 10-segment ASCII progress bar, e.g. [#######---] 72.5%. Fixed width
-- so it lines up in the monospaced table; trunc (not round) of the tenths keeps
-- the bar from reading "full" until a torrent is genuinely at 100%.
function tcProgressBar pPct
   local tFilled
   put trunc(pPct / 10) into tFilled
   if tFilled < 0 then
      put 0 into tFilled
   end if
   if tFilled > 10 then
      put 10 into tFilled
   end if
   return "[" & (char 1 to tFilled of "##########") & \
      (char 1 to (10 - tFilled) of "----------") & "]" && pPct & "%"
end tcProgressBar

-- Row text color by torrent state (the numeric state from the status record),
-- with any error overriding everything to red. Mirrors tcStateName's numbering.
function tcStateColor pState, pError
   if pError is not empty then
      return kClrRowErr
   end if
   switch pState
      case 4
      case 5
         return kClrRowSeed
      case 3
         return kClrRowDown
      case 1
      case 2
      case 7
         return kClrRowWait
      default
         return kClrRowIdle
   end switch
end tcStateColor

function tcFmtBytes pBytes
   local tUnits, tVal, tI
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB,TiB" into tUnits
   set the itemDelimiter to comma
   put pBytes into tVal
   put 1 into tI
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   return (the round of (tVal * 10) / 10) && (item tI of tUnits)
end tcFmtBytes

function tcFmtEta pSecs
   local tMin, tHrs
   if pSecs is empty or pSecs is not a number or pSecs <= 0 then
      return "-"
   end if
   if pSecs < 60 then
      return pSecs & "s"
   end if
   put trunc(pSecs / 60) into tMin
   if tMin < 60 then
      return tMin & "m"
   end if
   put trunc(tMin / 60) into tHrs
   return tHrs & "h" && (tMin mod 60) & "m"
end tcFmtEta

-- A share ratio (uploaded / downloaded) to two decimals, "-" when nothing has
-- been downloaded yet. Shared by the detail line and the session totals.
function tcRatio pUp, pDown
   if pDown is not a number or pDown <= 0 then
      return "-"
   end if
   return (the round of (pUp / pDown * 100)) / 100
end tcRatio

function tcShortHash pHash
   if pHash is empty then
      return "(pending)"
   end if
   if the number of chars of pHash > 14 then
      return (char 1 to 10 of pHash) & "..." & (char -4 to -1 of pHash)
   end if
   return pHash
end tcShortHash

function tcTrunc pText, pLen
   if the number of chars of pText <= pLen then
      return pText
   end if
   return (char 1 to (pLen - 1) of pText) & "..."
end tcTrunc

-- A friendly file label: the relative path, left-truncated so the filename (the
-- useful tail) stays visible when the path is long. Separator-agnostic.
function tcFileLabel pPath, pLen
   replace "\" with "/" in pPath
   if the number of chars of pPath <= pLen then
      return pPath
   end if
   return "..." & (char -(pLen - 3) to -1 of pPath)
end tcFileLabel

-- libtorrent file priority (0..7) -> a friendly word. 0 = skip (do not download),
-- 1..3 = low, 4..6 = normal, 7 = high. Mirrors tcCycleFilePriority's cycle.
function tcPrioText pPrio
   if pPrio is empty or pPrio is not a number then
      return "normal"
   end if
   if pPrio is 0 then
      return "skip"
   else if pPrio <= 3 then
      return "low"
   else if pPrio <= 6 then
      return "normal"
   else
      return "high"
   end if
end tcPrioText

-- Strip leading/trailing whitespace (a paste often carries a trailing newline);
-- internal characters are preserved, so file paths with spaces survive.
function tcTrim pStr
   local tWS
   put space & tab & numToChar(10) & numToChar(13) into tWS
   repeat while pStr is not empty and (char 1 of pStr) is in tWS
      delete char 1 of pStr
   end repeat
   repeat while pStr is not empty and (the last char of pStr) is in tWS
      delete the last char of pStr
   end repeat
   return pStr
end tcTrim

function tcDefaultSavePath
   local tBase
   put specialFolderPath("desktop") into tBase
   if tBase is empty then
      put specialFolderPath("documents") into tBase
   end if
   return tBase & "/torrentxt-downloads"
end tcDefaultSavePath

command tcLogMsg pMsg
   if there is no field "tcLog" then
      exit tcLogMsg
   end if
   put the time & "  " & pMsg & return after field "tcLog"
   -- keep the log bounded so a long-running session never bloats the field;
   -- rebuilding a huge field on every append is the kind of O(N) interpreter
   -- cost the performance playbook warns about.
   if the number of lines of field "tcLog" > 250 then
      delete line 1 to (the number of lines of field "tcLog" - 250) of field "tcLog"
   end if
   set the vScroll of field "tcLog" to the formattedHeight of field "tcLog"
end tcLogMsg

-- ---- the boot self-check ------------------------------------------------------
-- The plumbing is CARRIED (master: tools/demo-selfcheck.livecodescript; gate:
-- tools/check-demo-selfcheck-drift.py). What this file owns is the list of
-- assertions below - what is true about THIS demo at boot.
-- ==== DEMO SELF-CHECK v1 BEGIN (verbatim copy; master: tools/demo-selfcheck.livecodescript; gate: tools/check-demo-selfcheck-drift.py) ====
-- The sentinel is a CONSTANT so the probe compares against one spelling; a
-- literal repeated at the write and the read is a check that can pass while
-- disagreeing with itself.
constant kScProbe = "self-check: delayed write reached the status line"
local sScLines          -- the whole block, kept so a Copy button has something
local sScPassed, sScFailed, sScSkipped
local sScLogField       -- the adopting demo's own log field, set by scBegin

command scBegin pLogField
   put pLogField into sScLogField
   put empty into sScLines
   put 0 into sScPassed
   put 0 into sScFailed
   put 0 into sScSkipped
   scLine "== boot self-check (nothing is hosted, connected, or bound) =="
end scBegin

-- Each line is LOGGED as it is made, not accumulated and flushed at the end.
-- The first draft did both - a flush after the synchronous half and another
-- after the probe - which printed every synchronous line twice.
command scLine pText
   put pText & return after sScLines
   -- pin the stack: scFinish reaches here from a `send ... in` tick, and the
   -- field is named unqualified (OXT-ENGINE-NOTES 5.3)
   set the defaultStack to the short name of this stack
   if sScLogField is empty or there is no field sScLogField then
      exit scLine
   end if
   put pText & return after field sScLogField
   set the vscroll of field sScLogField to the formattedHeight of field sScLogField
end scLine

command scAssert pName, pOk
   if pOk then
      add 1 to sScPassed
      scLine "PASS  " & pName
   else
      add 1 to sScFailed
      scLine "FAIL  " & pName
   end if
end scAssert

-- SKIP, never FAIL, for an absent extension: a missing member is an
-- environment, and only a present-and-broken member is a defect.
command scSkip pName, pReason
   add 1 to sScSkipped
   scLine "SKIP  " & pName & " (" & pReason & ")"
end scSkip

-- An empty value prints as nothing, which reads as a missing check rather than
-- an answer of empty; every observed value in a self-check goes through here.
-- This is the playLoudness lesson (OXT-ENGINE-NOTES 5.4) as a helper: a check
-- that reports only its own name costs a whole engine pass to diagnose.
function scShow pValue
   if pValue is empty then
      return "empty"
   end if
   return pValue
end scShow

-- Returns the comma-list of control names in pList that do not exist, or empty.
-- The adopter passes EVERY control name its own script references, derived from
-- the source rather than hand-picked: a missing control is not cosmetic, it is
-- the "Chunk: error in object expression" class, and finding it at boot beats
-- finding it when somebody clicks.
function scMissing pList
   local tName, tMissing
   set the defaultStack to the short name of this stack
   repeat for each item tName in pList
      -- ALL THREE CONTROL TYPES. The kit builds fields (uiLabel/uiWrap/uiCap/
      -- uiSection/uiInput/uiArea/uiTable), buttons (uiButton/uiCheckbox) AND
      -- GRAPHICS (uiGfx/uiPanel/uiPill). The first version of this asked only
      -- about fields and buttons, so every uiPill a demo builds - the Tor
      -- pills in both Quick Shares, for one - reported as a missing control on
      -- a stack where it exists.
      if there is no field tName and there is no button tName \
            and there is no graphic tName then
         put tName & comma after tMissing
      end if
   end repeat
   if tMissing is empty then
      return empty
   end if
   return char 1 to -2 of tMissing
end scMissing

-- Call LAST in <pfx>ScRun. It arms the probe below; 400ms lands it before the
-- usual 800ms dashboard tick, so nothing races for the status line.
--
-- SAY THAT THE REPORT IS UNFINISHED, for the reason the suite harness carries a
-- RUN NOT FINISHED trailer: a report that simply stops reads exactly like a
-- report that ended, and the difference cost that harness a round trip on
-- 2026-08-19. One line is cheaper than the ambiguity.
command scArmProbe
   scLine "      ...one delayed-write check still to come; the count line " \
         & "below it is the end of the block"
   send "scTickProbe" to me in 400 milliseconds
end scArmProbe

-- THE ONE CHECK THAT NEEDS A TIMER.
--
-- OXT-ENGINE-NOTES 5.3 says an unqualified control reference inside a delayed
-- handler resolves against THE DEFAULTSTACK, not the stack whose script is
-- running - and that entry is classed DOCUMENTED, not OBSERVED, because this
-- tree has never actually watched the unpinned form fail. It also names the run
-- that would settle it: open a second stack in front and let a `send ... in`
-- handler write an unqualified field.
--
-- So this probe READS the defaultStack before pinning and PRINTS what it found.
-- On an ordinary run that line is context. On a run with another window in front
-- it is the measurement 5.3 is missing, taken for free and at no risk, because
-- the pin lands immediately afterwards and the write is verified.
command scTickProbe
   local tWas, tPrev, tPrevColor, tGot, tErr
   put the defaultStack into tWas
   set the defaultStack to the short name of this stack
   if there is no field "uiStatus" then
      scSkip "a delayed handler writes the status line", "the chrome is not built"
      scFinish
      exit scTickProbe
   end if
   -- RESTORE THE COLOUR TOO, not just the text. uiStatus takes a KIND, and
   -- handing it back "ok" would repaint a "bad" line green - so a stack whose
   -- extension is missing would end this probe claiming to be fine.
   put field "uiStatus" into tPrev
   put the foregroundColor of field "uiStatus" into tPrevColor
   try
      uiStatus kScProbe, empty
      put field "uiStatus" into tGot
   catch tErr
      put "THREW:" && tErr into tGot
   end try
   uiStatus tPrev, empty
   set the foregroundColor of field "uiStatus" to tPrevColor
   scAssert "a delayed handler writes the status line " \
         & "(defaultStack on entry: " & scShow(tWas) & ")", (tGot is kScProbe)
   scFinish
end scTickProbe

command scFinish
   scLine "      " & sScPassed & " passed, " & sScFailed & " failed, " \
         & sScSkipped & " skipped - select this block and copy it into the " \
         & "OXT pass record"
   if sScFailed is 0 then
      scLine "      boot self-check GREEN (this is the single-machine claim; " \
            & "the live legs are the runbook's)"
      exit scFinish
   end if
   scLine "      boot self-check has FAILURES above - report them before " \
         & "running any live leg"
   -- ONLY ON FAILURE does this touch the status line, and the asymmetry is
   -- deliberate. Green, the demo's own "Ready ..." line is the more useful
   -- thing to be reading and the detail is in the log a few lines up. Red, the
   -- log may be on a tab nobody has clicked - so the one surface a person is
   -- certainly looking at has to say so. Fail loud, pass quiet.
   uiStatus "Boot self-check: " & sScFailed & " FAILED (see the log)", "bad"
end scFinish
-- ==== DEMO SELF-CHECK v1 END ====

-- Every control name this script names OR builds, derived from the source
-- rather than hand-picked. Both halves are needed: the first draft matched
-- only `field "x"` references and missed five of datachannel-loopback's eight,
-- because that demo reaches its two logs through a variable. A missing control
-- is not cosmetic - it is the "Chunk: error in object expression" class, found
-- at boot instead of when somebody clicks.
constant kTcScControls = "tcAdd,tcAddFile,tcApplyLimit,tcBrowse,tcCopyMagnet,tcDetail,tcHeader,tcHelp,tcInput,tcInspect,tcInspectHdr,tcLimitLabel,tcLog,tcOpenFolder,tcPause,tcPauseAll,tcQDown,tcQUp,tcReannounce,tcRecheck,tcRemove,tcRemoveData,tcResume,tcResumeAll,tcSaveLabel,tcSavePath,tcSaveResume,tcSeed,tcStream,tcSubtitle,tcTabFiles,tcTabLog,tcTabPeers,tcTabTrackers,tcTorrents,tcTotals,tcUpLimit,uiFooter,uiStatus,uiTitle"

command tcScRun
   local tMissing, tPort, tErr
   scBegin "tcLog"
   put scMissing(kTcScControls) into tMissing
   scAssert "all 40 controls this script names exist (missing: " \
         & scShow(tMissing) & ")", (tMissing is empty)

   if sSession is empty or sSession is 0 then
      scSkip "the torrentxt session surface", "no session - the extension is absent, or another TorrentXT stack " \
            & "holds THE session (runbook trap 5.1)"
   else
      -- tcEnsureSession either starts THE session or re-adopts one this engine
      -- process still holds, and which of those happened decides what a stale
      -- handle means later - so print it rather than just asserting a number.
      put btListenPort(sSession) into tPort
      scAssert "the session is listening (handle " & scShow(sSession) \
            & ", port " & scShow(tPort) & ")", (tPort > 0)
      put btLastError() into tErr
      scAssert "btLastError is empty after a clean boot (" & scShow(tErr) & ")", \
            (tErr is empty)
      scAssert "the poll and refresh loops are armed", (sPolling is "true")
   end if
   scArmProbe
end tcScRun
