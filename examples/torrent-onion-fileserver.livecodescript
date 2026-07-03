script "onionFileServer"

-- torrent-onion-fileserver.livecodescript - share a WHOLE FOLDER over Tor as a
-- browsable web page, from OpenXTalk. Pick a folder; every file in it is served at
-- a fresh <56>.onion address with an auto-generated directory-listing page (browse
-- into subfolders, click a file to view or download it). No web server to install,
-- no hosting account, no port forwarding, and the server's IP address stays hidden
-- by Tor. Open the printed http://<address>.onion/ in Tor Browser.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI. Have a local
-- Tor daemon with the CONTROL PORT enabled (127.0.0.1:9051, or Tor Browser's
-- 9151). Click Start, wait for the pill to say "ready", click Share Folder and pick
-- a folder; when it says REACHABLE, open the printed .onion in Tor Browser.
--
-- WHY IT IS A TorrentXT DEMO: this is the companion to Quick Share. Quick Share
-- sends ONE file (by a code, or privately over Tor); this serves a whole FOLDER to
-- a plain browser over Tor. It reuses Quick Share's proven, on-engine serve path -
-- the chunked send pump (the false-stall fix), the OnionXT accept loop, the safe
-- filename discipline - and generalises it from one file to a directory tree.
--
-- WHAT IT DOES BETTER THAN A NAIVE FOLDER SERVER (the "or better"):
--   * STREAMING: a file is streamed to the browser in 64 KiB slices on a timer,
--     never read whole into memory - a multi-GB file does not blow up RAM, and the
--     single interpreted thread is never blocked reading a big file in one gulp.
--   * CONCURRENCY-SAFE: the pump opens/seeks/reads/closes the file within each tick
--     (no yield in between), so two browsers can pull the SAME file at once. A
--     persistent, whole-file-open handle (LiveCode keys handles by path and refuses a
--     second concurrent open) would corrupt overlapping reads of one file.
--   * HTTP RANGE (resumable + seekable): the server honours `Range: bytes=...` with a
--     206 Partial Content response, so a Tor-interrupted download RESUMES instead of
--     restarting, and audio/video SEEKS in the browser. Advertised via
--     `Accept-Ranges: bytes`. (VERIFY on-engine: the pump uses `seek to N in file`;
--     if downloads serve shifted bytes, the seek base is the first suspect.)
--
-- SECURITY / PRIVACY posture (be honest with the user):
--   * Tor hides the server's IP and the visitor's IP. There is NO passphrase and NO
--     encryption here: a browser cannot decrypt, so a browsable web share is served
--     in cleartext OVER the onion (the onion transport is the confidentiality). For
--     an encrypted, verified one-file transfer, use Quick Share with a passphrase.
--   * Path traversal ("..", %2e%2e) is refused after URL-decoding, before any disk
--     touch. File names are HTML-escaped so a crafted name cannot inject markup.
--   * Read-only: only GET/HEAD are served; there is no upload endpoint.
--
-- This is verified STATICALLY (tools/check-livecodescript.py) and needs an
-- on-engine OXT pass with a running Tor daemon before any runtime claim - the
-- project convention. See docs/ONIONXT-INTEGRATION-PLAN.md.

-- ---- constants (declared before first use; OXT resolves them by position) -----
constant kVPort = 80                 -- the onion service's public virtual port (URL needs no :port)
constant kChunk = 65536              -- 64 KiB: bytes read+sent per pump tick (never whole-file)
constant kPumpTick = 15              -- ms between send-pump slices (never a tight loop)
constant kMaxRequest = 262144        -- refuse a request head bigger than 256 KB (abuse guard)
constant kServeTimeout = 45000       -- ms idle watchdog per connection (Tor is slow)
constant kPublishTimeout = 90000     -- ms to wait for the onion descriptor to upload
constant kTorSocksPort = "9050"      -- system/standalone tor
constant kTorControlPort = "9051"
constant kTorSocksPortTB = "9150"    -- Tor Browser
constant kTorControlPortTB = "9151"
-- Bump when the generated UI changes so a saved stack rebuilds its controls.
constant kUiVersion = "fs-ui-2026-07"

-- ---- stack-local state -------------------------------------------------------
local sHasOnion         -- "true" if OnionXT loads (probed once at start)
local sRoot             -- the shared folder (no trailing slash), or empty
local sService          -- the live onion service handle (integer), or empty
local sOnionAddr        -- the published .onion address, or empty
local sPublished        -- "true" once the descriptor has uploaded (address usable)
local sTriedTB          -- "true" once we retried the Tor Browser control port pair
-- per-connection state, keyed by the OnionXT stream handle
local sReq              -- array: stream -> accumulated inbound request bytes
local sServed           -- array: stream -> "true" once we have begun answering it
local sTxPath           -- array: stream -> disk path of the file we are streaming out
local sTxPos            -- array: stream -> next byte offset to read (0-based; honours a Range)
local sTxRemaining      -- array: stream -> bytes still to send (respects a Range)
local sTxName           -- array: stream -> the file's leaf name (for the log)
local sTxDeadline       -- array: stream -> the milliseconds of the last activity (watchdog)

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   fsBuild
   fsStart
end openStack

on closeStack
   fsStop
end closeStack

