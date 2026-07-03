script "quickShareApp"

-- torrent-quickshare.livecodescript - the SIMPLEST possible TorrentXT demo:
-- drag a file onto the window, get a short code, send the code to a friend;
-- they paste it in and the file transfers straight from your machine to theirs.
-- No server, no upload, no size limit - it is plain peer-to-peer BitTorrent with
-- the DHT finding the peers, wrapped in a one-card stack.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI and starts a
-- TorrentXT session. Needs only the loaded org.openxtalk.library.torrent.
--
-- THE DEMO (two machines, both running this stack):
--   1. On machine A, drag a file onto the drop area (or click it to choose one).
--      A 40-character SHARE CODE appears. Click Copy and send it to machine B.
--   2. On machine B, paste the code into "Receive a file" and click Download.
--   3. The file transfers A -> B while A keeps this window open. Watch the
--      Transfers list fill in on both ends.
-- The code is the torrent's content address (its info-hash): it both names the
-- file and lets the DHT introduce the two machines, so no tracker or server is
-- needed. Keep the sending window open until your friend has the whole file.
--
-- OPTIONAL ENCRYPTION: type a passphrase before dropping a file and it is
-- encrypted end-to-end with cryptoXT (libsodium): the key is derived with Argon2id
-- and the file is sealed with crypto_secretstream. Only the CIPHERTEXT (under a
-- neutral .enc name) ever hits the swarm; the real filename and the salt ride
-- inside the (now longer) share code, and the passphrase - which you give your
-- friend separately - is what unlocks the bytes. The receiver types the same
-- passphrase; it is checked UP FRONT against a small authenticator in the code,
-- so a wrong passphrase is caught immediately and nothing is downloaded. On a
-- correct passphrase the file downloads, unlocks automatically, and the encrypted
-- .enc copy is cleaned up so only the real file is left. The encryption features
-- REQUIRE the cryptoXT extension (org.openxtalk.library.sodium); plain sharing
-- works without it.
--
-- Single-thread playbook: a 250 ms poll drains events and a 1 s loop repaints the
-- Transfers list. The heavy bytes move on libtorrent's own threads, never script.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sPolling          -- "true" while the poll/repaint loops are armed
local sShareCode        -- the most recent file's share code (plain hash or BTXQS1:)
local sCanEncrypt       -- "true" if cryptoXT (libsodium) is installed + working
local sPendingKey       -- array: info-hash -> 32-byte file key, for a download to decrypt
local sPendingName      -- array: info-hash -> original filename, for that download
local sXferName         -- array: info-hash -> real name to SHOW locally (swarm sees .enc)
local sTempEnc          -- array: info-hash -> temp .enc path we made (cleaned on close)

-- OnionXT (optional Tor anonymity, Model C). When the Tor toggle is on, a file's
-- bytes travel over an OnionXT onion stream (both IPs hidden) and NO torrent is
-- created. All of this is inert unless sHasOnion. See the ox* wiring below.
local sHasOnion         -- "true" if OnionXT loads AND cryptoXT works (probed once)
local sTorReady         -- "true" if Tor is bootstrapped + ready (LIVE cache; re-checked at use)
local sTorSend          -- "true" while the "Send privately over Tor" toggle is armed
local sWebServe         -- "true" while the "Serve as web download" checkbox is on
local sOnionTriedTB     -- "true" once we have retried the Tor Browser control port pair
local sActiveShare      -- array: the one live anon share (service, path, name, enc, salt, verify, ...)
local sOnionXfers       -- array: stream handle -> {name,dir,enc,total,got,state} for the transfers view
-- per send-stream state (keyed by the stream handle)
local sTxPath           -- array: stream -> path of the file we are streaming out
local sTxOffset         -- array: stream -> bytes sent so far (progress)
local sTxTotal          -- array: stream -> total bytes to send
local sTxDeadline       -- array: stream -> the milliseconds of the last send (idle watchdog)
local sTxReq            -- array: stream -> inbound request bytes accumulated before we start
local sTxMode           -- array: stream -> "btxo" (app protocol) or "http" (browser)
local sTxRaw            -- array: stream -> "true" for an HTTP body (raw bytes, no framing)
-- per receive-stream state (keyed by the stream handle)
local sRxBuf            -- array: stream -> reassembly buffer (drained + compacted each call)
local sRxState          -- array: stream -> "header" / "body" / "done"
local sRxTmp            -- array: stream -> temp output path we are writing into
local sRxName           -- array: stream -> real (sanitized) filename to save as
local sRxEnc            -- array: stream -> nonzero if the payload is a cryptoXT .enc
local sRxTotal          -- array: stream -> total payload bytes expected
local sRxGot            -- array: stream -> payload bytes written so far
local sRxKey            -- array: stream -> 32-byte file key (encrypted receive), else empty
local sRxSave           -- array: stream -> save folder for this receive
local sRxDeadline       -- array: stream -> the milliseconds of the last data (idle watchdog)

-- Optional end-to-end encryption (mirrors the channels demo), via cryptoXT
-- (libsodium). A passphrase turns a share into ciphertext under a NEUTRAL name:
-- the swarm only ever sees the .enc blob, the real filename and the Argon2id salt
-- ride inside the share code, and the passphrase (shared separately) is what
-- actually unlocks the bytes. Requires the org.openxtalk.library.sodium extension.
constant kCodePrefix = "BTXQS1:" -- marks an encrypted share code (vs a bare hash)
-- a fixed token sealed with the file key and carried in the share code, so the
-- receiver can verify the passphrase LOCALLY before downloading anything (a wrong
-- passphrase never pulls a useless .enc to disk).
constant kQsVerify = "BTXQSVERIFY"

-- ---- OnionXT (optional Tor anonymity) constants ------------------------------
-- Model C: with the Tor toggle on, the file's bytes ride an OnionXT onion stream
-- (both IPs hidden) and NO torrent is created. Requires the OnionXT extension +
-- cryptoXT + a LOCAL Tor daemon. Every ox* call is against OnionXT's published
-- ABI; verified statically here, needs an on-engine OXT pass with a running Tor
-- daemon (the project convention). See docs/ONIONXT-INTEGRATION-PLAN.md.
constant kTorCodePrefix = "BTXTOR1:"   -- marks an anonymous (Tor) share code
constant kOnionMagic = "BTXO"          -- 4 ASCII bytes: file-stream frame sync + go request
constant kOnionVer = 1                 -- stream protocol version
constant kOnionVPort = 80              -- the onion service's advertised virtual port
constant kOnionChunk = 65536           -- 64 KiB: max payload bytes in one data frame
constant kFlagEnc = 1                  -- header flags bit0: payload is a cryptoXT .enc
constant kOnionPumpTick = 15           -- ms between send-pump frames (never a tight loop)
constant kOnionSendTimeout = 30000     -- ms idle watchdog, sender
constant kOnionRecvTimeout = 60000     -- ms idle watchdog, receiver (Tor is slow)
constant kOnionPublishTimeout = 90000  -- ms to wait for the onion descriptor to upload
constant kOnionMaxName = 1024          -- reject a header nameLen beyond this (anti-DoS)
constant kOnionMaxTotal = 8589934592   -- 8 GiB payload ceiling; reject a larger header
constant kAnonSizeWarn = 268435456     -- 256 MiB: warn (never block) above this, anon path
constant kTorSocksPort = "9050"        -- system/standalone tor
constant kTorControlPort = "9051"
constant kTorSocksPortTB = "9150"      -- Tor Browser
constant kTorControlPortTB = "9151"

-- Bump when the generated UI changes; qsBuild rebuilds the controls on a mismatch
-- so updating the script in a SAVED stack picks up the new layout (passphrase
-- fields and all) instead of keeping the old controls around.
constant kQsUiVersion = "qs-ui-2026-08"

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   qsBuild
   qsStart
end openStack

on closeStack
   qsStop
end closeStack

-- ---- OS file drag-and-drop ---------------------------------------------------
-- These bubble up from whatever control is under the pointer to this stack
-- script, so a drop anywhere on the window works. Click-to-choose (the drop
-- area is also a button) is the guaranteed fallback if a platform does not
-- deliver OS file drops.
on dragEnter
   set the acceptDrop to true
   if there is a field "qsDrop" then
      set the backgroundColor of field "qsDrop" to "225,238,255"
   end if
end dragEnter

on dragMove
   set the acceptDrop to true
end dragMove

on dragLeave
   if there is a field "qsDrop" then
      set the backgroundColor of field "qsDrop" to "245,247,250"
   end if
end dragLeave

on dragDrop
   local tFiles
   if there is a field "qsDrop" then
      set the backgroundColor of field "qsDrop" to "245,247,250"
   end if
   put the dragData["files"] into tFiles
   if tFiles is empty then
      pass dragDrop
   end if
   -- one file at a time keeps the demo simple; the first dropped item wins
   qsShareFile (line 1 of tFiles)
end dragDrop

