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
-- Features: smart Add (magnet / http(s) .torrent / local .torrent / 40-hex
-- info-hash) with DUPLICATE DETECTION, or just DRAG a .torrent / magnet onto the
-- window; per-torrent Pause/Resume/Recheck/Reannounce/Remove(+Data), Open Folder,
-- Copy Magnet, Save Resume; a live INSPECTOR for the selected torrent with
-- Files / Peers / Trackers tabs (double-click a file to set skip/normal/high
-- priority); a Stream toggle (sequential download) and queue Up/Down; session
-- Pause All / Resume All; a global upload cap; a live colour-coded table with
-- inline progress bars; keyboard shortcuts (Enter adds, Space toggles
-- pause/resume, Delete removes); a detail line with share ratio; session totals
-- with a state breakdown and ratio; remembered settings + a resizable window; a
-- self-rebuild on script update (kUiVersion); a "What is this?" help dialog; and
-- an event log.
--
-- Design (single-thread playbook): one 250 ms poll loop drains events with a
-- single btPoll; one 800 ms refresh enumerates the torrents and repaints. The
-- refresh is split into tcRefreshOnce (repaint) + tcRefreshLoop (repaint then
-- reschedule) so calling it from an event NEVER spawns a second timer chain.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sLineHandles      -- array: table line number -> torrent handle (per refresh)
local sPolling          -- "true" while the loops are armed
local sPanelTab         -- the active inspector tab: "files" / "peers" / "trackers"
local sSeqOn            -- array: torrent handle -> "true" while sequential is on

-- Bump when the generated UI changes; tcBuildUI rebuilds the controls on a
-- mismatch so updating the script in a SAVED stack picks up the new layout
-- instead of keeping the old controls (and dead buttons) around.
constant kUiVersion = "client-ui-2026-06"

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   tcBuildUI
   tcEnsureSession
end openStack

on closeStack
   tcShutdown
