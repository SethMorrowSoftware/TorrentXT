-- torrent-build-ui-button.livecodescript - paste THIS into the script of a
-- BUTTON (make a button, open its script, paste, save), then click that button
-- ONCE. It builds the controls the torrentDemo stack script expects - the fields
-- "magnet", "savepath" and "status", plus Add/Pause/Resume buttons wired to the
-- demo's commands - and lays them out on the card. Idempotent: clicking again
-- repositions the controls instead of duplicating them. Once the UI is built you
-- can delete this builder button.
--
-- Runs in the OXT/LiveCode IDE (which allows setting a control's script at
-- runtime). The wired button handlers are built with "on" && "mouseUp" rather
-- than a literal so a line-based static checker never miscounts handlers.

on mouseUp
   uiBuildTorrentUI
end mouseUp

command uiBuildTorrentUI
   lock screen
   -- editable inputs
   uiMakeField "magnet",   "20,28,560,54",  false
   uiMakeField "savepath", "20,62,560,88",  false
   -- action buttons, each wired to the matching torrentDemo command
   uiMakeButton "btnAdd",    "Add Magnet", "20,98,150,130",  "addMagnet"
   uiMakeButton "btnPause",  "Pause",      "160,98,270,130", "pauseActive"
   uiMakeButton "btnResume", "Resume",     "280,98,390,130", "resumeActive"
   -- status display (locked, scrolling)
   uiMakeField "status", "20,140,560,360", true
   set the vScrollbar of field "status" to true
   -- seed a save folder + a usage hint the first time
   if field "savepath" is empty then
      put uiDefaultSavePath() into field "savepath"
   end if
   put "TorrentXT ready. Top field = magnet URI, second = save folder." & return & \
       "Paste a magnet, then click Add Magnet." into field "status"
   unlock screen
end uiBuildTorrentUI

command uiMakeField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end uiMakeField

command uiMakeButton pName, pLabel, pRect, pCommand
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
   -- give the new button a one-line handler that calls the stack command; the
   -- "on"/"end" tokens are split so they are not mistaken for real handlers
   set the script of button pName to \
      ("on" && "mouseUp" & return & "   " & pCommand & return & "end" && "mouseUp")
end uiMakeButton

function uiDefaultSavePath
   local tBase
   put specialFolderPath("desktop") into tBase
   if tBase is empty then
      put specialFolderPath("documents") into tBase
   end if
   return tBase & "/torrentxt-downloads"
end uiDefaultSavePath
