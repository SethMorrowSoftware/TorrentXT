script "newQuickShareApp"

-- newquickshare.livecodescript - a REVAMPED Quick Share (see torrent-quickshare for
-- the original). Same engine and features; a wider, shorter, self-explanatory UI that
-- fits a 720p screen: a two-column dashboard with a plain-English 3-way "how to share"
-- choice (Share code / Private-Tor / Web link) on the left and Receive / Transfers /
-- Activity on the right. Drag a file onto the window, get a short code, send the code
-- to a friend; they paste it in and the file transfers straight from your machine to
-- theirs. No server, no upload, no size limit - it is plain peer-to-peer BitTorrent
-- with the DHT finding the peers, wrapped in a one-card stack.
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
-- "My Shares" management: the swarm already holds ANY number of concurrent code
-- shares (each btAddTorrentFile lands in the session table); the only limit was the
-- single qsCode field, so an older share's code was lost the moment a newer one
-- replaced it. sShareCodeByHandle keeps every live code share's code against its
-- torrent handle, so the Transfers list can re-copy or stop each one individually.
local sShareCodeByHandle -- array: torrent handle -> the share code we minted for it
-- The Transfers list is the one actionable surface: each visible row (a download, a
-- code seed, a Tor stream, a web/folder page) is tagged with a stable identity so a
-- selection survives the 2-4 Hz repaint and Stop/Copy act on the right item.
local sXferRow          -- array: list line number -> "type|key" identity for that row
local sXferSel          -- the currently selected row identity ("type|key"), or empty
local sLastXferRows     -- last text set into the qsXfers list (only retype it on a change)
-- Clipboard auto-detect: when the window opens or comes to the front and the
-- clipboard holds something code-shaped, the Receive box is pre-filled (never
-- overwriting user input). Each clipboard value is offered exactly ONCE, so a
-- declined suggestion never nags on every focus change.
local sClipSuggested    -- the last clipboard text already offered (or dismissed)
-- Stall coaching (round 4): a download sitting at ZERO peers is the worst
-- novice moment - it reads as "broken" when it usually means "the sender
-- closed their window". Track when each torrent was first seen peerless so
-- 45s of that flips its row to plain English and logs the explanation ONCE.
local sStallSince       -- array: torrent handle -> the milliseconds 0 peers was first seen
local sStallWarned      -- array: torrent handle -> "true" once the one-time log ran

-- OnionXT (optional Tor anonymity, Model C). When the Tor toggle is on, a file's
-- bytes travel over an OnionXT onion stream (both IPs hidden) and NO torrent is
-- created. All of this is inert unless sHasOnion. See the ox* wiring below.
local sHasOnion         -- "true" if OnionXT loads AND cryptoXT works (probed once)
local sTorReady         -- "true" if Tor is bootstrapped + ready (LIVE cache; re-checked at use)
local sTorSend          -- "true" while the "Send privately over Tor" toggle is armed
local sWebServe         -- "true" while the "Also offer a Tor Browser download link" checkbox is on
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
-- Folder web-server state (Model C, but for a whole FOLDER). When a FOLDER is
-- dropped with Tor on, we do not create a torrent and do not use the single-file
-- BTXO transfer; instead we serve the folder as a browsable web page over the onion
-- (an auto directory listing + streamed, Range-capable file downloads), so a visitor
-- just opens http://<onion>/ in Tor Browser. A folder web server needs CONCURRENT
-- connections (page, icons, downloads), so this path keeps per-stream state and does
-- NOT use the single-file busy gate. Keyed by the OnionXT stream handle.
local sFsReq            -- array: stream -> accumulated inbound HTTP request bytes
local sFsServed         -- array: stream -> "true" once we have begun answering it
local sFsTxPath         -- array: stream -> disk path of the file being streamed out
local sFsTxPos          -- array: stream -> next byte offset to read (0-based; honours a Range)
local sFsTxRemaining    -- array: stream -> bytes still to send (respects a Range)
local sFsTxName         -- array: stream -> the file's leaf name (for the log)
local sFsTxDeadline     -- array: stream -> the milliseconds of the last activity (watchdog)
-- Dynamic routes (the light xTalk backend). A hosted web app can call back into
-- this stack: sHttpRoutes maps "METHOD /path" -> the name of an xTalk handler that
-- answers the request (see qsHttpRoute / qsHttpReply below). Works over BOTH
-- transports; on the direct web link a route sits under the token, e.g.
-- http://<ip>:<port>/<token>/_qs/info.
local sHttpRoutes       -- array: "METHOD /path" -> handler name in this script
-- qsHttpHeaderEnd's scanner choice, probed ONCE on first use: "fast" when the
-- engine's byteOffset proves it handles a multi-byte needle on a known vector,
-- else "loop" (the original interpreted scan). See qsHttpHeaderEnd.
local sHdrScanMode
-- The optional live WEB EDITOR (Phase C). Turns the served folder read-WRITE from a
-- browser, so it is deliberately locked down: OFF by default; a cryptoXT (Argon2id)
-- edit password; a random per-login session token; and - the hard rule - editing is
-- LAN-ONLY (a request from a non-local peer, or any Tor request, is refused), while
-- the site itself stays publicly shareable. Every write path is confined to the
-- served root by qsEditSafePath (the security linchpin, adversarially golden-tested).
local sEditOn           -- "true" when the editor is enabled for this session
local sEditSalt         -- Argon2id salt for the edit password
local sEditVerify       -- sxSecretBox verifier: proves a login password is correct
local sEditSession      -- the current valid edit-session token (random hex), or empty
-- Clearweb (direct, non-Tor) web sharing. A plain LiveCode socket HTTP server serves
-- a file/folder to any browser at http://<ip>:<port>/<token>/... . TorrentXT's
-- libtorrent opens the router port automatically (btMapPort / UPnP-NAT-PMP) and
-- discovers the public IP (the externalIp event), so no manual port forwarding is
-- needed when the router cooperates; the LAN link always works. The <token> (a random
-- capability string) means an open port is not an open directory to port-scanners.
-- Uses LiveCode's own sockets (accept/read/write/close), mirroring OnionXT's proven
-- on-engine idiom. NEEDS AN ON-ENGINE PASS - the socket + UPnP + local-IP layers are
-- the most engine-dependent code here (flagged VERIFY at each site).
local sWebShare         -- "true" while the "Share via web link" toggle is armed
local sCwActive         -- "true" while a clearweb share is live
local sCwKind           -- "file" or "folder"
local sCwRoot           -- the shared folder (no trailing slash), for a folder share
local sCwFilePath       -- the shared file's full path, for a file share
local sCwFileName       -- the shared file's leaf name, for a file share
local sCwName           -- display name (file leaf or folder leaf)
local sCwToken          -- the random capability token that gates every request
local sCwPort           -- the TCP port the listener + the port-map use
local sCwMapId          -- the btMapPort mapping id (0 = none/no UPnP)
local sCwMapped         -- "true" once a portMapped event confirms the router opened it
local sCwExtIp          -- the discovered public IP (from the externalIp event), or empty
local sCwLanIp          -- the best-effort LAN IP for the local link
local sCwLink           -- the primary browser link (for per-row Copy in My Shares)
-- per-connection state, keyed by the LiveCode socket id
local sCwReq            -- array: socket -> accumulated inbound HTTP request bytes
local sCwServed         -- array: socket -> "true" once we have begun answering it
local sCwTxPath         -- array: socket -> disk path of the file being streamed out
local sCwTxPos          -- array: socket -> next byte offset to read (0-based; honours a Range)
local sCwTxRemaining    -- array: socket -> bytes still to send (respects a Range)
local sCwTxName         -- array: socket -> the file's leaf name (for the log)
-- HTTP keep-alive (persistent connections) for the small buffered TEXT responses only;
-- a streamed file still closes its connection (bounding the risk to the framed path).
local sCwKeep           -- array: socket -> "true" if THIS response may keep the connection open
local sCwReqCount       -- array: socket -> requests already served on this connection (cap)
local sCwDeadline       -- array: socket -> the milliseconds of the last activity (idle watchdog)
local sCwMethod         -- array: socket -> the current request's method (HEAD must send no body)
local sCwWriting        -- array: socket -> "true" while a buffered response write is in flight

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
-- Tor-side idle watchdogs. Generous on purpose: circuit rebuilds and relay
-- congestion routinely stall a healthy Tor stream for 30-60+ seconds, and an
-- abort on the anon path is EXPENSIVE - a BTXO transfer has no resume, so a
-- watchdog that fires during an ordinary stall restarts the whole file. These
-- also pace the folder-server reap of dead/silent connections (qsFsWatchdog),
-- so raising them holds junk connections a little longer - the right trade
-- for an onion service, where the user-visible cost of a false abort is far
-- higher than the cost of a parked stream. (The clearweb kCwIdleTimeout below
-- stays short: closing an idle keep-alive is a normal HTTP event a browser
-- recovers from transparently.)
constant kOnionSendTimeout = 90000     -- ms idle watchdog, sender + folder server
constant kOnionRecvTimeout = 120000    -- ms idle watchdog, receiver (waits on the whole Tor path)
constant kOnionPublishTimeout = 90000  -- ms to wait for the onion descriptor to upload
constant kOnionMaxName = 1024          -- reject a header nameLen beyond this (anti-DoS)
constant kOnionMaxTotal = 8589934592   -- 8 GiB payload ceiling; reject a larger header
constant kFsMaxReq = 262144            -- web server: refuse an HTTP request (head + body) > 256 KB
constant kCwTokenBytes = 16            -- clearweb capability token: 16 random bytes (128 bits)
constant kCwMaxKeepAlive = 100         -- max requests served on one kept-alive connection
constant kCwIdleTimeout = 30000        -- ms an idle kept-alive connection is held open, then closed
                                       -- (kept SHORT deliberately, unlike the Tor watchdogs above:
                                       -- a browser reopens a closed keep-alive transparently, and
                                       -- an in-flight stream/write is never reaped - see qsCwWatchdog)
constant kCwMaxConns = 32              -- concurrent clearweb connections (state + a watchdog
                                       -- timer are per-socket, and UPnP exposes the port to the
                                       -- internet - a connect flood must not grow them unboundedly;
                                       -- a browser uses ~6 connections, so 32 is generous)
constant kCwChunk = 262144             -- 256 KiB clearweb file slice: the socket pump is paced by
                                       -- write-completions through the message queue, so bigger
                                       -- slices = fewer round-trips = faster LAN transfers, at a
                                       -- bounded 256 KiB per-connection buffer (Tor keeps the
                                       -- smaller kOnionChunk - its bottleneck is the network)
constant kEditTokenBytes = 24          -- live-editor session token: 24 random bytes (192 bits)
constant kEditVerify = "BTXEDIT1"      -- plaintext sealed under the edit key to prove a login
constant kEditMaxDepth = 32            -- editor file listing: recursion depth ceiling (anti-loop)
constant kEditMaxFileBytes = 262144    -- editor: biggest file it will read/save (256 KB; a save
                                       -- is additionally bounded by kFsMaxReq at the transport)
constant kAnonSizeWarn = 268435456     -- 256 MiB: warn (never block) above this, anon path
constant kTorSocksPort = "9050"        -- system/standalone tor
constant kTorControlPort = "9051"
constant kTorSocksPortTB = "9150"      -- Tor Browser
constant kTorControlPortTB = "9151"

-- Bump when the generated UI changes; qsBuild rebuilds the controls on a mismatch
-- so updating the script in a SAVED stack picks up the new layout (passphrase
-- fields and all) instead of keeping the old controls around.
constant kQsUiVersion = "nqs-ui-2027-05"

-- ---- UI design tokens ----------------------------------------------------------
-- One palette for every generated control, so the whole surface shifts together
-- (and a re-theme is a constants edit, not a hunt through qsBuild). Neutral grays
-- carry the chrome; ONE accent blue carries brand + interaction; the Tor chip gets
-- three semantic states (unavailable / connecting / ready). All literal RGB
-- strings - OXT constants must be literal and declared before first use.
constant kClrPage = "240,242,246"       -- window background
constant kClrCard = "255,255,255"       -- card fill (and input fill)
constant kClrCardLine = "225,229,236"   -- hairline card border / dividers
constant kClrBand = "44,90,160"         -- header band (brand blue)
constant kClrBandText = "255,255,255"   -- title on the band / badge digits
constant kClrBandSub = "199,216,241"    -- tagline on the band
constant kClrInk = "28,34,46"           -- primary text
constant kClrInkSoft = "95,104,118"     -- secondary text / status lines
constant kClrInkMute = "138,146,158"    -- captions, hints, empty states
constant kClrAccent = "43,108,196"      -- accent (step badges, drag-over border)
constant kClrFieldLine = "203,210,222"  -- entry-field border
constant kClrCodeBg = "244,246,250"     -- code/link output fill
constant kClrCodeLine = "210,217,229"   -- code/link output border
constant kClrDropBg = "247,249,252"     -- drop zone fill, idle
constant kClrDropHot = "232,241,255"    -- drop zone fill, hover / drag-over
constant kClrDropLine = "170,182,202"   -- drop zone dashed border, idle
constant kClrWarn = "150,110,40"        -- small amber hints ("LAN only"; Tor connecting rows)
constant kClrRowSend = "23,128,63"      -- transfers list: seeding / done / serving rows
constant kClrRowErr = "176,58,46"       -- transfers list: stopped / errored rows
constant kClrPillOff = "31,64,116"      -- Tor chip: unavailable (band-toned)
constant kClrPillOffText = "199,216,241"
constant kClrPillWait = "250,240,199"   -- Tor chip: bootstrapping
constant kClrPillWaitText = "133,98,14"
constant kClrPillOk = "205,240,214"     -- Tor chip: ready
constant kClrPillOkText = "22,101,52"

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   qsBuild
   qsStart
end openStack

on closeStack
   qsStop
end closeStack

on resumeStack
   -- the window came back to the front: a share code may be waiting on the
   -- clipboard (the classic receive flow is copy in chat -> switch to the app)
   qsClipboardSuggest
   pass resumeStack
end resumeStack

-- ---- OS file drag-and-drop ---------------------------------------------------
-- These bubble up from whatever control is under the pointer to this stack
-- script, so a drop anywhere on the window works. Click-to-choose (the drop
-- area is also a button) is the guaranteed fallback if a platform does not
-- deliver OS file drops.
on dragEnter
   set the acceptDrop to true
   qsDropPaint "hot"
end dragEnter

on dragMove
   set the acceptDrop to true
end dragMove

on dragLeave
   qsDropPaint "idle"
end dragLeave

on dragDrop
   local tFiles
   qsDropPaint "idle"
   put the dragData["files"] into tFiles
   if tFiles is empty then
      -- some platforms/drops deliver a lone path as "text" rather than "files"
      put the dragData["text"] into tFiles
   end if
   if tFiles is empty then
      -- NEVER swallow a drop silently: OS file-drop delivery is occasionally flaky,
      -- so say so and point at the always-reliable click fallback.
      qsLog "That drop did not register - drag delivery can be unreliable from a file window. Use the Choose a file / Choose a folder buttons instead (they always work)."
      exit dragDrop
   end if
   -- one item at a time keeps the demo simple; the first dropped item wins
   qsShareFile (line 1 of tFiles)
end dragDrop

on mouseUp
   switch the short name of the target
      case "qsDrop"
         qsChooseFile      -- clicking the drag zone is a shortcut to the file picker
         break
      case "qsChooseFile"
         qsChooseFile
         break
      case "qsChooseFolder"
         qsChooseFolder
         break
      case "qsCopy"
         qsCopyCode
         break
      case "qsCode"
         qsCopyCode        -- the code box itself is click-to-copy (tooltip says so)
         break
      case "qsGet"
         qsGetFile
         break
      -- each radio's grey caption is click-through to the same choice, so the
      -- whole two-line "option" reads (and behaves) as one control
      case "qsMethodCode"
      case "qsMethodCodeD"
         qsSetMethod "code"
         break
      case "qsMethodTor"
      case "qsMethodTorD"
         qsSetMethod "tor"
         break
      case "qsMethodWeb"
      case "qsMethodWebD"
         qsSetMethod "web"
         break
      case "qsPassSuggest"
         qsSuggestPass
         break
      case "qsWebCheck"
         qsToggleWeb
         break
      case "qsEditToggle"
         qsToggleEdit
         break
      case "qsWebCopy"
         qsCopyWebLink
         break
      case "qsWebLink"
         qsCopyWebLink     -- the link box is click-to-copy too
         break
      case "qsXfers"
         qsXferClick
         break
      case "qsXferCopy"
         qsCopySelected
         break
      case "qsXferStop"
         qsStopSelected
         break
      case "qsXferFolder"
         qsOpenSaveFolder
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- Hover affordance for the drop zone (it doubles as a "choose a file" button, so
-- it should light up like one). During an OS drag these do not fire - the drag*
-- handlers above own that state.
on mouseEnter
   if the short name of the target is "qsDrop" then
      qsDropPaint "hover"
   end if
   pass mouseEnter
end mouseEnter

on mouseLeave
   if the short name of the target is "qsDrop" then
      qsDropPaint "idle"
   end if
   pass mouseLeave
end mouseLeave

-- Return/Enter in the single-line inputs ACTS instead of inserting a newline: in
-- either Receive field it clicks Download for you (paste -> Enter, done); in a
-- passphrase field it is swallowed (a stray newline would silently become part
-- of the passphrase and the derived keys would never match).
on returnInField
   switch the short name of the target
      case "qsRecvCode"
      case "qsRecvPass"
         qsGetFile
         break
      case "qsSendPass"
      case "qsEditPass"
         break
      default
         pass returnInField
   end switch
end returnInField

on enterInField
   switch the short name of the target
      case "qsRecvCode"
      case "qsRecvPass"
         qsGetFile
         break
      case "qsSendPass"
      case "qsEditPass"
         break
      default
         pass enterInField
   end switch
end enterInField