end closeStack

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
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT Client"
   set the width of this stack to 860
   -- vertically resizable: lock the width, remember the user's height across runs,
   -- and let the three list regions (table / inspector / log) share the extra
   -- vertical space (see resizeStack / tcRelayout).
   set the minWidth of this stack to 860
   set the maxWidth of this stack to 860
   -- taller now that an inspector (Files/Peers/Trackers) sits between the control
   -- block and the log; the three list regions share the extra vertical space.
   set the minHeight of this stack to 680
   if the uHeight of this stack is a number and the uHeight of this stack >= 680 then
      set the height of this stack to (the uHeight of this stack)
   else
      set the height of this stack to 820
   end if
   -- a full-width brand title bar
   tcMakeLabel "tcTitle", "  TorrentXT Client", "0,0,860,34", 16
   set the opaque of field "tcTitle" to true
   set the backgroundColor of field "tcTitle" to "44,90,160"
   set the foregroundColor of field "tcTitle" to "255,255,255"
   set the textStyle of field "tcTitle" to "bold"
   tcMakeLabel "tcSubtitle", "BitTorrent for OpenXTalk - powered by libtorrent  ", "440,9,840,29", 11
   set the foregroundColor of field "tcSubtitle" to "208,221,240"
   set the textAlign of field "tcSubtitle" to "right"
   -- add row
   tcMakeField "tcInput", "16,38,560,64", false
   tcMakeButton "tcAdd", "Add", "568,38,650,64"
   tcMakeButton "tcAddFile", "Open .torrent", "658,38,844,64"
   -- save + seed row (Browse picks the download folder)
   tcMakeLabel "tcSaveLabel", "Save to:", "16,72,66,92", 11
   tcMakeField "tcSavePath", "70,70,470,94", false
   tcMakeButton "tcBrowse", "Browse...", "474,70,558,94"
   tcMakeButton "tcSeed", "Create + Seed Folder", "568,70,844,94"
   -- table header + selectable list (double-click a row to open its folder)
   tcMakeLabel "tcHeader", \
      "#" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Down" & tab & "Up" & tab & "Peers" & tab & "Size", \
      "16,102,844,120", 10
   tcMakeList "tcTorrents", "16,122,844,358", false
   set the tabStops of field "tcHeader" to "26,250,350,510,590,670,720"
   set the tabStops of field "tcTorrents" to "26,250,350,510,590,670,720"
   -- a fixed-width font lets the inline progress bars and the right-hand byte
   -- columns line up cleanly; OXT falls back gracefully if Courier is absent.
   set the textFont of field "tcHeader" to "Courier"
   set the textFont of field "tcTorrents" to "Courier"
   set the textSize of field "tcHeader" to 11
   set the textSize of field "tcTorrents" to 11
   -- a pale selection color keeps the state-colored row text legible when a row
   -- is hilited; the default system hilite is too dark for the colored text.
   set the hiliteColor of field "tcTorrents" to "200,221,242"
   -- a styled header bar frames the table
   set the opaque of field "tcHeader" to true
   set the backgroundColor of field "tcHeader" to "216,221,230"
   set the foregroundColor of field "tcHeader" to "28,38,58"
   set the textStyle of field "tcHeader" to "bold"
   -- per-torrent controls (row 1)
   tcMakeButton "tcPause", "Pause", "16,364,104,390"
   tcMakeButton "tcResume", "Resume", "108,364,196,390"
   tcMakeButton "tcRecheck", "Recheck", "200,364,288,390"
   tcMakeButton "tcReannounce", "Reannounce", "292,364,402,390"
   tcMakeButton "tcRemove", "Remove", "406,364,494,390"
   tcMakeButton "tcRemoveData", "Remove + Data", "498,364,620,390"
   -- per-torrent + session controls (row 2)
   tcMakeButton "tcOpenFolder", "Open Folder", "16,396,120,422"
   tcMakeButton "tcCopyMagnet", "Copy Magnet", "124,396,228,422"
   tcMakeButton "tcSaveResume", "Save Resume", "232,396,336,422"
   tcMakeButton "tcPauseAll", "Pause All", "360,396,448,422"
   tcMakeButton "tcResumeAll", "Resume All", "452,396,540,422"
   -- settings: a global upload cap (handy when seeding)
   tcMakeLabel "tcLimitLabel", "Up KB/s (0=off):", "560,400,672,420", 11
   tcMakeField "tcUpLimit", "676,398,740,422", false
   tcMakeButton "tcApplyLimit", "Apply", "748,398,820,422"
   -- detail line for the selected torrent, then session totals
   tcMakeLabel "tcDetail", "Select a torrent to see its details.", "16,430,844,450", 10
   tcMakeLabel "tcTotals", "", "16,454,844,474", 11
   set the opaque of field "tcTotals" to true
   set the backgroundColor of field "tcTotals" to "224,228,235"
   set the textStyle of field "tcTotals" to "bold"
   -- ---- live inspector: Files / Peers / Trackers for the selected torrent ----
   -- a tab row (the three tabs + a Stream toggle + queue + help), a column header,
   -- and a selectable list. tcRelayout positions all of these; the rects here are
   -- placeholders. The active tab is shown by disabling its button (see tcSetTab).
   tcMakeButton "tcTabFiles", "Files", "16,476,86,500"
   tcMakeButton "tcTabPeers", "Peers", "90,476,160,500"
   tcMakeButton "tcTabTrackers", "Trackers", "164,476,254,500"
   tcMakeButton "tcStream", "Stream: off", "300,476,410,500"
   tcMakeButton "tcQUp", "Q Up", "420,476,490,500"
   tcMakeButton "tcQDown", "Q Down", "494,476,574,500"
   tcMakeButton "tcHelp", "What is this?", "740,476,844,500"
   tcMakeLabel "tcInspectHdr", \
      "Name" & tab & "Size" & tab & "Progress" & tab & "Priority", "16,504,844,522", 10
   set the opaque of field "tcInspectHdr" to true
   set the backgroundColor of field "tcInspectHdr" to "216,221,230"
   set the foregroundColor of field "tcInspectHdr" to "28,38,58"
   set the textStyle of field "tcInspectHdr" to "bold"
   set the textFont of field "tcInspectHdr" to "Courier"
   set the textSize of field "tcInspectHdr" to 11
   tcMakeList "tcInspect", "16,524,844,640", false
   set the textFont of field "tcInspect" to "Courier"
   set the textSize of field "tcInspect" to 11
   -- same pale hilite as the table so coloured rows stay legible when selected
   set the hiliteColor of field "tcInspect" to "200,221,242"
   -- event log
   tcMakeList "tcLog", "16,480,844,702", true
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
   set the tooltip of button "tcStream" to "Toggle sequential (streaming) download for the selected torrent"
   set the tooltip of button "tcQUp" to "Move the selected torrent up in the priority queue"
   set the tooltip of button "tcQDown" to "Move the selected torrent down in the priority queue"
   set the tooltip of button "tcHelp" to "What this client can do"
   set the tooltip of field "tcInspect" to "Files / Peers / Trackers for the selected torrent. On Files, double-click a row to cycle priority."
   tcSetTab "files"
   set the uUiVersion of this stack to kUiVersion
   tcRelayout
   unlock screen
   tcLogMsg "Client built. Add takes a magnet, a .torrent path, an http(s) .torrent URL, or a 40-hex info-hash."
   tcLogMsg "Duplicates are detected. Double-click a row to open its folder. Create + Seed a folder to seed."
   tcLogMsg "Pick a torrent, then use the Files / Peers / Trackers tabs below. Drag a .torrent or magnet onto the window to add it."