on mouseUp
   switch the short name of the target
      case "qsDrop"
         qsBrowseFile
         break
      case "qsCopy"
         qsCopyCode
         break
      case "qsGet"
         qsGetFile
         break
      case "qsTorToggle"
         qsToggleTor
         break
      case "qsWebCheck"
         qsToggleWeb
         break
      case "qsWebCopy"
         qsCopyWebLink
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- ---- self-building UI (idempotent; rebuilds on a UI-version bump) ------------
command qsBuild
   -- a normal re-open with a matching version + the passphrase fields present is
   -- a fast no-op; a script update that changed the layout rebuilds from scratch.
   if the uUiVersion of this stack is kQsUiVersion and there is a field "qsSendPass" then
      exit qsBuild
   end if
   qsClearGeneratedUI
   lock screen
   set the width of this stack to 620
   set the height of this stack to 664
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - Quick Share"
   -- title band
   qsLabel "qsTitle", "  Quick Share - send a file with a code", "0,0,620,40", 15
   set the opaque of field "qsTitle" to true
   set the backgroundColor of field "qsTitle" to "44,90,160"
   set the foregroundColor of field "qsTitle" to "255,255,255"
   set the textStyle of field "qsTitle" to "bold"
   qsLabel "qsTagline", "Send a file straight to a friend with a short code. No server, no size limit, no upload first - peer-to-peer.", "24,48,424,70", 10
   set the foregroundColor of field "qsTagline" to "90,96,105"
   -- live Tor status pill (repainted only by qsOnionPill), sitting in the title band
   qsLabel "qsTorPill", "Tor: off", "430,8,612,32", 10
   set the opaque of field "qsTorPill" to true
   set the backgroundColor of field "qsTorPill" to "33,72,132"
   set the foregroundColor of field "qsTorPill" to "220,228,240"
   set the textAlign of field "qsTorPill" to "right"
   -- the optional "Send privately over Tor" toggle (two-state; managed via sTorSend)
   qsButton "qsTorToggle", "Send privately over Tor", "440,44,600,72"
   set the style of button "qsTorToggle" to "checkbox"
   set the autoHilite of button "qsTorToggle" to false
   -- SEND: an OPTIONAL passphrase (set it BEFORE dropping to encrypt), the drop
   -- area, then the resulting code.
   qsLabel "qsSendPassCap", "Lock with a passphrase (optional):", "24,76,300,96", 10
   qsField "qsSendPass", "304,74,596,98", false
   qsField "qsDrop", "24,104,596,184", true
   set the opaque of field "qsDrop" to true
   set the backgroundColor of field "qsDrop" to "245,247,250"
   set the borderWidth of field "qsDrop" to 1
   set the threeD of field "qsDrop" to false
   set the borderColor of field "qsDrop" to "175,185,200"
   set the textAlign of field "qsDrop" to "center"
   set the textSize of field "qsDrop" to 13
   set the foregroundColor of field "qsDrop" to "90,96,105"
   set the text of field "qsDrop" to (return & "Drag a file here to share" & return & "(or click to choose a file)")
   -- OPTIONAL: also serve a plaintext Tor share as a browser web download. Only a
   -- plaintext file shared over Tor is served this way; the URL appears at the right.
   qsButton "qsWebCheck", "Serve as web download", "24,186,220,208"
   set the style of button "qsWebCheck" to "checkbox"
   set the autoHilite of button "qsWebCheck" to false
   qsField "qsWebLink", "226,186,520,208", true
   set the textFont of field "qsWebLink" to "Courier"
   set the textSize of field "qsWebLink" to 9
   set the opaque of field "qsWebLink" to true
   set the backgroundColor of field "qsWebLink" to "255,250,225"
   qsButton "qsWebCopy", "Copy", "526,186,596,208"
   qsLabel "qsSharing", "", "24,212,596,232", 10
   set the textStyle of field "qsSharing" to "bold"
   qsLabel "qsCodeCap", "Your share code - give this to your friend:", "24,238,596,256", 10
   qsField "qsCode", "24,258,490,292", true
   set the textFont of field "qsCode" to "Courier"
   set the textSize of field "qsCode" to 12
   set the opaque of field "qsCode" to true
   set the backgroundColor of field "qsCode" to "255,250,225"
   qsButton "qsCopy", "Copy", "500,260,596,290"
   -- RECEIVE: paste a code, an optional passphrase (only if it is locked), download
   qsSection "qsRecvSec", "Receive a file", "24,308,596,330"
   qsLabel "qsRecvCap", "Paste a code a friend sent you, then click Download:", "24,336,596,354", 10
   qsField "qsRecvCode", "24,358,490,390", false
   set the textFont of field "qsRecvCode" to "Courier"
   set the textSize of field "qsRecvCode" to 11
   qsButton "qsGet", "Download", "500,358,596,390"
   qsLabel "qsRecvPassCap", "Passphrase (only if the file is locked):", "24,396,300,416", 10
   qsField "qsRecvPass", "304,394,596,418", false
   -- TRANSFERS: see it working
   qsSection "qsXferSec", "Transfers", "24,430,596,452"
   qsLabel "qsXferHead", "Name" & tab & "Direction" & tab & "Progress", "24,456,596,474", 9
   set the tabStops of field "qsXferHead" to "210,330"
   set the textFont of field "qsXferHead" to "Courier"
   set the textSize of field "qsXferHead" to 9
   qsList "qsXfers", "24,476,596,556", false
   set the tabStops of field "qsXfers" to "210,330"
   set the textFont of field "qsXfers" to "Courier"
   set the textSize of field "qsXfers" to 10
   qsLabel "qsStatus", "", "24,560,596,580", 10
   set the foregroundColor of field "qsStatus" to "90,96,105"
   -- a small activity log
   qsList "qsLog", "24,586,596,652", true
   set the textSize of field "qsLog" to 9
   qsAddTips
   qsOnionPill
   set the uUiVersion of this stack to kQsUiVersion
   unlock screen
end qsBuild

-- Delete every generated control (named "qs...") top-down so a kQsUiVersion bump
-- can rebuild the UI from scratch in a saved stack without leaving stale controls
-- behind. Controls the user added (not named "qs...") are left untouched.
command qsClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of fields of this card down to 1
      if the short name of field tI of this card begins with "qs" then
         delete field tI of this card
      end if
   end repeat
   repeat with tI = the number of buttons of this card down to 1
      if the short name of button tI of this card begins with "qs" then
         delete button tI of this card
      end if
   end repeat
   unlock screen
end qsClearGeneratedUI

command qsLabel pName, pText, pRect, pSize
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
end qsLabel

command qsSection pName, pText, pRect
   qsLabel pName, ("  " & pText), pRect, 11
   set the opaque of field pName to true
   set the backgroundColor of field pName to "210,216,226"
   set the foregroundColor of field pName to "30,40,60"
   set the textStyle of field pName to "bold"
end qsSection

command qsField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end qsField

command qsButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end qsButton

command qsList pName, pRect, pIsLog
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
end qsList

command qsAddTips
   set the tooltip of field "qsSendPass" to "Leave blank to share normally. Type a passphrase to ENCRYPT the file; tell your friend the passphrase separately."
   set the tooltip of field "qsDrop" to "Drag a file here, or click to choose one, to share it."
   set the tooltip of field "qsCode" to "Your file's share code. Click Copy and send it to your friend."
   set the tooltip of button "qsCopy" to "Copy the share code to the clipboard."
   set the tooltip of field "qsRecvCode" to "Paste the code a friend gave you here."
   set the tooltip of field "qsRecvPass" to "If your friend locked the file, type the passphrase they gave you here BEFORE clicking Download."
   set the tooltip of button "qsGet" to "Download the file for that code into your Quick Share folder."
   set the tooltip of field "qsXfers" to "Files you are sending and receiving, with live progress."
   set the tooltip of button "qsTorToggle" to "Off = normal peer-to-peer. On = send over Tor: both IP addresses are hidden and NO torrent is created (best for small, sensitive files). Add a passphrase to also encrypt and authenticate."
   set the tooltip of button "qsWebCheck" to "Only for a PLAINTEXT file shared over Tor: also let anyone with Tor Browser download it at a web link (both IPs stay hidden; the file is not encrypted and the sender is not verified). Leave the passphrase empty to use this."
   set the tooltip of field "qsWebLink" to "The browser download link for this share. Open it in Tor Browser, or click Copy to send it."
   set the tooltip of button "qsWebCopy" to "Copy the web download link to the clipboard."
   set the tooltip of field "qsTorPill" to "Status of your local Tor connection. 'ready' means anonymous sends and receives will work."
end qsAddTips

-- ---- session + loops ---------------------------------------------------------
command qsStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      qsLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      put 0 into sSession
      exit qsStart
   end if
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   put "true" into sPolling
   -- probe cryptoXT once so the passphrase fields can fail closed when it is absent
   put qsCanEncrypt() into sCanEncrypt
   -- probe OnionXT and bring up the Tor control link (non-blocking). The anon path
   -- is completely inert when OnionXT/cryptoXT/Tor are absent; nothing else changes.
   put qsHasOnion() into sHasOnion
   put "false" into sTorSend
   put "false" into sWebServe
   if sHasOnion then
      qsOnionStart
   else
      qsOnionPill
   end if
   if sCanEncrypt then
      qsLog "Ready. Drag a file to share it, or paste a code to download. Tip: type a passphrase first to ENCRYPT a file end-to-end."
   else
      qsLog "Ready. Drag a file to share it, or paste a code to download. (Encryption needs cryptoXT / org.openxtalk.library.sodium, which is not installed.)"
   end if
   send "qsPollOnce" to me in 0 milliseconds
   send "qsDashOnce" to me in 800 milliseconds
end qsStart

command qsStop
   local tKey, tErr
   put "false" into sPolling
   qsOnionStop
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   -- the session is stopped (so we are no longer seeding them); remove any temp
   -- .enc files we created for encrypted shares so they do not pile up.
   repeat for each key tKey in sTempEnc
      try
         if there is a file sTempEnc[tKey] then
            delete file sTempEnc[tKey]
         end if
      catch tErr
      end try
   end repeat
   put empty into sTempEnc
   put empty into sOnionXfers
end qsStop

command qsPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit qsPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit qsPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      qsHandleEvent tEvent
   end repeat
   send "qsPollOnce" to me in 250 milliseconds
end qsPollOnce

command qsDashOnce
   if sPolling is not "true" then
      exit qsDashOnce
   end if
   qsRefreshXfers
   send "qsDashOnce" to me in 1000 milliseconds
end qsDashOnce