on mouseUp
   switch the short name of the target
      case "fsStart"
         fsStart
         break
      case "fsShare"
         fsShareFolder
         break
      case "fsStopBtn"
         fsStopServing
         break
      case "fsCopy"
         fsCopyUrl
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- ---- self-building UI (idempotent; rebuilds on a UI-version bump) ------------
command fsBuild
   if the uUiVersion of this stack is kUiVersion and there is a field "fsUrl" then
      exit fsBuild
   end if
   fsClearGeneratedUI
   lock screen
   set the width of this stack to 640
   set the height of this stack to 470
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - Onion File Server"
   -- title band
   fsLabel "fsTitle", "  Onion File Server - share a folder over Tor", "0,0,640,40", 15
   set the opaque of field "fsTitle" to true
   set the backgroundColor of field "fsTitle" to "44,90,160"
   set the foregroundColor of field "fsTitle" to "255,255,255"
   set the textStyle of field "fsTitle" to "bold"
   fsLabel "fsTagline", "Pick a folder and browse it in Tor Browser at a private .onion address. No server, no hosting, no port forwarding - the server's IP stays hidden.", "24,48,616,84", 10
   set the foregroundColor of field "fsTagline" to "90,96,105"
   -- live Tor status pill (repainted only by fsPill)
   fsLabel "fsPillFld", "Tor: off", "430,8,632,32", 10
   set the opaque of field "fsPillFld" to true
   set the backgroundColor of field "fsPillFld" to "33,72,132"
   set the foregroundColor of field "fsPillFld" to "220,228,240"
   set the textAlign of field "fsPillFld" to "right"
   -- controls
   fsButton "fsStart", "Start", "24,92,150,124"
   fsButton "fsShare", "Share Folder", "162,92,320,124"
   fsButton "fsStopBtn", "Stop", "332,92,458,124"
   -- the published onion URL
   fsLabel "fsUrlCap", "Browser link (open in Tor Browser) - give this to whoever should get the files:", "24,132,616,150", 10
   fsField "fsUrl", "24,152,540,178", true
   set the textFont of field "fsUrl" to "Courier"
   set the textSize of field "fsUrl" to 11
   set the opaque of field "fsUrl" to true
   set the backgroundColor of field "fsUrl" to "255,250,225"
   put "(the .onion link will appear here once you Share a folder)" into field "fsUrl"
   fsButton "fsCopy", "Copy", "546,152,616,178"
   fsLabel "fsSharing", "", "24,184,616,204", 10
   set the textStyle of field "fsSharing" to "bold"
   -- activity log
   fsLabel "fsLogCap", "Activity", "24,214,616,232", 10
   set the textStyle of field "fsLogCap" to "bold"
   fsList "fsLog", "24,234,616,458", true
   set the textSize of field "fsLog" to 9
   set the textFont of field "fsLog" to "Courier"
   fsAddTips
   fsPill
   set the uUiVersion of this stack to kUiVersion
   unlock screen
end fsBuild

-- Delete every generated control (named "fs...") so a kUiVersion bump can rebuild
-- the UI from scratch in a saved stack without leaving stale controls behind.
command fsClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of fields of this card down to 1
      if the short name of field tI of this card begins with "fs" then
         delete field tI of this card
      end if
   end repeat
   repeat with tI = the number of buttons of this card down to 1
      if the short name of button tI of this card begins with "fs" then
         delete button tI of this card
      end if
   end repeat
   unlock screen
end fsClearGeneratedUI

command fsLabel pName, pText, pRect, pSize
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
end fsLabel

command fsField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end fsField

command fsButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end fsButton

command fsList pName, pRect, pIsLog
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to true
   set the vScrollbar of field pName to true
   set the listBehavior of field pName to (not pIsLog)
end fsList

command fsAddTips
   set the tooltip of button "fsStart" to "Connect to your local Tor daemon (127.0.0.1:9051, or Tor Browser's 9151)."
   set the tooltip of button "fsShare" to "Pick a folder to serve. Every file in it becomes browsable at the .onion link."
   set the tooltip of button "fsStopBtn" to "Take the onion down and stop serving."
   set the tooltip of field "fsUrl" to "The browser link for your share. Open it in Tor Browser, or click Copy to send it."
   set the tooltip of button "fsCopy" to "Copy the browser link to the clipboard."
   set the tooltip of field "fsPillFld" to "Status of your local Tor connection. 'ready' means the share will publish."
end fsAddTips

-- ---- start / share / stop ----------------------------------------------------
command fsStart
   -- Probe OnionXT and bring up the Tor control link (non-blocking). Everything is
   -- inert if OnionXT is not installed; bootstrap takes tens of seconds and is
   -- surfaced by the status callback + the pill.
   put fsHasOnion() into sHasOnion
   if not sHasOnion then
      fsLog "OnionXT is not installed. Install the OnionXT extension (and its dependency SodiumXT) and run a local Tor daemon, then reopen."
      fsPill
      exit fsStart
   end if
   put "false" into sTriedTB
   oxSetCallbackOwner the long id of me
   oxSetStatusCallback "fsStatus"
   oxSetPeerCallback "fsPeer"
   oxSetControlPort kTorControlPort
   oxSetSocksPort kTorSocksPort
   oxConnectControl
   if the result is not empty then
      fsTryTB
   end if
   fsPill
   fsLog "Connecting to the Tor control port... when the pill says 'ready', click Share Folder."
end fsStart