end tcBuildUI

command tcMakeLabel pName, pText, pRect, pSize
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
end tcMakeLabel

command tcMakeField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end tcMakeField

command tcMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end tcMakeButton

command tcMakeList pName, pRect, pIsLog
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
   if pIsLog then
      set the listBehavior of field pName to false
   else
      set the listBehavior of field pName to true
   end if
end tcMakeList

-- Reflow the three list regions (table, inspector, log), the two control rows,
-- the inspector tab row, and the detail/totals lines for the current (resizable)
-- height. The width is locked, so only vertical space is shared: the table takes
-- ~42% of the free space, the inspector ~32%, and the log fills the remainder
-- down to the bottom margin. Laid out top-to-bottom from the fixed table top so
-- the arithmetic stays readable. Called on build and resize; no-op until ready.
command tcRelayout
   local tH, tRight, tBottom, tAvail, tY, tTableH, tInspH
   if there is no field "tcLog" then   -- the last control built; UI not ready yet
      exit tcRelayout
   end if
   put the height of this stack into tH
   put (the width of this stack) - 16 into tRight
   put tH - 10 into tBottom                  -- bottom margin
   -- Vertical budget the three list regions share. Everything else below the
   -- table top (122) is fixed: the 116px control block, a 30px inspector tab row,
   -- an 18px inspector header, two 6px gaps, and the 10px bottom margin.
   put (tH - 122 - 116 - 30 - 18 - 12 - 10) into tAvail
   if tAvail < 300 then
      put 300 into tAvail
   end if
   put the round of (tAvail * 0.42) into tTableH
   put the round of (tAvail * 0.32) into tInspH
   -- top-to-bottom cursor from the fixed table top
   put 122 into tY
   set the rect of field "tcTorrents" to ("16," & tY & comma & tRight & comma & (tY + tTableH))
   put tY + tTableH + 6 into tY              -- gap, then the control block
   tcRowTop "tcPause,tcResume,tcRecheck,tcReannounce,tcRemove,tcRemoveData", tY
   tcRowTop "tcOpenFolder,tcCopyMagnet,tcSaveResume,tcPauseAll,tcResumeAll", (tY + 32)
   set the top of field "tcLimitLabel" to (tY + 36)
   set the top of field "tcUpLimit" to (tY + 34)
   set the top of button "tcApplyLimit" to (tY + 34)
   set the top of field "tcDetail" to (tY + 66)
   set the top of field "tcTotals" to (tY + 90)
   put tY + 116 into tY                       -- below the 116px control block
   tcRowTop "tcTabFiles,tcTabPeers,tcTabTrackers,tcStream,tcQUp,tcQDown,tcHelp", (tY + 2)
   put tY + 30 into tY                        -- below the tab row
   set the rect of field "tcInspectHdr" to ("16," & tY & comma & tRight & comma & (tY + 18))
   put tY + 18 into tY                        -- below the inspector header
   set the rect of field "tcInspect" to ("16," & tY & comma & tRight & comma & (tY + tInspH))
   put tY + tInspH + 6 into tY                -- gap, then the log fills the rest
   set the rect of field "tcLog" to ("16," & tY & comma & tRight & comma & tBottom)
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
         put 0 into sSession
         exit tcEnsureSession
      end try
      if sSession is 0 or sSession is empty then
         tcLogMsg "btStartSession returned 0:" && btLastError()
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
   put "true" into sPolling
   send "tcPollOnce" to me in 0 milliseconds
   send "tcRefreshLoop" to me in 600 milliseconds