-- ---- self-building UI (idempotent; rebuilds on a UI-version bump) ------------
command qsBuild
   -- a normal re-open with a matching version + the passphrase fields present is
   -- a fast no-op; a script update that changed the layout rebuilds from scratch.
   if the uUiVersion of this stack is kQsUiVersion and there is a field "qsSendPass" \
         and there is a graphic "qsDropBg" then
      exit qsBuild
   end if
   qsClearGeneratedUI
   lock screen
   -- Wide, short, two-column dashboard sized to fit a 720p screen (window 1100x640;
   -- the OS title bar adds ~30px, still well under 720). LEFT = Send (a plain-English
   -- 3-way choice, drop area, output, and a tucked-away More options block); RIGHT =
   -- Receive, Transfers, and Activity stacked. Cards (rounded, hairline-bordered,
   -- softly shadowed graphics created BEFORE the controls that sit on them) group
   -- each step so it reads at a glance. Every color comes from the kClr* tokens
   -- above; every rect sits on a consistent grid (20px card inset, ~12px between
   -- groups) - labels get margins 0 so a rect places its text exactly.
   set the width of this stack to 1100
   set the height of this stack to 640
   -- fixed-size dashboard: the layout is hand-placed, so a free resize would only
   -- tear it (VERIFY on-engine: property honoured by the window manager)
   set the resizable of this stack to false
   set the backgroundColor of this card to kClrPage
   set the title of this stack to "newQuickShare"

   -- title band (a plain filled graphic) + tagline + live Tor status chip. Each
   -- band label auto-sizes in qsLabel, then is CENTERED on the band's midline
   -- (y 28) by its measured height - no font-metric guessing (the pass-1 lesson).
   qsGfx "qsTitleBg", "0,0,1100,56"
   set the style of graphic "qsTitleBg" to "rectangle"
   set the filled of graphic "qsTitleBg" to true
   set the backgroundColor of graphic "qsTitleBg" to kClrBand
   set the lineSize of graphic "qsTitleBg" to 0
   qsLabel "qsTitle", "newQuickShare", "12,4,400,52", 16
   set the foregroundColor of field "qsTitle" to kClrBandText
   set the textStyle of field "qsTitle" to "bold"
   set the top of field "qsTitle" to (28 - ((the height of field "qsTitle") div 2))
   qsLabel "qsTagline", "Send & receive files - by code, over Tor, or a web link.", "240,4,830,52", 10
   set the foregroundColor of field "qsTagline" to kClrBandSub
   set the top of field "qsTagline" to (28 - ((the height of field "qsTagline") div 2))
   -- the Tor chip: a rounded pill whose color + text track the daemon state
   qsGfx "qsTorPillBg", "870,14,1080,42"
   set the roundRadius of graphic "qsTorPillBg" to 14
   set the filled of graphic "qsTorPillBg" to true
   set the backgroundColor of graphic "qsTorPillBg" to kClrPillOff
   set the lineSize of graphic "qsTorPillBg" to 0
   qsLabel "qsTorPill", "Tor: off", "878,4,1072,52", 10
   set the foregroundColor of field "qsTorPill" to kClrPillOffText
   set the textAlign of field "qsTorPill" to "center"
   set the top of field "qsTorPill" to (28 - ((the height of field "qsTorPill") div 2))

   -- =============== LEFT: SEND ===============
   qsPanel "qsSendPanel", "20,72,620,596"
   qsBadge "qsStep1", "40,90,66,116", "1"
   qsHdr "qsSendHdr", "Send a file or folder", "76,86,440,114"
   -- Signal that a sensible default is already picked (so no up-front decision is
   -- demanded), and keep the jargon out of the labels (it lives in the grey
   -- captions + tooltips).
   qsLabel "qsMethodCap", "How to share - Share code suits most people (change anytime):", "40,124,600,144", 10
   set the textStyle of field "qsMethodCap" to "bold"
   set the foregroundColor of field "qsMethodCap" to kClrInkSoft
   -- The send method: three mutually-exclusive RADIOS (autoHilite off; managed via
   -- sTorSend/sWebShare by qsSetMethod/qsSyncMethod), on an equal 3-column grid.
   -- Each caption is click-through to the same choice (mouseUp cases above).
   qsButton "qsMethodCode", "Share code", "40,148,220,168"
   set the style of button "qsMethodCode" to "radioButton"
   set the autoHilite of button "qsMethodCode" to false
   qsCap "qsMethodCodeD", "Resumable. Needs the app.", "59,170,224,186"
   qsButton "qsMethodTor", "Private - Tor", "230,148,410,168"
   set the style of button "qsMethodTor" to "radioButton"
   set the autoHilite of button "qsMethodTor" to false
   qsCap "qsMethodTorD", "Hides both IP addresses.", "249,170,414,186"
   qsButton "qsMethodWeb", "Web link", "420,148,600,168"
   set the style of button "qsMethodWeb" to "radioButton"
   set the autoHilite of button "qsMethodWeb" to false
   qsCap "qsMethodWebD", "Any browser. Not encrypted.", "439,170,600,186"
   -- optional end-to-end encryption: a passphrase set BEFORE dropping (needs
   -- cryptoXT), plus a Suggest button that mints a strong one from the CSPRNG
   qsLabel "qsSendPassCap", "Encrypt (optional):", "40,193,164,215", 10
   qsField "qsSendPass", "172,194,516,222", false
   qsButton "qsPassSuggest", "Suggest", "524,194,600,222"
   -- the drag zone: the hero action, so it gets the most visual weight - a dashed
   -- rounded target (qsDropBg) with a transparent click/drop overlay field on top
   -- (qsDrop keeps the name every existing handler targets). Drag delivery is
   -- OS/source-dependent - it can be unreliable from a file-manager window - so
   -- the two explicit picker buttons below are the always-works path, and a click
   -- on the zone itself opens the file picker as a shortcut.
   qsGfx "qsDropBg", "40,234,600,330"
   set the roundRadius of graphic "qsDropBg" to 12
   set the filled of graphic "qsDropBg" to true
   set the lineSize of graphic "qsDropBg" to 2
   set the dashes of graphic "qsDropBg" to "6,4"   -- VERIFY on-engine: dashed outline
   qsDropPaint "idle"
   qsField "qsDrop", "40,234,600,330", true
   set the opaque of field "qsDrop" to false
   set the borderWidth of field "qsDrop" to 0
   set the textAlign of field "qsDrop" to "center"
   set the textSize of field "qsDrop" to 13
   set the foregroundColor of field "qsDrop" to kClrInk
   set the margins of field "qsDrop" to "8,30,8,8"   -- top margin centers the 2 lines
   -- the zone's two-line message is method-aware, painted by qsDropHint (via the
   -- qsSyncMethod call below), so a drop always says what it is about to do
   -- always-reliable pickers: separate file / folder choosers open the native dialog
   -- directly (no guessing), so sharing a FOLDER is one obvious click even when a drag
   -- will not register.
   qsButton "qsChooseFile", "Choose a file...", "40,340,314,368"
   qsButton "qsChooseFolder", "Choose a folder...", "326,340,600,368"
   -- the resulting code / link, with a Copy button, then a plain-English status line
   qsLabel "qsCodeCap", "Share this with your friend", "40,382,440,404", 12
   set the textStyle of field "qsCodeCap" to "bold"
   qsField "qsCode", "40,410,512,446", true
   set the textFont of field "qsCode" to qsMonoFont()
   set the textSize of field "qsCode" to 12
   set the margins of field "qsCode" to "8,8,8,8"
   set the backgroundColor of field "qsCode" to kClrCodeBg
   set the borderColor of field "qsCode" to kClrCodeLine
   -- a long locked/Tor code never wraps into an unreadable clipped block: it shows
   -- one clean line and Copy (or a click) always carries the FULL text
   set the dontWrap of field "qsCode" to true
   qsButton "qsCopy", "Copy", "520,410,600,446"
   qsLabel "qsSharing", "", "40,452,600,506", 10
   set the foregroundColor of field "qsSharing" to kClrInkSoft
   put "Nothing is shared yet - pick a method above, then drop a file." into field "qsSharing"
   -- MORE OPTIONS: a quiet labelled divider; qsSyncMethod reveals + lays out only
   -- the advanced row(s) that apply to the chosen method (Share code shows none)
   qsCap "qsMoreCap", "MORE OPTIONS", "40,510,132,528"
   set the textSize of field "qsMoreCap" to 9
   set the textStyle of field "qsMoreCap" to "bold"
   qsGfx "qsMoreLine", "138,520,600,521"
   set the style of graphic "qsMoreLine" to "rectangle"
   set the filled of graphic "qsMoreLine" to true
   set the backgroundColor of graphic "qsMoreLine" to kClrCardLine
   set the lineSize of graphic "qsMoreLine" to 0
   qsButton "qsWebCheck", "Also offer a Tor Browser download link", "40,530,520,550"
   set the style of button "qsWebCheck" to "checkbox"
   set the autoHilite of button "qsWebCheck" to false
   qsField "qsWebLink", "40,558,512,584", true
   set the textFont of field "qsWebLink" to qsMonoFont()
   set the textSize of field "qsWebLink" to 10
   set the backgroundColor of field "qsWebLink" to kClrCodeBg
   set the borderColor of field "qsWebLink" to kClrCodeLine
   set the dontWrap of field "qsWebLink" to true
   qsButton "qsWebCopy", "Copy", "520,556,600,584"
   qsButton "qsEditToggle", "Enable web editing", "40,560,304,582"
   set the style of button "qsEditToggle" to "checkbox"
   set the autoHilite of button "qsEditToggle" to false
   qsLabel "qsEditPassCap", "Password:", "310,557,376,583", 10
   qsField "qsEditPass", "380,558,520,584", false
   qsLabel "qsEditHint", "LAN only", "526,557,600,583", 9
   set the foregroundColor of field "qsEditHint" to kClrWarn
   set the textAlign of field "qsEditHint" to "right"

   -- =============== RIGHT: RECEIVE ===============
   qsPanel "qsRecvPanel", "640,72,1080,244"
   qsBadge "qsStep2", "656,90,682,116", "2"
   qsHdr "qsRecvSec", "Receive a file", "692,86,940,114"
   qsLabel "qsRecvCap", "Paste the code your friend sent you:", "656,122,1064,142", 10
   set the foregroundColor of field "qsRecvCap" to kClrInkSoft
   qsField "qsRecvCode", "656,146,948,180", false
   set the textFont of field "qsRecvCode" to qsMonoFont()
   set the textSize of field "qsRecvCode" to 11
   set the margins of field "qsRecvCode" to "8,8,8,8"
   set the dontWrap of field "qsRecvCode" to true
   qsButton "qsGet", "Download", "956,146,1064,180"
   -- Enter in either Receive field also clicks Download (returnInField above); the
   -- default ring marks Download as the primary action of the whole right column
   set the default of button "qsGet" to true
   qsLabel "qsRecvPassCap", "Passphrase (only if the file is locked):", "656,186,1064,206", 10
   set the foregroundColor of field "qsRecvPassCap" to kClrInkSoft
   qsField "qsRecvPass", "656,212,1064,236", false
   -- =============== RIGHT: TRANSFERS & SHARES ===============
   -- One actionable list of everything live: downloads, code seeds, and Tor/web pages.
   -- Click a row to select it, then Copy code (re-fetch that share's code) or Stop it.
   -- Multiple code shares run at once - each is its own selectable, stoppable row.
   qsPanel "qsXferPanel", "640,256,1080,474"
   qsHdr "qsXferSec", "Transfers & shares", "656,268,940,292"
   -- the head's default left margin (8) lands within 1px of the list body's text
   -- origin (1px border + 6px margin), so the columns line up without magic
   qsLabel "qsXferHead", "Name" & tab & "Direction" & tab & "Progress", "655,298,1064,316", 9
   set the tabStops of field "qsXferHead" to "230,340"
   set the textFont of field "qsXferHead" to qsMonoFont()
   set the foregroundColor of field "qsXferHead" to kClrInkMute
   qsList "qsXfers", "656,318,1064,404", false
   set the tabStops of field "qsXfers" to "230,340"
   set the textFont of field "qsXfers" to qsMonoFont()
   set the textSize of field "qsXfers" to 10
   put empty into sLastXferRows   -- freshly (re)built list: force the next refresh to paint
   -- the live detail strip: peers/seeds/rates/ratio for the SELECTED row, fed
   -- by qsRefreshXfers from status data the repaint loop already fetches
   qsLabel "qsXferInfo", "", "656,408,1064,430", 9
   set the textFont of field "qsXferInfo" to qsMonoFont()
   set the foregroundColor of field "qsXferInfo" to kClrInkSoft
   put "Click a row above for live details." into field "qsXferInfo"
   -- per-row management: pick a row, then act on THAT share/transfer
   qsCap "qsXferHint", "Selected:", "656,438,728,460"
   qsButton "qsXferCopy", "Copy code", "734,434,838,462"
   qsButton "qsXferStop", "Stop", "846,434,918,462"
   qsButton "qsXferFolder", "Open folder", "926,434,1064,462"
   -- =============== RIGHT: ACTIVITY ===============
   qsPanel "qsActPanel", "640,486,1080,596"
   qsHdr "qsActSec", "Activity", "656,494,940,518"
   qsList "qsLog", "656,524,1064,584", true
   set the textSize of field "qsLog" to 9
   set the foregroundColor of field "qsLog" to kClrInkSoft
   -- slim status strip along the very bottom: connection state left, live rates right
   qsLabel "qsStatus", "", "20,604,700,634", 10
   set the foregroundColor of field "qsStatus" to kClrInkSoft
   qsLabel "qsRates", "", "700,604,1080,634", 10
   set the foregroundColor of field "qsRates" to kClrInkSoft
   set the textAlign of field "qsRates" to "right"
   qsAddTips
   qsOnionPill
   qsSyncMethod
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
   -- the chrome layer (cards, chips, the drop target) is graphics since ui-2027-02
   repeat with tI = the number of graphics of this card down to 1
      if the short name of graphic tI of this card begins with "qs" then
         delete graphic tI of this card
      end if
   end repeat
   unlock screen
end qsClearGeneratedUI

command qsLabel pName, pText, pRect, pSize
   local tTop
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
   set the foregroundColor of field pName to kClrInk
   put pText into field pName
   -- OXT pass 1 taught us never to GUESS font metrics: hand-sized label rects
   -- (and a single-number `set the margins to 0`, which OXT ignored) clipped the
   -- bottom of every line on Windows. Ask the engine instead: grow the field to
   -- its own formattedHeight (top edge pinned), so a label can never be shorter
   -- than the text it holds, whatever the platform's line height and margins.
   -- Empty labels (qsSharing, the status strip) keep their given rect: they
   -- receive text later and must hold a fixed multi-line/strip height.
   if pText is not empty then
      set the itemDelimiter to comma
      put item 2 of pRect into tTop
      set the height of field pName to the formattedHeight of field pName
      set the top of field pName to tTop
   end if
end qsLabel

-- Create-or-reuse a named graphic: the chrome layer (cards, the Tor chip, the
-- drop target, dividers). Created BEFORE the controls that sit on it, so it stays
-- behind them in z-order. roundRect + antialiased by default; callers restyle.
command qsGfx pName, pRect
   if there is no graphic pName then
      create graphic
      set the name of the last graphic to pName
   end if
   set the rect of graphic pName to pRect
   set the style of graphic pName to "roundRect"
   set the antialiased of graphic pName to true
end qsGfx

-- A dashboard card: a rounded, hairline-bordered, softly shadowed panel placed
-- BEHIND a group of controls. It only groups a step visually; clicks on it fall
-- through to `default: pass mouseUp`.
command qsPanel pName, pRect
   qsGfx pName, pRect
   set the roundRadius of graphic pName to 14
   set the filled of graphic pName to true
   set the backgroundColor of graphic pName to kClrCard
   set the lineSize of graphic pName to 1
   -- a graphic strokes its outline in the foregroundColor; borderColor is set too
   -- so whichever the engine honours, the hairline lands (VERIFY on the OXT pass)
   set the foregroundColor of graphic pName to kClrCardLine
   set the borderColor of graphic pName to kClrCardLine
   qsSoftShadow pName
end qsPanel

-- A soft drop shadow under a card. Graphic effects are an LC-9-era feature, so
-- this is a PURE enhancement: an engine without them just skips it (the try)
-- and the hairline border still separates the card from the page.
command qsSoftShadow pName
   local tShadow, tErr
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
end qsSoftShadow

-- A small filled circle holding a step number ("1" Send, "2" Receive), so the two
-- entry points pop without shouting: accent disc + centered white digit on top.
command qsBadge pName, pRect, pDigit
   local tL, tT, tR, tB
   set the itemDelimiter to comma
   put item 1 of pRect into tL
   put item 2 of pRect into tT
   put item 3 of pRect into tR
   put item 4 of pRect into tB
   qsGfx (pName & "Bg"), pRect
   set the roundRadius of graphic (pName & "Bg") to (tB - tT)   -- radius caps = circle
   set the filled of graphic (pName & "Bg") to true
   set the backgroundColor of graphic (pName & "Bg") to kClrAccent
   set the lineSize of graphic (pName & "Bg") to 0
   -- the digit field auto-sizes in qsLabel; center it on the disc by MEASURED
   -- height (pass 1 clipped the digit clean off by trusting guessed metrics)
   qsLabel pName, pDigit, pRect, 11
   set the textStyle of field pName to "bold"
   set the foregroundColor of field pName to kClrBandText
   set the textAlign of field pName to "center"
   set the top of field pName to (tT + (((tB - tT) - the height of field pName) div 2))
end qsBadge

-- A bold, dark section header sitting on a card (e.g. "Send a file or folder").
command qsHdr pName, pText, pRect
   qsLabel pName, pText, pRect, 14
   set the textStyle of field pName to "bold"
end qsHdr

-- A small, muted caption (radio descriptions, hints, the MORE OPTIONS divider).
command qsCap pName, pText, pRect
   qsLabel pName, pText, pRect, 10
   set the foregroundColor of field pName to kClrInkMute
end qsCap

command qsField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
   -- flat "modern input" chrome instead of the engine's sunken-3D default
   set the threeD of field pName to false
   set the borderWidth of field pName to 1
   set the borderColor of field pName to kClrFieldLine
   set the opaque of field pName to true
   set the backgroundColor of field pName to kClrCard
   -- 4-item margins form ONLY: OXT ignored the single-number form on pass 1
   set the margins of field pName to "6,6,6,6"
   set the textSize of field pName to 11
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
   qsField pName, pRect, true
   set the vScrollbar of field pName to true
   set the borderColor of field pName to kClrCardLine
   if pIsLog then
      set the listBehavior of field pName to false
   else
      set the listBehavior of field pName to true
   end if
end qsList

-- The platform's own terminal face for codes / links / the transfers table, so
-- the monospace surfaces look native instead of typewriter-Courier. If a face is
-- missing the engine substitutes its default - a soft, safe failure.
function qsMonoFont
   if the platform is "MacOS" then
      return "Menlo"
   else if the platform is "Win32" then
      return "Consolas"
   end if
   return "DejaVu Sans Mono"
end qsMonoFont

-- Paint the drop target for its three states - "idle", "hover" (pointer over it)
-- and "hot" (an OS drag is over the window) - in ONE place, so the drag handlers,
-- the hover handlers and the build cannot disagree about the colors.
command qsDropPaint pMode
   if there is no graphic "qsDropBg" then
      exit qsDropPaint
   end if
   if pMode is "hot" then
      set the backgroundColor of graphic "qsDropBg" to kClrDropHot
      set the foregroundColor of graphic "qsDropBg" to kClrAccent
      set the borderColor of graphic "qsDropBg" to kClrAccent
   else if pMode is "hover" then
      set the backgroundColor of graphic "qsDropBg" to kClrDropHot
      set the foregroundColor of graphic "qsDropBg" to kClrDropLine
      set the borderColor of graphic "qsDropBg" to kClrDropLine
   else
      set the backgroundColor of graphic "qsDropBg" to kClrDropBg
      set the foregroundColor of graphic "qsDropBg" to kClrDropLine
      set the borderColor of graphic "qsDropBg" to kClrDropLine
   end if
end qsDropPaint

-- Write the drop zone's two lines (headline + muted detail). A wholesale
-- `set the text` resets chunk styling, so line 2's smaller/muted look is
-- re-applied here every time - the ONE place drop-zone text is ever written.
command qsDropText pLine1, pLine2
   if there is no field "qsDrop" then
      exit qsDropText
   end if
   set the text of field "qsDrop" to (pLine1 & return & pLine2)
   set the textSize of line 2 of field "qsDrop" to 10
   set the foregroundColor of line 2 of field "qsDrop" to kClrInkMute
end qsDropText

-- The method-aware idle hint: the hero control narrates what a drop WILL do
-- under the currently selected method. Repainted by qsSyncMethod on every
-- method change, and by a short timer after a share preview (qsShareFile).
command qsDropHint
   if sTorSend is "true" then
      qsDropText "Drag & drop to send privately over Tor", \
         "both IP addresses stay hidden - or click to browse (the buttons below always work)"
   else if sWebShare is "true" then
      qsDropText "Drag & drop to share as a web link", \
         "opens in any browser, no app needed - or click to browse (the buttons below always work)"
   else
      qsDropText "Drag & drop a file or folder here", \
         "you get a short code to send - or click to browse (the buttons below always work)"
   end if
end qsDropHint

-- Flash a Copy button's label to "Copied!" for a beat, then restore it - the
-- feedback lands AT the pointer instead of only in the far-away Activity log.
-- The original label rides a custom property so any button can flash.
command qsCopyFlash pBtn
   if there is no button pBtn then
      exit qsCopyFlash
   end if
   if the uRealLabel of button pBtn is empty then
      set the uRealLabel of button pBtn to the label of button pBtn
   end if
   set the label of button pBtn to "Copied!"
   send ("qsCopyFlashReset" && quote & pBtn & quote) to me in 1200 milliseconds
end qsCopyFlash

command qsCopyFlashReset pBtn
   if there is no button pBtn then
      exit qsCopyFlashReset
   end if
   if the uRealLabel of button pBtn is not empty then
      set the label of button pBtn to the uRealLabel of button pBtn
   end if
end qsCopyFlashReset

command qsAddTips
   set the tooltip of field "qsSendPass" to "Leave blank to share normally. Type a passphrase to ENCRYPT the file; tell your friend the passphrase separately."
   set the tooltip of button "qsPassSuggest" to "Fill in a strong random passphrase (16 characters, no confusable letters). Send it to your friend separately from the code - a phone call or a different app is ideal."
   set the tooltip of field "qsDrop" to "Drag a file or folder here from your desktop or a file window. If a drag will not register (it can be unreliable from a file window), use the Choose buttons below - they always work."
   set the tooltip of button "qsChooseFile" to "Open a dialog to pick a file to share, using the method selected above. Always works, even when a drag will not register."
   set the tooltip of button "qsChooseFolder" to "Open a dialog to pick a FOLDER to share. Over a web link or Tor it becomes a browsable page; as a share code the whole folder is sent. Always works, even when a drag will not register."
   set the tooltip of field "qsCode" to "Your file's share code. Click the code (or the Copy button) to copy it, then send it to your friend."
   set the tooltip of button "qsCopy" to "Copy the share code to the clipboard."
   set the tooltip of field "qsRecvCode" to "Paste the code a friend gave you here."
   set the tooltip of field "qsRecvPass" to "If your friend locked the file, type the passphrase they gave you here BEFORE clicking Download."
   set the tooltip of button "qsGet" to "Download the file for that code into your newQuickShare folder."
   set the tooltip of field "qsXfers" to "Everything live: downloads, the files you are sharing by code (each is its own row - you can run many at once), and any Tor or web page. Click a row to select it, then Copy code or Stop."
   set the tooltip of button "qsXferCopy" to "Copy the share code for the selected row back to the clipboard - handy when several shares are running and you need an older one's code again. For a download row this copies a magnet link (works in any torrent client)."
   set the tooltip of button "qsXferStop" to "Stop the selected item: stop sharing a file (peers can no longer download it), or cancel a download in progress. Your original files are never deleted."
   set the tooltip of button "qsXferFolder" to "Open your newQuickShare download folder in the file manager - every received file lands there."
   set the tooltip of field "qsXferInfo" to "Live details for the selected row: connected peers and seeds, transfer rates, upload ratio, and bytes done."
   set the tooltip of button "qsMethodCode" to "The classic way: a normal peer-to-peer BitTorrent share. Give your friend the code; the transfer resumes if interrupted. Your IP is visible to peers."
   set the tooltip of button "qsMethodTor" to "Send over Tor: both IP addresses are hidden and NO torrent is created (best for small, sensitive files). Add a passphrase to also encrypt and authenticate. Drag a FOLDER to serve it as a browsable Tor web page - open the link in Tor Browser."
   set the tooltip of button "qsMethodWeb" to "Serve the file or folder over the plain web: the recipient just opens a link in any browser, no app needed. The router port is opened automatically (UPnP) and the link carries a secret token. Fast, but your IP is visible and the download is not encrypted - use Tor for privacy."
   set the tooltip of button "qsWebCheck" to "Only for a PLAINTEXT file shared over Tor: also let anyone with Tor Browser download it at a web link (both IPs stay hidden; the file is not encrypted and the sender is not verified). Leave the passphrase empty to use this."
   set the tooltip of field "qsWebLink" to "The browser download link for this share. Click the link (or Copy) to copy it; open it in the recipient's browser."
   set the tooltip of button "qsWebCopy" to "Copy the web download link to the clipboard."
   set the tooltip of button "qsEditToggle" to "Make the web-shared FOLDER editable from a browser - but ONLY from a device on your own local network (never over the internet or Tor). Set an edit password first. Visit the shared link with /_edit added on the end to open the editor. Needs cryptoXT (org.openxtalk.library.sodium)."
   set the tooltip of field "qsEditPass" to "A password you choose to unlock the live editor. Anyone on your LAN who opens the /_edit page must type it before they can change files. Needs cryptoXT installed."
   set the tooltip of field "qsEditHint" to "The live editor only answers devices on your local network; internet and Tor visitors can view the site but never reach the editor."
   set the tooltip of field "qsTorPill" to "Status of your local Tor connection. 'ready' means anonymous sends and receives will work. If it says 'not running', start Tor (or Tor Browser) on this computer - control port 9051 or 9151 - and it connects by itself."
   -- the radio captions are click-through to the same choice, so they share the
   -- radio's tooltip (one source of truth, no drift)
   set the tooltip of field "qsMethodCodeD" to the tooltip of button "qsMethodCode"
   set the tooltip of field "qsMethodTorD" to the tooltip of button "qsMethodTor"
   set the tooltip of field "qsMethodWebD" to the tooltip of button "qsMethodWeb"
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
   -- UPnP + NAT-PMP: let libtorrent open a router port automatically for the clearweb
   -- direct-link feature (btMapPort). On by default in libtorrent, but set explicitly
   -- so the port mappers are certainly active.
   btSetBool sSession, "enable_upnp", true
   btSetBool sSession, "enable_natpmp", true
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
   put "false" into sWebShare
   -- the built-in demo route: a hosted app (or curl) can GET /_qs/info for live
   -- share metadata as JSON - the pattern to copy for your own routes. Register
   -- more with qsHttpRoute "POST", "/api/thing", "myHandler" (handler in this
   -- script: on myHandler pConn, pRequest ... qsHttpReply pConn, 200, ...).
   put empty into sHttpRoutes
   qsHttpRoute "GET", "/_qs/info", "qsInfoRoute"
   -- the live web editor (Phase C). Always registered, but every handler refuses unless
   -- the editor is enabled AND the caller is LAN-local (see qsEditReachable), so these
   -- routes are invisible (404) to Tor and to public clearweb visitors.
   put "false" into sEditOn
   put empty into sEditSalt
   put empty into sEditVerify
   put empty into sEditSession
   qsHttpRoute "GET", "/_edit", "qsEditPageRoute"
   qsHttpRoute "POST", "/_edit/login", "qsEditLoginRoute"
   qsHttpRoute "GET", "/_edit/api/list", "qsEditListRoute"
   qsHttpRoute "GET", "/_edit/api/read", "qsEditReadRoute"
   qsHttpRoute "PUT", "/_edit/api/write", "qsEditWriteRoute"
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
   -- repaint the method-driven UI now that sCanEncrypt + the method flags are known:
   -- qsBuild ran qsSyncMethod BEFORE this point, when sCanEncrypt was still empty, so
   -- without this the encrypt row would sit hidden + falsely captioned "install cryptoXT".
   qsSyncMethod
   -- drop keyboard focus: without this the engine focuses the first traversal
   -- control (the Share code radio) and draws a focus box around it at open
   focus on nothing
   -- a share code may already be on the clipboard (copy in chat -> open the app)
   qsClipboardSuggest
   send "qsPollOnce" to me in 0 milliseconds
   send "qsDashOnce" to me in 800 milliseconds
end qsStart

command qsStop
   local tKey, tErr
   put "false" into sPolling
   qsOnionStop
   qsStopClearweb
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
   -- reset the My Shares bookkeeping too: torrent handle values restart at a fixed
   -- number for a fresh session, so a stale handle->code entry left here would make a
   -- reopened session's first download look like a seed with someone else's code.
   put empty into sShareCodeByHandle
   put empty into sXferRow
   put empty into sXferSel
   put empty into sStallSince
   put empty into sStallWarned
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
   local tData, tH, tHash, tParent, tName, tPass, tSz
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
   -- Narrate the pick in the drop zone AT ONCE: packaging/encrypting a big file
   -- blocks the single engine thread with no other feedback. Text-only, and the
   -- zone falls back to its method hint on a short timer, so no share branch
   -- (with its many early exits) has to remember to restore it.
   if there is a folder pPath then
      qsDropText ("Sharing the folder: " & tName), \
         "setting up - a big folder can take a moment"
   else
      put qsFileSize(pPath) into tSz
      if tSz is a number and tSz > 0 then
         qsDropText ("Sharing: " & tName & " (" & qsBytes(tSz) & ")"), \
            "setting up - a big file can take a moment"
      else
         qsDropText ("Sharing: " & tName), "setting up..."
      end if
   end if
   send "qsDropHint" to me in 6000 milliseconds
   -- yield once so the preview can paint before the blocking work (VERIFY
   -- on-engine that a zero wait flushes the screen; harmless if it does not)
   wait 0 milliseconds
   -- starting any NON-web share replaces a running clearweb server (so switching
   -- transports does not leave its listener + port mapping orphaned)
   if sCwActive is "true" and sWebShare is not "true" then
      qsStopClearweb
   end if
   -- Direct web link (clearweb) branch: serve the file/folder over a plain LiveCode
   -- socket HTTP server the recipient opens in any browser. No torrent, no Tor. A
   -- dropped passphrase does not apply (a browser cannot decrypt); the unguessable
   -- link token is the access control.
   if sWebShare is "true" then
      if tPass is not empty then
         qsLog "A direct web link is served to a plain browser, which cannot decrypt - sharing UNENCRYPTED. Use Tor + a passphrase for a private, encrypted transfer."
      end if
      qsStartClearweb pPath, tName
      exit qsShareFile
   end if
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
         -- a FOLDER over Tor is served as a browsable web page (no encryption: a
         -- browser cannot decrypt, so this is cleartext over the onion). A dropped
         -- passphrase does not apply to a folder share.
         if tPass is not empty then
            qsLog "A folder is shared as a browsable Tor web page, which a browser cannot decrypt - sharing it UNENCRYPTED (both IPs still hidden). Drop a single file to encrypt."
         end if
         qsStartOnionFolder pPath, tName
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
      put tHash into sShareCodeByHandle[tH]   -- retain THIS share's code (My Shares)
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
      put sShareCode into sShareCodeByHandle[tH]   -- retain THIS share's code (My Shares)
      set the text of field "qsCode" to sShareCode
      set the text of field "qsSharing" to ("Sharing " & quote & tName & quote & " ENCRYPTED - send the code AND tell your friend the passphrase separately.")
      qsLog "Encrypted" && quote & tName & quote & ". Send the code (Copy) AND the passphrase - your friend needs both."
   end if
end qsShareFile

-- Always-reliable pickers behind the two "Choose..." buttons (and a click on the drag
-- zone). Separate file and folder choosers open the native dialog DIRECTLY - no "file or
-- folder?" prompt to wade through - so a user is never stuck when an OS drag will not
-- register (drag delivery is engine/source-dependent). Both run the SAME qsShareFile
-- path as a drop, honouring the currently selected share method.
command qsChooseFile
   answer file "Choose a file to share:"
   if it is empty then
      exit qsChooseFile
   end if
   qsShareFile it
end qsChooseFile

command qsChooseFolder
   answer folder "Choose a folder to share:"
   if it is empty then
      exit qsChooseFolder
   end if
   qsShareFile it
end qsChooseFolder

command qsCopyCode
   if field "qsCode" is empty then
      qsLog "Share a file first to get a code."
      exit qsCopyCode
   end if
   set the clipboardData["text"] to field "qsCode"
   qsCopyFlash "qsCopy"
   qsLog "Code copied. Send it to your friend by email, chat, anywhere."
end qsCopyCode

-- Fill the Encrypt field with a strong, phone-typeable passphrase: 4 groups of
-- 4 from an unambiguous alphabet (no 0/O, 1/l/i, or 8/B look-alikes), bytes
-- from libsodium's CSPRNG. ~78 bits before the tiny mod-30 bias - far beyond
-- what an offline Argon2id guess could ever chew through for a file share.
-- Hidden alongside the passphrase field when encryption cannot work.
command qsSuggestPass
   local tBytes, tOut, tI, tN
   if not sCanEncrypt then
      qsLog "Passphrase suggestions need cryptoXT (org.openxtalk.library.sodium)."
      exit qsSuggestPass
   end if
   put sxRandomBytes(16) into tBytes
   put "" into tOut
   repeat with tI = 1 to 16
      put byteToNum(byte tI of tBytes) into tN
      put char ((tN mod 30) + 1) of "abcdefghjkmnpqrstuvwxyz2345679" after tOut
      if tI mod 4 is 0 and tI < 16 then
         put "-" after tOut
      end if
   end repeat
   put tOut into field "qsSendPass"
   qsLog "Suggested a strong passphrase. Tell it to your friend SEPARATELY from the code - a call or a different app is ideal."
end qsSuggestPass

-- ---- clipboard auto-detect (the copy -> open -> Enter receive flow) ----------
-- Does this text LOOK like something the Receive box accepts? A bare 40/64-hex
-- info-hash, a locked (BTXQS1:) or Tor (BTXTOR1:) code, or a magnet link.
function qsLooksLikeCode pText
   local tHex, tI
   if pText begins with kCodePrefix or pText begins with kTorCodePrefix then
      return true
   end if
   if pText begins with "magnet:" then
      return true
   end if
   if the number of chars of pText is not 40 and the number of chars of pText is not 64 then
      return false
   end if
   put toLower(pText) into tHex
   repeat with tI = 1 to the number of chars of tHex
      if char tI of tHex is not in "0123456789abcdef" then
         return false
      end if
   end repeat
   return true
end qsLooksLikeCode

-- Is this a code WE minted (and is still live)? Offering the user a download
-- of their own outbound share - fresh on the clipboard from the Copy button -
-- would be nonsense, so those never pre-fill the Receive box.
function qsIsOwnCode pCode
   local tK
   if pCode is not empty and pCode is sShareCode then
      return true
   end if
   repeat for each key tK in sShareCodeByHandle
      if sShareCodeByHandle[tK] is pCode then
         return true
      end if
   end repeat
   if sActiveShare["code"] is pCode then
      return true
   end if
   return false
end qsIsOwnCode

-- If the clipboard holds something code-shaped and the Receive box is empty,
-- pre-fill it so receiving collapses to copy -> open -> Enter. Runs at start
-- and whenever the window comes back to the front (resumeStack). Polite by
-- construction: never overwrites user input, offers each clipboard value only
-- once, and ignores our own outbound codes. The try guards the clipboard read
-- (it can fail transiently when another app holds the clipboard on Windows).
command qsClipboardSuggest
   local tClip, tErr
   if there is no field "qsRecvCode" then
      exit qsClipboardSuggest
   end if
   put "" into tClip
   try
      put qsTrim(the clipboardData["text"]) into tClip
   catch tErr
      exit qsClipboardSuggest
   end try
   if tClip is empty or tClip is sClipSuggested then
      exit qsClipboardSuggest
   end if
   put tClip into sClipSuggested   -- one offer per value, even if it is declined
   if not qsLooksLikeCode(tClip) then
      exit qsClipboardSuggest
   end if
   if qsIsOwnCode(tClip) then
      exit qsClipboardSuggest
   end if
   if qsTrim(field "qsRecvCode") is not empty then
      exit qsClipboardSuggest
   end if
   put tClip into field "qsRecvCode"
   qsLog "Found a share code on your clipboard - check it, then click Download (or press Enter)."
end qsClipboardSuggest

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
   local tIH, tDisp, tDir, tK, tE, tProg, tRemain, tSelLine, tPrevLine
   local tNow, tPeers, tStalled, tClr, tLive, tSelStat, tId, tSelType, tSelKey
   local tInfo, tRatio, tSavedID
   if sSession is 0 or sSession is empty then
      exit qsRefreshXfers
   end if
   put the milliseconds into tNow   -- one clock read per pass (the perf playbook)
   -- snapshot the user's current selection BY IDENTITY before we rebuild the map, so
   -- the highlight follows the same transfer even as rows reorder or the list is
   -- retyped wholesale each pass. Reads the live listBehavior hilite (set the instant
   -- the user clicked), so it does not depend on a mouseUp reaching us.
   put the hilitedLines of field "qsXfers" into tPrevLine
   if tPrevLine is a number and tPrevLine > 0 and sXferRow[tPrevLine] is not empty then
      put sXferRow[tPrevLine] into sXferSel
   end if
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put 0 into tLineNum
   put empty into sXferRow   -- rebuild the row -> identity map each pass (rows reorder)
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put ("torrent|" & tH) into sXferRow[tLineNum]   -- this row -> its torrent handle
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
      -- compact live stats in place of a text bar: percent, rate, and (downloading) ETA
      put tPct & "%" into tProg
      if tDir contains "receiving" then
         if tS["downloadRate"] is a number and tS["downloadRate"] > 0 then
            put tProg && qsRateShort(tS["downloadRate"]) into tProg
            if tS["totalWanted"] is a number and tS["totalDone"] is a number then
               put (tS["totalWanted"] - tS["totalDone"]) into tRemain
               if tRemain > 0 then
                  put tProg && qsEtaShort(tRemain / tS["downloadRate"]) into tProg
               end if
            end if
         end if
      else if tDir contains "sending" then
         if tS["uploadRate"] is a number and tS["uploadRate"] > 0 then
            put tProg && qsRateShort(tS["uploadRate"]) into tProg
         end if
      end if
      -- stall coaching: a receive-side row at ZERO peers for 45s flips its
      -- progress cell to plain English and logs the why ONCE per torrent (a
      -- seed with no peers is just idle, so "sending" rows are exempt)
      put false into tStalled
      put tS["numPeers"] into tPeers
      put 1 into tLive[tH]
      if not (tDir contains "sending") then
         if tPeers is a number and tPeers is 0 then
            if sStallSince[tH] is empty then
               put tNow into sStallSince[tH]
            else if (tNow - sStallSince[tH]) > 45000 then
               put true into tStalled
               put "waiting for your friend..." into tProg
               if sStallWarned[tH] is not "true" then
                  put "true" into sStallWarned[tH]
                  qsLog "No peers for" && quote & tDisp & quote && "yet - the sender must keep their newQuickShare window open. The transfer starts by itself once they are online."
               end if
            end if
         else if sStallSince[tH] is not empty then
            delete variable sStallSince[tH]
         end if
      end if
      -- the row's state color (applied after the retype, chunk-level)
      if tS["error"] is not empty then
         put kClrRowErr into tClr[tLineNum]
      else if tStalled then
         put kClrInkMute into tClr[tLineNum]
      else if tDir contains "sending" then
         put kClrRowSend into tClr[tLineNum]
      else if tDir contains "receiving" then
         put kClrAccent into tClr[tLineNum]
      else
         put kClrInkMute into tClr[tLineNum]
      end if
      -- keep the SELECTED torrent's full status for the detail strip below
      -- (no extra FFI call: this pass already fetched it)
      if sXferSel is ("torrent|" & tH) then
         put tS into tSelStat
      end if
      put qsTrunc(tDisp, 26) & tab & tDir & tab & tProg & return after tRows
      add tS["downloadRate"] to tDown
      add tS["uploadRate"] to tUp
   end repeat
   -- prune stall bookkeeping for torrents that no longer exist (the keys list
   -- is snapshotted once, so deleting inside the loop is safe)
   repeat for each line tK in the keys of sStallSince
      if tLive[tK] is empty then
         delete variable sStallSince[tK]
         if sStallWarned[tK] is not empty then
            delete variable sStallWarned[tK]
         end if
      end if
   end repeat
   -- append anonymous (Tor) transfers; they have NO torrent handle, so the torrent
   -- loop above never sees them. Same "name TAB dir TAB bar" row format.
   repeat for each key tK in sOnionXfers
      add 1 to tLineNum
      put ("onion|" & tK) into sXferRow[tLineNum]   -- this row -> its onion stream
      put sOnionXfers[tK] into tE
      put tE["dir"] & " via Tor" into tDir
      if tE["enc"] is "true" then
         put tDir && "(locked)" into tDir
      end if
      if tE["state"] is "connecting" or tE["total"] is 0 then
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & "connecting..." & return after tRows
         put kClrWarn into tClr[tLineNum]
      else if tE["state"] is "done" then
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & "done" & return after tRows
         put kClrRowSend into tClr[tLineNum]
      else if tE["state"] is "error" then
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & "stopped" & return after tRows
         put kClrRowErr into tClr[tLineNum]
      else
         put (the round of (tE["got"] / tE["total"] * 1000) / 10) into tPct
         put qsTrunc(tE["name"], 26) & tab & tDir & tab & tPct & "%  " & qsBytes(tE["got"]) & return after tRows
         if tE["dir"] is "receiving" then
            put kClrAccent into tClr[tLineNum]
         else
            put kClrRowSend into tClr[tLineNum]
         end if
      end if
   end repeat
   -- a folder web share has no torrent and no per-file transfer rows; show one status
   -- line so the Transfers panel is not misleadingly empty while it is serving.
   if sActiveShare["kind"] is "folder" and sActiveShare["revealed"] is "true" then
      add 1 to tLineNum
      put "torweb|" into sXferRow[tLineNum]        -- the one Tor folder web page
      put qsTrunc(sActiveShare["name"], 26) & tab & "web via Tor" & tab & "serving (open the link)" & return after tRows
      put kClrRowSend into tClr[tLineNum]
   end if
   if sCwActive is "true" then
      add 1 to tLineNum
      put "web|" into sXferRow[tLineNum]           -- the one clearweb share
      put qsTrunc(sCwName, 26) & tab & "direct web" & tab & "serving (open the link)" & return after tRows
      put kClrRowSend into tClr[tLineNum]
   end if
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   if tLineNum is 0 then
      put "Nothing yet. Drag a file to share, or paste a code to download." into tRows
      put kClrInkMute into tClr[1]
   end if
   -- Only RETYPE the list when its content actually changed. A wholesale field relayout
   -- + redraw every poll is the biggest avoidable UI cost (the OXT perf playbook), and -
   -- more importantly here - a repaint mid-drag can compete with the OS drop delivery and
   -- make a drop intermittently fail to register. An idle set of shares produces the same
   -- tRows every pass, so we skip it entirely; an active transfer (its % changes) still
   -- updates as before.
   if tRows is not sLastXferRows then
      put tRows into sLastXferRows
      lock screen
      set the text of field "qsXfers" to tRows
      -- keep the user's selection pinned to the SAME item across this repaint: rows
      -- reorder (the torrent enumeration is not stable) and a plain hilitedLine would
      -- drift to a different transfer. Re-find the selected identity by value; if the
      -- item has ended (no row carries it), drop the selection.
      if sXferSel is not empty then
         put 0 into tSelLine
         repeat for each key tK in sXferRow
            if sXferRow[tK] is sXferSel then
               put tK into tSelLine
               exit repeat
            end if
         end repeat
         if tSelLine > 0 then
            set the hilitedLines of field "qsXfers" to tSelLine
         else
            -- the selected item ended: drop BOTH the tracked identity and the field's
            -- lingering highlight. Retyping the list text does not reset the hilite, so a
            -- stale highlight would be re-read next pass and re-bound to whatever
            -- unrelated transfer now sits on that line number (a wrong Stop/Copy target).
            put empty into sXferSel
            set the hilitedLines of field "qsXfers" to empty
         end if
      end if
      -- per-row state colors, chunk-level. Only runs when the text was retyped:
      -- chunk colors survive between repaints, so an idle list costs nothing.
      repeat with tI = 1 to the number of lines of tRows
         if tClr[tI] is not empty then
            set the foregroundColor of line tI of field "qsXfers" to tClr[tI]
         end if
      end repeat
      unlock screen
   end if
   -- the live detail strip for the SELECTED row: novices get a sentence, power
   -- users get peers/seeds/rates/ratio. Runs every pass (a selection can change
   -- without the row text changing), but only retypes the field on a change.
   put qsSelectedIdentity() into tId
   put "Click a row above for live details." into tInfo
   if tId is not empty then
      put the itemDelimiter into tSavedID
      set the itemDelimiter to "|"
      put item 1 of tId into tSelType
      put item 2 of tId into tSelKey
      set the itemDelimiter to tSavedID
      switch tSelType
         case "torrent"
            if tSelStat is not an array then
               -- selection landed between passes; one small status call catches up
               put btTorrentStatus(tSelKey) into tSelStat
            end if
            if tSelStat["name"] is empty then
               put "Fetching details from the swarm..." into tInfo
            else
               put ("peers " & tSelStat["numPeers"] & " (" & tSelStat["numSeeds"] & " seeds)" \
                  & "   down " & qsRateShort(tSelStat["downloadRate"]) \
                  & "   up " & qsRateShort(tSelStat["uploadRate"])) into tInfo
               if tSelStat["totalDone"] is a number and tSelStat["totalDone"] > 0 \
                     and tSelStat["allTimeUpload"] is a number then
                  put (the round of (tSelStat["allTimeUpload"] / tSelStat["totalDone"] * 10) / 10) into tRatio
                  put tInfo & "   ratio " & tRatio into tInfo
               end if
               if tSelStat["totalWanted"] is a number and tSelStat["totalWanted"] > 0 then
                  put tInfo & "   " & qsBytes(tSelStat["totalDone"]) & " of " \
                     & qsBytes(tSelStat["totalWanted"]) into tInfo
               end if
            end if
            break
         case "onion"
            put sOnionXfers[tSelKey] into tE
            put ("via Tor - " & tE["dir"] & ", " & qsBytes(tE["got"]) & " of " & qsBytes(tE["total"])) into tInfo
            break
         case "torweb"
            put "Serving a folder page over Tor - open the link in Tor Browser." into tInfo
            break
         case "web"
            put ("Serving over the web: " & sCwLink) into tInfo
            break
         default
            break
      end switch
   end if
   if tInfo is not the text of field "qsXferInfo" then
      set the text of field "qsXferInfo" to tInfo
   end if
   put btDhtState(sSession) into tD
   put tD["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("Connected to the peer network (" & tNodes & " DHT nodes)") into tStat
   else
      put "Connecting to the peer network..." into tStat
   end if
   -- state on the left, live rates on the right (two fields, not spacing hacks)
   set the text of field "qsStatus" to tStat
   set the text of field "qsRates" to ("sending " & qsBytes(tUp) & "/s" & "      " & \
      "receiving " & qsBytes(tDown) & "/s")
end qsRefreshXfers

-- ---- My Shares: per-row selection, copy, and stop --------------------------
-- The Transfers list is the single actionable surface. Each row was tagged with a
-- stable "type|key" identity in qsRefreshXfers (sXferRow); these handlers resolve the
-- selected row and act on exactly that item, so any number of concurrent code shares
-- (plus the single Tor and single web share) can be managed independently.

-- Record the clicked row's identity immediately (belt-and-suspenders with the
-- top-of-refresh snapshot, so the selection is captured even before the next repaint).
command qsXferClick
   local tLine
   put the hilitedLines of field "qsXfers" into tLine
   if tLine is a number and tLine > 0 and sXferRow[tLine] is not empty then
      put sXferRow[tLine] into sXferSel
   end if
end qsXferClick

-- Resolve the identity the user has selected RIGHT NOW: prefer the live hilite mapped
-- through the current row map (valid between repaints), else the persisted selection.
function qsSelectedIdentity
   local tLine
   put the hilitedLines of field "qsXfers" into tLine
   if tLine is a number and tLine > 0 and sXferRow[tLine] is not empty then
      return sXferRow[tLine]
   end if
   return sXferSel
end qsSelectedIdentity

command qsCopySelected
   local tId, tType, tKey, tCode, tSavedID
   put qsSelectedIdentity() into tId
   if tId is empty then
      qsLog "Click a row in Transfers & shares first, then Copy code."
      exit qsCopySelected
   end if
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "|"
   put item 1 of tId into tType
   put item 2 of tId into tKey
   set the itemDelimiter to tSavedID
   switch tType
      case "torrent"
         put sShareCodeByHandle[tKey] into tCode
         if tCode is empty then
            -- a download row has no minted code, but its info-hash IS the share:
            -- hand out a magnet link, which pastes into ANY torrent client (and
            -- into this app's own Receive box) - an ex-dead-end, now useful
            put btInfoHash(tKey) into tCode
            if tCode is empty then
               qsLog "No code for that row yet - it is still fetching its details from the swarm."
               exit qsCopySelected
            end if
            put "magnet:?xt=urn:btih:" & tCode & "&tr=" & qsTracker() into tCode
            set the clipboardData["text"] to tCode
            qsCopyFlash "qsXferCopy"
            qsLog "Copied that download as a magnet link - it works in any torrent client, or in this app's Receive box."
            exit qsCopySelected
         end if
         break
      case "onion"
         -- a receiving onion row is a download, not a share: it has no code to hand out
         if sOnionXfers[tKey]["dir"] is "receiving" then
            qsLog "That row is a Tor download you are receiving, not a share - there is no code to copy."
            exit qsCopySelected
         end if
         put sActiveShare["code"] into tCode
         break
      case "torweb"
         put sActiveShare["code"] into tCode
         break
      case "web"
         put sCwLink into tCode
         break
      default
         put empty into tCode
   end switch
   if tCode is empty then
      qsLog "There is no code to copy for that row yet."
      exit qsCopySelected
   end if
   set the clipboardData["text"] to tCode
   qsCopyFlash "qsXferCopy"
   qsLog "Copied that share's code to the clipboard. Send it to your friend."
end qsCopySelected

-- Open the newQuickShare download folder in the OS file manager - the #1
-- post-download question is "where did my file go?". `launch url` on a file:
-- URL hands the folder to the default handler (VERIFY on-engine per platform);
-- any failure still prints the exact path, so the button never dead-ends.
command qsOpenSaveFolder
   local tPath, tErr
   put qsSaveFolder() into tPath
   try
      if char 1 of tPath is "/" then
         launch url ("file://" & tPath)
      else
         launch url ("file:///" & tPath)   -- Windows drive paths lack the leading /
      end if
      if the result is not empty then
         qsLog "Could not open the folder automatically. Your downloads are in: " & tPath
      end if
   catch tErr
      qsLog "Could not open the folder automatically. Your downloads are in: " & tPath
   end try
end qsOpenSaveFolder

command qsStopSelected
   local tId, tType, tKey, tSavedID
   put qsSelectedIdentity() into tId
   if tId is empty then
      qsLog "Click a row in Transfers & shares first, then Stop."
      exit qsStopSelected
   end if
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "|"
   put item 1 of tId into tType
   put item 2 of tId into tKey
   set the itemDelimiter to tSavedID
   switch tType
      case "torrent"
         qsStopTorrentRow tKey
         break
      case "onion"
         -- an onion row is EITHER an incoming download (cancel just that stream) or the
         -- outgoing share's live send (stop the whole share). sActiveShare is the send
         -- side only, so a receiving row must NOT route there or it would kill an
         -- unrelated outgoing share and leave the download running.
         if sOnionXfers[tKey]["dir"] is "receiving" then
            if sOnionXfers[tKey]["state"] is "done" or sOnionXfers[tKey]["state"] is "error" then
               qsLog "That Tor download has already finished or stopped."
            else
               qsOnionRecvAbort tKey, "Tor download cancelled."
            end if
         else
            qsOnionStopShare
         end if
         break
      case "torweb"
         qsOnionStopShare
         break
      case "web"
         qsStopWebShare
         break
      default
         qsLog "That row cannot be stopped."
   end switch
   -- reflect the change at once (the row disappears / the panel updates)
   qsRefreshXfers
end qsStopSelected

-- Stop ONE torrent row: a code seed (peers can no longer fetch it) or a download in
-- progress (cancel it). Never deletes the user's own files. Cleans the per-hash and
-- per-handle bookkeeping so nothing leaks, and clears the left-panel code field only
-- if it still shows THIS share's now-dead code.
command qsStopTorrentRow pHandle
   local tS, tHash, tIsSeed, tComplete, tName, tPrompt, tRc, tEnc, tErr, tCode
   put btTorrentStatus(pHandle) into tS
   if tS is empty then
      qsLog "That item has already ended."
      exit qsStopTorrentRow
   end if
   put toLower(tS["infoHashV1"]) into tHash
   put sShareCodeByHandle[pHandle] into tCode      -- non-empty => a share we created
   put (tCode is not empty) into tIsSeed
   -- a RECEIVED file that has finished keeps seeding to the swarm; it is complete, so it
   -- must not be described as a cancellable "partial download".
   put (tS["progress"] is a number and tS["progress"] >= 1) into tComplete
   if tHash is not empty and sXferName[tHash] is not empty then
      put sXferName[tHash] into tName
   else
      put tS["name"] into tName
   end if
   if tName is empty then
      put "this item" into tName
   end if
   if tIsSeed then
      put ("Stop sharing " & quote & tName & quote & "?" & return & return & \
         "Peers will no longer be able to download it with its code. Your original file is NOT deleted.") into tPrompt
   else if tComplete then
      put ("Stop seeding " & quote & tName & quote & "?" & return & return & \
         "The complete file stays in your download folder; you just stop sharing it back to the swarm.") into tPrompt
   else
      put ("Cancel the download of " & quote & tName & quote & "?" & return & return & \
         "Any partial file already saved stays in your download folder for you to remove.") into tPrompt
   end if
   answer tPrompt with "Keep going" or "Stop"
   if it is not "Stop" then
      exit qsStopTorrentRow
   end if
   -- keep files: pDeleteFiles is false so a seed never deletes the user's original and
   -- a cancelled download leaves its partial for the user to decide on
   put btRemoveTorrent(sSession, pHandle, false) into tRc
   delete variable sShareCodeByHandle[pHandle]
   if tHash is not empty then
      put sTempEnc[tHash] into tEnc
      if tEnc is not empty then
         try
            if there is a file tEnc then
               delete file tEnc          -- our own ciphertext temp, safe to remove
            end if
         catch tErr
         end try
      end if
      delete variable sTempEnc[tHash]
      delete variable sXferName[tHash]
      delete variable sPendingKey[tHash]
      delete variable sPendingName[tHash]
   end if
   put empty into sXferSel
   if tCode is not empty and the text of field "qsCode" is tCode then
      set the text of field "qsCode" to ""
      set the text of field "qsSharing" to ""
   end if
   if tIsSeed then
      qsLog "Stopped sharing " & quote & tName & quote & "."
   else if tComplete then
      qsLog "Stopped seeding " & quote & tName & quote & "."
   else
      qsLog "Cancelled the download of " & quote & tName & quote & "."
   end if
end qsStopTorrentRow

-- Stop the single live Tor share (file OR folder web page). Mirrors the replace-previous
-- teardown in qsStartOnionShare: abort any live transfer first (so the file handle is
-- closed before we delete the .enc), remove the service, delete our temp, reset state.
command qsOnionStopShare
   local tErr, tCode
   if sActiveShare["service"] is empty then
      qsLog "There is no Tor share to stop."
      exit qsOnionStopShare
   end if
   answer ("Stop this Tor share?" & return & return & \
      "The private address stops working immediately, and any transfer in progress is cut off.") with "Keep going" or "Stop"
   if it is not "Stop" then
      exit qsOnionStopShare
   end if
   put sActiveShare["code"] into tCode
   if sActiveShare["stream"] is not empty then
      qsOnionServeAbort sActiveShare["stream"]
   end if
   try
      oxRemoveService sActiveShare["service"]   -- also closes any folder-server streams
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
   put empty into sXferSel
   if tCode is not empty and the text of field "qsCode" is tCode then
      set the text of field "qsCode" to ""
      set the text of field "qsWebLink" to ""
      set the text of field "qsSharing" to ""
   end if
   qsLog "Tor share stopped."
end qsOnionStopShare

-- Stop the single live web (clearweb) share. qsStopClearweb does the socket + port-map
-- teardown and (now) guards its own field clearing, so a coexisting code share's code
-- in the left panel survives.
command qsStopWebShare
   if not sCwActive then
      qsLog "There is no web share to stop."
      exit qsStopWebShare
   end if
   answer ("Stop this web share?" & return & return & \
      "The link stops working immediately and the router port is released.") with "Keep going" or "Stop"
   if it is not "Stop" then
      exit qsStopWebShare
   end if
   put empty into sXferSel
   qsStopClearweb
end qsStopWebShare

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
      case "externalIp"
         -- libtorrent discovered our public IP (from UPnP, the DHT, or a tracker). Use
         -- it to build the internet link even if the router did not open the port - the
         -- user can forward it manually; qsCwStatusText explains the state.
         put pEvent["externalIp"] into sCwExtIp
         if sCwActive is "true" then
            qsLog "Your public IP is " & pEvent["externalIp"] & "."
            qsCwShowLinks
         end if
         break
      case "portMapped"
         -- the router confirmed the mapping: the internet link is now live.
         if sCwActive is "true" then
            put "true" into sCwMapped
            qsLog "Router opened port " & pEvent["externalPort"] & " via " & pEvent["transport"] & " - the internet link is live."
            qsCwShowLinks
         end if
         break
      case "portMapError"
         if sCwActive is "true" then
            qsLog "Router refused to open the port automatically. To share over the internet, forward port " & sCwPort & " (TCP) to " & sCwLanIp & " in your router settings, then use the internet link above; otherwise use Tor. The local-network link still works."
            qsCwShowLinks
         end if
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
   put tBase & "/newQuickShare" into tBase
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

-- A COMPACT data rate for the Transfers rows, e.g. "1.2M/s" (short unit, no space) so it
-- fits the narrow progress column. 0/empty -> "0B/s". Item delimiter saved + restored.
-- Pinned by rate_short() in the golden.
function qsRateShort pBps
   local tV, tU, tUnit, tUnits, tSavedID
   if pBps is empty or pBps is not a number or pBps <= 0 then
      return "0B/s"
   end if
   put the itemDelimiter into tSavedID
   set the itemDelimiter to comma
   put "B,K,M,G,T" into tUnits
   put pBps into tV
   put 1 into tU
   repeat while tV >= 1024 and tU < the number of items of tUnits
      put tV / 1024 into tV
      add 1 to tU
   end repeat
   put (item tU of tUnits) into tUnit
   set the itemDelimiter to tSavedID
   return (the round of (tV * 10) / 10) & tUnit & "/s"
end qsRateShort

-- A short ETA from a seconds count: "45s", "3m", "1h12m", or ">1d". Empty for a bad
-- input. Pinned by eta_short() in the golden.
function qsEtaShort pSecs
   local tS
   if pSecs is empty or pSecs is not a number or pSecs < 0 then
      return ""
   end if
   put trunc(pSecs) into tS
   if tS < 60 then
      return tS & "s"
   else if tS < 3600 then
      return (tS div 60) & "m"
   else if tS < 86400 then
      return (tS div 3600) & "h" & ((tS mod 3600) div 60) & "m"
   end if
   return ">1d"
end qsEtaShort

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
   if sActiveShare["kind"] is "folder" then
      -- a folder is browser-only: the "code" AND the web link are both the onion URL
      put tOnion into sActiveShare["onion"]
      put "true" into sActiveShare["revealed"]
      put ("http://" & tOnion & "/") into sShareCode
      put sShareCode into sActiveShare["code"]   -- per-row Copy (My Shares)
      set the text of field "qsCode" to ("http://" & tOnion & "/")
      set the text of field "qsWebLink" to ("http://" & tOnion & "/")
      set the text of field "qsSharing" to ("Serving the folder " & quote & sActiveShare["name"] & quote & " over Tor - both IPs hidden. Open the link in Tor Browser to browse and download; keep this window open.")
      qsLog "Tor web page published. Open  http://" & tOnion & "/  in Tor Browser to browse the folder. Copy the link to send it."
      exit qsOnionServicePublished
   end if
   put qsMakeTorCode(tOnion, sActiveShare["name"], sActiveShare["salt"], sActiveShare["verify"]) into tCode
   put tCode into sShareCode
   put tCode into sActiveShare["code"]   -- per-row Copy (My Shares)
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
      set the text of field "qsSharing" to ("Sharing " & quote & sActiveShare["name"] & quote & " over Tor (not encrypted) - both IPs hidden. Send the code above and keep this window open. Tick the checkbox below to also allow a Tor Browser link.")
      qsLog "Private Tor address published. Click Copy and send the code to your friend."
   end if
end qsOnionServicePublished

-- Repaint the live pill AND drive the toggle's disabled/hilite state. A mode the
-- environment cannot honor never stays silently armed (sTorSend forced off).
command qsOnionPill
   local tState, tBg, tFg
   if there is no field "qsTorPill" then
      exit qsOnionPill
   end if
   -- short chip texts only (the chip is 190px wide; overflow just clips): the
   -- "how do I fix it" detail lives in the chip's tooltip and the Activity log
   if not sHasOnion then
      if sCanEncrypt then
         put "Tor: extension not installed" into tState
      else
         put "Tor: needs cryptoXT" into tState
      end if
      put kClrPillOff into tBg
      put kClrPillOffText into tFg
      set the disabled of button "qsMethodTor" to true
   else if not oxIsControlAuthenticated() then
      put "Tor: not running" into tState
      put kClrPillOff into tBg
      put kClrPillOffText into tFg
      set the disabled of button "qsMethodTor" to true
   else if not oxIsReady() then
      put ("Tor: connecting " & oxBootstrapProgress() & "%") into tState
      put kClrPillWait into tBg
      put kClrPillWaitText into tFg
      set the disabled of button "qsMethodTor" to false
   else
      put "Tor: ready" into tState
      put kClrPillOk into tBg
      put kClrPillOkText into tFg
      set the disabled of button "qsMethodTor" to false
   end if
   -- if Tor became unavailable while it was the chosen method, fall back to a share code
   if (the disabled of button "qsMethodTor") and (sTorSend is "true") then
      put "false" into sTorSend
      qsSyncMethod
   end if
   set the text of field "qsTorPill" to tState
   set the foregroundColor of field "qsTorPill" to tFg
   if there is a graphic "qsTorPillBg" then
      set the backgroundColor of graphic "qsTorPillBg" to tBg
   end if
end qsOnionPill

-- The send method is a 3-way, mutually-exclusive RADIO choice - "code", "tor", or
-- "web" - carried in sTorSend / sWebShare (both false = a classic share code). These
-- two handlers replace the old pair of managed checkboxes; the actual send still keys
-- off sTorSend / sWebShare exactly as before, so only the presentation changed.
command qsSetMethod pMethod
   if pMethod is "tor" then
      if the disabled of button "qsMethodTor" then
         qsSyncMethod            -- Tor unavailable: ignore the click, keep the display honest
         exit qsSetMethod
      end if
      put "true" into sTorSend
      put "false" into sWebShare
   else if pMethod is "web" then
      put "false" into sTorSend
      put "true" into sWebShare
   else
      put "false" into sTorSend
      put "false" into sWebShare
   end if
   qsSyncMethod
end qsSetMethod

-- Paint the three radios from the current state (both off = the Share code option).
command qsSyncMethod
   local tIsTor, tIsWeb, tIsCode
   if there is no button "qsMethodCode" then
      exit qsSyncMethod
   end if
   set the hilite of button "qsMethodTor" to (sTorSend is "true")
   set the hilite of button "qsMethodWeb" to (sWebShare is "true")
   set the hilite of button "qsMethodCode" to (sTorSend is not "true" and sWebShare is not "true")
   put (sTorSend is "true") into tIsTor
   put (sWebShare is "true") into tIsWeb
   put (not tIsTor and not tIsWeb) into tIsCode
   -- ENCRYPT ROW: show the passphrase field only where encryption can actually work
   -- (Share code, or Tor). For a Web link a browser cannot decrypt, and without cryptoXT
   -- nothing can - in both cases HIDE the field and turn the caption into a full-width
   -- plain-English reason, so the affordance never misleads (qsShareFile already ignores
   -- a passphrase on the web branch, so this changes no share behaviour).
   -- rect heights here must stay >= the build-time auto-sized height (qsLabel
   -- measures the engine's real line height); 28px holds one line on any platform
   if tIsWeb then
      set the visible of field "qsSendPass" to false
      set the visible of button "qsPassSuggest" to false
      set the rect of field "qsSendPassCap" to "40,193,600,221"
      set the foregroundColor of field "qsSendPassCap" to kClrInkMute
      put "Not encrypted - a web link opens in any browser, which cannot decrypt." into field "qsSendPassCap"
   else if sCanEncrypt is not "true" then
      set the visible of field "qsSendPass" to false
      set the visible of button "qsPassSuggest" to false
      set the rect of field "qsSendPassCap" to "40,193,600,221"
      set the foregroundColor of field "qsSendPassCap" to kClrInkMute
      put "Encrypt: install cryptoXT (org.openxtalk.library.sodium) to lock this file." into field "qsSendPassCap"
   else
      set the visible of field "qsSendPass" to true
      set the visible of button "qsPassSuggest" to true
      set the rect of field "qsSendPassCap" to "40,193,164,221"
      set the foregroundColor of field "qsSendPassCap" to kClrInk   -- back to a field label
      put "Encrypt (optional):" into field "qsSendPassCap"
   end if
   -- MORE OPTIONS: reveal only the advanced control(s) that apply to THIS method; the
   -- common Share-code path shows NONE (fully decluttered). qsWebLink/qsWebCopy are a
   -- SHARED secondary-link OUTPUT (both the Tor web-download AND the clearweb Web path
   -- write to it), so they stay visible for tor AND web - only qsWebCheck is Tor-only and
   -- the editor group is Web-only.
   set the visible of field "qsMoreCap" to (not tIsCode)
   if there is a graphic "qsMoreLine" then
      set the visible of graphic "qsMoreLine" to (not tIsCode)
   end if
   set the visible of button "qsWebCheck" to tIsTor
   set the visible of field "qsWebLink" to (not tIsCode)
   set the visible of button "qsWebCopy" to (not tIsCode)
   set the visible of button "qsEditToggle" to tIsWeb
   set the visible of field "qsEditPassCap" to tIsWeb
   set the visible of field "qsEditPass" to tIsWeb
   set the visible of field "qsEditHint" to tIsWeb
   -- lay the two More-options rows out per method: on Tor the checkbox CAUSES the
   -- link (cause before effect), on Web the link is the first output and the
   -- LAN-editor row follows it - so the block always reads top-down in the order
   -- things happen, with no gap where the other method's control would sit.
   if tIsTor then
      set the rect of button "qsWebCheck" to "40,530,520,550"
      set the rect of field "qsWebLink" to "40,558,512,584"
      set the rect of button "qsWebCopy" to "520,556,600,584"
   else if tIsWeb then
      set the rect of field "qsWebLink" to "40,528,512,554"
      set the rect of button "qsWebCopy" to "520,526,600,554"
      set the rect of button "qsEditToggle" to "40,560,304,582"
      set the rect of field "qsEditPassCap" to "310,557,376,583"
      set the rect of field "qsEditPass" to "380,558,520,584"
      set the rect of field "qsEditHint" to "526,557,600,583"
   end if
   -- never leave an advanced mode silently armed once its context is gone (the qsOnionPill
   -- idiom); guarded so this is a no-op at build time when nothing was armed.
   if sWebServe is "true" and not tIsTor then
      put "false" into sWebServe
      set the hilite of button "qsWebCheck" to false
   end if
   if sEditOn is "true" and not tIsWeb then
      qsEditDisable
      set the hilite of button "qsEditToggle" to false
   end if
   -- the drop zone narrates the chosen method (text-only; colors are qsDropPaint's)
   qsDropHint
end qsSyncMethod

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
   -- close any live folder-server connections too (they are not in sOnionXfers)
   repeat for each key tK in sFsReq
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

-- Byte size of a file WITHOUT loading it whole into memory. OpenXTalk does not support
-- 'the detailedFiles', so historically we read the whole file to count it - O(file size)
-- I/O that also FROZE the UI thread and DOUBLED the disk reads for every download (size
-- pass + send pass). Now we find the size with an O(log n) SEEK PROBE (a handful of
-- single-byte reads), and only fall back to the old linear count if the probe cannot
-- determine it. Empty return = unreadable. Pinned by file_size_probe() in the golden.
function qsFileSize pPath
   local tSize
   put qsFileSizeSeek(pPath) into tSize
   if tSize is not empty then
      return tSize
   end if
   return qsFileSizeRead(pPath)
end qsFileSize

-- The fast path: locate EOF by exponential-then-binary search over `seek to N; read 1`.
-- readable(N) = a byte exists at 0-based offset N (i.e. N < size); the file size is the
-- smallest N that is NOT readable. Returns the size, or empty to signal "fall back" (a
-- read/seek error, or a size beyond the 8 GiB ceiling we serve - a runaway guard against
-- an engine that never reports EOF). All seek/read work is wrapped so a misbehaving
-- engine degrades to the always-correct linear count rather than a wrong Content-Length.
function qsFileSizeSeek pPath
   local tLo, tHi, tMid, tErr, tCap
   put 8589934592 into tCap                 -- kOnionMaxTotal: 8 GiB serve ceiling
   open file pPath for binary read
   if the result is not empty then
      return empty
   end if
   try
      seek to 0 in file pPath
      read from file pPath for 1
      if it is empty then                   -- empty file
         close file pPath
         return 0
      end if
      put 0 into tLo                         -- offset tLo is readable
      put 1 into tHi
      repeat
         if tHi > tCap then                  -- too big / no EOF reported: give up, fall back
            close file pPath
            return empty
         end if
         seek to tHi in file pPath
         read from file pPath for 1
         if it is empty then
            exit repeat                      -- tHi is NOT readable: an upper bound
         end if
         put tHi into tLo
         put (tHi * 2) into tHi
      end repeat
      repeat while (tHi - tLo) > 1           -- narrow to size = smallest non-readable offset
         put (tLo + tHi) div 2 into tMid
         seek to tMid in file pPath
         read from file pPath for 1
         if it is empty then
            put tMid into tHi
         else
            put tMid into tLo
         end if
      end repeat
      close file pPath
      return tHi
   catch tErr
      try
         close file pPath
      catch tErr
      end try
      return empty
   end try
end qsFileSizeSeek

-- The fallback: read the whole file in bounded 4 MiB chunks (O(file size) I/O, O(1)
-- memory). Always correct; used only when the seek probe bows out. Hardened with an
-- 8 GiB ceiling so an engine whose read never signals EOF can NEVER spin this loop
-- forever and freeze the single UI thread (which would look like "the shared page never
-- loads" - every served file's size passes through here).
function qsFileSizeRead pPath
   local tSize, tErr
   put 0 into tSize
   open file pPath for binary read
   if the result is not empty then
      return empty
   end if
   repeat
      read from file pPath for 4194304
      if it is empty then
         exit repeat                        -- EOF (or a read error): done
      end if
      add the number of bytes in it to tSize
      if tSize > 8589934592 then            -- 8 GiB serve ceiling: bail rather than spin
         try
            close file pPath
         catch tErr
         end try
         return empty                       -- an engine that never signals EOF: give up
      end if
   end repeat
   close file pPath
   return tSize
end qsFileSizeRead

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
   put "file" into sActiveShare["kind"]
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

-- SEND entry for a FOLDER: publish an onion and serve the folder as a browsable web
-- page (auto directory listing + streamed, Range-capable downloads). NO torrent, NO
-- encryption (a browser cannot decrypt), NO single-file BTXO transfer - a visitor
-- just opens the printed http://<onion>/ in Tor Browser. One active share at a time.
command qsStartOnionFolder pPath, pName
   local tSvc, tPort, tSafe, tRoot, tErr
   put qsSafeLeaf(pName) into tSafe
   put pPath into tRoot
   replace "\" with "/" in tRoot
   if the last char of tRoot is "/" then
      delete the last char of tRoot
   end if
   -- one active anon share at a time: tear down any previous service + temp. Removing
   -- the service also closes any live folder-server streams (their closed event
   -- cleans the per-stream state).
   if sActiveShare["service"] is not empty then
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
      exit qsStartOnionFolder
   end if
   put "folder" into sActiveShare["kind"]
   put tRoot into sActiveShare["root"]
   put tSafe into sActiveShare["name"]
   put 0 into sActiveShare["enc"]
   put tPort into sActiveShare["port"]
   put tSvc into sActiveShare["service"]
   put "true" into sActiveShare["web"]
   put "false" into sActiveShare["revealed"]
   set the text of field "qsCode" to ""
   set the text of field "qsWebLink" to ""
   set the text of field "qsSharing" to ("Publishing a private Tor address for the folder " & quote & tSafe & quote & " - this can take up to a minute...")
   qsLog "Publishing a private Tor web page for the folder " & quote & tSafe & quote & "..."
   send ("qsOnionPublishWatchdog " & tSvc) to me in kOnionPublishTimeout milliseconds
end qsStartOnionFolder

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
   -- a FOLDER share is a concurrent browsable web server: each connection is its own
   -- per-stream state (no single-file busy gate), so a page + its icons + downloads
   -- are all served at once.
   if sActiveShare["kind"] is "folder" then
      qsFsPeer pStream
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
      "Content-Length: " & (the number of bytes in tData) & tCrlf) into tHead
   put qsHttpExtraHeaders() after tHead
   put ("Connection: close" & tCrlf & tCrlf) after tHead
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

-- ==== the FOLDER web server (Model C, a browsable page over the onion) ========
-- When the active share is a FOLDER, serve sActiveShare["root"] as a browsable web
-- page over the onion: an auto directory listing, index.html precedence, a
-- trailing-slash redirect, MIME by extension, and STREAMED, Range-capable downloads
-- (resumable + seekable). Concurrency-safe: every browser connection is its own
-- per-stream state, and the pump opens/seeks/reads/closes the file within a single
-- tick (no yield between), so two browsers can pull the SAME file without sharing a
-- cursor (LiveCode keys a file handle by path and no-ops a second open). Read-only
-- (GET/HEAD); ".." is refused after URL-decoding; file names are HTML-escaped. This
-- is the standalone Onion File Server folded into Quick Share. Verified STATICALLY +
-- by tests/fileserver_golden.py; the one unproven primitive is `seek to N in file`
-- in qsFsPump (flagged VERIFY), used for every download so any base error is a loud,
-- first-test-obvious failure, not silent corruption.

command qsFsPeer pStream
   put "" into sFsReq[pStream]
   put "false" into sFsServed[pStream]
   put the milliseconds into sFsTxDeadline[pStream]
   oxSetStreamCallback pStream, "qsFsStream"
   send ("qsFsWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
end qsFsPeer

-- Accumulate the request until it is COMPLETE: the CRLFCRLF header terminator has
-- arrived AND, if the head declares a Content-Length (a POST to a route), the whole
-- body too. The kFsMaxReq cap bounds head + body together (abuse guard).
command qsFsStream pStream, pEvent, pData
   if pEvent is "data" then
      if sFsServed[pStream] is "true" then
         exit qsFsStream
      end if
      put pData after sFsReq[pStream]
      put the milliseconds into sFsTxDeadline[pStream]
      if the number of bytes in sFsReq[pStream] > kFsMaxReq then
         put "true" into sFsServed[pStream]
         qsFsSendText pStream, "413 Payload Too Large", "text/plain; charset=utf-8", "Request too large."
         exit qsFsStream
      end if
      if qsHttpReqComplete(sFsReq[pStream]) then
         put "true" into sFsServed[pStream]
         qsFsHandle pStream
      end if
   else if pEvent is "closed" or pEvent is "error" then
      qsFsCleanup pStream
   end if
end qsFsStream

command qsFsHandle pStream
   local tHeaders
   put qsHttpParse(sFsReq[pStream]) into tHeaders
   qsFsServePath pStream, tHeaders
end qsFsHandle

-- ==== the light HTTP backend (request framing, routes, replies) ==============
-- Shared by BOTH transports (onion + clearweb). A request is parsed into an array
-- (__method / __path / __query / __body + lowercased headers); a registered dynamic
-- route (qsHttpRoute) is answered by an xTalk handler in this script via qsHttpReply.
-- The connection is an opaque token "ox:<stream>" or "cw:<socket>" so a route handler
-- and qsHttpReply stay transport-neutral.

-- 1-based byte index of the first CR of the CRLFCRLF that ends the header block, or 0
-- if the head is not fully received yet. Byte discipline (no char/line on binary),
-- mirroring OnionXT's proven onion-httpd.
function qsHttpHeaderEnd pData
   local tN, tI, tB1, tB2, tB3, tB4, tTerm, tProbe, tErr
   put the number of bytes in pData into tN
   if tN < 4 then
      return 0
   end if
   put (numToByte(13) & numToByte(10) & numToByte(13) & numToByte(10)) into tTerm
   -- FAST PATH. This function re-runs on EVERY arriving chunk of a request (the
   -- completeness check), so the interpreted per-byte scan below is O(n^2) per
   -- connection - against the 256 KB request cap that is an engine-thread stall
   -- any uploader (or abuser) can trigger. byteOffset is an engine-NATIVE scan.
   -- It is probed ONCE against a known vector rather than trusted blindly: an
   -- engine whose byteOffset mishandled a multi-byte needle would silently
   -- break request framing, which is far worse than being slow.
   if sHdrScanMode is empty then
      put "loop" into sHdrScanMode
      try
         put byteOffset(tTerm, (numToByte(65) & tTerm & numToByte(66))) into tProbe
         if tProbe is 2 then
            put "fast" into sHdrScanMode
         end if
      catch tErr
      end try
   end if
   if sHdrScanMode is "fast" then
      -- same contract as the loop: 1-based index of the first CR, 0 if absent
      -- (pinned by http_header_end() in the golden)
      return byteOffset(tTerm, pData)
   end if
   repeat with tI = 1 to tN - 3
      put byteToNum(byte tI of pData) into tB1
      if tB1 is 13 then
         put byteToNum(byte (tI + 1) of pData) into tB2
         put byteToNum(byte (tI + 2) of pData) into tB3
         put byteToNum(byte (tI + 3) of pData) into tB4
         if tB2 is 10 and tB3 is 13 and tB4 is 10 then
            return tI
         end if
      end if
   end repeat
   return 0
end qsHttpHeaderEnd

-- Is the request fully received? The head must have arrived, and if it declares a
-- Content-Length (a POST to a route) the whole body too. GET/HEAD have no body.
function qsHttpReqComplete pData
   local tHeadEnd, tHeaders, tContentLen, tBodyStart, tHave
   put qsHttpHeaderEnd(pData) into tHeadEnd
   if tHeadEnd is 0 then
      return false
   end if
   put qsHttpParseHead(byte 1 to (tHeadEnd - 1) of pData) into tHeaders
   put tHeaders["content-length"] into tContentLen
   if tContentLen is empty or tContentLen is not an integer then
      return true
   end if
   put tHeadEnd + 4 into tBodyStart
   put (the number of bytes in pData) - tBodyStart + 1 into tHave
   return (tHave >= tContentLen)
end qsHttpReqComplete

-- The exact byte length of ONE complete request at the front of pData: the head (up to
-- and including the terminating CRLFCRLF, i.e. tHeadEnd + 3 bytes) plus its
-- Content-Length body. Used by keep-alive to trim the request just served and leave any
-- pipelined bytes intact for the next one. Returns 0 if the head is not yet complete (a
-- caller must never trim on 0). Pinned by keepalive_req_length() in the golden.
function qsHttpReqLength pData
   local tHeadEnd, tHeaders, tLen
   put qsHttpHeaderEnd(pData) into tHeadEnd
   if tHeadEnd is 0 then
      return 0
   end if
   put qsHttpParseHead(byte 1 to (tHeadEnd - 1) of pData) into tHeaders
   put tHeaders["content-length"] into tLen
   if tLen is not an integer or tLen < 0 then
      put 0 into tLen
   end if
   return tHeadEnd + 3 + tLen
end qsHttpReqLength

-- Parse the head block (request line + header lines, ASCII) into an array: __method /
-- __path / __query, plus lowercased header names -> values. Save/restore delimiters.
function qsHttpParseHead pHeadBytes
   local tText, tSaved, tSavedID, tReqLine, tResource, tI, tLine, tColon, tName, tValue, tOut
   put textDecode(pHeadBytes, "UTF-8") into tText
   put the lineDelimiter into tSaved
   put the itemDelimiter into tSavedID
   set the lineDelimiter to (numToChar(13) & numToChar(10))
   put line 1 of tText into tReqLine
   put toUpper(word 1 of tReqLine) into tOut["__method"]
   put word 3 of tReqLine into tOut["__version"]   -- e.g. HTTP/1.1 (keep-alive default)
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
         put toLower(qsTrim(char 1 to (tColon - 1) of tLine)) into tName
         put qsTrim(char (tColon + 1) to -1 of tLine) into tValue
         -- "__" is our reserved pseudo-field namespace (__method/__path/__query/__body);
         -- never let a client header shadow one. (Real HTTP header names never start "__".)
         if tName begins with "__" then
            next repeat
         end if
         -- conflicting duplicate Content-Length headers make the framing
         -- ambiguous (smuggling's classic lever). We are the only parser here,
         -- so nothing downstream can disagree with us - but flag it anyway and
         -- let the serve handlers refuse with a 400 (belt-and-braces).
         if tName is "content-length" and tOut[tName] is not empty \
               and tOut[tName] is not tValue then
            put "true" into tOut["__dupcl"]
         end if
         put tValue into tOut[tName]
      end if
   end repeat
   set the lineDelimiter to tSaved
   set the itemDelimiter to tSavedID
   return tOut
end qsHttpParseHead

-- Full parse: the head plus the raw body bytes, CAPPED to the declared Content-Length
-- (so trailing/pipelined bytes never bleed into __body). __body is RAW bytes (a POST
-- body may be binary), the head is text.
function qsHttpParse pData
   local tHeadEnd, tOut, tContentLen, tBodyStart, tBodyEnd
   put qsHttpHeaderEnd(pData) into tHeadEnd
   if tHeadEnd is 0 then
      put qsHttpParseHead(pData) into tOut     -- defensive: no terminator seen
      put "" into tOut["__body"]
      return tOut
   end if
   put qsHttpParseHead(byte 1 to (tHeadEnd - 1) of pData) into tOut
   put "" into tOut["__body"]
   put tOut["content-length"] into tContentLen
   if tContentLen is an integer and tContentLen > 0 then
      put tHeadEnd + 4 into tBodyStart
      if tBodyStart <= the number of bytes in pData then
         put tBodyStart + tContentLen - 1 into tBodyEnd
         if tBodyEnd > the number of bytes in pData then
            put the number of bytes in pData into tBodyEnd
         end if
         put byte tBodyStart to tBodyEnd of pData into tOut["__body"]
      end if
   end if
   return tOut
end qsHttpParse

-- Round-5 hardening: does any "/"-separated SEGMENT of a decoded path start
-- with a dot? The static pipelines (listing + serving, BOTH transports) treat
-- such paths as nonexistent - sharing a website folder must never leak .git,
-- .env, editor droppings and friends over an anonymous link (the classic
-- static-host mistake). 404, never 403: hidden means "does not exist". The
-- LAN-gated, password-gated editor keeps its own rules (qsEditSafePath) and
-- may legitimately touch dotfiles; this guard is only for the read paths.
-- Mirrored by has_dot_segment() in tests/fileserver_golden.py.
function qsHasDotSegment pPath
   local tSeg, tSavedID
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "/"
   repeat for each item tSeg in pPath
      if tSeg is not empty and char 1 of tSeg is "." then
         set the itemDelimiter to tSavedID
         return true
      end if
   end repeat
   set the itemDelimiter to tSavedID
   return false
end qsHasDotSegment

-- Control bytes (<32) in a DECODED path could smuggle CR/LF/NUL toward the OS
-- or the log. qsEditSafePath already refuses them on the editor's write path;
-- this brings the static READ path up to the same bar (round-5 symmetry).
function qsPathHasControl pPath
   local tCh
   repeat for each char tCh in pPath
      if charToNum(tCh) < 32 then
         return true
      end if
   end repeat
   return false
end qsPathHasControl

-- Register a dynamic route: pHandler is a command in THIS script, called as
-- pHandler pConn, pRequest (pRequest is the parsed array; reply with qsHttpReply).
command qsHttpRoute pMethod, pPath, pHandler
   put pHandler into sHttpRoutes[toUpper(pMethod) & space & pPath]
end qsHttpRoute

-- Call a route handler; a throw or a missing handler becomes a clean 500 (so a buggy
-- route never crashes the poll loop or leaves the connection hung).
command qsHttpDispatch pConn, pHandler, pRequest
   local tErr
   try
      dispatch pHandler to me with pConn, pRequest
      if the result is "unhandled" then
         qsHttpReply pConn, 500, "text/plain; charset=utf-8", ("Route handler not found: " & pHandler)
      end if
   catch tErr
      qsHttpReply pConn, 500, "text/plain; charset=utf-8", ("Route handler error: " & tErr)
   end try
end qsHttpDispatch

-- Reply from a route handler, transport-neutral. pConn is "ox:<stream>" (onion) or
-- "cw:<socket>" (clearweb); we route to the matching one-shot text sender, which sets
-- Content-Length, closes, and cleans up.
command qsHttpReply pConn, pCode, pType, pBody
   local tKind, tId, tStatus
   put char 1 to 3 of pConn into tKind
   put char 4 to -1 of pConn into tId
   put pCode & space & qsHttpReason(pCode) into tStatus
   if tKind is "ox:" then
      qsFsSendText tId, tStatus, pType, pBody
   else
      qsCwSendText tId, tStatus, pType, pBody
   end if
end qsHttpReply

function qsHttpReason pCode
   if pCode is 200 then
      return "OK"
   else if pCode is 201 then
      return "Created"
   else if pCode is 204 then
      return "No Content"
   else if pCode is 400 then
      return "Bad Request"
   else if pCode is 401 then
      return "Unauthorized"
   else if pCode is 403 then
      return "Forbidden"
   else if pCode is 404 then
      return "Not Found"
   else if pCode is 405 then
      return "Method Not Allowed"
   else if pCode is 409 then
      return "Conflict"
   else if pCode is 413 then
      return "Payload Too Large"
   else if pCode is 500 then
      return "Internal Server Error"
   end if
   return "OK"
end qsHttpReason

-- Escape a string for a JSON value (backslash FIRST, then the rest).
function qsJsonEscape pText
   local tOut, tBack
   put numToChar(92) into tBack           -- a single backslash
   put pText into tOut
   replace tBack with (tBack & tBack) in tOut
   replace quote with (tBack & quote) in tOut
   replace numToChar(13) with (tBack & "r") in tOut
   replace numToChar(10) with (tBack & "n") in tOut
   replace numToChar(9) with (tBack & "t") in tOut
   return tOut
end qsJsonEscape

-- The built-in demo route (registered in qsStart): GET /_qs/info returns a little live
-- share metadata as JSON. Copy this shape for your own routes.
command qsInfoRoute pConn, pRequest
   local tJson, tName, tMode, tQ
   put "" into tName
   put "none" into tMode
   if sCwActive is "true" then
      put sCwName into tName
      put "clearweb" into tMode
   else if sActiveShare["kind"] is "folder" then
      put sActiveShare["name"] into tName
      put "tor" into tMode
   end if
   put quote into tQ
   put "{" & tQ & "app" & tQ & ":" & tQ & "newQuickShare" & tQ & "," & \
      tQ & "mode" & tQ & ":" & tQ & qsJsonEscape(tMode) & tQ & "," & \
      tQ & "share" & tQ & ":" & tQ & qsJsonEscape(tName) & tQ & "," & \
      tQ & "method" & tQ & ":" & tQ & qsJsonEscape(pRequest["__method"]) & tQ & "}" into tJson
   qsHttpReply pConn, 200, "application/json; charset=utf-8", tJson
end qsInfoRoute

-- ============================================================================
-- THE LIVE WEB EDITOR (Phase C). LAN-ONLY, password-gated, OFF by default. See the
-- editor state locals up top for the trust model. Its routes are registered once in
-- qsStart and are always present; every one gates on qsEditReachable first, so a Tor
-- visitor or a public clearweb peer just gets a 404 and never learns an editor exists.
-- cryptoXT (sx*) is required for the password - without it the editor cannot be enabled
-- (it fails closed). Writes are confined to the served folder by qsEditSafePath.
-- ----------------------------------------------------------------------------

-- Is this connection from the local network (so it MAY reach the editor)? The only
-- trustworthy signal is the TCP peer address the engine hands us, which a remote
-- attacker cannot forge across the internet - NEVER a request header. Tor (ox:) is by
-- definition remote, so it is always refused. For clearweb (cw:) the connection token
-- carries the accepted-socket id "<ip>:<port>"; the peer ip is up to the first colon.
function qsEditIsLocal pConn
   local tKind, tId, tIp, tSavedID, tA, tB
   put char 1 to 3 of pConn into tKind
   if tKind is not "cw:" then
      return false                    -- Tor, and anything unexpected: not local
   end if
   put char 4 to -1 of pConn into tId
   if tId begins with "::1" then
      return true                     -- IPv6 loopback ("::1:<port>")
   end if
   -- The rest assumes an IPv4 "<ip>:<port>" peer id (what OXT's TCP listener yields on a
   -- LAN). A globally-routable IPv6 peer (2xxx.., fe80.., fc00..) has a non-numeric first
   -- field, so it falls through to false = REMOTE - a safe default. IPv6 LAN peers other
   -- than loopback are therefore not recognised as local (refused, never wrongly allowed).
   put the itemDelimiter into tSavedID
   set the itemDelimiter to ":"
   put item 1 of tId into tIp         -- "<ip>:<port>[|n]" -> the ip
   set the itemDelimiter to "."
   put item 1 of tIp into tA
   put item 2 of tIp into tB
   set the itemDelimiter to tSavedID
   if tA is not a number then
      return false
   end if
   -- Deliberately STRICTER than qsIsPrivateIp: a true LAN / loopback only. Carrier-NAT
   -- space (100.64/10) is the ISP's SHARED range, not your home network, so it is NOT
   -- treated as local for the editor - even though qsIsPrivateIp (used only to decide
   -- whether to SHOW an internet link) accepts it. Loopback 127/8, RFC-1918 10/8 +
   -- 172.16-31/12 + 192.168/16, and link-local 169.254/16 are the local ranges.
   if tA is 10 or tA is 127 then
      return true
   end if
   if tA is 192 and tB is 168 then
      return true
   end if
   if tA is 169 and tB is 254 then
      return true
   end if
   if tA is 172 and tB is a number and tB >= 16 and tB <= 31 then
      return true
   end if
   return false
end qsEditIsLocal

-- The disk root the editor may read/write: the CURRENTLY-shared clearweb FOLDER. A
-- single-file share or no active folder share -> empty (editing unavailable). Editing
-- is tied to the clearweb folder server because that is the only surface a LAN browser
-- can reach.
function qsEditServedRoot
   if sCwActive is "true" and sCwKind is "folder" then
      return sCwRoot
   end if
   return ""
end qsEditServedRoot

-- Is the editor even reachable for this connection? It must be ENABLED, cryptoXT must
-- be present, there must be a served folder, AND the peer must be local. The outer
-- gate: when false the route answers 404 (invisible to the caller), never hinting an
-- editor could exist.
function qsEditReachable pConn
   if sEditOn is not "true" then
      return false
   end if
   if not sCanEncrypt then
      return false
   end if
   if qsEditServedRoot() is empty then
      return false
   end if
   return qsEditIsLocal(pConn)
end qsEditReachable

-- Does pKey open the edit verifier (proving the login password was correct)? Mirrors
-- qsKeyOpensVerifier; a wrong key makes sxSecretBoxOpen throw, which we catch as false.
function qsEditKeyOpens pKey
   local tOut, tErr
   if sEditVerify is empty then
      return false
   end if
   try
      put sxSecretBoxOpen(sEditVerify, pKey) into tOut
   catch tErr
      return false
   end try
   return (textDecode(tOut, "ASCII") is kEditVerify)
end qsEditKeyOpens

-- Is this request authorised to EDIT? Reachable (enabled + local + served folder) AND
-- carrying the current session token in the x-edit-token header. The token is minted
-- only by a correct-password login, so this is the write gate.
function qsEditAuthed pConn, pRequest
   if not qsEditReachable(pConn) then
      return false
   end if
   if sEditSession is empty then
      return false
   end if
   return (pRequest["x-edit-token"] is sEditSession)
end qsEditAuthed

-- Enable the editor with a login password. Derives an Argon2id key from the password +
-- a fresh random salt, seals a known marker under it as the verifier, and stores salt +
-- verifier (never the password or the key). Any existing session is invalidated, so
-- changing the password forces a re-login. Requires cryptoXT; returns "" on success or
-- an error string. KDF params (opslimit "2", interactive memory) match the share-code
-- path - keep them identical across the demo.
function qsEditEnable pPassword
   local tSalt, tKey, tErr
   if not sCanEncrypt then
      return "The live editor needs cryptoXT (org.openxtalk.library.sodium) for its password. Install it, then try again."
   end if
   if pPassword is empty then
      return "Set an edit password first."
   end if
   try
      put sxRandomBytes(16) into tSalt
      put sxPwHash(textEncode(pPassword, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tKey
      put sxSecretBox(textEncode(kEditVerify, "ASCII"), tKey) into sEditVerify
   catch tErr
      return ("Could not set up the editor: " & tErr)
   end try
   put tSalt into sEditSalt
   put "" into sEditSession            -- force a fresh login under the new password
   put "true" into sEditOn
   return ""
end qsEditEnable

-- The LAN editor URL, logged when the editor is on AND a folder is web-shared (a single
-- file or no clearweb folder means there is nothing to edit yet - say so instead).
command qsEditShowLink
   if sEditOn is not "true" then
      exit qsEditShowLink
   end if
   if qsEditServedRoot() is empty then
      qsLog "Editing is armed - it becomes reachable once you share a FOLDER via web link (not a single file)."
      exit qsEditShowLink
   end if
   if sCwLanIp is empty then
      qsLog ("Editor: open http://YOUR-LAN-IP:" & sCwPort & "/" & sCwToken & "/_edit on a device on this network.")
   else
      qsLog ("Editor: open http://" & sCwLanIp & ":" & sCwPort & "/" & sCwToken & "/_edit on this network.")
   end if
end qsEditShowLink

-- Disable the editor and forget everything about it: no session, no salt, no verifier.
command qsEditDisable
   put "false" into sEditOn
   put "" into sEditSalt
   put "" into sEditVerify
   put "" into sEditSession
end qsEditDisable

-- POST /_edit/login : the request body is the candidate password (raw UTF-8 bytes). On
-- a correct password we mint a NEW random session token (invalidating any prior one)
-- and return it as plain text for the browser to keep and send back in x-edit-token. A
-- wrong password -> 401, with no hint about which half was wrong.
command qsEditLoginRoute pConn, pRequest
   local tPass, tKey, tErr, tToken
   if not qsEditReachable(pConn) then
      qsHttpReply pConn, 404, "text/plain; charset=utf-8", "Not found."
      exit qsEditLoginRoute
   end if
   put textDecode(pRequest["__body"], "UTF-8") into tPass
   if tPass is empty then
      qsHttpReply pConn, 400, "text/plain; charset=utf-8", "Missing password."
      exit qsEditLoginRoute
   end if
   try
      put sxPwHash(textEncode(tPass, "UTF-8"), sEditSalt, 32, "2", sxPwMemInteractive()) into tKey
   catch tErr
      qsHttpReply pConn, 500, "text/plain; charset=utf-8", "Login failed."
      exit qsEditLoginRoute
   end try
   if not qsEditKeyOpens(tKey) then
      qsHttpReply pConn, 401, "text/plain; charset=utf-8", "Wrong password."
      exit qsEditLoginRoute
   end if
   put qsMakeToken(kEditTokenBytes) into tToken
   put tToken into sEditSession
   qsHttpReply pConn, 200, "text/plain; charset=utf-8", tToken
end qsEditLoginRoute

-- Uniform refusal for an authenticated editor API: 404 when the editor is not even
-- reachable for this caller (keep it invisible), 401 when it IS reachable but the
-- request has no valid session (the browser should re-login).
command qsEditDeny pConn
   if qsEditReachable(pConn) then
      qsHttpReply pConn, 401, "text/plain; charset=utf-8", "Not logged in."
   else
      qsHttpReply pConn, 404, "text/plain; charset=utf-8", "Not found."
   end if
end qsEditDeny

-- One URL-decoded query-string value, or empty. Splits on & (as lines) then = (as
-- items) using DIFFERENT delimiters so neither loop rescans the other's separator -
-- no mid-loop delimiter change (an xTalk footgun).
function qsQueryParam pQuery, pName
   local tLine, tSavedID, tSavedLD, tRet
   put "" into tRet
   put the lineDelimiter into tSavedLD
   put the itemDelimiter into tSavedID
   set the lineDelimiter to "&"
   set the itemDelimiter to "="
   repeat for each line tLine in pQuery
      if item 1 of tLine is pName then
         if the number of items of tLine >= 2 then
            put urlDecode(item 2 to -1 of tLine) into tRet
         end if
         exit repeat
      end if
   end repeat
   set the lineDelimiter to tSavedLD
   set the itemDelimiter to tSavedID
   return tRet
end qsQueryParam

-- GET /_edit : the editor page itself. Reachable (enabled + local + served folder)
-- callers get the self-contained HTML; everyone else gets a 404. The page carries the
-- login form, so it needs no session yet.
command qsEditPageRoute pConn, pRequest
   if not qsEditReachable(pConn) then
      qsHttpReply pConn, 404, "text/plain; charset=utf-8", "Not found."
      exit qsEditPageRoute
   end if
   qsHttpReply pConn, 200, "text/html; charset=utf-8", qsEditHtml()
end qsEditPageRoute

-- GET /_edit/api/list : newline-separated relative paths of every file under the
-- served folder (forward slashes). Auth required.
command qsEditListRoute pConn, pRequest
   if not qsEditAuthed(pConn, pRequest) then
      qsEditDeny pConn
      exit qsEditListRoute
   end if
   qsHttpReply pConn, 200, "text/plain; charset=utf-8", qsEditFileList(qsEditServedRoot())
end qsEditListRoute

-- GET /_edit/api/read?path=REL : the file's bytes as text/plain (UTF-8). Auth
-- required; the path is confined to the served root by qsEditSafePath, and a file
-- bigger than the editor cap is refused (a browser textarea is for text/code).
command qsEditReadRoute pConn, pRequest
   local tRel, tDisk, tData
   if not qsEditAuthed(pConn, pRequest) then
      qsEditDeny pConn
      exit qsEditReadRoute
   end if
   put qsQueryParam(pRequest["__query"], "path") into tRel
   put qsEditSafePath(qsEditServedRoot(), tRel) into tDisk
   if tDisk is empty then
      qsHttpReply pConn, 400, "text/plain; charset=utf-8", "Bad path."
      exit qsEditReadRoute
   end if
   if there is no file tDisk then
      qsHttpReply pConn, 404, "text/plain; charset=utf-8", "No such file."
      exit qsEditReadRoute
   end if
   put "" into tData
   open file tDisk for binary read
   if the result is not empty then
      qsHttpReply pConn, 500, "text/plain; charset=utf-8", "Could not open the file."
      exit qsEditReadRoute
   end if
   -- read in chunks and stop the moment we cross the cap (avoids reading a huge file
   -- twice just to size it; a browser textarea is for text/code, not big binaries)
   repeat
      read from file tDisk for 65536
      if it is empty then
         exit repeat
      end if
      put it after tData
      if the number of bytes in tData > kEditMaxFileBytes then
         close file tDisk
         qsHttpReply pConn, 413, "text/plain; charset=utf-8", "This file is too large to edit in the browser."
         exit qsEditReadRoute
      end if
   end repeat
   close file tDisk
   qsHttpReply pConn, 200, "text/plain; charset=utf-8", tData
end qsEditReadRoute

-- PUT /_edit/api/write?path=REL : replace (or create) the file with the request body.
-- Auth required; qsEditSafePath confines the target to the served root. The body is
-- already bounded by kFsMaxReq at the transport, and we re-check the editor cap.
command qsEditWriteRoute pConn, pRequest
   local tRel, tDisk, tBody, tErr
   if not qsEditAuthed(pConn, pRequest) then
      qsEditDeny pConn
      exit qsEditWriteRoute
   end if
   put qsQueryParam(pRequest["__query"], "path") into tRel
   put qsEditSafePath(qsEditServedRoot(), tRel) into tDisk
   if tDisk is empty then
      qsHttpReply pConn, 400, "text/plain; charset=utf-8", "Bad path."
      exit qsEditWriteRoute
   end if
   if there is a folder tDisk then
      qsHttpReply pConn, 409, "text/plain; charset=utf-8", "That path is a folder."
      exit qsEditWriteRoute
   end if
   put pRequest["__body"] into tBody
   if the number of bytes in tBody > kEditMaxFileBytes then
      qsHttpReply pConn, 413, "text/plain; charset=utf-8", "That file is too large to save through the editor."
      exit qsEditWriteRoute
   end if
   -- REPLACE the file wholesale. `open file ... for binary write` does NOT truncate in
   -- this engine (it overwrites from offset 0 and leaves any longer tail in place), so
   -- saving a SHORTER file would otherwise keep stale trailing bytes. Delete first - the
   -- same guard qsEncryptFile uses - so the saved bytes are exactly the new content.
   if there is a file tDisk then
      delete file tDisk
   end if
   open file tDisk for binary write
   if the result is not empty then
      qsHttpReply pConn, 500, "text/plain; charset=utf-8", "Could not open the file for writing."
      exit qsEditWriteRoute
   end if
   write tBody to file tDisk
   put the result into tErr
   close file tDisk
   if tErr is not empty then
      qsHttpReply pConn, 500, "text/plain; charset=utf-8", ("Write failed: " & tErr)
      exit qsEditWriteRoute
   end if
   qsHttpReply pConn, 200, "text/plain; charset=utf-8", "Saved."
end qsEditWriteRoute

-- Every file under pRoot, as newline-separated forward-slash relative paths. Recursion
-- is depth-bounded (kEditMaxDepth) so a directory symlink loop cannot run away.
function qsEditFileList pRoot
   return qsEditListDir(pRoot, "", 0)
end qsEditFileList

function qsEditListDir pRoot, pRel, pDepth
   local tSaved, tFiles, tFolders, tName, tOut, tChildRel, tDiskDir
   put "" into tOut
   if pRel is empty then
      put pRoot into tDiskDir
   else
      put pRoot & "/" & pRel into tDiskDir
   end if
   put the defaultFolder into tSaved
   set the defaultFolder to tDiskDir
   put the files into tFiles
   put the folders into tFolders
   set the defaultFolder to tSaved
   repeat for each line tName in tFiles
      if tName is empty then
         next repeat
      end if
      if pRel is empty then
         put tName & return after tOut
      else
         put pRel & "/" & tName & return after tOut
      end if
   end repeat
   if pDepth >= kEditMaxDepth then
      return tOut
   end if
   repeat for each line tName in tFolders
      if tName is "." or tName is ".." or tName is empty then
         next repeat
      end if
      if pRel is empty then
         put tName into tChildRel
      else
         put pRel & "/" & tName into tChildRel
      end if
      put qsEditListDir(pRoot, tChildRel, pDepth + 1) after tOut
   end repeat
   return tOut
end qsEditListDir

-- The self-contained editor page: no external assets (CSP/offline safe), all HTML
-- attributes single-quoted and all JS single-quoted so the string never needs a double
-- quote. The JS derives its API base from location.pathname (which ends in /_edit,
-- token prefix and all), logs in for a session token, lists files, and reads/saves via
-- plain-text endpoints so there is no JSON to parse.
function qsEditHtml
   return ("<!doctype html><html><head><meta charset='utf-8'>" & \
      "<meta name='viewport' content='width=device-width,initial-scale=1'>" & \
      "<title>TorrentXT Live Editor</title><style>" & \
      "*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,sans-serif;color:#1c2430;background:#fff;height:100vh;display:flex;flex-direction:column}" & \
      "#bar{padding:.6em .9em;border-bottom:1px solid #e5e8ee;display:flex;gap:.8em;align-items:baseline;flex:0 0 auto}" & \
      "#bar b{font-size:1.05em}#msg{font-size:.85em}.muted{color:#8a909a}" & \
      "#login{max-width:24em;margin:3em auto;padding:0 1em}#login input{width:100%;padding:.5em;font-size:1em;margin:.4em 0}" & \
      "#app{flex:1 1 auto;display:flex;min-height:0}" & \
      "#files{flex:0 0 15em;overflow:auto;border-right:1px solid #e5e8ee;padding:.4em}" & \
      "#files .f{padding:.3em .4em;font-size:.86em;cursor:pointer;border-radius:4px;word-break:break-all}" & \
      "#files .f:hover{background:#eef2f8}#files .f.on{background:#2c5aa0;color:#fff}" & \
      "#pane{flex:1 1 auto;display:flex;flex-direction:column;min-width:0}" & \
      "#tools{padding:.4em;display:flex;gap:.4em;border-bottom:1px solid #e5e8ee}" & \
      "#tools input{flex:1 1 auto;padding:.4em;font-family:ui-monospace,monospace}" & \
      "button{padding:.4em .8em;cursor:pointer;border:1px solid #b9c1cd;background:#f6f8fb;border-radius:5px}button:hover{background:#eef2f8}" & \
      "#ed{flex:1 1 auto;width:100%;border:0;padding:.7em;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.9em;resize:none;outline:none;line-height:1.45}" & \
      "@media(prefers-color-scheme:dark){body{background:#12151a;color:#dfe4ea}#bar,#files,#tools{border-color:#2a2f38}" & \
      "#files .f:hover{background:#20242c}#tools input,#ed{background:#12151a;color:#dfe4ea}" & \
      "button{background:#20242c;color:#dfe4ea;border-color:#39404b}button:hover{background:#2a2f38}}" & \
      "</style></head><body>" & \
      "<div id='bar'><b>TorrentXT Live Editor</b><span id='msg' class='muted'>LAN-only. Changes are written to the shared folder.</span></div>" & \
      "<div id='login'><p>This folder is shared live. Enter the edit password to make changes.</p>" & \
      "<input id='pw' type='password' placeholder='edit password' autofocus>" & \
      "<button id='unlock'>Unlock</button></div>" & \
      "<div id='app' style='display:none'><div id='files'></div>" & \
      "<div id='pane'><div id='tools'>" & \
      "<input id='path' placeholder='path/to/file.html' spellcheck='false'>" & \
      "<button id='save'>Save</button><button id='new'>New</button><button id='reload'>Refresh</button></div>" & \
      "<textarea id='ed' spellcheck='false' placeholder='Select a file on the left, or type a path and Save to create one.'></textarea>" & \
      "</div></div>" & \
      "<script>(function(){" & \
      "var base=location.pathname.slice(0,location.pathname.lastIndexOf('/_edit'))+'/_edit';" & \
      "var token='';var cur='';" & \
      "var msg=document.getElementById('msg');" & \
      "function say(t){msg.textContent=t;}" & \
      "function api(p,o){o=o||{};o.headers=o.headers||{};if(token)o.headers['x-edit-token']=token;return fetch(base+p,o);}" & \
      "function unlock(){var pw=document.getElementById('pw').value;" & \
      "fetch(base+'/login',{method:'POST',body:pw}).then(function(r){if(!r.ok){say('Login failed. Check the password.');return null;}return r.text();})" & \
      ".then(function(t){if(!t)return;token=t;document.getElementById('login').style.display='none';document.getElementById('app').style.display='flex';list();})" & \
      ".catch(function(){say('Network error.');});}" & \
      "function list(){api('/api/list').then(function(r){return r.text();}).then(function(t){" & \
      "var box=document.getElementById('files');box.innerHTML='';var n=0;" & \
      "t.split('\n').forEach(function(name){name=name.trim();if(!name)return;n++;" & \
      "var d=document.createElement('div');d.className='f';d.textContent=name;" & \
      "d.onclick=function(){open1(name);};box.appendChild(d);});" & \
      "say(n+' file(s). Click one to edit.');}).catch(function(){say('Could not list files.');});}" & \
      "function mark(name){var fs=document.getElementById('files').children;for(var i=0;i<fs.length;i++){fs[i].className=(fs[i].textContent===name)?'f on':'f';}}" & \
      "function open1(name){api('/api/read?path='+encodeURIComponent(name)).then(function(r){if(!r.ok){say('Could not open '+name);return null;}return r.text();})" & \
      ".then(function(t){if(t===null)return;cur=name;document.getElementById('path').value=name;document.getElementById('ed').value=t;mark(name);say('Editing '+name);});}" & \
      "function save(){var p=document.getElementById('path').value.trim();if(!p){say('Enter a file path first.');return;}" & \
      "api('/api/write?path='+encodeURIComponent(p),{method:'PUT',body:document.getElementById('ed').value}).then(function(r){" & \
      "return r.text().then(function(t){if(r.ok){say('Saved '+p);if(p!==cur){cur=p;list();}}else{say('Save failed: '+t);}});}).catch(function(){say('Network error.');});}" & \
      "function newFile(){cur='';document.getElementById('path').value='';document.getElementById('ed').value='';mark('');document.getElementById('path').focus();say('New file - type a path, then Save.');}" & \
      "document.getElementById('unlock').onclick=unlock;" & \
      "document.getElementById('pw').addEventListener('keydown',function(e){if(e.key==='Enter')unlock();});" & \
      "document.getElementById('save').onclick=save;" & \
      "document.getElementById('new').onclick=newFile;" & \
      "document.getElementById('reload').onclick=list;" & \
      "})();</script></body></html>")
end qsEditHtml

-- Route: a folder (listing or its index.html, with a trailing-slash redirect), a
-- file (streamed, Range-aware), else 404. Only GET/HEAD; ".." refused.
command qsFsServePath pStream, pHeaders
   local tRaw, tPath, tDisk, tIndex, tMethod, tRoot, tSpa, tRouteKey
   put pHeaders["__method"] into tMethod
   put pHeaders["__path"] into tRaw          -- still %xx-encoded; used for the redirect Location
   put urlDecode(tRaw) into tPath            -- real chars for disk mapping
   if tPath is empty then
      put "/" into tPath
   end if
   -- traversal guard AFTER decoding, before any disk touch AND before route dispatch
   replace "\" with "/" in tPath
   if tPath contains ".." then
      qsFsSendText pStream, "403 Forbidden", "text/plain; charset=utf-8", "Forbidden."
      exit qsFsServePath
   end if
   if qsPathHasControl(tPath) then
      qsFsSendText pStream, "400 Bad Request", "text/plain; charset=utf-8", "Bad request."
      exit qsFsServePath
   end if
   -- unframeable request: a chunked body or conflicting Content-Lengths would
   -- desync body extraction, so refuse before any route sees it (mirrors qsCwServe)
   if pHeaders["transfer-encoding"] contains "chunked" or pHeaders["__dupcl"] is "true" then
      qsFsSendText pStream, "400 Bad Request", "text/plain; charset=utf-8", "Unsupported request framing."
      exit qsFsServePath
   end if
   qsAccessLog "via Tor", tMethod, tPath
   -- a registered dynamic route answers FIRST (any method, so a POST works); only
   -- then does the static GET/HEAD pipeline apply. Hand the handler the decoded path.
   put toUpper(tMethod) & space & tPath into tRouteKey
   if sHttpRoutes[tRouteKey] is not empty then
      put tPath into pHeaders["__path"]
      qsHttpDispatch ("ox:" & pStream), sHttpRoutes[tRouteKey], pHeaders
      exit qsFsServePath
   end if
   if tMethod is not "GET" and tMethod is not "HEAD" then
      qsFsSendText pStream, "405 Method Not Allowed", "text/plain; charset=utf-8", "Only GET and HEAD are supported."
      exit qsFsServePath
   end if
   put sActiveShare["root"] into tRoot
   if tRoot is empty then
      qsFsSendText pStream, "503 Service Unavailable", "text/plain; charset=utf-8", "No folder is being shared."
      exit qsFsServePath
   end if
   -- dotfiles are invisible to the static pipeline (see qsHasDotSegment)
   if qsHasDotSegment(tPath) then
      qsFsSendText pStream, "404 Not Found", "text/html; charset=utf-8", qsFsNotFound(tPath)
      exit qsFsServePath
   end if
   put tRoot & tPath into tDisk
   if there is a folder tDisk then
      if the last char of tPath is not "/" then
         qsFsSendRedirect pStream, (tRaw & "/")
         exit qsFsServePath
      end if
      put tDisk & "index.html" into tIndex    -- tDisk ends with "/" here
      if there is a file tIndex then
         qsFsServeFile pStream, tIndex, "index.html", pHeaders
      else
         qsFsSendText pStream, "200 OK", "text/html; charset=utf-8", qsFsListing(tDisk, tPath)
      end if
      exit qsFsServePath
   end if
   if there is a file tDisk then
      qsFsServeFile pStream, tDisk, tPath, pHeaders
      exit qsFsServePath
   end if
   -- unresolved: a SPA route falls back to index.html; otherwise a real 404
   put qsSiteSpaTarget(tRoot, tPath) into tSpa
   if tSpa is not empty then
      qsFsServeFile pStream, tSpa, "index.html", pHeaders
   else
      qsFsSendText pStream, "404 Not Found", "text/html; charset=utf-8", qsFsNotFound(tPath)
   end if
end qsFsServePath

-- Response headers added to EVERYTHING we serve (both transports), as CRLF-terminated
-- lines: identify the server, forbid MIME sniffing (safer when hosting untrusted-looking
-- files), and - because the folder can be edited live - tell the browser to revalidate
-- rather than serve a stale cached copy.
function qsHttpExtraHeaders
   local tCrlf
   put (numToChar(13) & numToChar(10)) into tCrlf
   return ("Server: newQuickShare" & tCrlf & "X-Content-Type-Options: nosniff" & tCrlf & \
      "Cache-Control: no-cache" & tCrlf)
end qsHttpExtraHeaders

-- A filename safe to drop into a Content-Disposition quoted-string: printable ASCII
-- only, no quote/backslash/control byte (so we never need RFC 5987 encoding). Empty in
-- -> "download".
function qsSafeFilename pName
   local tOut, tCh, tN
   put "" into tOut
   repeat for each char tCh in pName
      put charToNum(tCh) into tN
      if tN >= 32 and tN <= 126 and tCh is not quote and tCh is not "\" then
         put tCh after tOut
      end if
   end repeat
   if tOut is empty then
      return "download"
   end if
   return tOut
end qsSafeFilename

-- Content-Disposition so a saved file keeps its REAL name (not the URL token): "inline"
-- by default (a browser still renders html/img/pdf in place), upgraded to "attachment"
-- (force a download) when the request carries ?dl. CRLF-terminated. Transport-neutral.
function qsHttpDisposition pForMime, pHeaders
   local tName, tKind, tCrlf
   put (numToChar(13) & numToChar(10)) into tCrlf
   put qsSafeFilename(qsFsLeaf(pForMime)) into tName
   if qsQueryParam(pHeaders["__query"], "dl") is not empty then
      put "attachment" into tKind
   else
      put "inline" into tKind
   end if
   return ("Content-Disposition: " & tKind & "; filename=" & quote & tName & quote & tCrlf)
end qsHttpDisposition

-- The clearweb peer's IP, from the accepted-socket id "<ip>:<port>[|n]".
function qsCwPeer pSocketID
   local tIp, tSavedID
   put the itemDelimiter into tSavedID
   set the itemDelimiter to ":"
   put item 1 of pSocketID into tIp
   set the itemDelimiter to tSavedID
   return tIp
end qsCwPeer

-- A compact ACCESS-LOG line in the Activity panel, so you can SEE the server working:
-- who connected and what they asked for. pPeer is an IP (clearweb) or "via Tor".
command qsAccessLog pPeer, pMethod, pPath
   qsLog (pPeer & "  " & toUpper(pMethod) & " " & pPath)
end qsAccessLog

-- Serve a file: size it, honour a Range, write the HTTP head, then arm the pump. The
-- file is NEVER read whole into memory.
command qsFsServeFile pStream, pDisk, pForMime, pHeaders
   local tSize, tRange, tStart, tEnd, tLen, tStatus, tHead, tCrlf, tType, tSavedID
   put qsFileSize(pDisk) into tSize
   if tSize is empty then
      qsFsSendText pStream, "404 Not Found", "text/plain; charset=utf-8", "Not found."
      exit qsFsServeFile
   end if
   put (numToChar(13) & numToChar(10)) into tCrlf
   put qsFsMime(pForMime) into tType
   put qsFsParseRange(pHeaders["range"], tSize) into tRange
   if tRange is "unsatisfiable" then
      put ("HTTP/1.1 416 Range Not Satisfiable" & tCrlf & "Content-Range: bytes */" & tSize & tCrlf & \
         "Content-Length: 0" & tCrlf & "Connection: close" & tCrlf & tCrlf) into tHead
      oxWrite pStream, textEncode(tHead, "UTF-8")
      oxCloseStream pStream
      qsFsCleanup pStream
      exit qsFsServeFile
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
   put qsHttpExtraHeaders() after tHead
   put qsHttpDisposition(pForMime, pHeaders) after tHead
   put ("Connection: close" & tCrlf & tCrlf) after tHead
   oxWrite pStream, textEncode(tHead, "UTF-8")
   if the result is not empty then
      qsFsAbort pStream
      exit qsFsServeFile
   end if
   put qsFsLeaf(pForMime) into sFsTxName[pStream]
   qsLog "Serving " & quote & sFsTxName[pStream] & quote & " (" & qsBytes(tLen) & ") over Tor - " & tStatus
   if pHeaders["__method"] is "HEAD" then
      oxCloseStream pStream
      qsFsCleanup pStream
      exit qsFsServeFile
   end if
   put pDisk into sFsTxPath[pStream]
   put tStart into sFsTxPos[pStream]
   put tLen into sFsTxRemaining[pStream]
   put the milliseconds into sFsTxDeadline[pStream]
   send ("qsFsPump " & pStream) to me in kOnionPumpTick milliseconds
end qsFsServeFile

-- One slice per tick. The file is opened/seeked/read/closed within this single tick
-- (no yield between), so concurrent downloads of the same file never share a cursor.
-- No writability gate (the false-stall lesson): pace on the timer + oxWrite's error.
command qsFsPump pStream
   local tWant, tSlice, tErr
   if sFsTxPath[pStream] is empty then
      exit qsFsPump
   end if
   put kOnionChunk into tWant
   if sFsTxRemaining[pStream] < tWant then
      put sFsTxRemaining[pStream] into tWant
   end if
   if tWant <= 0 then
      qsFsFinish pStream
      exit qsFsPump
   end if
   open file sFsTxPath[pStream] for binary read
   if the result is not empty then
      qsFsAbort pStream
      exit qsFsPump
   end if
   -- VERIFY (on-engine): `seek to N in file` sets the read cursor N bytes from the
   -- START (0-based), so the next read returns bytes [N..].
   seek to sFsTxPos[pStream] in file sFsTxPath[pStream]
   read from file sFsTxPath[pStream] for tWant
   put it into tSlice
   try
      close file sFsTxPath[pStream]
   catch tErr
   end try
   if tSlice is empty then
      qsFsFinish pStream
      exit qsFsPump
   end if
   oxWrite pStream, tSlice
   if the result is not empty then
      qsFsAbort pStream
      exit qsFsPump
   end if
   add (the number of bytes in tSlice) to sFsTxPos[pStream]
   subtract (the number of bytes in tSlice) from sFsTxRemaining[pStream]
   put the milliseconds into sFsTxDeadline[pStream]
   send ("qsFsPump " & pStream) to me in kOnionPumpTick milliseconds
end qsFsPump

command qsFsFinish pStream
   qsLog "Served " & quote & sFsTxName[pStream] & quote & " over Tor."
   oxCloseStream pStream
   qsFsCleanup pStream
end qsFsFinish

command qsFsSendText pStream, pStatus, pType, pBody
   local tData, tHead, tCrlf
   put (numToChar(13) & numToChar(10)) into tCrlf
   put textEncode(pBody, "UTF-8") into tData
   put ("HTTP/1.1 " & pStatus & tCrlf & "Content-Type: " & pType & tCrlf & \
      "Content-Length: " & (the number of bytes in tData) & tCrlf) into tHead
   put qsHttpExtraHeaders() after tHead
   put ("Connection: close" & tCrlf & tCrlf) after tHead
   oxWrite pStream, (textEncode(tHead, "UTF-8") & tData)
   oxCloseStream pStream
   qsFsCleanup pStream
end qsFsSendText

command qsFsSendRedirect pStream, pLocation
   local tHead, tCrlf
   put (numToChar(13) & numToChar(10)) into tCrlf
   put ("HTTP/1.1 301 Moved Permanently" & tCrlf & "Location: " & pLocation & tCrlf & \
      "Content-Length: 0" & tCrlf & "Connection: close" & tCrlf & tCrlf) into tHead
   oxWrite pStream, textEncode(tHead, "UTF-8")
   oxCloseStream pStream
   qsFsCleanup pStream
end qsFsSendRedirect

command qsFsCleanup pStream
   delete variable sFsReq[pStream]
   delete variable sFsServed[pStream]
   delete variable sFsTxPath[pStream]
   delete variable sFsTxPos[pStream]
   delete variable sFsTxRemaining[pStream]
   delete variable sFsTxName[pStream]
   delete variable sFsTxDeadline[pStream]
end qsFsCleanup

command qsFsAbort pStream
   oxCloseStream pStream
   qsFsCleanup pStream
end qsFsAbort

-- Idle watchdog per connection. No-ops once the connection is done/cleaned.
-- Keyed on sFsServed: that is "false"/"true" for the WHOLE life of a connection
-- and only goes empty when qsFsCleanup deletes it. The old sentinel (sFsReq
-- empty) could not tell "cleaned up" from "connected but silent", so a peer
-- that opened a stream and never sent a byte was NEVER reaped - the exact
-- slow-loris hold the watchdog exists to stop (the round-5 deep-dive bug).
command qsFsWatchdog pStream
   if sFsServed[pStream] is empty then
      exit qsFsWatchdog
   end if
   if (the milliseconds - sFsTxDeadline[pStream]) > kOnionSendTimeout then
      qsFsAbort pStream
      exit qsFsWatchdog
   end if
   send ("qsFsWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
end qsFsWatchdog

-- Build the directory-listing page. Uses `the files` / `the folders` (portable;
-- `the detailedFiles` is a compile-time "bad factor" on some OXT engines). Names are
-- HTML-escaped and path-encoded; links are relative so a subfolder browses in.
-- Per-file sizes are omitted (OXT has no cheap size call - sizing every file would
-- read each one just to draw a page); the size is in each file's Content-Length.
-- The browsable directory page (used by BOTH transports). A card with a header
-- (folder icon + path + item-count pill), one rounded row per entry with a
-- type-coloured icon, and a brand footer. Per-file sizes are omitted on purpose (OXT
-- has no cheap size call - sizing every file would read each one just to draw a page);
-- each file's size is in its Content-Length. Rows are built first so the header can
-- show the final count.
function qsFsListing pDiskFolder, pUrlPath
   local tSaved, tFiles, tFolders, tName, tRows, tOut, tCount, tHeading, tBase, tSz
   put the defaultFolder into tSaved
   set the defaultFolder to pDiskFolder
   put the files into tFiles
   put the folders into tFolders
   set the defaultFolder to tSaved
   put pDiskFolder into tBase                -- for per-file sizing; ensure one trailing /
   if the last char of tBase is not "/" then
      put "/" after tBase
   end if
   -- present entries in a stable, case-insensitive A-Z order (the OS order is arbitrary)
   sort lines of tFolders ascending text by toLower(each)
   sort lines of tFiles ascending text by toLower(each)
   put "" into tRows
   put 0 into tCount
   if pUrlPath is not "/" then
      put "<li class='up'><a href='../'><svg class='ic'><use href='#i-up'/></svg><span class='nm'>Up a level</span></a></li>" after tRows
   end if
   repeat for each line tName in tFolders
      if tName is "." or tName is ".." or tName is empty then
         next repeat
      end if
      if char 1 of tName is "." then
         next repeat      -- hidden entries stay hidden (matches the 404 guard)
      end if
      put "<li class='dir t-dir'><a href='" & qsFsPathEncode(tName) & "/'>" & \
         "<svg class='ic'><use href='#i-dir'/></svg><span class='nm'>" & qsFsHtmlEscape(tName) & "</span></a></li>" after tRows
      add 1 to tCount
   end repeat
   repeat for each line tName in tFiles
      if tName is empty then
         next repeat
      end if
      if char 1 of tName is "." then
         next repeat      -- hidden entries stay hidden (matches the 404 guard)
      end if
      -- per-file size (cheap now: the O(log n) seek probe, not a full read)
      put qsBytes(qsFileSize(tBase & tName)) into tSz
      put "<li class='file t-" & qsFsIcon(tName, false) & "'><a href='" & qsFsPathEncode(tName) & "'>" & \
         "<svg class='ic'><use href='#i-" & qsFsIcon(tName, false) & "'/></svg><span class='nm'>" & qsFsHtmlEscape(tName) & \
         "</span><span class='sz'>" & tSz & "</span></a></li>" after tRows
      add 1 to tCount
   end repeat
   if pUrlPath is "/" then
      put "Home" into tHeading
   else
      put qsFsHtmlEscape(pUrlPath) into tHeading
   end if
   put qsFsPageTop("Index of " & qsFsHtmlEscape(pUrlPath)) into tOut
   put qsFsIconSprite() after tOut
   put "<main class='card'><header class='hd'><svg class='fi'><use href='#i-dir'/></svg>" & \
      "<h1>" & tHeading & "</h1><span class='cnt'>" & tCount & " item(s)</span></header>" after tOut
   put "<ul class='fl'>" & tRows & "</ul>" after tOut
   put "<footer class='ft'><svg class='ic'><use href='#i-dl'/></svg>" & \
      "<span>Shared with <b>TorrentXT</b> - downloads resume if interrupted.</span></footer></main>" after tOut
   put qsFsPageBottom() after tOut
   return tOut
end qsFsListing

-- Classify a file (or folder) into an icon/colour type token used by the listing:
-- one of dir/img/vid/aud/code/doc/zip/pdf/file. Mirrors qsFsMime's extension families;
-- the extension is the last dot-item, lowercased. Item delimiter is saved + restored
-- around the whole lookup (it is set to '.' then ',' internally), with a SINGLE exit so
-- it can never leak. Pinned by fs_icon() in tests/fileserver_golden.py.
function qsFsIcon pName, pIsDir
   local tExtn, tSavedID, tType
   if pIsDir then
      return "dir"
   end if
   put "file" into tType
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "."
   put toLower(the last item of pName) into tExtn
   set the itemDelimiter to ","
   if tExtn is among the items of "png,jpg,jpeg,gif,webp,svg,ico,avif,bmp,heic" then
      put "img" into tType
   else if tExtn is among the items of "mp4,m4v,webm,mov,mkv,avi" then
      put "vid" into tType
   else if tExtn is among the items of "mp3,ogg,oga,wav,flac,m4a,aac" then
      put "aud" into tType
   else if tExtn is among the items of "html,htm,css,js,mjs,json,xml,yml,yaml,wasm,map,ts,tsx,jsx,py,rb,go,rs,c,h,cpp,sh" then
      put "code" into tType
   else if tExtn is among the items of "txt,md,log,csv,doc,docx,rtf,odt" then
      put "doc" into tType
   else if tExtn is among the items of "zip,tar,gz,tgz,rar,7z,bz2,xz" then
      put "zip" into tType
   else if tExtn is "pdf" then
      put "pdf" into tType
   end if
   set the itemDelimiter to tSavedID
   return tType
end qsFsIcon

-- The icon set as a hidden inline SVG sprite (defined once per page; each row references
-- a symbol with <use>). Feather-style line icons; they inherit stroke + colour from the
-- .ic / .t-* CSS, so the same geometry recolours per type and adapts to dark mode.
function qsFsIconSprite
   return ("<svg xmlns='http://www.w3.org/2000/svg' width='0' height='0' style='position:absolute' aria-hidden='true'>" & \
      "<symbol id='i-dir' viewBox='0 0 24 24'><path d='M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z'/></symbol>" & \
      "<symbol id='i-file' viewBox='0 0 24 24'><path d='M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z'/><polyline points='13 2 13 9 20 9'/></symbol>" & \
      "<symbol id='i-img' viewBox='0 0 24 24'><rect x='3' y='3' width='18' height='18' rx='2'/><circle cx='8.5' cy='8.5' r='1.5'/><path d='M21 15l-5-5L5 21'/></symbol>" & \
      "<symbol id='i-vid' viewBox='0 0 24 24'><polygon points='23 7 16 12 23 17 23 7'/><rect x='1' y='5' width='15' height='14' rx='2'/></symbol>" & \
      "<symbol id='i-aud' viewBox='0 0 24 24'><path d='M9 18V5l12-2v13'/><circle cx='6' cy='18' r='3'/><circle cx='18' cy='16' r='3'/></symbol>" & \
      "<symbol id='i-code' viewBox='0 0 24 24'><polyline points='16 18 22 12 16 6'/><polyline points='8 6 2 12 8 18'/></symbol>" & \
      "<symbol id='i-doc' viewBox='0 0 24 24'><path d='M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z'/><polyline points='14 2 14 8 20 8'/><line x1='16' y1='13' x2='8' y2='13'/><line x1='16' y1='17' x2='8' y2='17'/></symbol>" & \
      "<symbol id='i-pdf' viewBox='0 0 24 24'><path d='M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z'/><polyline points='14 2 14 8 20 8'/><line x1='16' y1='13' x2='8' y2='13'/><line x1='16' y1='17' x2='8' y2='17'/></symbol>" & \
      "<symbol id='i-zip' viewBox='0 0 24 24'><path d='M21 8v13H3V8'/><rect x='1' y='3' width='22' height='5'/><line x1='10' y1='12' x2='14' y2='12'/></symbol>" & \
      "<symbol id='i-up' viewBox='0 0 24 24'><polyline points='9 14 4 9 9 4'/><path d='M20 20v-7a4 4 0 0 0-4-4H4'/></symbol>" & \
      "<symbol id='i-dl' viewBox='0 0 24 24'><path d='M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4'/><polyline points='7 10 12 15 17 10'/><line x1='12' y1='15' x2='12' y2='3'/></symbol>" & \
      "<symbol id='i-warn' viewBox='0 0 24 24'><circle cx='12' cy='12' r='10'/><line x1='12' y1='8' x2='12' y2='12'/><line x1='12' y1='16' x2='12.01' y2='16'/></symbol>" & \
      "</svg>")
end qsFsIconSprite

function qsFsNotFound pPath
   return (qsFsPageTop("Not found") & qsFsIconSprite() & \
      "<main class='card'><header class='hd'><svg class='fi' style='color:#dc2626'><use href='#i-warn'/></svg>" & \
      "<h1>Not found</h1></header><div class='msg'>There is nothing at " & qsFsHtmlEscape(pPath) & \
      " in this share.<br><br><a href='/'>Back to the top</a></div></main>" & qsFsPageBottom())
end qsFsNotFound

-- Single-page-app fallback (auto, no configuration). When a request does not resolve
-- to a real file or folder, and the served folder is a WEBSITE (has index.html at its
-- root), and the requested path looks like a client-side ROUTE (its last segment has
-- no ".", so it is not a missing asset such as app.js or logo.png), serve the root
-- index.html so the app's own router handles the route - the standard behaviour of a
-- static host for a SPA. Returns the index.html disk path, or empty for "send a real
-- 404". Safe: pRelPath already passed the ".." guard, and we serve a FIXED file (root
-- index.html), never a path-derived one, so there is no traversal here. A folder with
-- no root index.html is a plain file share and never falls back (returns empty). A
-- missing ASSET (a path whose leaf has an extension) always gets a real 404.
function qsSiteSpaTarget pRoot, pRelPath
   local tIndex, tLeaf, tSavedID, tRel
   put pRoot & "/index.html" into tIndex
   if there is no file tIndex then
      return ""
   end if
   put pRelPath into tRel
   replace "\" with "/" in tRel
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "/"
   put the last item of tRel into tLeaf
   set the itemDelimiter to tSavedID
   if tLeaf contains "." then
      return ""
   end if
   return tIndex
end qsSiteSpaTarget

-- THE editor security linchpin. Resolve a browser-supplied relative path to an
-- absolute disk path *confined to the served root*, or return empty to refuse. It
-- rejects anything that could climb out or reach an absolute location before it
-- ever touches the disk: any ".." (dot-dot in any segment), any ":" (a Windows
-- drive or a scheme like http:), and any control byte (NUL / CR / LF / tab, which
-- could smuggle a second path or fool the OS). Then it rebuilds the path from clean
-- segments only - "" and "." are dropped, a bare ".." aborts - so the result is
-- always pRoot followed by ordinary names. Mirrored byte-for-byte by edit_safe_path
-- in tests/fileserver_golden.py, which pins ~20 adversarial vectors; change both
-- together or the confinement guarantee drifts. NOTE this is LEXICAL confinement: the
-- returned string is guaranteed under pRoot, but if the sharer placed a SYMLINK inside
-- the shared folder pointing elsewhere, the OS follows it on open. The editor never
-- CREATES links (a save always writes a regular file), so this is only reachable via a
-- link the sharer put there themselves - on a LAN-only, password-gated surface. Don't
-- share a folder containing links you would not want followed.
function qsEditSafePath pRoot, pRelPath
   local tRel, tSeg, tOut, tSavedID, tCh, tBad
   put pRelPath into tRel
   replace "\" with "/" in tRel
   if tRel contains ".." then
      return ""
   end if
   if tRel contains ":" then
      return ""
   end if
   put false into tBad
   repeat for each char tCh in tRel
      if charToNum(tCh) < 32 then
         put true into tBad
      end if
   end repeat
   if tBad then
      return ""
   end if
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "/"
   put "" into tOut
   repeat for each item tSeg in tRel
      if tSeg is empty or tSeg is "." then
         next repeat
      end if
      if tSeg is ".." then
         set the itemDelimiter to tSavedID
         return ""
      end if
      put "/" & tSeg after tOut
   end repeat
   set the itemDelimiter to tSavedID
   if tOut is empty then
      return ""
   end if
   return pRoot & tOut
end qsEditSafePath

-- Shared page chrome. Single-quoted HTML attributes so the string literals never
-- contain a double quote. Light + dark, mobile-friendly, no external assets.
-- Shared page chrome (folder listing, 404, web-download-off). Single-quoted HTML
-- attributes so the string literal never needs a double quote. A centred card with a
-- gradient header, rounded rows, type-coloured icons, and a brand footer; light + dark,
-- mobile-friendly, fully self-contained (no external asset - required over Tor and CSP).
function qsFsPageTop pTitle
   return ("<!doctype html><html><head><meta charset='utf-8'>" & \
      "<meta name='viewport' content='width=device-width,initial-scale=1'>" & \
      "<title>" & pTitle & "</title><style>" & \
      "*{box-sizing:border-box}" & \
      "body{font-family:system-ui,-apple-system,sans-serif;margin:0;padding:2.2em 1em;color:#1c2430;background:#f4f6fa;-webkit-font-smoothing:antialiased}" & \
      ".card{max-width:52em;margin:0 auto;background:#fff;border:1px solid #e6e9f0;border-radius:14px;box-shadow:0 1px 3px rgba(20,30,50,.06),0 10px 34px rgba(20,30,50,.05);overflow:hidden}" & \
      ".hd{display:flex;align-items:center;gap:.7em;padding:1.05em 1.25em;border-bottom:1px solid #eef1f6;background:linear-gradient(180deg,#fbfcfe,#f5f8fc)}" & \
      ".hd .fi{width:26px;height:26px;color:#2c5aa0;flex:0 0 auto;fill:none;stroke:currentColor;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}" & \
      ".hd h1{font-size:1.05em;margin:0;font-weight:640;letter-spacing:.2px;word-break:break-all}" & \
      ".hd .cnt{margin-left:auto;font-size:.76em;color:#5b6472;background:#eef2f8;border:1px solid #e2e8f2;padding:.18em .62em;border-radius:999px;white-space:nowrap}" & \
      "ul.fl{list-style:none;margin:0;padding:.4em}" & \
      "ul.fl li a{display:flex;align-items:center;gap:.72em;padding:.5em .72em;border-radius:9px;color:inherit;text-decoration:none;transition:background .12s}" & \
      "ul.fl li a:hover{background:#f1f5fb}" & \
      "ul.fl li .nm{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" & \
      "ul.fl li .sz{flex:0 0 auto;color:#8a909a;font-size:.85em;font-variant-numeric:tabular-nums;padding-left:1em}" & \
      "ul.fl li.dir .nm{font-weight:600;color:#2c5aa0}" & \
      "ul.fl li.up a{color:#8a909a}ul.fl li.up .nm{font-size:.9em}" & \
      ".ic{width:20px;height:20px;flex:0 0 auto;fill:none;stroke:currentColor;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}" & \
      ".t-dir .ic{color:#e8a317}.t-img .ic{color:#22a06b}.t-vid .ic{color:#8b5cf6}.t-aud .ic{color:#ec4899}" & \
      ".t-code .ic{color:#3b82f6}.t-doc .ic{color:#64748b}.t-zip .ic{color:#b45309}.t-pdf .ic{color:#dc2626}.t-file .ic{color:#94a3b8}" & \
      ".ft{display:flex;align-items:center;gap:.5em;padding:.85em 1.25em;border-top:1px solid #eef1f6;background:#fafbfd;color:#8a909a;font-size:.82em}" & \
      ".ft .ic{width:15px;height:15px;color:#2c5aa0}.ft b{font-weight:600;color:#2c5aa0}" & \
      ".msg{padding:1.4em 1.25em;color:#5b6472;line-height:1.55}.msg a{color:#2c5aa0}" & \
      "@media(prefers-color-scheme:dark){" & \
      "body{background:#0e1116;color:#dfe4ea}" & \
      ".card{background:#161a20;border-color:#262c35;box-shadow:0 1px 3px rgba(0,0,0,.3),0 12px 38px rgba(0,0,0,.32)}" & \
      ".hd{background:linear-gradient(180deg,#1a1f26,#161a20);border-color:#242a33}" & \
      ".hd .fi{color:#7ea6e0}.hd .cnt{background:#20262f;border-color:#2b323c;color:#aab2bf}" & \
      "ul.fl li a:hover{background:#1e242c}ul.fl li.dir .nm{color:#7ea6e0}" & \
      ".ft{background:#141820;border-color:#242a33;color:#828a96}.ft .ic,.ft b{color:#7ea6e0}" & \
      ".msg{color:#aab2bf}.msg a{color:#7ea6e0}}" & \
      "</style></head><body>")
end qsFsPageTop

function qsFsPageBottom
   return "</body></html>"
end qsFsPageBottom

-- The leaf (basename) of a path, for the log.
function qsFsLeaf pPath
   local tOut, tSavedID
   put pPath into tOut
   replace "\" with "/" in tOut
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "/"
   put the last item of tOut into tOut
   set the itemDelimiter to tSavedID
   return tOut
end qsFsLeaf

-- Parse a single HTTP byte-range against a known total. Returns "start,end"
-- (inclusive, 0-based), "" (no/ignored range -> whole file), or "unsatisfiable"
-- (valid but out of bounds -> 416). Matches tests/fileserver_golden.py.
function qsFsParseRange pRange, pTotal
   local tSpec, tStart, tEnd, tSavedID
   if pRange is empty then
      return ""
   end if
   if not (pRange begins with "bytes=") then
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
end qsFsParseRange

-- Map a file extension to a MIME type. Unknown -> octet-stream (the browser
-- downloads it); known media/text/image types render inline.
function qsFsMime pPath
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
   else if tExtn is "wasm" then
      return "application/wasm"
   else if tExtn is "mjs" then
      return "application/javascript; charset=utf-8"
   else if tExtn is "xml" then
      return "application/xml; charset=utf-8"
   else if tExtn is "map" then
      return "application/json; charset=utf-8"
   else if tExtn is "webmanifest" then
      return "application/manifest+json"
   else if tExtn is "woff" then
      return "font/woff"
   else if tExtn is "woff2" then
      return "font/woff2"
   else if tExtn is "ttf" then
      return "font/ttf"
   else if tExtn is "otf" then
      return "font/otf"
   else if tExtn is "eot" then
      return "application/vnd.ms-fontobject"
   else if tExtn is "avif" then
      return "image/avif"
   else if tExtn is "csv" then
      return "text/csv; charset=utf-8"
   end if
   return "application/octet-stream"
end qsFsMime

-- Encode a name for a URL PATH segment ("+" -> "%20" so a space is a path space).
function qsFsPathEncode pName
   local tEnc
   put urlEncode(pName) into tEnc
   replace "+" with "%20" in tEnc
   return tEnc
end qsFsPathEncode

-- Escape a value for HTML so a crafted file name cannot inject markup ("&" first).
function qsFsHtmlEscape pText
   local tOut
   put pText into tOut
   replace "&" with "&amp;" in tOut
   replace "<" with "&lt;" in tOut
   replace ">" with "&gt;" in tOut
   replace quote with "&quot;" in tOut
   replace "'" with "&#39;" in tOut
   return tOut
end qsFsHtmlEscape

-- ==== the CLEARWEB web server (a direct browser link, no Tor) =================
-- Serves the shared file/folder over a plain LiveCode socket HTTP server, so the
-- recipient just opens http://<ip>:<port>/<token>/... in ANY browser - no app, no
-- Tor. TorrentXT's libtorrent opens the router port automatically (btMapPort /
-- UPnP-NAT-PMP) and reports the public IP (the externalIp event); the LAN link always
-- works. The <token> (random capability string) gates every request, so an open port
-- is not an open directory to port-scanners. Reuses the qsFs* pure helpers
-- (parse/route/listing/range/mime/escape); only the I/O differs - LiveCode sockets,
-- mirroring OnionXT's proven on-engine accept/read/write/close idiom.
--
-- NEEDS AN ON-ENGINE PASS: the socket, UPnP, and local-IP calls are the most
-- engine-dependent code in this demo. Each such site is flagged VERIFY.

command qsStartClearweb pPath, pName
   local tErr, tPort
   if sSession is 0 or sSession is empty then
      qsLog "No session - reopen the stack."
      exit qsStartClearweb
   end if
   if sCwActive is "true" then
      qsStopClearweb            -- one active clearweb share at a time
   end if
   replace "\" with "/" in pPath
   if the last char of pPath is "/" then
      delete the last char of pPath
   end if
   if there is a folder pPath then
      put "folder" into sCwKind
      put pPath into sCwRoot
      put "" into sCwFilePath
      put "" into sCwFileName
   else if there is a file pPath then
      put "file" into sCwKind
      put "" into sCwRoot
      put pPath into sCwFilePath
      put qsFsLeaf(pPath) into sCwFileName
   else
      qsLog "Could not find that file or folder to share on the web."
      exit qsStartClearweb
   end if
   put qsSafeLeaf(pName) into sCwName
   put qsMakeToken() into sCwToken
   put qsPickPort() into tPort
   put tPort into sCwPort
   -- VERIFY (on-engine): `accept connections on port N with message` starts a TCP
   -- listener (bound to ALL interfaces, so LAN + WAN clients reach it); `the result`
   -- is empty on success, else the bind error (usually the port is in use). Mirrors
   -- OnionXT's oxStartService listener.
   accept connections on port tPort with message "qsCwAccept"
   if the result is not empty then
      qsLog "Could not start the web server on port " & tPort & " (" & the result & "). Drop it again to try another port."
      exit qsStartClearweb
   end if
   put "true" into sCwActive
   put 0 into sCwMapId
   put "false" into sCwMapped
   put empty into sCwExtIp
   put qsLanIp() into sCwLanIp
   -- Ask the router to open the port automatically (UPnP / NAT-PMP via libtorrent).
   -- Best-effort and NON-FATAL: this is only for the INTERNET link - the LAN link
   -- works without it - so any failure (an older native library without the port-map
   -- ABI, UPnP off, no mapper) must never break the share. Wrap it so a throw or a 0
   -- both just mean "no automatic internet link". A portMapped / portMapError /
   -- externalIp event arrives later through the poll loop and fills in the link.
   put 0 into sCwMapId
   try
      put btMapPort(sSession, tPort, tPort, true) into sCwMapId
   catch tErr
      put 0 into sCwMapId
   end try
   if sCwMapId is 0 then
      qsLog "Could not ask the router to open the port automatically (UPnP/NAT-PMP off or unsupported). The local-network link works now; for the internet, forward port " & tPort & " (TCP) to this computer manually, or use Tor."
   else
      qsLog "Asked the router to open port " & tPort & " automatically - waiting for it to confirm (a portMapped or portMapError follows)."
   end if
   -- Find our public IP so the internet link can show a real address. libtorrent only
   -- reports it (the externalIp event) once it sees peer/tracker traffic, which a
   -- torrent-less clearweb session never has - so we ask a lightweight HTTP echo. This
   -- also returns the TRUE internet-facing IP, making carrier-NAT detection accurate.
   qsCwFetchPublicIp
   qsCwShowLinks       -- qsCwStatusText (inside) sets the Sharing line for the state
   qsLog "Web share started for " & quote & sCwName & quote & " on port " & tPort & ". On the same network the link works right away."
   qsEditShowLink      -- if the editor is armed and this is a folder, point to /_edit
end qsStartClearweb

command qsStopClearweb
   local tK, tErr, tRc
   if not sCwActive then
      exit qsStopClearweb
   end if
   qsCwSafeClose sCwPort        -- VERIFY: closing the port-id socket stops accepting
   repeat for each key tK in sCwReq
      qsCwSafeClose tK
      qsCwClean tK
   end repeat
   if sCwMapId is not 0 and sSession is not 0 and sSession is not empty then
      try
         put btUnmapPort(sSession, sCwMapId) into tRc
      catch tErr
      end try
   end if
   put "false" into sCwActive
   put 0 into sCwMapId
   put empty into sCwToken
   put empty into sCwRoot
   put empty into sCwFilePath
   -- clear the left-panel link only if it still shows THIS web share: a code share
   -- created afterwards may own the field now (concurrent shares), and wiping it would
   -- lose that share's code from view.
   if sCwLink is not empty and the text of field "qsCode" is sCwLink then
      set the text of field "qsCode" to ""
      set the text of field "qsSharing" to ""
   end if
   set the text of field "qsWebLink" to ""
   put empty into sCwLink
   qsLog "Web share stopped."
end qsStopClearweb

-- A browser connected. Stream the request in (`read ... with message`, re-armed per
-- delivery - OnionXT's proven pattern) and answer once the header block arrives.
command qsCwAccept pSocketID
   if not sCwActive then
      qsCwSafeClose pSocketID
      exit qsCwAccept
   end if
   -- bound concurrent connections: per-socket state rides eleven sCw* arrays
   -- plus a watchdog timer, and UPnP exposes this port to the whole internet -
   -- refuse at accept beyond the cap so a connect flood cannot grow them.
   if the number of lines of (the keys of sCwServed) >= kCwMaxConns then
      qsCwSafeClose pSocketID
      exit qsCwAccept
   end if
   put "" into sCwReq[pSocketID]
   put "false" into sCwServed[pSocketID]
   put "false" into sCwKeep[pSocketID]
   put "" into sCwMethod[pSocketID]        -- no method parsed yet (qsCwServe sets it)
   put 0 into sCwReqCount[pSocketID]
   put the milliseconds into sCwDeadline[pSocketID]
   read from socket pSocketID with message "qsCwData"
   -- idle watchdog: closes a connection that stalls (never sends, or a kept-alive
   -- connection that goes quiet), so a slow-loris or an abandoned keep-alive cannot
   -- pile up sockets. Re-armed while the connection makes progress (qsCwData/qsCwWrote
   -- refresh sCwDeadline). The socket id ("ip:port") MUST be quoted: `send` re-parses
   -- the trailing text as an expression, and an unquoted id syntax-errors instead of
   -- arriving intact.
   send ("qsCwWatchdog " & quote & pSocketID & quote) to me in kCwIdleTimeout milliseconds
end qsCwAccept

command qsCwData pSocketID, pData
   if sCwServed[pSocketID] is empty then
      exit qsCwData            -- not one of ours (or already cleaned up)
   end if
   if sCwServed[pSocketID] is "true" then
      exit qsCwData            -- already answering; ignore trailing bytes
   end if
   put the milliseconds into sCwDeadline[pSocketID]   -- recv activity: not idle
   put pData after sCwReq[pSocketID]
   if the number of bytes in sCwReq[pSocketID] > kFsMaxReq then
      put "true" into sCwServed[pSocketID]
      -- this path never runs qsCwServe, so sCwKeep still holds the PREVIOUS request's
      -- decision on a reused connection. Force close: the request is oversized/unframed,
      -- so continuing (qsCwNext) would mis-trim the unread body into bogus requests.
      put "false" into sCwKeep[pSocketID]
      qsCwSendText pSocketID, "413 Payload Too Large", "text/plain; charset=utf-8", "Request too large."
      exit qsCwData
   end if
   if qsHttpReqComplete(sCwReq[pSocketID]) then
      put "true" into sCwServed[pSocketID]
      qsCwServe pSocketID
   else
      read from socket pSocketID with message "qsCwData"   -- more head/body to come
   end if
end qsCwData

-- Parse, check the capability token (the first path segment), then route: for a file
-- share only the one file is reachable; for a folder share, browse within the root.
command qsCwServe pSocketID
   local tHeaders, tMethod, tRaw, tPath, tTok, tRest, tDisk, tIndex, tSavedID, tSpa, tRouteKey
   put qsHttpParse(sCwReq[pSocketID]) into tHeaders
   put tHeaders["__method"] into tMethod
   put tMethod into sCwMethod[pSocketID]   -- a HEAD reply must carry no body (qsCwSendText)
   put tHeaders["__path"] into tRaw
   -- decide keep-alive for THIS request. We can only frame a request that ends at its
   -- Content-Length; a chunked body is unframeable, so refuse it (and close, so its
   -- trailing bytes can never be mis-read as the next request). HTTP/1.1 defaults to
   -- keep-alive unless "Connection: close"; HTTP/1.0 needs an explicit "keep-alive".
   put "false" into sCwKeep[pSocketID]
   -- unframeable request: a chunked body OR conflicting Content-Lengths would
   -- desync keep-alive trimming into bogus requests. Refuse and (sCwKeep is
   -- still false here) close, so no trailing bytes are ever re-framed.
   if tHeaders["transfer-encoding"] contains "chunked" or tHeaders["__dupcl"] is "true" then
      qsCwSendText pSocketID, "400 Bad Request", "text/plain; charset=utf-8", "Unsupported request framing."
      exit qsCwServe
   end if
   if tHeaders["__version"] is "HTTP/1.1" then
      if toLower(tHeaders["connection"]) is not "close" then
         put "true" into sCwKeep[pSocketID]
      end if
   else
      if toLower(tHeaders["connection"]) is "keep-alive" then
         put "true" into sCwKeep[pSocketID]
      end if
   end if
   put urlDecode(tRaw) into tPath
   replace "\" with "/" in tPath
   if tPath contains ".." then
      qsCwSendText pSocketID, "403 Forbidden", "text/plain; charset=utf-8", "Forbidden."
      exit qsCwServe
   end if
   if qsPathHasControl(tPath) then
      qsCwSendText pSocketID, "400 Bad Request", "text/plain; charset=utf-8", "Bad request."
      exit qsCwServe
   end if
   qsAccessLog qsCwPeer(pSocketID), tMethod, tPath
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "/"
   put item 2 of tPath into tTok            -- /<token>/... ; item 1 is "" (leading /)
   if the number of items of tPath >= 3 then
      put "/" & (item 3 to -1 of tPath) into tRest
   else
      put "/" into tRest
   end if
   set the itemDelimiter to tSavedID
   if tTok is not sCwToken then
      qsCwSendText pSocketID, "404 Not Found", "text/plain; charset=utf-8", "Not found."
      exit qsCwServe
   end if
   -- a registered dynamic route (under the token) answers FIRST, any method. Give the
   -- handler the app-relative path (token stripped) so a route is transport-neutral.
   put toUpper(tMethod) & space & tRest into tRouteKey
   if sHttpRoutes[tRouteKey] is not empty then
      put tRest into tHeaders["__path"]
      qsHttpDispatch ("cw:" & pSocketID), sHttpRoutes[tRouteKey], tHeaders
      exit qsCwServe
   end if
   if tMethod is not "GET" and tMethod is not "HEAD" then
      qsCwSendText pSocketID, "405 Method Not Allowed", "text/plain; charset=utf-8", "Only GET and HEAD are supported."
      exit qsCwServe
   end if
   if sCwKind is "file" then
      -- only the one shared file is reachable: "/<token>/" or "/<token>/<name>"
      if tRest is "/" or tRest is ("/" & sCwFileName) then
         qsCwServeFile pSocketID, sCwFilePath, sCwFileName, tHeaders
      else
         qsCwSendText pSocketID, "404 Not Found", "text/plain; charset=utf-8", "Not found."
      end if
      exit qsCwServe
   end if
   -- folder share: route tRest within sCwRoot (mirrors qsFsServePath). Dotfiles
   -- are invisible here (qsHasDotSegment); the single-FILE share above is exempt
   -- on purpose - explicitly choosing a dotfile to share is the sharer's intent.
   if qsHasDotSegment(tRest) then
      qsCwSendText pSocketID, "404 Not Found", "text/html; charset=utf-8", qsFsNotFound(tRest)
      exit qsCwServe
   end if
   put sCwRoot & tRest into tDisk
   if there is a folder tDisk then
      if the last char of tRest is not "/" then
         qsCwSendRedirect pSocketID, (tRaw & "/")
         exit qsCwServe
      end if
      put tDisk & "index.html" into tIndex
      if there is a file tIndex then
         qsCwServeFile pSocketID, tIndex, "index.html", tHeaders
      else
         qsCwSendText pSocketID, "200 OK", "text/html; charset=utf-8", qsFsListing(tDisk, tRest)
      end if
      exit qsCwServe
   end if
   if there is a file tDisk then
      qsCwServeFile pSocketID, tDisk, tRest, tHeaders
      exit qsCwServe
   end if
   -- unresolved: a SPA route falls back to index.html; otherwise a real 404
   put qsSiteSpaTarget(sCwRoot, tRest) into tSpa
   if tSpa is not empty then
      qsCwServeFile pSocketID, tSpa, "index.html", tHeaders
   else
      qsCwSendText pSocketID, "404 Not Found", "text/html; charset=utf-8", qsFsNotFound(tRest)
   end if
end qsCwServe

-- Serve a file over the socket: size it, honour a Range, write the head, then pump the
-- body. The file is opened/seeked/read/closed within each pump tick (concurrency-safe).
command qsCwServeFile pSocketID, pDisk, pForMime, pHeaders
   local tSize, tRange, tStart, tEnd, tLen, tStatus, tHead, tCrlf, tType, tSavedID
   put qsFileSize(pDisk) into tSize
   if tSize is empty then
      qsCwSendText pSocketID, "404 Not Found", "text/plain; charset=utf-8", "Not found."
      exit qsCwServeFile
   end if
   put (numToChar(13) & numToChar(10)) into tCrlf
   put qsFsMime(pForMime) into tType
   put qsFsParseRange(pHeaders["range"], tSize) into tRange
   if tRange is "unsatisfiable" then
      qsCwWriteClose pSocketID, textEncode(("HTTP/1.1 416 Range Not Satisfiable" & tCrlf & \
         "Content-Range: bytes */" & tSize & tCrlf & "Content-Length: 0" & tCrlf & \
         "Connection: close" & tCrlf & tCrlf), "UTF-8")
      exit qsCwServeFile
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
   put qsHttpExtraHeaders() after tHead
   put qsHttpDisposition(pForMime, pHeaders) after tHead
   put ("Connection: close" & tCrlf & tCrlf) after tHead
   write textEncode(tHead, "UTF-8") to socket pSocketID
   if the result is not empty then
      qsCwClose pSocketID
      exit qsCwServeFile
   end if
   put qsFsLeaf(pForMime) into sCwTxName[pSocketID]
   qsLog "Web: serving " & quote & sCwTxName[pSocketID] & quote & " (" & qsBytes(tLen) & ") - " & tStatus
   if pHeaders["__method"] is "HEAD" then
      qsCwClose pSocketID
      exit qsCwServeFile
   end if
   put pDisk into sCwTxPath[pSocketID]
   put tStart into sCwTxPos[pSocketID]
   put tLen into sCwTxRemaining[pSocketID]
   qsCwPump pSocketID
end qsCwServeFile

-- One slice per call, paced by the socket write-completion callback (qsCwWrote) for
-- natural backpressure - no unbounded buffering of a big file. The file is
-- opened/seeked/read/closed within this call (no yield), so concurrent downloads of
-- the same file never share a cursor.
command qsCwPump pSocketID
   local tWant, tSlice, tErr
   if sCwTxPath[pSocketID] is empty then
      exit qsCwPump
   end if
   put kCwChunk into tWant
   if sCwTxRemaining[pSocketID] < tWant then
      put sCwTxRemaining[pSocketID] into tWant
   end if
   if tWant <= 0 then
      qsCwFinish pSocketID
      exit qsCwPump
   end if
   open file sCwTxPath[pSocketID] for binary read
   if the result is not empty then
      qsCwClose pSocketID
      exit qsCwPump
   end if
   -- VERIFY (on-engine): `seek to N in file` sets the read cursor N bytes from the
   -- START (0-based), so the next read returns bytes [N..].
   seek to sCwTxPos[pSocketID] in file sCwTxPath[pSocketID]
   read from file sCwTxPath[pSocketID] for tWant
   put it into tSlice
   try
      close file sCwTxPath[pSocketID]
   catch tErr
   end try
   if tSlice is empty then
      qsCwFinish pSocketID
      exit qsCwPump
   end if
   add (the number of bytes in tSlice) to sCwTxPos[pSocketID]
   subtract (the number of bytes in tSlice) from sCwTxRemaining[pSocketID]
   -- VERIFY (on-engine): `write ... to socket ... with message` calls the handler when
   -- the slice has been sent, giving backpressure. Mirrors OnionXT's write idiom.
   write tSlice to socket pSocketID with message "qsCwWrote"
   if the result is not empty then
      qsCwClose pSocketID
   end if
end qsCwPump

command qsCwWrote pSocketID
   if sCwTxPath[pSocketID] is empty then
      exit qsCwWrote           -- already finished/cleaned
   end if
   put the milliseconds into sCwDeadline[pSocketID]   -- send progress: not idle
   qsCwPump pSocketID
end qsCwWrote

command qsCwFinish pSocketID
   qsLog "Web: sent " & quote & sCwTxName[pSocketID] & quote & "."
   qsCwClose pSocketID
end qsCwFinish

-- Small text/redirect responses: fully buffered, with an exact Content-Length, so they
-- are the ONLY responses that may keep the connection alive (a streamed file always
-- closes - see qsCwServeFile). qsCwWantsKeep decides per response; on keep-alive we
-- write with a "continue" completion (qsCwNext), else the terminal "close" completion.
-- We always write BEFORE closing (a raw socket can drop unsent bytes if closed at once).
function qsCwWantsKeep pSocketID
   -- "< cap - 1": the response that will be the LAST one allowed must advertise close,
   -- so we never send "keep-alive" and then close the socket under a pipelined next
   -- request. Still serves exactly kCwMaxKeepAlive requests per connection.
   return (sCwKeep[pSocketID] is "true" and sCwReqCount[pSocketID] < (kCwMaxKeepAlive - 1))
end qsCwWantsKeep

command qsCwSendText pSocketID, pStatus, pType, pBody
   local tData, tHead, tCrlf, tKeep, tBody
   put (numToChar(13) & numToChar(10)) into tCrlf
   put textEncode(pBody, "UTF-8") into tData
   put qsCwWantsKeep(pSocketID) into tKeep
   put ("HTTP/1.1 " & pStatus & tCrlf & "Content-Type: " & pType & tCrlf & \
      "Content-Length: " & (the number of bytes in tData) & tCrlf) into tHead
   put qsHttpExtraHeaders() after tHead
   -- a HEAD reply must report the accurate Content-Length a GET would return but send NO
   -- body; on a kept-alive connection an unread body would be mis-read as the framing of
   -- the next response. (The file path already handles HEAD in qsCwServeFile.)
   if sCwMethod[pSocketID] is "HEAD" then
      put "" into tBody
   else
      put tData into tBody
   end if
   if tKeep then
      put ("Connection: keep-alive" & tCrlf & tCrlf) after tHead
      qsCwWriteContinue pSocketID, (textEncode(tHead, "UTF-8") & tBody)
   else
      put ("Connection: close" & tCrlf & tCrlf) after tHead
      qsCwWriteClose pSocketID, (textEncode(tHead, "UTF-8") & tBody)
   end if
end qsCwSendText

command qsCwSendRedirect pSocketID, pLocation
   local tHead, tCrlf, tKeep
   put (numToChar(13) & numToChar(10)) into tCrlf
   put qsCwWantsKeep(pSocketID) into tKeep
   put ("HTTP/1.1 301 Moved Permanently" & tCrlf & "Location: " & pLocation & tCrlf & \
      "Content-Length: 0" & tCrlf) into tHead
   if tKeep then
      put ("Connection: keep-alive" & tCrlf & tCrlf) after tHead
      qsCwWriteContinue pSocketID, textEncode(tHead, "UTF-8")
   else
      put ("Connection: close" & tCrlf & tCrlf) after tHead
      qsCwWriteClose pSocketID, textEncode(tHead, "UTF-8")
   end if
end qsCwSendRedirect

command qsCwWriteClose pSocketID, pBytes
   put "true" into sCwWriting[pSocketID]   -- a buffered flush is in flight (watchdog: not idle)
   write pBytes to socket pSocketID with message "qsCwWroteClose"
   if the result is not empty then
      qsCwClose pSocketID
   end if
end qsCwWriteClose

command qsCwWroteClose pSocketID
   put "false" into sCwWriting[pSocketID]
   qsCwClose pSocketID
end qsCwWroteClose

-- Keep-alive write: after the response flushes, DO NOT close - advance to the next
-- request on the same connection.
command qsCwWriteContinue pSocketID, pBytes
   put "true" into sCwWriting[pSocketID]   -- a buffered flush is in flight (watchdog: not idle)
   write pBytes to socket pSocketID with message "qsCwWroteContinue"
   if the result is not empty then
      qsCwClose pSocketID
   end if
end qsCwWriteContinue

command qsCwWroteContinue pSocketID
   put "false" into sCwWriting[pSocketID]
   qsCwNext pSocketID
end qsCwWroteContinue

-- One response is fully sent on a kept-alive connection: drop the request we just
-- answered from the buffer (preserving any pipelined bytes for the next one), bump the
-- per-connection request count against the cap, then serve or await the next request.
command qsCwNext pSocketID
   local tLen, tBuf
   put qsHttpReqLength(sCwReq[pSocketID]) into tLen
   if tLen <= 0 then
      qsCwClose pSocketID          -- cannot frame what we just served; do not risk a hang
      exit qsCwNext
   end if
   put sCwReq[pSocketID] into tBuf
   delete byte 1 to tLen of tBuf
   put tBuf into sCwReq[pSocketID]
   add 1 to sCwReqCount[pSocketID]
   put "false" into sCwServed[pSocketID]
   -- next request's method is not parsed yet: a 413 fired before qsCwServe must not
   -- inherit this request's method and wrongly suppress its body as if it were a HEAD.
   put "" into sCwMethod[pSocketID]
   put the milliseconds into sCwDeadline[pSocketID]
   if sCwReqCount[pSocketID] >= kCwMaxKeepAlive then
      qsCwClose pSocketID          -- connection hit its request cap; close politely
      exit qsCwNext
   end if
   qsCwDrain pSocketID
end qsCwNext

-- Serve a request already buffered behind the one we just answered (HTTP pipelining),
-- else re-arm the read for the next request's bytes.
command qsCwDrain pSocketID
   if qsHttpReqComplete(sCwReq[pSocketID]) then
      put "true" into sCwServed[pSocketID]
      qsCwServe pSocketID
   else
      read from socket pSocketID with message "qsCwData"
   end if
end qsCwDrain

-- Close a kept-alive connection that has gone idle past kCwIdleTimeout. Re-arms itself
-- while the connection is still alive but not yet idle; a no-op once cleaned/closed. Only
-- a connection that is genuinely idle (waiting to READ the next request) is reaped - an
-- in-progress file stream or an in-flight buffered write is NOT idle and must never be
-- force-closed, or a slow/paused download or a large listing on a slow link is truncated.
command qsCwWatchdog pSocketID
   if sCwServed[pSocketID] is empty then
      exit qsCwWatchdog            -- already cleaned up
   end if
   if not (pSocketID is among the lines of the openSockets) then
      qsCwClean pSocketID
      exit qsCwWatchdog
   end if
   if sCwTxPath[pSocketID] is not empty or sCwWriting[pSocketID] is "true" then
      -- actively streaming a file, or flushing a buffered response: paced by
      -- write-completion backpressure, not idle. Keep watching, do not close.
      send ("qsCwWatchdog " & quote & pSocketID & quote) to me in kCwIdleTimeout milliseconds
      exit qsCwWatchdog
   end if
   if (the milliseconds - sCwDeadline[pSocketID]) >= kCwIdleTimeout then
      qsCwClose pSocketID
      exit qsCwWatchdog
   end if
   send ("qsCwWatchdog " & quote & pSocketID & quote) to me in kCwIdleTimeout milliseconds
end qsCwWatchdog

command qsCwClose pSocketID
   qsCwSafeClose pSocketID
   qsCwClean pSocketID
end qsCwClose

-- Idempotent close (mirrors OnionXT's oxSafeCloseSocket): only close an id the engine
-- still lists, so a stale id is a clean no-op.
command qsCwSafeClose pSocketID
   if pSocketID is empty then
      exit qsCwSafeClose
   end if
   if pSocketID is among the lines of the openSockets then
      close socket pSocketID
   end if
end qsCwSafeClose

command qsCwClean pSocketID
   delete variable sCwReq[pSocketID]
   delete variable sCwServed[pSocketID]
   delete variable sCwTxPath[pSocketID]
   delete variable sCwTxPos[pSocketID]
   delete variable sCwTxRemaining[pSocketID]
   delete variable sCwTxName[pSocketID]
   delete variable sCwKeep[pSocketID]
   delete variable sCwReqCount[pSocketID]
   delete variable sCwDeadline[pSocketID]
   delete variable sCwMethod[pSocketID]
   delete variable sCwWriting[pSocketID]
end qsCwClean

-- Stack-level socket messages. Act only on OUR clearweb sockets; pass anything else
-- along so OnionXT's own sockets are unaffected.
on socketClosed pSocketID
   if sCwServed[pSocketID] is not empty then
      qsCwClean pSocketID
   else
      pass socketClosed
   end if
end socketClosed

on socketError pSocketID, pError
   if sCwServed[pSocketID] is not empty then
      qsCwClean pSocketID
   else
      pass socketError
   end if
end socketError

on socketTimeout pSocketID
   if sCwServed[pSocketID] is not empty then
      qsCwClose pSocketID
   else
      pass socketTimeout
   end if
end socketTimeout

-- A random capability token, hex (URL-safe). Uses cryptoXT's CSPRNG when present;
-- else OXT's random() (weaker, but still an unguessable demo link). pBytes is the
-- entropy in bytes; empty defaults to the clearweb token size.
function qsMakeToken pBytes
   local tRaw, tHex, tI, tByte, tN
   put pBytes into tN
   if tN is not a number or tN < 1 then
      put kCwTokenBytes into tN
   end if
   put "" into tRaw
   if sCanEncrypt then
      put sxRandomBytes(tN) into tRaw
   else
      repeat tN times
         put numToByte(random(256) - 1) after tRaw
      end repeat
   end if
   put "" into tHex
   repeat with tI = 1 to the number of bytes in tRaw
      put byteToNum(byte tI of tRaw) into tByte
      put char ((tByte div 16) + 1) of "0123456789abcdef" after tHex
      put char ((tByte mod 16) + 1) of "0123456789abcdef" after tHex
   end repeat
   return tHex
end qsMakeToken

-- Best-effort LAN IP for the local link. VERIFY (on-engine): platform-dependent;
-- hostNameToAddress of the machine's own name usually returns its LAN IP(s); take the
-- first non-loopback one. Empty -> the UI shows a "YOUR-IP" placeholder.
function qsLanIp
   local tIps, tIp, tErr
   try
      put hostNameToAddress(the hostName) into tIps
      repeat for each line tIp in tIps
         if tIp is not empty and not (tIp begins with "127.") then
            return tIp
         end if
      end repeat
   catch tErr
   end try
   return ""
end qsLanIp

-- Build + show the clearweb link(s): the internet link (if we have the public IP) as
-- the primary, and the local-network link. Both are copyable (qsCopy / qsWebCopy).
command qsCwShowLinks
   local tPath, tLan, tWan
   if not sCwActive then
      exit qsCwShowLinks
   end if
   if sCwKind is "folder" then
      put "/" & sCwToken & "/" into tPath
   else
      put "/" & sCwToken & "/" & qsFsPathEncode(sCwFileName) into tPath
   end if
   put "" into tLan
   put "" into tWan
   if sCwLanIp is not empty then
      put ("http://" & sCwLanIp & ":" & sCwPort & tPath) into tLan
   end if
   -- Show the internet link whenever we know a PUBLIC IP - if the router opened the
   -- port it works immediately, otherwise it works once the user forwards the port
   -- (qsCwStatusText explains which). A private / carrier-NAT address is never a
   -- usable internet link, so it is not shown.
   if sCwExtIp is not empty and not qsIsPrivateIp(sCwExtIp) then
      put ("http://" & sCwExtIp & ":" & sCwPort & tPath) into tWan
   end if
   -- the primary link (qsCode, with the Copy button) is the internet link when we have
   -- one, else the LAN link; the other goes in qsWebLink.
   if tWan is not empty then
      set the text of field "qsCode" to tWan
      set the text of field "qsWebLink" to tLan
      put tWan into sCwLink
   else if tLan is not empty then
      set the text of field "qsCode" to tLan
      set the text of field "qsWebLink" to tLan
      put tLan into sCwLink
   else
      set the text of field "qsCode" to ("http://YOUR-IP:" & sCwPort & tPath)
      set the text of field "qsWebLink" to "(could not detect your IP; use the local link or Tor)"
      put ("http://YOUR-IP:" & sCwPort & tPath) into sCwLink
   end if
   qsCwStatusText
end qsCwShowLinks

-- Explain, in the Sharing line, exactly what works: the internet link is live (router
-- opened the port), needs a manual forward (router would not), impossible (carrier
-- NAT), or still detecting the public IP.
command qsCwStatusText
   local tMsg
   if not sCwActive then
      exit qsCwStatusText
   end if
   if sCwExtIp is not empty and not qsIsPrivateIp(sCwExtIp) then
      if sCwMapped is "true" then
         put ("Internet link is LIVE (top link) - your router opened the port automatically. Anyone can open it in a browser; keep this window open.") into tMsg
      else
         put ("Internet link shown above, but the router did not open the port. Forward port " & sCwPort & " (TCP) to " & sCwLanIp & " in your router settings to enable it; the local link already works on your own network.") into tMsg
      end if
   else if sCwExtIp is not empty then
      put ("A direct internet link is not possible here - your connection uses carrier-grade NAT (shared public IP " & sCwExtIp & "). Use the local-network link, or share over Tor (which always reaches the internet).") into tMsg
   else
      put ("Local-network link is live. Looking up your public IP for an internet link... if none appears you are likely behind carrier NAT - use Tor for internet sharing.") into tMsg
   end if
   set the text of field "qsSharing" to tMsg
end qsCwStatusText

-- Is pIp a private / loopback / carrier-NAT address (so it can never be a usable
-- internet link)? RFC 1918 (10/8, 172.16-31/12, 192.168/16), CGNAT (100.64-127/10),
-- link-local (169.254/16), loopback (127/8).
function qsIsPrivateIp pIp
   local tA, tB, tSavedID
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "."
   put item 1 of pIp into tA
   put item 2 of pIp into tB
   set the itemDelimiter to tSavedID
   if tA is not a number then
      return false
   end if
   if tA is 10 or tA is 127 then
      return true
   end if
   if tA is 192 and tB is 168 then
      return true
   end if
   if tA is 169 and tB is 254 then
      return true
   end if
   if tA is 172 and tB is a number and tB >= 16 and tB <= 31 then
      return true
   end if
   if tA is 100 and tB is a number and tB >= 64 and tB <= 127 then
      return true
   end if
   return false
end qsIsPrivateIp

-- Fetch our public (internet-facing) IP from a lightweight HTTP echo, so the internet
-- link can show a real address even when libtorrent never reports one. ASYNCHRONOUS
-- (load URL ... with message) so a slow/unreachable echo never freezes the single UI
-- thread; the reply lands in qsCwIpReply. Non-fatal - if it fails, the LAN link and
-- the "forward the port / look up your IP" guidance still stand. VERIFY (on-engine):
-- the load URL / with-message flow and that plain-HTTP URL access is available.
command qsCwFetchPublicIp
   local tErr
   try
      -- https: an on-path attacker must not be able to feed us a wrong "public
      -- IP" for the displayed link. VERIFY (on-engine): OXT's libURL TLS.
      load URL "https://api.ipify.org/" with message "qsCwIpReply"
   catch tErr
   end try
end qsCwFetchPublicIp

command qsCwIpReply pUrl, pStatus
   local tIp, tErr, tSavedID, tOk
   if pStatus is not "cached" then
      try
         unload URL pUrl
      catch tErr
      end try
      exit qsCwIpReply           -- "error"/other: leave the IP unset; guidance stands
   end if
   put qsTrim(URL pUrl) into tIp
   try
      unload URL pUrl
   catch tErr
   end try
   if not sCwActive then
      exit qsCwIpReply
   end if
   -- validate it really looks like an IPv4 (reject an HTML error page etc.)
   put the itemDelimiter into tSavedID
   set the itemDelimiter to "."
   put (the number of items of tIp is 4 and item 1 of tIp is a number and item 4 of tIp is a number) into tOk
   set the itemDelimiter to tSavedID
   if not tOk then
      exit qsCwIpReply
   end if
   put tIp into sCwExtIp
   qsCwShowLinks
end qsCwIpReply

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

-- Flip the "Also offer a Tor Browser download link" checkbox (managed; autoHilite off).
command qsToggleWeb
   if sWebServe is "true" then
      put "false" into sWebServe
      set the hilite of button "qsWebCheck" to false
   else
      put "true" into sWebServe
      set the hilite of button "qsWebCheck" to true
   end if
end qsToggleWeb

-- Flip the "Enable web editing" checkbox (managed two-state; autoHilite off). ON arms
-- the LAN-only editor from the edit password (a fresh Argon2id key + verifier); OFF
-- forgets the password and any live login session. Anything that would leave it half-on
-- (no cryptoXT, blank password, KDF error) reports and leaves the box unchecked.
command qsToggleEdit
   local tPass, tErr
   if sEditOn is "true" then
      qsEditDisable
      set the hilite of button "qsEditToggle" to false
      qsLog "Live web editing turned OFF."
      exit qsToggleEdit
   end if
   if not sCanEncrypt then
      set the hilite of button "qsEditToggle" to false
      qsLog "Live editing needs cryptoXT (org.openxtalk.library.sodium) for its password. Install it, then try again."
      exit qsToggleEdit
   end if
   put field "qsEditPass" into tPass
   if tPass is empty then
      set the hilite of button "qsEditToggle" to false
      qsLog "Type an edit password first, then tick 'Enable web editing'."
      exit qsToggleEdit
   end if
   put qsEditEnable(tPass) into tErr
   if tErr is not empty then
      set the hilite of button "qsEditToggle" to false
      qsLog tErr
      exit qsToggleEdit
   end if
   set the hilite of button "qsEditToggle" to true
   qsLog "Live web editing is ON (LAN devices only)."
   qsEditShowLink
end qsToggleEdit

command qsCopyWebLink
   if field "qsWebLink" is empty then
      qsLog "No web link yet - share a plaintext file over Tor with 'Also offer a Tor Browser download link' ticked."
      exit qsCopyWebLink
   end if
   set the clipboardData["text"] to field "qsWebLink"
   qsCopyFlash "qsWebCopy"
   qsLog "Web link copied. Anyone with Tor Browser can open it to download."
end qsCopyWebLink

-- Shown to a browser when the sender did NOT tick the Tor Browser link checkbox.
function qsHtmlDisabled
   return (qsFsPageTop("Not available") & qsFsIconSprite() & \
      "<main class='card'><header class='hd'><svg class='fi' style='color:#e8a317'><use href='#i-warn'/></svg>" & \
      "<h1>Web download is off</h1></header><div class='msg'>The sender shared this file for the app only. " & \
      "Ask them for the share code, or to turn on the Tor Browser download link.</div></main>" & qsFsPageBottom())
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