-- Retry the control connection on the Tor Browser port pair, exactly once.
command fsTryTB
   if sTriedTB is "true" then
      exit fsTryTB
   end if
   put "true" into sTriedTB
   oxSetControlPort kTorControlPortTB
   oxSetSocksPort kTorSocksPortTB
   oxConnectControl
end fsTryTB

command fsShareFolder
   local tFolder, tSvc, tPort
   if not sHasOnion then
      fsLog "OnionXT is not installed - cannot share."
      exit fsShareFolder
   end if
   if not fsReadyNow() then
      fsLog "Tor is still connecting - watch the pill, then click Share Folder again."
      exit fsShareFolder
   end if
   answer folder "Choose a folder to share over Tor"
   put it into tFolder
   if tFolder is empty then
      exit fsShareFolder      -- cancelled
   end if
   if there is no folder tFolder then
      fsLog "That folder could not be found."
      exit fsShareFolder
   end if
   put fsStripSlash(tFolder) into sRoot
   -- Already publishing? Just swap the served folder; it goes live at the same
   -- .onion, so a link you already handed out keeps working (like the spike).
   if sService is not empty then
      fsLog "Now sharing: " & sRoot & "  (live at the same .onion)"
      set the text of field "fsSharing" to ("Sharing " & sRoot)
      exit fsShareFolder
   end if
   put fsPickPort() into tPort
   -- oxCreateService (no seed) publishes a FRESH ephemeral onion each run: a new,
   -- unlinkable address every time the app opens. OnionXT owns the loopback
   -- listener and rejects non-loopback peers (the proven path).
   oxCreateService kVPort, tPort
   put the result into tSvc
   if tSvc is not an integer then
      fsLog "Could not publish a Tor address: " & tSvc
      exit fsShareFolder
   end if
   put tSvc into sService
   put "false" into sPublished
   put empty into sOnionAddr
   set the text of field "fsUrl" to ""
   set the text of field "fsSharing" to ("Publishing a private Tor address for " & sRoot & " - this can take up to a minute...")
   fsLog "Sharing folder: " & sRoot
   fsLog "Publishing the onion (port " & kVPort & " -> 127.0.0.1:" & tPort & ")..."
   -- arm the publish watchdog against THIS service handle
   send ("fsPublishWatchdog " & tSvc) to me in kPublishTimeout milliseconds
end fsShareFolder

command fsStopServing
   local tErr
   if sService is empty then
      fsLog "Not currently sharing."
      exit fsStopServing
   end if
   try
      oxRemoveService sService
   catch tErr
   end try
   put empty into sService
   put empty into sRoot
   put empty into sOnionAddr
   put "false" into sPublished
   set the text of field "fsUrl" to ""
   set the text of field "fsSharing" to ""
   fsLog "Onion removed - no longer serving."
end fsStopServing

-- Tear the onion subsystem down on close. All idempotent. (No files are held open -
-- the pump opens and closes within each tick - so there is nothing to close here.)
command fsStop
   local tErr
   if not sHasOnion then
      exit fsStop
   end if
   if sService is not empty then
      try
         oxRemoveService sService
      catch tErr
      end try
   end if
   try
      oxDisconnectControl
   catch tErr
   end try
   put empty into sService
end fsStop

-- ---- OnionXT status + the pill -----------------------------------------------
-- OnionXT status callback (dispatched with pKind, pInfo). Keep it short - it runs
-- on the shared main thread.
command fsStatus pKind, pInfo
   if pKind is "control" then
      if pInfo is "authenticated" then
         fsLog "Tor control connected - bootstrapping (this can take a minute)..."
      else if (pInfo is "authfailed" or pInfo is "error") then
         fsTryTB
      end if
   else if pKind is "service" then
      -- an address was assigned (may not resolve until the descriptor uploads)
      put pInfo into sOnionAddr
   else if pKind is "serviceReady" then
      fsServicePublished pInfo
   end if
   fsPill
end fsStatus

-- Our descriptor uploaded: reveal the browser link now (an address handed out
-- earlier would just fail to resolve). One active share, so serviceReady is
-- unambiguous. VERIFY: pInfo semantics for serviceReady.
command fsServicePublished pInfo
   local tOnion
   if sService is empty then
      exit fsServicePublished
   end if
   if sPublished is "true" then
      exit fsServicePublished
   end if
   put oxServiceAddress(sService) into tOnion
   if tOnion is empty then
      exit fsServicePublished
   end if
   put tOnion into sOnionAddr
   put "true" into sPublished
   set the text of field "fsUrl" to ("http://" & tOnion & "/")
   set the text of field "fsSharing" to ("Serving " & sRoot & " over Tor - both IPs hidden. Open the link in Tor Browser; keep this window open.")
   fsLog "REACHABLE - open  http://" & tOnion & "/  in Tor Browser to browse the files."
end fsServicePublished

-- Repaint the live pill.
command fsPill
   local tState
   if there is no field "fsPillFld" then
      exit fsPill
   end if
   if not sHasOnion then
      put "Tor: no extension" into tState
   else if not oxIsControlAuthenticated() then
      put "Tor: no daemon (start Tor on 127.0.0.1:9051 or 9151)" into tState
   else if not oxIsReady() then
      put ("Tor: connecting " & oxBootstrapProgress() & "%") into tState
   else
      put "Tor: ready" into tState
   end if
   set the text of field "fsPillFld" to tState
end fsPill

