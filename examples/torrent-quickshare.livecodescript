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
-- passphrase, and the file unlocks automatically when the download completes.
-- The encryption features REQUIRE the cryptoXT extension
-- (org.openxtalk.library.sodium); plain sharing works without it.
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

-- Optional end-to-end encryption (mirrors the channels demo), via cryptoXT
-- (libsodium). A passphrase turns a share into ciphertext under a NEUTRAL name:
-- the swarm only ever sees the .enc blob, the real filename and the Argon2id salt
-- ride inside the share code, and the passphrase (shared separately) is what
-- actually unlocks the bytes. Requires the org.openxtalk.library.sodium extension.
constant kCodePrefix = "BTXQS1:" -- marks an encrypted share code (vs a bare hash)

-- Bump when the generated UI changes; qsBuild rebuilds the controls on a mismatch
-- so updating the script in a SAVED stack picks up the new layout (passphrase
-- fields and all) instead of keeping the old controls around.
constant kQsUiVersion = "qs-ui-2026-06"

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
   qsLabel "qsTagline", "Send a file straight to a friend with a short code. No server, no size limit, no upload first - peer-to-peer.", "24,48,596,70", 10
   set the foregroundColor of field "qsTagline" to "90,96,105"
   -- SEND: an OPTIONAL passphrase (set it BEFORE dropping to encrypt), the drop
   -- area, then the resulting code.
   qsLabel "qsSendPassCap", "Lock with a passphrase (optional):", "24,76,300,96", 10
   qsField "qsSendPass", "304,74,596,98", false
   qsField "qsDrop", "24,104,596,206", true
   set the opaque of field "qsDrop" to true
   set the backgroundColor of field "qsDrop" to "245,247,250"
   set the borderWidth of field "qsDrop" to 1
   set the threeD of field "qsDrop" to false
   set the borderColor of field "qsDrop" to "175,185,200"
   set the textAlign of field "qsDrop" to "center"
   set the textSize of field "qsDrop" to 13
   set the foregroundColor of field "qsDrop" to "90,96,105"
   set the text of field "qsDrop" to (return & return & "Drag a file here to share" & return & return & "(or click to choose a file)")
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
   local tEncPath, tEncParent, tErr, tSalt, tKey
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
      put qsMakeCode(tHash, tName, tSalt) into sShareCode
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
   local tCode, tMag, tH, tHash, tName, tPass, tRest, tB64, tB64Salt, tSalt, tKey
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
   if tCode begins with kCodePrefix then
      -- locked share code: BTXQS1:<hash>:<base64 name>:<base64 salt>
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
   local tIH, tDisp, tDir
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
-- and the Argon2id salt (both base64'd). The colon is a safe delimiter because
-- neither a hex hash nor base64 ever contains one.
function qsMakeCode pHash, pName, pSalt
   return kCodePrefix & pHash & ":" & qsB64(textEncode(pName, "UTF-8")) & ":" & qsB64(pSalt)
end qsMakeCode

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
   if tErr is not empty then
      qsLog "Could not unlock" && quote & sPendingName[tHash] & quote & ":" && tErr
   else
      qsLog "Unlocked to" && quote & sPendingName[tHash] & quote & "in" && tSave & "."
   end if
   put empty into sPendingKey[tHash]
   put empty into sPendingName[tHash]
end qsMaybeDecryptFinished

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