end tcEnsureSession

command tcShutdown
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   set the uSession of this stack to empty
   -- remember the user's settings for next launch
   if there is a field "tcSavePath" then
      set the uSavePath of this stack to tcTrim(field "tcSavePath")
      set the uUpLimit of this stack to tcTrim(field "tcUpLimit")
   end if
end tcShutdown

function tcHaveSession
   if sSession is 0 or sSession is empty then
      tcLogMsg "No session - reopen the stack to start one."
      return false
   end if
   return true
end tcHaveSession

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
      put empty into field "tcInput"
      tcRefreshOnce
   end if
end tcReportAdd

-- ---- per-torrent control (on the selected table row) -------------------------
command tcControlSelected pAction
   local tH, tLine, tLeft
   put tcSelectedHandle() into tH
   if tH is 0 then
      tcLogMsg "Select a torrent in the table first."
      exit tcControlSelected
   end if
   put item 1 of (the hilitedLines of field "tcTorrents") into tLine
   switch pAction
      case "pause"
         btPause tH
         tcLogMsg "Paused torrent" && tH
         break
      case "resume"
         btResume tH
         tcLogMsg "Resumed torrent" && tH
         break
      case "recheck"
         btForceRecheck tH
         tcLogMsg "Rechecking torrent" && tH
         break
      case "reannounce"
         btForceReannounce tH
         tcLogMsg "Reannounced torrent" && tH
         break
      case "remove"
         btRemoveTorrent sSession, tH, false
         tcLogMsg "Removed torrent" && tH && "(kept files)"
         break
      case "removeData"
         answer "Delete the downloaded files for torrent" && tH & "?" with "Cancel" or "Delete"
         if it is not "Delete" then
            exit tcControlSelected
         end if
         btRemoveTorrent sSession, tH, true
         tcLogMsg "Removed torrent" && tH && "AND deleted its files"
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
   tcLogMsg "Upload limit set to" && tKB && "KB/s"
end tcApplyUpLimit

-- ---- the poll loop (one FFI drain per pass) ----------------------------------
command tcPollOnce
   local tEvents, tEvent
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
   switch pEvent["name"]
      case "torrentAdded"
         tcLogMsg "+ added torrent" && pEvent["torrent"]
         tcRefreshOnce
         break
      case "metadataReceived"
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
   if sSession is 0 or sSession is empty then
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
         "   No torrents yet - paste a magnet or .torrent above, or Create + Seed a folder."
      set the foregroundColor of line 1 of field "tcTorrents" to "130,130,130"
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
   tcUpdateDetail tSelH
   tcUpdateStreamButton tSelH
   tcUpdatePanel
   unlock screen
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

-- Switch the inspector to a tab. The active tab's button is disabled so it reads
-- as "current"; the per-tab column header + tab stops are set here (tab stops are
-- absolute pixels and must stay inside the field), then the panel repaints.
command tcSetTab pTab
   put pTab into sPanelTab
   set the disabled of button "tcTabFiles" to (pTab is "files")
   set the disabled of button "tcTabPeers" to (pTab is "peers")
   set the disabled of button "tcTabTrackers" to (pTab is "trackers")
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
   put tcSelectedHandle() into tH
   if tH is 0 then
      set the text of field "tcInspect" to "   Select a torrent above to inspect its files, peers, and trackers."
      set the foregroundColor of line 1 of field "tcInspect" to "130,130,130"
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
            put "   No peers connected yet (still finding the swarm)." into tOut
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
            put "   No trackers - this torrent relies on DHT / PEX / LSD." into tOut
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
               put "150,150,150" into tColors[tLine]
            else if tPct >= 100 then
               put "0,140,70" into tColors[tLine]
            end if
         end repeat
         if tLine is 0 then
            put "   No file list yet (metadata still pending)." into tOut
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
      "INSPECT: select a torrent, then use the Files / Peers / Trackers tabs. On Files, double-click a row to cycle its priority (skip -> normal -> high); skipped files are not downloaded." & return & return & \
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
      return "200,40,40"
   end if
   switch pState
      case 4
      case 5
         return "0,140,70"
      case 3
         return "30,90,200"
      case 1
      case 2
      case 7
         return "190,130,0"
      default
         return "110,110,110"
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