command fsCopyUrl
   if field "fsUrl" is empty or field "fsUrl" begins with "(" then
      fsLog "No link yet - Start, then Share a folder."
      exit fsCopyUrl
   end if
   set the clipboardData["text"] to field "fsUrl"
   fsLog "Link copied. Anyone with Tor Browser can open it."
end fsCopyUrl

-- Live, authoritative Tor readiness, re-read at the moment of use.
function fsReadyNow
   if not sHasOnion then
      return false
   end if
   return oxIsReady()
end fsReadyNow

-- If the descriptor never uploads in time, tear the half-built service down.
command fsPublishWatchdog pService
   local tErr
   if sService is empty then
      exit fsPublishWatchdog
   end if
   if sService is not pService then
      exit fsPublishWatchdog      -- superseded; clean no-op
   end if
   if sPublished is "true" then
      exit fsPublishWatchdog
   end if
   try
      oxRemoveService sService
   catch tErr
   end try
   put empty into sService
   put empty into sRoot
   set the text of field "fsSharing" to ""
   fsLog "Tor could not publish the address in time. Make sure the pill says 'ready', then Share the folder again."
end fsPublishWatchdog

-- ==== the HTTP server over OnionXT ==========================================
-- OnionXT delivers a fresh inbound stream per browser connection (loopback already
-- enforced). Each connection gets its own per-stream state, so several visitors -
-- and a browser's parallel requests (page, then icon, then a download) - are all
-- served concurrently; the timer-paced pump multiplexes them cooperatively.

command fsPeer pStream, pService, pPeerAddr
   if sService is empty then
      oxCloseStream pStream
      exit fsPeer
   end if
   put "" into sReq[pStream]
   put "false" into sServed[pStream]
   put the milliseconds into sTxDeadline[pStream]
   oxSetStreamCallback pStream, "fsStream"
   send ("fsServeWatchdog " & pStream) to me in kServeTimeout milliseconds
end fsPeer

-- Accumulate the request until the CRLFCRLF that ends the header block arrives,
-- then handle it. GET/HEAD carry no body, so the header terminator IS completion.
command fsStream pStream, pEvent, pData
   local tCrlf2
   if pEvent is "data" then
      if sServed[pStream] is "true" then
         exit fsStream      -- already answering; ignore the rest of the request
      end if
      put pData after sReq[pStream]
      put the milliseconds into sTxDeadline[pStream]
      if the number of bytes in sReq[pStream] > kMaxRequest then
         put "true" into sServed[pStream]
         fsSendText pStream, "413 Payload Too Large", "text/plain; charset=utf-8", "Request too large."
         exit fsStream
      end if
      put (numToByte(13) & numToByte(10) & numToByte(13) & numToByte(10)) into tCrlf2
      if sReq[pStream] contains tCrlf2 then
         put "true" into sServed[pStream]
         fsHandle pStream
      end if
   else if pEvent is "closed" or pEvent is "error" then
      fsCleanup pStream       -- peer went away; free the buffer / close any open file
   end if
end fsStream

command fsHandle pStream
   local tHeaders
   put fsParseRequest(sReq[pStream]) into tHeaders
   fsServePath pStream, tHeaders
end fsHandle

-- Parse the request into an array: __method / __path / __query, plus lowercased
-- header names -> values. GET/HEAD have no body, so decoding the whole request as
-- UTF-8 is safe (there is no binary payload to corrupt). Save/restore delimiters.
function fsParseRequest pData
   local tText, tSaved, tSavedID, tReqLine, tResource, tI, tLine, tColon, tName, tValue, tOut
   put textDecode(pData, "UTF-8") into tText
   put the lineDelimiter into tSaved
   put the itemDelimiter into tSavedID
   set the lineDelimiter to (numToChar(13) & numToChar(10))
   put line 1 of tText into tReqLine
   put toUpper(word 1 of tReqLine) into tOut["__method"]
   put word 2 of tReqLine into tResource
   set the itemDelimiter to "?"
   put item 1 of tResource into tOut["__path"]
   if the number of items of tResource > 1 then
      put item 2 to -1 of tResource into tOut["__query"]
   end if
   repeat with tI = 2 to the number of lines of tText
      put line tI of tText into tLine
      if tLine is empty then
         next repeat
      end if
      put offset(":", tLine) into tColon
      if tColon > 1 then
         put toLower(fsTrim(char 1 to (tColon - 1) of tLine)) into tName
         put fsTrim(char (tColon + 1) to -1 of tLine) into tValue
         put tValue into tOut[tName]
      end if
   end repeat
   set the lineDelimiter to tSaved
   set the itemDelimiter to tSavedID
   return tOut
end fsParseRequest