-- ---- sending: turn a dropped/chosen file into a seeded torrent + a code ------
-- Without a passphrase this is the original flow: package the file and seed it,
-- the code IS its info-hash. With a passphrase we encrypt the file to a temp .enc
-- first and seed THAT (a neutral name, ciphertext bytes); the code then carries
-- the hash plus the real filename so the receiver can name + unlock it.
command qsShareFile pPath
   local tData, tH, tHash, tParent, tName, tPass
   local tEncPath, tEncParent, tErr, tSalt, tKey, tVerifier
   if sSession is 0 then
      qsLog "No session - reopen the stack."
      exit qsShareFile
   end if
   if pPath is empty then
      exit qsShareFile
   end if
   -- separator-agnostic: normalise to "/" so the parent split works on Windows too
   replace "\" with "/" in pPath
   if the last char of pPath is "/" then
      delete the last char of pPath
   end if
   if there is no file pPath and there is no folder pPath then
      qsLog "Could not find that file:" && pPath
      exit qsShareFile
   end if
   set the itemDelimiter to "/"
   put the last item of pPath into tName
   put item 1 to -2 of pPath into tParent
   if tParent is empty then
      put "/" into tParent
   end if
   put qsTrim(field "qsSendPass") into tPass
   -- FIRST-PRIORITY anonymous branch: with the Tor toggle on, the bytes ride an
   -- onion stream and NO torrent is created (mutual-exclusion invariant, section 3).
   if sTorSend is "true" then
      if not sHasOnion then
         qsLog "Turn off 'Send privately over Tor', or install OnionXT + cryptoXT + a local Tor daemon."
         exit qsShareFile
      end if
      if not qsOnionReadyNow() then
         qsLog "Tor is still connecting - watch the pill, then drop the file again."
         exit qsShareFile
      end if
      if there is a folder pPath then
         qsLog "Anonymous send handles one file at a time - zip the folder first, then send the zip."
         exit qsShareFile
      end if
      qsStartOnionShare pPath, tName, tPass
      exit qsShareFile
   end if
   if tPass is not empty and not sCanEncrypt then
      qsLog "cryptoXT (org.openxtalk.library.sodium) is not installed - sharing WITHOUT a passphrase. Install it to encrypt."
      put empty into tPass
   end if
   if tPass is empty then
      -- plaintext share (original behaviour): seed the file as-is
      qsLog "Packaging" && quote & tName & quote & "..."
      put btCreateTorrent(pPath, 0, 0, qsTracker()) into tData
      if tData is empty then
         qsLog "Could not package that file:" && btLastError()
         exit qsShareFile
      end if
      put btAddTorrentFile(sSession, tData, tParent) into tH
      if tH is 0 then
         qsLog "Could not start sharing:" && btLastError()
         exit qsShareFile
      end if
      put btInfoHash(tH) into tHash
      if tHash is empty then
         qsLog "Almost - the code is not ready yet. Drop the file again in a moment."
         exit qsShareFile
      end if
      put tHash into sShareCode
      set the text of field "qsCode" to tHash
      set the text of field "qsSharing" to ("Sharing " & quote & tName & quote & " (not encrypted) - keep this window open so your friend can download.")
      qsLog "Got a code for" && quote & tName & quote & ". Click Copy and send it to your friend."
   else
      -- encrypted share: derive a key from the passphrase + a fresh random salt
      -- (the salt rides in the share code), encrypt to a temp .enc with cryptoXT,
      -- then seed the ciphertext.
      put qsTempEncPath() into tEncPath
      put sxRandomBytes(16) into tSalt
      put sxPwHash(textEncode(tPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tKey
      -- a small authenticator so the receiver can check the passphrase up front
      put sxSecretBox(textEncode(kQsVerify, "ASCII"), tKey) into tVerifier
      qsLog "Encrypting" && quote & tName & quote & "- the app may pause briefly on a large file..."
      put qsEncryptFile(pPath, tEncPath, tKey) into tErr
      if tErr is not empty then
         qsLog "Could not encrypt" && quote & tName & quote & ":" && tErr
         exit qsShareFile
      end if
      set the itemDelimiter to "/"
      put item 1 to -2 of tEncPath into tEncParent
      if tEncParent is empty then
         put "/" into tEncParent
      end if
      put btCreateTorrent(tEncPath, 0, 0, qsTracker()) into tData
      if tData is empty then
         qsLog "Could not package the encrypted file:" && btLastError()
         exit qsShareFile
      end if
      put btAddTorrentFile(sSession, tData, tEncParent) into tH
      if tH is 0 then
         qsLog "Could not start sharing:" && btLastError()
         exit qsShareFile
      end if
      put btInfoHash(tH) into tHash
      if tHash is empty then
         qsLog "Almost - the code is not ready yet. Drop the file again in a moment."
         exit qsShareFile
      end if
      put tName into sXferName[toLower(tHash)]    -- show the REAL name locally
      put tEncPath into sTempEnc[toLower(tHash)]  -- clean up on close
      put qsMakeCode(tHash, tName, tSalt, tVerifier) into sShareCode
      set the text of field "qsCode" to sShareCode
      set the text of field "qsSharing" to ("Sharing " & quote & tName & quote & " ENCRYPTED - send the code AND tell your friend the passphrase separately.")
      qsLog "Encrypted" && quote & tName & quote & ". Send the code (Copy) AND the passphrase - your friend needs both."
   end if
end qsShareFile

command qsBrowseFile
   answer file "Choose a file to share:"
   if it is empty then
      exit qsBrowseFile
   end if
   qsShareFile it
end qsBrowseFile

command qsCopyCode
   if field "qsCode" is empty then
      qsLog "Share a file first to get a code."
      exit qsCopyCode
   end if
   set the clipboardData["text"] to field "qsCode"
   qsLog "Code copied. Send it to your friend by email, chat, anywhere."
end qsCopyCode

-- ---- receiving: a code becomes a download ------------------------------------
-- A plain code is a magnet or a bare info-hash (the original flow). A code that
-- begins with the BTXQS1: prefix is a LOCKED share: it carries the info-hash and
-- the real filename, and needs the passphrase. We stash the passphrase + name
-- against the hash so qsMaybeDecryptFinished can unlock the .enc when it lands.
command qsGetFile
   local tCode, tMag, tH, tHash, tName, tPass, tRest, tB64, tB64Salt, tB64Verify, tSalt, tKey
   if sSession is 0 then
      qsLog "No session - reopen the stack."
      exit qsGetFile
   end if
   put qsTrim(field "qsRecvCode") into tCode
   if tCode is empty then
      qsLog "Paste a code from your friend first."
      exit qsGetFile
   end if
   put qsTrim(field "qsRecvPass") into tPass
   -- an anonymous (Tor) share code routes through the onion path, checked first
   if tCode begins with kTorCodePrefix then
      qsReceiveOnion tCode
      exit qsGetFile
   end if
   if tCode begins with kCodePrefix then
      -- locked share code: BTXQS1:<hash>:<base64 name>:<base64 salt>:<base64 verifier>
      if not sCanEncrypt then
         qsLog "This code is locked, but cryptoXT (org.openxtalk.library.sodium) is not installed - cannot decrypt."
         exit qsGetFile
      end if
      if tPass is empty then
         qsLog "This code is LOCKED - type the passphrase your friend gave you, then click Download."
         exit qsGetFile
      end if
      put char ((the number of chars of kCodePrefix) + 1) to -1 of tCode into tRest
      set the itemDelimiter to ":"
      put item 1 of tRest into tHash
      put item 2 of tRest into tB64
      put item 3 of tRest into tB64Salt
      put item 4 of tRest into tB64Verify
      put toLower(tHash) into tHash
      if the number of chars of tHash is not 40 and the number of chars of tHash is not 64 then
         qsLog "That locked code looks damaged (bad hash)."
         exit qsGetFile
      end if
      if tB64Salt is empty then
         qsLog "That locked code is missing its salt (was it made by an older version?)."
         exit qsGetFile
      end if
      put textDecode(base64Decode(tB64), "UTF-8") into tName
      if tName is empty then
         put ("shared-file-" & tHash) into tName
      end if
      -- derive the same key the sender used (passphrase + the salt from the code)
      put base64Decode(tB64Salt) into tSalt
      put sxPwHash(textEncode(tPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tKey
      -- CHECK THE PASSPHRASE NOW, before downloading anything: if the verifier in
      -- the code does not open with this key, the passphrase is wrong, so we ask
      -- again and never pull the .enc to disk. (Older codes have no verifier; those
      -- fall back to verify-on-finish.)
      if tB64Verify is not empty and not qsKeyOpensVerifier(tKey, tB64Verify) then
         qsLog "That passphrase does not match this file. Check it and click Download again."
         answer "That passphrase does not match this locked file." & return & return & \
            "Check the passphrase your friend gave you and try again." with "OK"
         select the text of field "qsRecvPass"
         exit qsGetFile
      end if
      put tKey into sPendingKey[tHash]
      put tName into sPendingName[tHash]
      put tName into sXferName[tHash]            -- show the real name while it downloads
      put "magnet:?xt=urn:btih:" & tHash & "&tr=" & qsTracker() into tMag
      put btAddMagnet(sSession, tMag, qsSaveFolder()) into tH
      if tH is 0 then
         qsLog "Could not start the download:" && btLastError()
         exit qsGetFile
      end if
      put empty into field "qsRecvCode"
      qsLog "Downloading the locked file" && quote & tName & quote & " to" && qsSaveFolder() & " - it unlocks automatically when complete."
   else
      -- accept a full magnet link, or a bare 40-hex (v1) / 64-hex (v2) info-hash
      if tCode begins with "magnet:" then
         put tCode into tMag
      else
         put toLower(tCode) into tCode
         if the number of chars of tCode is not 40 and the number of chars of tCode is not 64 then
            qsLog "That does not look like a share code (it should be 40 characters)."
            exit qsGetFile
         end if
         put "magnet:?xt=urn:btih:" & tCode & "&tr=" & qsTracker() into tMag
      end if
      put btAddMagnet(sSession, tMag, qsSaveFolder()) into tH
      if tH is 0 then
         qsLog "Could not start the download:" && btLastError()
         exit qsGetFile
      end if
      put empty into field "qsRecvCode"
      qsLog "Downloading to" && qsSaveFolder() & ". Watch the Transfers list - your friend must be online."
   end if
end qsGetFile

-- ---- transfers view + events -------------------------------------------------
command qsRefreshXfers
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tLineNum, tD, tNodes, tStat
   local tIH, tDisp, tDir, tK, tE
   if sSession is 0 or sSession is empty then
      exit qsRefreshXfers
   end if
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put 0 into tLineNum
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      -- show the REAL name for an encrypted transfer (the swarm sees the .enc
      -- name); mark it "(locked)" so it is obvious it is end-to-end encrypted.
      put toLower(tS["infoHashV1"]) into tIH
      put tS["name"] into tDisp
      put qsRole(tS["state"]) into tDir
      if tIH is not empty and sXferName[tIH] is not empty then
         put sXferName[tIH] into tDisp
         put tDir && "(locked)" into tDir
      end if
      put qsTrunc(tDisp, 26) & tab & tDir & tab & qsBar(tPct) & return after tRows
      add tS["downloadRate"] to tDown
      add tS["uploadRate"] to tUp
   end repeat
   -- append anonymous (Tor) transfers; they have NO torrent handle, so the torrent
   -- loop above never sees them. Same "name TAB dir TAB bar" row format.
   repeat for each key tK in sOnionXfers
      put sOnionXfers[tK] into tE
      put tE["dir"] & " via Tor" into tDir
      if tE["enc"] is "true" then
         put tDir && "(locked)" into tDir
      end if
      if tE["state"] is "connecting" or tE["total"] is 0 then
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & "connecting..." & return after tRows
      else if tE["state"] is "done" then
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & "done" & return after tRows
      else if tE["state"] is "error" then
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & "stopped" & return after tRows
      else
         put (the round of (tE["got"] / tE["total"] * 1000) / 10) into tPct
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & qsBar(tPct) & return after tRows
      end if
      add 1 to tLineNum
   end repeat
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   if tLineNum is 0 then
      put "   Nothing yet. Drag a file to share, or paste a code to download." into tRows
   end if
   lock screen
   set the text of field "qsXfers" to tRows
   unlock screen
   put btDhtState(sSession) into tD
   put tD["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("Connected - DHT: " & tNodes & " nodes") into tStat
   else
      put "Connecting to the network..." into tStat
   end if
   put tStat & "        sending " & (qsBytes(tUp) & "/s") & "    receiving " & (qsBytes(tDown) & "/s") into field "qsStatus"
end qsRefreshXfers

command qsHandleEvent pEvent
   switch pEvent["name"]
      case "torrentAdded"
         qsRefreshXfers
         break
      case "metadataReceived"
         qsLog "Got the details for" && pEvent["torrentName"] & " - downloading the file now..."
         break
      case "torrentFinished"
         -- a locked download decrypts itself here (a no-op for a plain download)
         qsMaybeDecryptFinished pEvent["torrent"]
         qsLog "Download complete. Saved in" && qsSaveFolder() & "."
         qsRefreshXfers
         break
      default
         break
   end switch
end qsHandleEvent

-- ---- small helpers -----------------------------------------------------------
function qsTracker
   return "udp://tracker.opentrackr.org:1337/announce"
end qsTracker

function qsSaveFolder
   local tBase, tErr
   put specialFolderPath("documents") into tBase
   if tBase is empty then
      put specialFolderPath("desktop") into tBase
   end if
   put tBase & "/TorrentXT Quick Share" into tBase
   if there is no folder tBase then
      try
         create folder tBase
      catch tErr
      end try
   end if
   return tBase
end qsSaveFolder

-- map a libtorrent state to a plain-language direction for the demo
function qsRole pState
   switch pState
      case 3
         return "receiving"
      case 4
      case 5
         return "sending"
      case 1
      case 2
      case 7
         return "preparing"
      default
         return "waiting"
   end switch
end qsRole

-- a 10-segment ASCII progress bar, e.g. [####------] 42%  (monospaced field)
function qsBar pPct
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
end qsBar

function qsBytes pBytes
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
end qsBytes

function qsTrunc pText, pLen
   if the number of chars of pText <= pLen then
      return pText
   end if
   return (char 1 to (pLen - 1) of pText) & "..."
end qsTrunc

function qsTrim pText
   local tT
   put pText into tT
   repeat while tT begins with space or tT begins with tab or tT begins with return
      delete char 1 of tT
   end repeat
   repeat while tT ends with space or tT ends with tab or tT ends with return
      delete the last char of tT
   end repeat
   return tT
end qsTrim

-- ---- optional end-to-end encryption (cryptoXT / libsodium) -------------------
-- Is cryptoXT installed and working? A real secretbox round-trip with a random
-- key (fast - no Argon2id), wrapped in a try so a missing org.openxtalk.library.
-- sodium is a clean "no". Probed once at start so the passphrase fields can fail
-- closed rather than erroring.
function qsCanEncrypt
   local tKey, tBox, tOut, tErr
   try
      put sxRandomBytes(32) into tKey
      put sxSecretBox(textEncode("probe", "ASCII"), tKey) into tBox
      put sxSecretBoxOpen(tBox, tKey) into tOut
   catch tErr
      return false
   end try
   return (textDecode(tOut, "ASCII") is "probe")
end qsCanEncrypt

-- A small helper: base64 with the line breaks stripped so a code stays one line.
function qsB64 pData
   local tB64
   put base64Encode(pData) into tB64
   replace numToChar(13) with "" in tB64
   replace numToChar(10) with "" in tB64
   return tB64
end qsB64

-- Build the locked share code: a prefix, the .enc info-hash, the original filename,
-- the Argon2id salt, and a passphrase verifier (all base64'd). The colon is a safe
-- delimiter because neither a hex hash nor base64 ever contains one.
function qsMakeCode pHash, pName, pSalt, pVerifier
   return kCodePrefix & pHash & ":" & qsB64(textEncode(pName, "UTF-8")) & ":" & \
      qsB64(pSalt) & ":" & qsB64(pVerifier)
end qsMakeCode

-- Does pKey open the passphrase verifier carried in a share code? Used to check
-- the passphrase BEFORE downloading, so a wrong one never fetches a .enc.
function qsKeyOpensVerifier pKey, pB64Verify
   local tOut, tErr
   try
      put sxSecretBoxOpen(base64Decode(pB64Verify), pKey) into tOut
   catch tErr
      return false
   end try
   return (textDecode(tOut, "ASCII") is kQsVerify)
end qsKeyOpensVerifier

-- a unique temp path with a NEUTRAL name (the torrent name leaks nothing)
function qsTempEncPath
   local tBase
   put specialFolderPath("temporary") into tBase
   if tBase is empty then
      put specialFolderPath("documents") into tBase
   end if
   return tBase & "/btxshare-" & the milliseconds & "-" & random(999999) & ".enc"
end qsTempEncPath

-- Encrypt/decrypt a file with the 32-byte key pKey via cryptoXT (libsodium
-- secretstream, streamed entirely C-side so the bytes never enter a Data, with
-- per-chunk authentication). Returns "" on success, else an error string.
function qsEncryptFile pSrc, pDst, pKey
   local tErr
   try
      if there is a file pDst then
         delete file pDst
      end if
      sxEncryptFile pSrc, pDst, pKey
   catch tErr
      return tErr
   end try
   return ""
end qsEncryptFile

function qsDecryptFile pSrc, pDst, pKey
   local tErr
   try
      sxDecryptFile pSrc, pDst, pKey
   catch tErr
      return tErr
   end try
   return ""
end qsDecryptFile

-- When a LOCKED download finishes, decrypt the .enc to its real name beside it.
-- A no-op for a plain download (nothing stashed against its info-hash). The .enc
-- is left in place so the receiver keeps seeding it to the swarm.
command qsMaybeDecryptFinished pTorrent
   local tS, tHash, tSave, tEncName, tEncPath, tOut, tErr
   put btTorrentStatus(pTorrent) into tS
   put toLower(tS["infoHashV1"]) into tHash
   if tHash is empty or sPendingKey[tHash] is empty then
      exit qsMaybeDecryptFinished
   end if
   put tS["savePath"] into tSave
   put tS["name"] into tEncName            -- the neutral .enc filename
   put tSave & "/" & tEncName into tEncPath
   put tSave & "/" & sPendingName[tHash] into tOut
   qsLog "Unlocking" && quote & sPendingName[tHash] & quote & "- the app may pause briefly on a large file..."
   put qsDecryptFile(tEncPath, tOut, sPendingKey[tHash]) into tErr
   -- drop the torrent and DELETE the .enc so no encrypted blob is left in the
   -- user's folder. btRemoveTorrent (deleteFiles = true) removes the .enc; the
   -- decrypted real file is not part of the torrent, so it stays.
   btRemoveTorrent sSession, pTorrent, true
   if tErr is not empty then
      qsLog "Could not unlock" && quote & sPendingName[tHash] & quote & ":" && tErr & " (the encrypted copy was removed)."
   else
      qsLog "Unlocked to" && quote & sPendingName[tHash] & quote & "in" && tSave & ". (Encrypted copy cleaned up.)"
   end if
   put empty into sPendingKey[tHash]
   put empty into sPendingName[tHash]
end qsMaybeDecryptFinished

-- ==== OnionXT: optional Tor anonymity (Model C) ==============================
-- The whole block below is inert unless sHasOnion. It NEVER touches libtorrent:
-- an anonymous transfer creates no torrent and makes no DHT call (the mutual-
-- exclusion invariant). Every ox* handler is OnionXT's published ABI; this is
-- verified statically (tools/check-livecodescript.py) and NEEDS an on-engine OXT
-- pass with a running Tor daemon before any runtime claim. See
-- docs/ONIONXT-INTEGRATION-PLAN.md and its VERIFY register (section 12.3).

-- Is OnionXT installed AND cryptoXT working? OnionXT depends on cryptoXT, so both
-- must be present for any anonymous transfer (even a plaintext one). A guarded
-- oxVersion() probe, mirroring qsCanEncrypt. VERIFY: oxVersion resolves only when
-- the OnionXT extension is loaded.
function qsHasOnion
   local tV, tErr
   if not sCanEncrypt then
      return false
   end if
   try
      put oxVersion() into tV
   catch tErr
      return false
   end try
   return (tV is not empty)
end qsHasOnion

-- Live, authoritative Tor readiness, re-read at the moment of use (never trust the
-- cached sTorReady for a go/no-go). oxIsReady() is true only at 100% bootstrap.
function qsOnionReadyNow
   if not sHasOnion then
      return false
   end if
   return oxIsReady()
end qsOnionReadyNow

-- Bring up the OnionXT control connection at the tail of qsStart (only when
-- sHasOnion). Non-blocking: bootstrap takes tens of seconds and is surfaced by the
-- status callback + the 1 s dash pill. Registers our callbacks and dispatch owner
-- first, then connects on the stock tor control port (9051); the status callback
-- retries the Tor Browser port pair (9151) once on an auth failure.
command qsOnionStart
   if not sHasOnion then
      exit qsOnionStart
   end if
   put "false" into sOnionTriedTB
   oxSetCallbackOwner the long id of me
   oxSetStatusCallback "qsOnionStatus"
   oxSetPeerCallback "qsOnionPeer"
   oxSetControlPort kTorControlPort
   oxSetSocksPort kTorSocksPort
   oxConnectControl
   if the result is not empty then
      qsOnionTryTB
   end if
   qsOnionPill
end qsOnionStart

-- Retry the control connection on the Tor Browser port pair, exactly once.
command qsOnionTryTB
   if sOnionTriedTB is "true" then
      exit qsOnionTryTB
   end if
   put "true" into sOnionTriedTB
   oxSetControlPort kTorControlPortTB
   oxSetSocksPort kTorSocksPortTB
   oxConnectControl
end qsOnionTryTB

-- OnionXT status callback (dispatched with pKind, pInfo). Coalesced bootstrap and
-- event updates on the main thread. Keep it short - it runs on the shared thread.
command qsOnionStatus pKind, pInfo
   if pKind is "control" then
      if pInfo is "authenticated" then
         qsLog "Tor control connected - bootstrapping (this can take a minute)..."
      else if (pInfo is "authfailed" or pInfo is "error") then
         qsOnionTryTB
      end if
   else if pKind is "serviceReady" then
      qsOnionServicePublished pInfo
   end if
   put qsOnionReadyNow() into sTorReady
   qsOnionPill
end qsOnionStatus

-- Our onion service descriptor uploaded: build and reveal the share code now (an
-- address handed out earlier would just fail to resolve). One active share, so the
-- serviceReady event is unambiguous. VERIFY: pInfo semantics for serviceReady.
command qsOnionServicePublished pInfo
   local tOnion, tCode
   if sActiveShare["service"] is empty then
      exit qsOnionServicePublished
   end if
   if sActiveShare["revealed"] is "true" then
      exit qsOnionServicePublished
   end if
   put oxServiceAddress(sActiveShare["service"]) into tOnion
   if tOnion is empty then
      exit qsOnionServicePublished
   end if
   put qsMakeTorCode(tOnion, sActiveShare["name"], sActiveShare["salt"], sActiveShare["verify"]) into tCode
   put tCode into sShareCode
   put tOnion into sActiveShare["onion"]
   set the text of field "qsCode" to tCode
   put "true" into sActiveShare["revealed"]
   if sActiveShare["enc"] is kFlagEnc then
      set the text of field "qsSharing" to ("Sharing " & quote & sActiveShare["name"] & quote & " ENCRYPTED over Tor - both IPs hidden. Send the code AND the passphrase; keep this window open. An interrupted transfer restarts from the beginning.")
      qsLog "Private Tor address published. Click Copy and send the code to your friend."
   else if sActiveShare["web"] is "true" then
      -- plaintext + web download on: also hand out the browser URL (Tor Browser)
      set the text of field "qsWebLink" to ("http://" & tOnion & "/")
      set the text of field "qsSharing" to ("Sharing " & quote & sActiveShare["name"] & quote & " over Tor (not encrypted) - both IPs hidden, sender not verified. App users: the code above. Browser: the Web link on the right.")
      qsLog "Tor address published. App code is above; browser download link (Tor Browser): http://" & tOnion & "/"
   else
      -- plaintext, app-only: a browser hitting the onion gets a 'web download off' page
      set the text of field "qsWebLink" to ""
      set the text of field "qsSharing" to ("Sharing " & quote & sActiveShare["name"] & quote & " over Tor (not encrypted) - both IPs hidden, but the sender is not verified. Send the code above; keep this window open. (Tick 'Serve as web download' to also allow a Tor Browser link.)")
      qsLog "Private Tor address published. Click Copy and send the code to your friend."
   end if
end qsOnionServicePublished

-- Repaint the live pill AND drive the toggle's disabled/hilite state. A mode the
-- environment cannot honor never stays silently armed (sTorSend forced off).
command qsOnionPill
   local tState
   if there is no field "qsTorPill" then
      exit qsOnionPill
   end if
   if not sHasOnion then
      if sCanEncrypt then
         put "Tor: no extension" into tState
      else
         put "Tor: needs cryptoXT" into tState
      end if
      set the disabled of button "qsTorToggle" to true
   else if not oxIsControlAuthenticated() then
      put "Tor: no daemon (start Tor on 127.0.0.1:9051 or 9151)" into tState
      set the disabled of button "qsTorToggle" to true
   else if not oxIsReady() then
      put ("Tor: connecting " & oxBootstrapProgress() & "%") into tState
      set the disabled of button "qsTorToggle" to false
   else
      put "Tor: ready" into tState
      set the disabled of button "qsTorToggle" to false
   end if
   if (the disabled of button "qsTorToggle") and (sTorSend is "true") then
      put "false" into sTorSend
      set the hilite of button "qsTorToggle" to false
   end if
   set the text of field "qsTorPill" to tState
end qsOnionPill

-- Flip the send-over-Tor toggle (managed two-state; autoHilite is off).
command qsToggleTor
   if the disabled of button "qsTorToggle" then
      exit qsToggleTor
   end if
   if sTorSend is "true" then
      put "false" into sTorSend
      set the hilite of button "qsTorToggle" to false
   else
      put "true" into sTorSend
      set the hilite of button "qsTorToggle" to true
   end if
end qsToggleTor

-- Tear down the onion subsystem on close, BEFORE btStopSession. All idempotent.
command qsOnionStop
   local tK, tErr
   if not sHasOnion then
      exit qsOnionStop
   end if
   repeat for each key tK in sOnionXfers
      try
         oxCloseStream tK
      catch tErr
      end try
   end repeat
   if sActiveShare["service"] is not empty then
      try
         oxRemoveService sActiveShare["service"]
      catch tErr
      end try
   end if
   try
      oxDisconnectControl
   catch tErr
   end try
   repeat for each key tK in sRxTmp
      try
         if sRxTmp[tK] is not empty and there is a file sRxTmp[tK] then
            delete file sRxTmp[tK]
         end if
      catch tErr
      end try
   end repeat
end qsOnionStop

-- Reduce an attacker-chosen name (share code OR stream header) to a safe filename
-- LEAF: basename only, no drive/colon, no leading dots, no separators or controls
-- surviving. Empty result becomes "shared-file". Applied before opening any temp
-- and before the final move - closes path traversal / arbitrary write.
function qsSafeLeaf pName
   local tN, tCh, tOut
   put pName into tN
   replace "\" with "/" in tN
   set the itemDelimiter to "/"
   put the last item of tN into tN
   if tN contains ":" then
      set the itemDelimiter to ":"
      put the last item of tN into tN
   end if
   repeat while tN begins with "."
      delete char 1 of tN
   end repeat
   put "" into tOut
   repeat for each char tCh in tN
      if charToNum(tCh) >= 32 and tCh is not "/" and tCh is not "\" then
         put tCh after tOut
      end if
   end repeat
   put tOut into tN
   if tN is empty or tN is ".." or tN is "." then
      return "shared-file"
   end if
   return tN
end qsSafeLeaf

-- Build a BTXTOR1 anonymous share code: prefix, onion, then base64 name/salt/verify
-- (empty salt/verify for a plaintext share). Colons are safe delimiters: neither a
-- v3 .onion nor base64 ever contains ':'.
function qsMakeTorCode pOnion, pName, pSalt, pVerifier
   return kTorCodePrefix & pOnion & ":" & qsB64(textEncode(qsSafeLeaf(pName), "UTF-8")) & ":" & \
      qsB64(pSalt) & ":" & qsB64(pVerifier)
end qsMakeTorCode

-- Byte size of a file WITHOUT loading it whole into memory. OpenXTalk does not
-- support 'the detailedFiles', so we open the file and count in bounded 4 MiB
-- chunks: O(file size) I/O but O(1) memory. Used for the header totalLen and the
-- large-file warning (both small-file cases in practice). Empty if unreadable.
function qsFileSize pPath
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
end qsFileSize

-- A pseudo-random high loopback port for OnionXT to bind its internal listener to.
-- A collision surfaces as an oxCreateService error string, and the caller reports it.
function qsPickPort
   return (20000 + random(40000))
end qsPickPort

-- Build the stream header: magic(4) ver(1) flags(1) nameLen(u16 BE) name(UTF-8)
-- totalLen(u64 BE as hi:u32 then lo:u32). Binary discipline throughout.
function qsOnionHeader pName, pEnc, pTotal
   local tNameB, tFlags, tHi, tLo, tOut
   put textEncode(qsSafeLeaf(pName), "UTF-8") into tNameB
   put 0 into tFlags
   if pEnc is kFlagEnc then
      put kFlagEnc into tFlags
   end if
   put (pTotal div 4294967296) into tHi
   put (pTotal mod 4294967296) into tLo
   put kOnionMagic into tOut
   put numToByte(kOnionVer) after tOut
   put numToByte(tFlags) after tOut
   put binaryEncode("n", the number of bytes in tNameB) after tOut
   put tNameB after tOut
   put binaryEncode("NN", tHi, tLo) after tOut
   return tOut
end qsOnionHeader

-- Decode a big-endian unsigned u16 / u32 from raw bytes (matches the golden test).
function qsBEu16 pBytes
   return (byteToNum(byte 1 of pBytes) * 256 + byteToNum(byte 2 of pBytes))
end qsBEu16

function qsBEu32 pBytes
   local tA, tB, tC, tD
   put byteToNum(byte 1 of pBytes) into tA
   put byteToNum(byte 2 of pBytes) into tB
   put byteToNum(byte 3 of pBytes) into tC
   put byteToNum(byte 4 of pBytes) into tD
   return (((tA * 256 + tB) * 256 + tC) * 256 + tD)
end qsBEu32

-- SEND entry: turn a dropped file into a fresh, unlinkable onion service and (once
-- the descriptor uploads) reveal a BTXTOR1 code. Reuses the existing cryptoXT path
-- when a passphrase is set. NO torrent is created.
command qsStartOnionShare pPath, pName, pPass
   local tTotal, tSalt, tKey, tVerifier, tEncPath, tEncFlag, tStreamFile
   local tSvc, tPort, tSafe, tErr
   put qsFileSize(pPath) into tTotal
   if tTotal is empty or tTotal < 0 then
      qsLog "Could not read that file's size."
      exit qsStartOnionShare
   end if
   if tTotal > kAnonSizeWarn then
      answer ("This file is large for an anonymous Tor transfer and will be slow." & return & \
         "For big media, share it on the public swarm instead (that reveals your IP).") with "Cancel" or "Send over Tor anyway"
      if it is not "Send over Tor anyway" then
         exit qsStartOnionShare
      end if
   end if
   put qsSafeLeaf(pName) into tSafe
   put "" into tSalt
   put "" into tVerifier
   put 0 into tEncFlag
   put pPath into tStreamFile
   if pPass is not empty and sCanEncrypt then
      put sxRandomBytes(16) into tSalt
      put sxPwHash(textEncode(pPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tKey
      put sxSecretBox(textEncode(kQsVerify, "ASCII"), tKey) into tVerifier
      put qsTempEncPath() into tEncPath
      put tEncPath into sTempEnc[tEncPath]
      qsLog "Encrypting " & quote & tSafe & quote & " before the private transfer - the app may pause briefly on a large file..."
      put qsEncryptFile(pPath, tEncPath, tKey) into tErr
      if tErr is not empty then
         qsLog "Could not encrypt " & quote & tSafe & quote & ":" && tErr
         try
            if there is a file tEncPath then
               delete file tEncPath
            end if
         catch tErr
         end try
         exit qsStartOnionShare
      end if
      put tEncPath into tStreamFile
      put kFlagEnc into tEncFlag
   else if pPass is not empty then
      qsLog "cryptoXT is not installed - sending over Tor WITHOUT encryption (your IP is still hidden, but the sender is not verified)."
   end if
   -- one active anon share at a time: tear down any previous service + temp
   if sActiveShare["service"] is not empty then
      -- if a receiver is mid-transfer, abort it FIRST so the file handle is closed
      -- before we delete the .enc it is reading (defined cleanup ordering)
      if sActiveShare["stream"] is not empty then
         qsOnionServeAbort sActiveShare["stream"]
      end if
      try
         oxRemoveService sActiveShare["service"]
      catch tErr
      end try
      if sActiveShare["encTmp"] is not empty then
         try
            if there is a file sActiveShare["encTmp"] then
               delete file sActiveShare["encTmp"]
            end if
         catch tErr
         end try
      end if
   end if
   put empty into sActiveShare
   put qsPickPort() into tPort
   oxCreateServiceFromSeed sxRandomBytes(32), kOnionVPort, tPort
   put the result into tSvc
   if tSvc is not an integer then
      qsLog "Could not publish a Tor address:" && tSvc
      if tEncFlag is kFlagEnc then
         try
            if there is a file tEncPath then
               delete file tEncPath
            end if
         catch tErr
         end try
      end if
      exit qsStartOnionShare
   end if
   put tStreamFile into sActiveShare["path"]
   put tSafe into sActiveShare["name"]
   put tEncFlag into sActiveShare["enc"]
   put tSalt into sActiveShare["salt"]
   put tVerifier into sActiveShare["verify"]
   put tPort into sActiveShare["port"]
   put tSvc into sActiveShare["service"]
   put sWebServe into sActiveShare["web"]
   put "false" into sActiveShare["revealed"]
   put "false" into sActiveShare["busy"]
   if tEncFlag is kFlagEnc then
      put tEncPath into sActiveShare["encTmp"]
      put qsFileSize(tEncPath) into sActiveShare["total"]
   else
      put tTotal into sActiveShare["total"]
   end if
   set the text of field "qsCode" to ""
   set the text of field "qsWebLink" to ""
   set the text of field "qsSharing" to ("Publishing a private Tor address for " & quote & tSafe & quote & " - this can take up to a minute...")
   qsLog "Publishing a private Tor service for " & quote & tSafe & quote & "..."
   -- arm the publish watchdog against THIS service handle, so a later share's
   -- watchdog (a rapid second drop) never tears down this one by mistake
   send ("qsOnionPublishWatchdog " & tSvc) to me in kOnionPublishTimeout milliseconds
end qsStartOnionShare

-- If the descriptor never uploads in time, tear the half-built service down.
command qsOnionPublishWatchdog pService
   local tErr
   if sActiveShare["service"] is empty then
      exit qsOnionPublishWatchdog
   end if
   if sActiveShare["service"] is not pService then
      exit qsOnionPublishWatchdog   -- superseded by a newer share; clean no-op
   end if
   if sActiveShare["revealed"] is "true" then
      exit qsOnionPublishWatchdog
   end if
   try
      oxRemoveService sActiveShare["service"]
   catch tErr
   end try
   if sActiveShare["encTmp"] is not empty then
      try
         if there is a file sActiveShare["encTmp"] then
            delete file sActiveShare["encTmp"]
         end if
      catch tErr
      end try
   end if
   put empty into sActiveShare
   set the text of field "qsSharing" to ""
   qsLog "Tor could not publish the private address in time. Make sure the pill says 'ready', then try again."
end qsOnionPublishWatchdog

-- A receiver dialed our service: OnionXT hands us a fresh inbound stream. Register
-- its stream callback and wait for the 4-byte magic request before we push. One
-- active receiver at a time for QuickShare (a sequential retry reuses the code).
command qsOnionPeer pStream, pService, pPeerAddr
   if sActiveShare["service"] is empty then
      oxCloseStream pStream
      exit qsOnionPeer
   end if
   if sActiveShare["busy"] is "true" then
      oxCloseStream pStream
      exit qsOnionPeer
   end if
   put "true" into sActiveShare["busy"]
   put pStream into sActiveShare["stream"]
   -- do not seed a transfers row yet: only a real file transfer (the BTXO app
   -- protocol, or an HTTP GET /download) gets a row, so a browser's index or
   -- favicon hit leaves no noise in the Transfers list.
   put "" into sTxReq[pStream]
   put "" into sTxMode[pStream]
   put "" into sTxRaw[pStream]
   put the milliseconds into sTxDeadline[pStream]
   oxSetStreamCallback pStream, "qsOnionServeStream"
   send ("qsOnionSendWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
end qsOnionPeer

-- Sender's per-stream handler. Auto-detects the caller from the first byte: the
-- app sends the "BTXO" magic (framed protocol); a browser sends "GET "/"HEAD "
-- (HTTP). Anything else is junk from a local process and is dropped.
command qsOnionServeStream pStream, pEvent, pData
   local tFirst, tCrlf2
   if pEvent is "data" then
      if sActiveShare["stream"] is not pStream then
         exit qsOnionServeStream
      end if
      if sOnionXfers[pStream]["state"] is "active" then
         exit qsOnionServeStream   -- a transfer is already running; ignore extra inbound
      end if
      put pData after sTxReq[pStream]
      put the milliseconds into sTxDeadline[pStream]
      if the number of bytes in sTxReq[pStream] < 1 then
         exit qsOnionServeStream
      end if
      if sTxMode[pStream] is empty then
         put byte 1 of sTxReq[pStream] into tFirst
         if tFirst is "G" or tFirst is "H" then
            put "http" into sTxMode[pStream]
         else if tFirst is "B" then
            if the number of bytes in sTxReq[pStream] < 4 then
               exit qsOnionServeStream
            end if
            if (byte 1 to 4 of sTxReq[pStream]) is not kOnionMagic then
               oxCloseStream pStream
               qsOnionServeAbort pStream
               exit qsOnionServeStream
            end if
            put "btxo" into sTxMode[pStream]
         else
            oxCloseStream pStream
            qsOnionServeAbort pStream
            exit qsOnionServeStream
         end if
      end if
      if sTxMode[pStream] is "btxo" then
         qsOnionBeginSend pStream
      else
         -- HTTP: serve once the whole request header block (CRLF CRLF) has arrived
         put (numToByte(13) & numToByte(10) & numToByte(13) & numToByte(10)) into tCrlf2
         if sTxReq[pStream] contains tCrlf2 then
            qsOnionServeHttp pStream
         else if the number of bytes in sTxReq[pStream] > 16384 then
            oxCloseStream pStream
            qsOnionServeAbort pStream
         end if
      end if
   else if pEvent is "closed" or pEvent is "error" then
      if sOnionXfers[pStream]["state"] is "active" then
         qsOnionServeAbort pStream   -- peer dropped mid-transfer
      end if
   end if
end qsOnionServeStream

-- Open the file, send the header, and arm the frame pump.
command qsOnionBeginSend pStream
   local tHeader
   put sActiveShare["name"] into sOnionXfers[pStream]["name"]
   put "sending" into sOnionXfers[pStream]["dir"]
   if sActiveShare["enc"] is kFlagEnc then
      put "true" into sOnionXfers[pStream]["enc"]
   else
      put "" into sOnionXfers[pStream]["enc"]
   end if
   put sActiveShare["total"] into sOnionXfers[pStream]["total"]
   put 0 into sOnionXfers[pStream]["got"]
   put "active" into sOnionXfers[pStream]["state"]
   open file sActiveShare["path"] for binary read
   if the result is not empty then
      qsLog "Could not open the file to send:" && the result
      qsOnionServeAbort pStream
      exit qsOnionBeginSend
   end if
   put sActiveShare["path"] into sTxPath[pStream]
   put 0 into sTxOffset[pStream]
   put sActiveShare["total"] into sTxTotal[pStream]
   put the milliseconds into sTxDeadline[pStream]
   put qsOnionHeader(sActiveShare["name"], sActiveShare["enc"], sActiveShare["total"]) into tHeader
   oxWrite pStream, tHeader
   if the result is not empty then
      qsLog "Private send failed (header):" && the result
      qsOnionServeAbort pStream
      exit qsOnionBeginSend
   end if
   send ("qsOnionSendPump " & pStream) to me in kOnionPumpTick milliseconds
end qsOnionBeginSend

-- One frame per tick (never a tight loop). Sequential reads advance the file.
command qsOnionSendPump pStream
   local tSlice
   if sTxPath[pStream] is empty then
      exit qsOnionSendPump
   end if
   -- NOTE: no writability gate here. An earlier oxStreamState-based backpressure
   -- gate could misread a live stream (a "connected" state contains "connect") and
   -- STALL forever, so the send watchdog then falsely closed the connection and the
   -- file body never arrived (the browser saw "connection lost"). We pace with the
   -- kOnionPumpTick timer + oxWrite's error return instead; a real backpressure gate
   -- needs the on-engine oxStreamState VERIFY (what does an open stream report?).
   read from file sTxPath[pStream] for kOnionChunk
   put it into tSlice
   if tSlice is empty then
      -- BTXO ends with a zero-length terminator; HTTP relies on Content-Length
      if sTxRaw[pStream] is not "true" then
         oxWrite pStream, binaryEncode("N", 0)
      end if
      close file sTxPath[pStream]
      put "done" into sOnionXfers[pStream]["state"]
      qsLog "Sent " & quote & sActiveShare["name"] & quote & " over Tor."
      oxCloseStream pStream
      qsOnionServeCleanup pStream
      exit qsOnionSendPump
   end if
   if sTxRaw[pStream] is "true" then
      oxWrite pStream, tSlice
   else
      oxWrite pStream, (binaryEncode("N", the number of bytes in tSlice) & tSlice)
   end if
   if the result is not empty then
      qsLog "Private send failed:" && the result
      qsOnionServeAbort pStream
      exit qsOnionSendPump
   end if
   add (the number of bytes in tSlice) to sTxOffset[pStream]
   put sTxOffset[pStream] into sOnionXfers[pStream]["got"]
   put the milliseconds into sTxDeadline[pStream]
   send ("qsOnionSendPump " & pStream) to me in kOnionPumpTick milliseconds
end qsOnionSendPump

-- Clear per-stream send state and free the share for the next sequential receiver.
command qsOnionServeCleanup pStream
   local tErr
   try
      close file sTxPath[pStream]
   catch tErr
   end try
   put empty into sTxPath[pStream]
   put empty into sTxOffset[pStream]
   put empty into sTxTotal[pStream]
   put empty into sTxDeadline[pStream]
   put empty into sTxReq[pStream]
   put empty into sTxMode[pStream]
   put empty into sTxRaw[pStream]
   if sActiveShare["stream"] is pStream then
      put "false" into sActiveShare["busy"]
      put empty into sActiveShare["stream"]
   end if
end qsOnionServeCleanup

command qsOnionServeAbort pStream
   if sOnionXfers[pStream] is not empty then
      put "error" into sOnionXfers[pStream]["state"]
   end if
   oxCloseStream pStream
   qsOnionServeCleanup pStream
end qsOnionServeAbort

-- Idle watchdog for a serve stream, armed at accept. Keyed off sActiveShare's
-- current stream (which cleanup clears) so it works before a transfer row exists
-- and no-ops once the stream is done/superseded.
command qsOnionSendWatchdog pStream
   if sActiveShare["stream"] is not pStream then
      exit qsOnionSendWatchdog
   end if
   if (the milliseconds - sTxDeadline[pStream]) > kOnionSendTimeout then
      qsLog "The private transfer stalled - closing it."
      qsOnionServeAbort pStream
      exit qsOnionSendWatchdog
   end if
   send ("qsOnionSendWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
end qsOnionSendWatchdog

-- ---- serve a browser over HTTP (plaintext shares only) ----------------------
-- A plaintext Tor share ALSO answers a plain browser: open http://<onion>/ in Tor
-- Browser and download it, no app needed. IP-anonymous (Tor), but NOT encrypted
-- and the sender is not verified - only plaintext shares are ever served this way
-- (a browser cannot decrypt a cryptoXT .enc). Routes: "/" = an index page with a
-- Download link; "/download" = the file bytes; anything else (favicon, ...) = 404.
command qsOnionServeHttp pStream
   local tReq, tMethod, tPath, tHead, tFn, tCrlf
   put (numToChar(13) & numToChar(10)) into tCrlf
   put textDecode(sTxReq[pStream], "UTF-8") into tReq
   put word 1 of tReq into tMethod
   put word 2 of tReq into tPath
   if sActiveShare["enc"] is kFlagEnc then
      qsOnionHttpText pStream, "200 OK", "text/html; charset=utf-8", qsHtmlEncrypted()
      exit qsOnionServeHttp
   end if
   if sActiveShare["web"] is not "true" then
      qsOnionHttpText pStream, "403 Forbidden", "text/html; charset=utf-8", qsHtmlDisabled()
      exit qsOnionServeHttp
   end if
   if tPath is "/download" then
      put qsSafeLeaf(sActiveShare["name"]) into tFn
      replace quote with "" in tFn
      replace ";" with "" in tFn
      put ("HTTP/1.1 200 OK" & tCrlf & "Content-Type: application/octet-stream" & tCrlf & \
         "Content-Length: " & sActiveShare["total"] & tCrlf & \
         "Content-Disposition: attachment; filename=" & quote & tFn & quote & tCrlf & \
         "Connection: close" & tCrlf & tCrlf) into tHead
      -- seed a real transfer row (only /download counts as a transfer)
      put tFn into sOnionXfers[pStream]["name"]
      put "sending" into sOnionXfers[pStream]["dir"]
      put "" into sOnionXfers[pStream]["enc"]
      put sActiveShare["total"] into sOnionXfers[pStream]["total"]
      put 0 into sOnionXfers[pStream]["got"]
      put "active" into sOnionXfers[pStream]["state"]
      oxWrite pStream, textEncode(tHead, "UTF-8")
      if the result is not empty then
         qsOnionServeAbort pStream
         exit qsOnionServeHttp
      end if
      if tMethod is "HEAD" then
         put "done" into sOnionXfers[pStream]["state"]
         oxCloseStream pStream
         qsOnionServeCleanup pStream
         exit qsOnionServeHttp
      end if
      open file sActiveShare["path"] for binary read
      if the result is not empty then
         qsOnionServeAbort pStream
         exit qsOnionServeHttp
      end if
      put sActiveShare["path"] into sTxPath[pStream]
      put "true" into sTxRaw[pStream]
      put the milliseconds into sTxDeadline[pStream]
      send ("qsOnionSendPump " & pStream) to me in kOnionPumpTick milliseconds
      exit qsOnionServeHttp
   end if
   if tPath is "/" then
      qsOnionHttpText pStream, "200 OK", "text/html; charset=utf-8", qsHtmlIndex()
      exit qsOnionServeHttp
   end if
   qsOnionHttpText pStream, "404 Not Found", "text/plain; charset=utf-8", "Not found."
end qsOnionServeHttp

-- Send a small text/html HTTP response and close (used for the index, the
-- encrypted notice, and 404s - never for the file body).
command qsOnionHttpText pStream, pStatus, pType, pBody
   local tData, tHead, tCrlf
   put (numToChar(13) & numToChar(10)) into tCrlf
   put textEncode(pBody, "UTF-8") into tData
   put ("HTTP/1.1 " & pStatus & tCrlf & "Content-Type: " & pType & tCrlf & \
      "Content-Length: " & (the number of bytes in tData) & tCrlf & "Connection: close" & tCrlf & tCrlf) into tHead
   oxWrite pStream, (textEncode(tHead, "UTF-8") & tData)
   oxCloseStream pStream
   qsOnionServeCleanup pStream
end qsOnionHttpText

-- The download landing page (single-quoted HTML attributes so the LiveCode string
-- literals never contain a double quote). Shows the name, size, a Download button,
-- and the honest "anonymous but not encrypted" notice.
function qsHtmlIndex
   local tName, tSize
   put qsSafeLeaf(sActiveShare["name"]) into tName
   replace "&" with "&amp;" in tName
   replace "<" with "&lt;" in tName
   replace ">" with "&gt;" in tName
   put qsBytes(sActiveShare["total"]) into tSize
   return ("<!doctype html><html><head><meta charset='utf-8'>" & \
      "<meta name='viewport' content='width=device-width,initial-scale=1'>" & \
      "<title>Download</title></head>" & \
      "<body style='font-family:system-ui,sans-serif;max-width:34em;margin:3em auto;padding:0 1em'>" & \
      "<h2>" & tName & "</h2><p>" & tSize & " - shared privately over Tor.</p>" & \
      "<p><a href='/download' download style='display:inline-block;padding:.6em 1.2em;" & \
      "background:#2c5aa0;color:#fff;text-decoration:none;border-radius:6px'>Download</a></p>" & \
      "<p style='color:#888;font-size:.9em'>This transfer is anonymous - both IP addresses are hidden by " & \
      "Tor - but it is NOT encrypted, and the sender is not cryptographically verified.</p></body></html>")
end qsHtmlIndex

function qsHtmlEncrypted
   return ("<!doctype html><html><head><meta charset='utf-8'><title>Encrypted</title></head>" & \
      "<body style='font-family:system-ui,sans-serif;max-width:34em;margin:3em auto;padding:0 1em'>" & \
      "<h2>This file is encrypted</h2><p>It cannot be downloaded in a browser. Ask the sender for the " & \
      "app share code and the passphrase.</p></body></html>")
end qsHtmlEncrypted

-- RECEIVE entry: parse a BTXTOR1 code, verify the passphrase locally BEFORE dialing,
-- then dial the onion and wire the receiver state machine.
command qsReceiveOnion pCode
   local tRest, tOnion, tB64, tB64Salt, tB64Verify, tName, tPass, tSalt, tKey, tStream, tErr
   if not sHasOnion then
      qsLog "This is a private Tor share, but OnionXT (or cryptoXT) is not installed - ask your friend to share it normally, or install OnionXT + cryptoXT + Tor."
      exit qsReceiveOnion
   end if
   put char ((the number of chars of kTorCodePrefix) + 1) to -1 of pCode into tRest
   set the itemDelimiter to ":"
   put item 1 of tRest into tOnion
   put item 2 of tRest into tB64
   put item 3 of tRest into tB64Salt
   put item 4 of tRest into tB64Verify
   if not oxIsValidAddress(tOnion) then
      qsLog "That Tor code has a malformed address."
      exit qsReceiveOnion
   end if
   put qsSafeLeaf(textDecode(base64Decode(tB64), "UTF-8")) into tName
   if tName is empty then
      put "shared-file" into tName
   end if
   put qsTrim(field "qsRecvPass") into tPass
   put "" into tKey
   if tB64Verify is not empty then
      if not sCanEncrypt then
         qsLog "This code is locked, but cryptoXT is not installed - cannot decrypt."
         exit qsReceiveOnion
      end if
      if tPass is empty then
         qsLog "This code is LOCKED - type the passphrase your friend gave you, then click Download."
         exit qsReceiveOnion
      end if
      if tB64Salt is empty then
         qsLog "That locked code is missing its salt."
         exit qsReceiveOnion
      end if
      put base64Decode(tB64Salt) into tSalt
      put "" into tKey
      try
         put sxPwHash(textEncode(tPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tKey
      catch tErr
         qsLog "That locked code has a malformed salt."
         exit qsReceiveOnion
      end try
      if not qsKeyOpensVerifier(tKey, tB64Verify) then
         answer ("That passphrase does not match this locked file." & return & return & \
            "Check the passphrase your friend gave you and try again.") with "OK"
         select the text of field "qsRecvPass"
         exit qsReceiveOnion
      end if
   else
      answer ("This Tor code is not encrypted." & return & return & \
         "Your IP address stays hidden, but the sender is NOT verified - anyone who intercepts the code could substitute a file. Ask your friend for a passphrase for a verified transfer.") with "Cancel" or "Download anyway"
      if it is not "Download anyway" then
         exit qsReceiveOnion
      end if
   end if
   if not qsOnionReadyNow() then
      qsLog "Tor is still connecting - watch the pill, then click Download again."
      exit qsReceiveOnion
   end if
   oxDial tOnion, kOnionVPort
   put the result into tStream
   if tStream is not an integer then
      qsLog "Could not open a Tor connection to that address:" && tStream
      exit qsReceiveOnion
   end if
   put "header" into sRxState[tStream]
   put "" into sRxBuf[tStream]
   put tKey into sRxKey[tStream]
   put tName into sRxName[tStream]
   put qsSaveFolder() into sRxSave[tStream]
   put 0 into sRxGot[tStream]
   put the milliseconds into sRxDeadline[tStream]
   put tName into sOnionXfers[tStream]["name"]
   put "receiving" into sOnionXfers[tStream]["dir"]
   if tB64Verify is not empty then
      put "true" into sOnionXfers[tStream]["enc"]
   else
      put "" into sOnionXfers[tStream]["enc"]
   end if
   put 0 into sOnionXfers[tStream]["total"]
   put 0 into sOnionXfers[tStream]["got"]
   put "connecting" into sOnionXfers[tStream]["state"]
   oxSetStreamCallback tStream, "qsOnionRecvStream"
   send ("qsOnionRecvWatchdog " & tStream) to me in kOnionRecvTimeout milliseconds
   put empty into field "qsRecvCode"
   qsLog "Connecting privately over Tor to fetch " & quote & tName & quote & "..."
end qsReceiveOnion

-- Receiver's per-stream handler: send the request on open, feed data to the state
-- machine, abort a partial transfer on close/error.
command qsOnionRecvStream pStream, pEvent, pData
   if pEvent is "open" then
      oxWrite pStream, kOnionMagic
      put the milliseconds into sRxDeadline[pStream]
   else if pEvent is "data" then
      qsOnionRecvData pStream, pData
   else if pEvent is "closed" or pEvent is "error" then
      if sRxState[pStream] is not "done" and sRxState[pStream] is not empty then
         qsOnionRecvAbort pStream, "The sender went offline before the transfer finished. Try the code again."
      end if
   end if
end qsOnionRecvStream

-- The receive state machine (section 3.3): reassemble the header, then drain
-- length-prefixed frames into a temp file, draining+compacting the buffer each call
-- so the payload never dwells whole in a Data.
command qsOnionRecvData pStream, pData
   local tNameLen, tName, tHi, tLo, tTotal, tFlags, tLen, tPayload
   if sRxState[pStream] is empty or sRxState[pStream] is "done" then
      exit qsOnionRecvData   -- already finished/cleared; ignore any trailing bytes
   end if
   put pData after sRxBuf[pStream]
   put the milliseconds into sRxDeadline[pStream]
   if sRxState[pStream] is "header" then
      if the number of bytes in sRxBuf[pStream] < 8 then
         exit qsOnionRecvData
      end if
      if (byte 1 to 4 of sRxBuf[pStream]) is not kOnionMagic then
         qsOnionRecvAbort pStream, "Unexpected data on the Tor stream (bad magic)."
         exit qsOnionRecvData
      end if
      if byteToNum(byte 5 of sRxBuf[pStream]) is not kOnionVer then
         qsOnionRecvAbort pStream, "Unsupported Tor stream version."
         exit qsOnionRecvData
      end if
      put byteToNum(byte 6 of sRxBuf[pStream]) into tFlags
      put qsBEu16(byte 7 to 8 of sRxBuf[pStream]) into tNameLen
      if tNameLen > kOnionMaxName then
         qsOnionRecvAbort pStream, "Tor stream header looks malformed (name too long)."
         exit qsOnionRecvData
      end if
      if the number of bytes in sRxBuf[pStream] < (8 + tNameLen + 8) then
         exit qsOnionRecvData
      end if
      put textDecode(byte 9 to (8 + tNameLen) of sRxBuf[pStream], "UTF-8") into tName
      put qsBEu32(byte (9 + tNameLen) to (12 + tNameLen) of sRxBuf[pStream]) into tHi
      put qsBEu32(byte (13 + tNameLen) to (16 + tNameLen) of sRxBuf[pStream]) into tLo
      put (tHi * 4294967296 + tLo) into tTotal
      if tTotal > kOnionMaxTotal then
         qsOnionRecvAbort pStream, "Refusing an oversized Tor transfer."
         exit qsOnionRecvData
      end if
      if sRxKey[pStream] is not empty and (tFlags bitAnd kFlagEnc) is 0 then
         qsOnionRecvAbort pStream, "This share was supposed to be encrypted but arrived unencrypted - do not trust it."
         exit qsOnionRecvData
      end if
      if (tFlags bitAnd kFlagEnc) is not 0 and sRxKey[pStream] is empty then
         qsOnionRecvAbort pStream, "This file is encrypted but the code had no passphrase - ask your friend to re-share."
         exit qsOnionRecvData
      end if
      put (tFlags bitAnd kFlagEnc) into sRxEnc[pStream]
      if tName is not empty then
         put qsSafeLeaf(tName) into sRxName[pStream]
      end if
      put tTotal into sRxTotal[pStream]
      put tTotal into sOnionXfers[pStream]["total"]
      put 0 into sRxGot[pStream]
      put qsTempEncPath() into sRxTmp[pStream]
      open file sRxTmp[pStream] for binary write
      if the result is not empty then
         qsOnionRecvAbort pStream, "Could not open a temp file to receive into."
         exit qsOnionRecvData
      end if
      delete byte 1 to (16 + tNameLen) of sRxBuf[pStream]
      put "body" into sRxState[pStream]
      put "active" into sOnionXfers[pStream]["state"]
   end if
   repeat while sRxState[pStream] is "body"
      if the number of bytes in sRxBuf[pStream] < 4 then
         exit repeat
      end if
      put qsBEu32(byte 1 to 4 of sRxBuf[pStream]) into tLen
      if tLen is 0 then
         delete byte 1 to 4 of sRxBuf[pStream]
         put "done" into sRxState[pStream]
         exit repeat
      end if
      if tLen > kOnionChunk then
         qsOnionRecvAbort pStream, "Tor stream frame too large - aborting."
         exit qsOnionRecvData
      end if
      if the number of bytes in sRxBuf[pStream] < (4 + tLen) then
         exit repeat
      end if
      put byte 5 to (4 + tLen) of sRxBuf[pStream] into tPayload
      write tPayload to file sRxTmp[pStream]
      if the result is not empty then
         qsOnionRecvAbort pStream, "Could not write the received data to disk:" && the result
         exit qsOnionRecvData
      end if
      add tLen to sRxGot[pStream]
      put sRxGot[pStream] into sOnionXfers[pStream]["got"]
      delete byte 1 to (4 + tLen) of sRxBuf[pStream]
   end repeat
   -- belt and suspenders: finish on the byte count even if the terminator frame is
   -- lost or a close event races it, so a fully-received file is never discarded.
   if sRxState[pStream] is "body" and sRxGot[pStream] >= sRxTotal[pStream] then
      put "done" into sRxState[pStream]
   end if
   if sRxState[pStream] is "done" then
      qsOnionRecvFinish pStream
   end if
end qsOnionRecvData

-- Transfer complete: verify the byte count, decrypt or move into the save folder.
command qsOnionRecvFinish pStream
   local tSave, tOut, tErr, tErr2
   close file sRxTmp[pStream]
   if sRxGot[pStream] is not sRxTotal[pStream] then
      qsOnionRecvAbort pStream, "The transfer ended early (incomplete) - nothing was saved."
      exit qsOnionRecvFinish
   end if
   put sRxSave[pStream] into tSave
   put tSave & "/" & qsSafeLeaf(sRxName[pStream]) into tOut
   if sRxEnc[pStream] is not 0 then
      put qsDecryptFile(sRxTmp[pStream], tOut, sRxKey[pStream]) into tErr
      try
         if there is a file sRxTmp[pStream] then
            delete file sRxTmp[pStream]
         end if
      catch tErr2
      end try
      if tErr is not empty then
         put "error" into sOnionXfers[pStream]["state"]
         qsLog "Downloaded over Tor but could not unlock " & quote & sRxName[pStream] & quote & ":" && tErr
         qsOnionRecvClear pStream
         oxCloseStream pStream
         exit qsOnionRecvFinish
      end if
   else
      put qsMoveFile(sRxTmp[pStream], tOut) into tErr
      if tErr is not empty then
         put "error" into sOnionXfers[pStream]["state"]
         qsLog "Downloaded over Tor but could not save the file:" && tErr
         qsOnionRecvClear pStream
         oxCloseStream pStream
         exit qsOnionRecvFinish
      end if
   end if
   put "done" into sOnionXfers[pStream]["state"]
   qsLog "Received " & quote & sRxName[pStream] & quote & " over Tor into" && tSave & "."
   qsOnionRecvClear pStream
   oxCloseStream pStream
end qsOnionRecvFinish

command qsOnionRecvClear pStream
   put empty into sRxBuf[pStream]
   put empty into sRxState[pStream]
   put empty into sRxTmp[pStream]
   put empty into sRxName[pStream]
   put empty into sRxEnc[pStream]
   put empty into sRxTotal[pStream]
   put empty into sRxGot[pStream]
   put empty into sRxKey[pStream]
   put empty into sRxSave[pStream]
   put empty into sRxDeadline[pStream]
end qsOnionRecvClear

command qsOnionRecvAbort pStream, pMsg
   local tErr
   try
      close file sRxTmp[pStream]
   catch tErr
   end try
   if sRxTmp[pStream] is not empty then
      try
         if there is a file sRxTmp[pStream] then
            delete file sRxTmp[pStream]
         end if
      catch tErr
      end try
   end if
   put "error" into sOnionXfers[pStream]["state"]
   qsLog pMsg
   qsOnionRecvClear pStream
   oxCloseStream pStream
end qsOnionRecvAbort

-- Idle watchdog for a receive stream (also catches a dead peer that sends nothing).
command qsOnionRecvWatchdog pStream
   if sRxState[pStream] is empty or sRxState[pStream] is "done" then
      exit qsOnionRecvWatchdog
   end if
   if (the milliseconds - sRxDeadline[pStream]) > kOnionRecvTimeout then
      qsOnionRecvAbort pStream, "The private (Tor) download stalled - closing it. Try the code again."
      exit qsOnionRecvWatchdog
   end if
   send ("qsOnionRecvWatchdog " & pStream) to me in kOnionRecvTimeout milliseconds
end qsOnionRecvWatchdog

-- Move a finished plaintext temp to its real name (rename avoids a full read).
function qsMoveFile pSrc, pDst
   local tErr
   try
      if there is a file pDst then
         delete file pDst
      end if
      rename file pSrc to pDst
   catch tErr
      return tErr
   end try
   return ""
end qsMoveFile

-- Flip the "Serve as web download" checkbox (managed two-state; autoHilite off).
command qsToggleWeb
   if sWebServe is "true" then
      put "false" into sWebServe
      set the hilite of button "qsWebCheck" to false
   else
      put "true" into sWebServe
      set the hilite of button "qsWebCheck" to true
   end if
end qsToggleWeb

command qsCopyWebLink
   if field "qsWebLink" is empty then
      qsLog "No web link yet - share a plaintext file over Tor with 'Serve as web download' ticked."
      exit qsCopyWebLink
   end if
   set the clipboardData["text"] to field "qsWebLink"
   qsLog "Web link copied. Anyone with Tor Browser can open it to download."
end qsCopyWebLink

-- Shown to a browser when the sender did NOT tick 'Serve as web download'.
function qsHtmlDisabled
   return ("<!doctype html><html><head><meta charset='utf-8'><title>Not available</title></head>" & \
      "<body style='font-family:system-ui,sans-serif;max-width:34em;margin:3em auto;padding:0 1em'>" & \
      "<h2>Web download is off</h2><p>The sender shared this file for the app only. Ask them for the " & \
      "share code, or to tick 'Serve as web download'.</p></body></html>")
end qsHtmlDisabled

command qsLog pMsg
   if there is no field "qsLog" then
      exit qsLog
   end if
   put the time & "  " & pMsg & return after field "qsLog"
   if the number of lines of field "qsLog" > 200 then
      delete line 1 to (the number of lines of field "qsLog" - 200) of field "qsLog"
   end if
   set the vScroll of field "qsLog" to the formattedHeight of field "qsLog"
end qsLog