-- Route: a folder (listing or its index.html, with a trailing-slash redirect), a
-- file (streamed, Range-aware), else 404. Only GET/HEAD are served.
command fsServePath pStream, pHeaders
   local tRaw, tPath, tDisk, tIndex, tMethod
   put pHeaders["__method"] into tMethod
   if tMethod is not "GET" and tMethod is not "HEAD" then
      fsSendText pStream, "405 Method Not Allowed", "text/plain; charset=utf-8", "Only GET and HEAD are supported."
      exit fsServePath
   end if
   if sRoot is empty then
      fsSendText pStream, "503 Service Unavailable", "text/plain; charset=utf-8", "No folder is being shared."
      exit fsServePath
   end if
   put pHeaders["__path"] into tRaw          -- still %xx-encoded; used for the redirect Location
   put urlDecode(tRaw) into tPath            -- real chars for disk mapping
   if tPath is empty then
      put "/" into tPath
   end if
   -- Path-traversal guard AFTER decoding (catches %2e%2e), before any disk touch.
   replace "\" with "/" in tPath
   if tPath contains ".." then
      fsSendText pStream, "403 Forbidden", "text/plain; charset=utf-8", "Forbidden."
      exit fsServePath
   end if
   put sRoot & tPath into tDisk
   if there is a folder tDisk then
      -- A folder URL must end in "/" so the relative links in the listing resolve;
      -- redirect the browser back with the slash added if it does not.
      if the last char of tPath is not "/" then
         fsSendRedirect pStream, (tRaw & "/")
         exit fsServePath
      end if
      put tDisk & "index.html" into tIndex    -- tDisk ends with "/" here
      if there is a file tIndex then
         fsServeFile pStream, tIndex, "index.html", pHeaders
      else
         fsSendText pStream, "200 OK", "text/html; charset=utf-8", fsListingHtml(tDisk, tPath)
      end if
      exit fsServePath
   end if
   if there is a file tDisk then
      fsServeFile pStream, tDisk, tPath, pHeaders
      exit fsServePath
   end if
   fsSendText pStream, "404 Not Found", "text/html; charset=utf-8", fsNotFoundHtml(tPath)
end fsServePath

-- Serve a file: size it, honour a Range, write the HTTP head, then arm the chunked
-- pump. The file is NEVER read whole into memory. A plain (non-Range) download uses
-- the exact Quick Share pump (proven); only a ranged request seeks.
command fsServeFile pStream, pDisk, pForMime, pHeaders
   local tSize, tRange, tStart, tEnd, tLen, tStatus, tHead, tCrlf, tType, tSavedID
   put fsFileSize(pDisk) into tSize
   if tSize is empty then
      fsSendText pStream, "404 Not Found", "text/plain; charset=utf-8", "Not found."
      exit fsServeFile
   end if
   put fsCrlf() into tCrlf
   put fsMime(pForMime) into tType
   put fsParseRange(pHeaders["range"], tSize) into tRange
   if tRange is "unsatisfiable" then
      put ("HTTP/1.1 416 Range Not Satisfiable" & tCrlf & "Content-Range: bytes */" & tSize & tCrlf & \
         "Content-Length: 0" & tCrlf & "Connection: close" & tCrlf & tCrlf) into tHead
      oxWrite pStream, textEncode(tHead, "UTF-8")
      oxCloseStream pStream
      fsCleanup pStream
      exit fsServeFile
   end if
   if tRange is empty then
      put 0 into tStart
      put (tSize - 1) into tEnd
      put "200 OK" into tStatus
   else
      put the itemDelimiter into tSavedID
      set the itemDelimiter to ","
      put item 1 of tRange into tStart
      put item 2 of tRange into tEnd
      set the itemDelimiter to tSavedID
      put "206 Partial Content" into tStatus
   end if
   put (tEnd - tStart + 1) into tLen
   put ("HTTP/1.1 " & tStatus & tCrlf & "Content-Type: " & tType & tCrlf & \
      "Accept-Ranges: bytes" & tCrlf & "Content-Length: " & tLen & tCrlf) into tHead
   if tStatus begins with "206" then
      put ("Content-Range: bytes " & tStart & "-" & tEnd & "/" & tSize & tCrlf) after tHead
   end if
   put ("Connection: close" & tCrlf & tCrlf) after tHead
   oxWrite pStream, textEncode(tHead, "UTF-8")
   if the result is not empty then
      fsAbort pStream
      exit fsServeFile
   end if
   put fsLeaf(pForMime) into sTxName[pStream]
   fsLog "Serving " & quote & sTxName[pStream] & quote & " (" & fsBytes(tLen) & \
      ") - " & tStatus
   if pHeaders["__method"] is "HEAD" then
      oxCloseStream pStream
      fsCleanup pStream
      exit fsServeFile
   end if
   -- Arm the chunked pump. The file is opened per-tick (see fsSendPump), not held
   -- open, so several browsers can pull the SAME file at once. sTxPos is the next
   -- byte to read (tStart honours a Range; 0 for a full download).
   put pDisk into sTxPath[pStream]
   put tStart into sTxPos[pStream]
   put tLen into sTxRemaining[pStream]
   put the milliseconds into sTxDeadline[pStream]
   send ("fsSendPump " & pStream) to me in kPumpTick milliseconds
end fsServeFile

-- One slice per tick (never a tight loop). The remaining counter (not EOF alone)
-- bounds a ranged response to its window.
--
-- CONCURRENCY: the file is OPENED, SEEKED, READ and CLOSED entirely within this one
-- tick, with no yield in between, so two browsers pulling the SAME file never share
-- a cursor. LiveCode keys a file handle by PATH and makes a second `open file` on an
-- already-open path a silent no-op sharing one cursor - a persistent handle would
-- interleave and corrupt concurrent reads of the same file. Per-tick open/close
-- sidesteps that and still streams (O(1) memory); the open/close cost is nothing
-- next to Tor's latency.
--
-- NOTE: no writability gate here - an oxStreamState backpressure gate misread a live
-- stream ("connected" contains "connect") and stalled forever, so the body never
-- arrived (the Quick Share false-stall). We pace on the timer + oxWrite's error
-- return instead.
command fsSendPump pStream
   local tWant, tSlice, tErr
   if sTxPath[pStream] is empty then
      exit fsSendPump
   end if
   put kChunk into tWant
   if sTxRemaining[pStream] < tWant then
      put sTxRemaining[pStream] into tWant
   end if
   if tWant <= 0 then
      fsFinishSend pStream       -- the whole (possibly ranged) body is out
      exit fsSendPump
   end if
   open file sTxPath[pStream] for binary read
   if the result is not empty then
      fsAbort pStream            -- the file vanished mid-transfer
      exit fsSendPump
   end if
   -- VERIFY (on-engine): `seek to N in file` sets the read cursor N bytes from the
   -- START of the file (0-based), so the next read returns bytes [N..]. This is the
   -- one unproven primitive; if a download serves shifted/garbled bytes on-engine,
   -- the seek base is the first thing to check (a one-line fix). It is a loud,
   -- first-test-obvious failure, not silent corruption.
   seek to sTxPos[pStream] in file sTxPath[pStream]
   read from file sTxPath[pStream] for tWant
   put it into tSlice
   try
      close file sTxPath[pStream]
   catch tErr
   end try
   if tSlice is empty then
      fsFinishSend pStream       -- EOF (defensive: file shorter than declared)
      exit fsSendPump
   end if
   oxWrite pStream, tSlice
   if the result is not empty then
      fsAbort pStream
      exit fsSendPump
   end if
   add (the number of bytes in tSlice) to sTxPos[pStream]
   subtract (the number of bytes in tSlice) from sTxRemaining[pStream]
   put the milliseconds into sTxDeadline[pStream]
   send ("fsSendPump " & pStream) to me in kPumpTick milliseconds
end fsSendPump

command fsFinishSend pStream
   fsLog "Served " & quote & sTxName[pStream] & quote & " over Tor."
   oxCloseStream pStream
   fsCleanup pStream
end fsFinishSend

-- ---- small HTTP responses (immediate close after the single write; the proven
-- Quick Share pattern) --------------------------------------------------------
command fsSendText pStream, pStatus, pType, pBody
   local tData, tHead, tCrlf
   put fsCrlf() into tCrlf
   put textEncode(pBody, "UTF-8") into tData
   put ("HTTP/1.1 " & pStatus & tCrlf & "Content-Type: " & pType & tCrlf & \
      "Content-Length: " & (the number of bytes in tData) & tCrlf & "Connection: close" & tCrlf & tCrlf) into tHead
   oxWrite pStream, (textEncode(tHead, "UTF-8") & tData)
   oxCloseStream pStream
   fsCleanup pStream
end fsSendText

command fsSendRedirect pStream, pLocation
   local tHead, tCrlf
   put fsCrlf() into tCrlf
   put ("HTTP/1.1 301 Moved Permanently" & tCrlf & "Location: " & pLocation & tCrlf & \
      "Content-Length: 0" & tCrlf & "Connection: close" & tCrlf & tCrlf) into tHead
   oxWrite pStream, textEncode(tHead, "UTF-8")
   oxCloseStream pStream
   fsCleanup pStream
end fsSendRedirect

-- Clear per-stream state and close any open file handle. Idempotent (a double call
-- on the normal path is a harmless no-op). Does NOT close the OnionXT stream - the
-- caller does that; on a "closed"/"error" event the stream is already gone.
command fsCleanup pStream
   local tErr
   if sTxPath[pStream] is not empty then
      try
         close file sTxPath[pStream]
      catch tErr
      end try
   end if
   delete variable sReq[pStream]
   delete variable sServed[pStream]
   delete variable sTxPath[pStream]
   delete variable sTxPos[pStream]
   delete variable sTxRemaining[pStream]
   delete variable sTxName[pStream]
   delete variable sTxDeadline[pStream]
end fsCleanup

command fsAbort pStream
   oxCloseStream pStream
   fsCleanup pStream
end fsAbort

-- Idle watchdog per connection, armed at accept. No-ops once the connection is
-- done/cleaned (its per-stream state is gone).
command fsServeWatchdog pStream
   if sReq[pStream] is empty and sTxPath[pStream] is empty then
      exit fsServeWatchdog        -- nothing in flight; served + cleaned, or gone
   end if
   if (the milliseconds - sTxDeadline[pStream]) > kServeTimeout then
      fsAbort pStream
      exit fsServeWatchdog
   end if
   send ("fsServeWatchdog " & pStream) to me in kServeTimeout milliseconds
end fsServeWatchdog

-- ---- directory listing + error pages ----------------------------------------
-- Build a directory-listing page for pDiskFolder (a disk path ending in "/"),
-- served at pUrlPath (a URL path ending in "/"). Uses `the files` / `the folders`
-- (portable; `the detailedFiles` is a compile-time "bad factor" on some OXT
-- engines). Names are HTML-escaped (a file named "<script>" cannot inject) and
-- path-encoded in the hrefs; links are relative to pUrlPath, so a subfolder browses
-- in and ".." goes up. Per-file SIZES are deliberately omitted from the listing:
-- OXT has no cheap size call (no detailedFiles), and sizing every file would mean
-- reading each one just to draw a page - a media folder could be many GB. The size
-- appears where it is free: in each file's own Content-Length header.
function fsListingHtml pDiskFolder, pUrlPath
   local tSaved, tFiles, tFolders, tName, tOut, tCount
   put the defaultFolder into tSaved
   set the defaultFolder to pDiskFolder
   put the files into tFiles
   put the folders into tFolders
   set the defaultFolder to tSaved
   put fsPageTop("Index of " & fsHtmlEscape(pUrlPath)) into tOut
   put "<h1>Index of " & fsHtmlEscape(pUrlPath) & "</h1><ul class='fl'>" after tOut
   if pUrlPath is not "/" then
      put "<li class='up'><a href='../'>.. (up a level)</a></li>" after tOut
   end if
   put 0 into tCount
   repeat for each line tName in tFolders
      if tName is "." or tName is ".." then
         next repeat
      end if
      put "<li class='dir'><a href='" & fsPathEncode(tName) & "/'>" & fsHtmlEscape(tName) & "/</a></li>" after tOut
      add 1 to tCount
   end repeat
   repeat for each line tName in tFiles
      if tName is empty then
         next repeat
      end if
      put "<li class='file'><a href='" & fsPathEncode(tName) & "'>" & fsHtmlEscape(tName) & "</a></li>" after tOut
      add 1 to tCount
   end repeat
   put "</ul><p class='muted'>" & tCount & " item(s) - shared anonymously over Tor. Downloads resume if interrupted.</p>" after tOut
   put fsPageBottom() after tOut
   return tOut
end fsListingHtml

function fsNotFoundHtml pPath
   return fsPageTop("Not found") & "<h1>Not found</h1><p class='muted'>" & \
      "There is nothing at " & fsHtmlEscape(pPath) & " in this share.</p>" & \
      "<p><a href='/'>Back to the top</a></p>" & fsPageBottom()
end fsNotFoundHtml

-- Shared page chrome. Single-quoted HTML attributes so the LiveCode string literals
-- never contain a double quote. Dark-friendly, mobile-friendly, no external assets.
function fsPageTop pTitle
   return ("<!doctype html><html><head><meta charset='utf-8'>" & \
      "<meta name='viewport' content='width=device-width,initial-scale=1'>" & \
      "<title>" & pTitle & "</title><style>" & \
      "body{font-family:system-ui,-apple-system,sans-serif;max-width:46em;margin:2.4em auto;padding:0 1.1em;color:#1c2430;background:#fff}" & \
      "h1{font-size:1.25em;border-bottom:1px solid #e5e8ee;padding-bottom:.4em}" & \
      "ul.fl{list-style:none;padding:0;margin:1em 0}" & \
      "ul.fl li{padding:.34em .2em;border-bottom:1px solid #f0f2f6}" & \
      "ul.fl li.dir a{font-weight:600}" & \
      "a{color:#2c5aa0;text-decoration:none}a:hover{text-decoration:underline}" & \
      ".muted{color:#8a909a;font-size:.9em}" & \
      "@media(prefers-color-scheme:dark){body{background:#12151a;color:#dfe4ea}" & \
      "h1{border-color:#2a2f38}ul.fl li{border-color:#20242c}a{color:#7ea6e0}.muted{color:#828a96}}" & \
      "</style></head><body>")
end fsPageTop

function fsPageBottom
   return "</body></html>"
end fsPageBottom

-- ---- helpers -----------------------------------------------------------------
-- Byte size of a file WITHOUT loading it whole into memory. OpenXTalk does not
-- support 'the detailedFiles', so we open the file and count in bounded 4 MiB
-- chunks: O(file size) I/O but O(1) memory. Empty if unreadable.
function fsFileSize pPath
   local tSize
   put 0 into tSize
   open file pPath for binary read
   if the result is not empty then
      return empty
   end if
   repeat
      read from file pPath for 4194304
      if it is empty then
         exit repeat
      end if
      add the number of bytes in it to tSize
   end repeat
   close file pPath
   return tSize
end fsFileSize

-- Parse a single HTTP byte-range against a known total. Returns "start,end"
-- (inclusive, 0-based), or "" for no/ignored range (serve the whole file), or
-- "unsatisfiable" for a syntactically valid but out-of-bounds range (-> 416).
-- Only a single range is honoured; a multi-range request falls back to the whole
-- file. Matches the golden test (tests/fileserver_golden.py).
function fsParseRange pRange, pTotal
   local tSpec, tStart, tEnd, tSavedID
   if pRange is empty then
      return ""
   end if
   if pRange does not begin with "bytes=" then
      return ""
   end if
   put char 7 to -1 of pRange into tSpec       -- after "bytes="
   if tSpec contains "," then
      return ""                                 -- multi-range: serve the whole file
   end if
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "-"
   put item 1 of tSpec into tStart
   put item 2 of tSpec into tEnd
   set the itemDelimiter to tSavedID
   if tStart is empty then
      -- suffix range "bytes=-N": the last N bytes
      if tEnd is empty or tEnd is not an integer then
         return "unsatisfiable"
      end if
      put (pTotal - tEnd) into tStart
      if tStart < 0 then
         put 0 into tStart
      end if
      put (pTotal - 1) into tEnd
   else
      if tStart is not an integer then
         return "unsatisfiable"
      end if
      if tEnd is empty then
         put (pTotal - 1) into tEnd
      else if tEnd is not an integer then
         return "unsatisfiable"
      end if
   end if
   if tStart > tEnd or tStart < 0 or tStart >= pTotal then
      return "unsatisfiable"
   end if
   if tEnd >= pTotal then
      put (pTotal - 1) into tEnd
   end if
   return tStart & "," & tEnd
end fsParseRange

-- A pseudo-random high loopback port for OnionXT's internal listener. A collision
-- surfaces as an oxCreateService error string, which the caller reports.
function fsPickPort
   return (20000 + random(40000))
end fsPickPort

function fsStripSlash pFolder
   local tOut
   put pFolder into tOut
   if tOut is not empty and (the last char of tOut is "/" or the last char of tOut is "\") then
      delete the last char of tOut
   end if
   return tOut
end fsStripSlash

-- The leaf (basename) of a path, for logging.
function fsLeaf pPath
   local tOut, tSavedID
   put pPath into tOut
   replace "\" with "/" in tOut
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "/"
   put the last item of tOut into tOut
   set the itemDelimiter to tSavedID
   return tOut
end fsLeaf

-- Human-readable byte size, e.g. 3.4 MiB (for the log and Content-Length notes).
function fsBytes pBytes
   local tUnits, tVal, tI, tSavedID
   if pBytes is empty or pBytes is not a number then
      return "0 B"
   end if
   put "B,KiB,MiB,GiB,TiB" into tUnits
   put the itemDelimiter into tSavedID
   set the itemDelimiter to comma
   put pBytes into tVal
   put 1 into tI
   repeat while tVal >= 1024 and tI < the number of items of tUnits
      put tVal / 1024 into tVal
      add 1 to tI
   end repeat
   put (the round of (tVal * 10) / 10) && (item tI of tUnits) into tVal
   set the itemDelimiter to tSavedID
   return tVal
end fsBytes

function fsCrlf
   return (numToChar(13) & numToChar(10))
end fsCrlf

function fsTrim pText
   local tOut, tTab
   put pText into tOut
   put numToChar(9) into tTab
   repeat while tOut is not empty and (the first char of tOut is space or the first char of tOut is tTab)
      delete the first char of tOut
   end repeat
   repeat while tOut is not empty and (the last char of tOut is space or the last char of tOut is tTab)
      delete the last char of tOut
   end repeat
   return tOut
end fsTrim

-- Map a file extension to a MIME type. Unknown -> octet-stream (the browser
-- downloads it). Known media/text/image types render inline in the browser.
function fsMime pPath
   local tSavedID, tExtn
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "."
   put toLower(the last item of pPath) into tExtn
   set the itemDelimiter to tSavedID
   if tExtn is "html" or tExtn is "htm" then
      return "text/html; charset=utf-8"
   else if tExtn is "css" then
      return "text/css; charset=utf-8"
   else if tExtn is "js" then
      return "application/javascript; charset=utf-8"
   else if tExtn is "json" then
      return "application/json; charset=utf-8"
   else if tExtn is "txt" or tExtn is "md" or tExtn is "log" then
      return "text/plain; charset=utf-8"
   else if tExtn is "png" then
      return "image/png"
   else if tExtn is "jpg" or tExtn is "jpeg" then
      return "image/jpeg"
   else if tExtn is "gif" then
      return "image/gif"
   else if tExtn is "webp" then
      return "image/webp"
   else if tExtn is "svg" then
      return "image/svg+xml"
   else if tExtn is "ico" then
      return "image/x-icon"
   else if tExtn is "pdf" then
      return "application/pdf"
   else if tExtn is "mp4" or tExtn is "m4v" then
      return "video/mp4"
   else if tExtn is "webm" then
      return "video/webm"
   else if tExtn is "mp3" then
      return "audio/mpeg"
   else if tExtn is "ogg" or tExtn is "oga" then
      return "audio/ogg"
   else if tExtn is "wav" then
      return "audio/wav"
   else if tExtn is "zip" then
      return "application/zip"
   end if
   return "application/octet-stream"
end fsMime

-- Encode a name for a URL PATH segment. urlEncode uses "+" for space (form style);
-- a path wants "%20", so fix that up.
function fsPathEncode pName
   local tEnc
   put urlEncode(pName) into tEnc
   replace "+" with "%20" in tEnc
   return tEnc
end fsPathEncode

-- Escape a value for HTML text/attribute context so a crafted file name cannot
-- inject markup. "&" first, then the rest.
function fsHtmlEscape pText
   local tOut
   put pText into tOut
   replace "&" with "&amp;" in tOut
   replace "<" with "&lt;" in tOut
   replace ">" with "&gt;" in tOut
   replace quote with "&quot;" in tOut
   replace "'" with "&#39;" in tOut
   return tOut
end fsHtmlEscape

-- Is OnionXT installed? A guarded oxVersion() probe: it resolves only when the
-- OnionXT extension (and its SodiumXT dependency) is loaded.
function fsHasOnion
   local tV, tErr
   try
      put oxVersion() into tV
   catch tErr
      return false
   end try
   return (tV is not empty)
end fsHasOnion

command fsLog pMsg
   if there is no field "fsLog" then
      exit fsLog
   end if
   put the time & "  " & pMsg & return after field "fsLog"
   if the number of lines of field "fsLog" > 300 then
      delete line 1 to (the number of lines of field "fsLog" - 300) of field "fsLog"
   end if
   set the vScroll of field "fsLog" to the formattedHeight of field "fsLog"
end fsLog
