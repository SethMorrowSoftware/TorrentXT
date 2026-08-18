script "dhtChannelsApp"

-- torrent-dht-channels.livecodescript - a self-building, MULTI-MACHINE TorrentXT
-- demo that combines the BEP44 DHT key-value store with BitTorrent file transfer
-- into one decentralized "channel" app. NO SERVER anywhere: the DHT is the
-- directory, BitTorrent moves the bytes.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI and starts a
-- TorrentXT session. Needs only the loaded org.openxtalk.library.torrent (v3+).
-- Your channel identity / names / subscriptions persist automatically to a small
-- file in your per-user folder, so they survive across runs (and as a standalone
-- .exe / app, which cannot save its own stack). Click "Lock Identity..." to seal
-- that file with a passphrase via SodiumXT (Argon2id + secretbox); you then enter
-- it each launch, and there is no recovery if you lose it.
--
-- THE DEMO (run it on two or more machines):
--   1. (Optional) click "Rename" to give the active channel a display name. You
--      can keep several channels and switch between them with the picker.
--   2. Click "Publish a File..." - it creates a torrent, seeds it, and publishes
--      the magnet in the active channel's FEED, signed under its ed25519 key on
--      the DHT. Publish more files - the channel keeps a feed of recent releases.
--   3. Click "Copy" to put that channel's CARD ("Name | public key") on the
--      clipboard, and send it to another machine.
--   4. There, paste the card (or a bare key) and click Follow - it fetches that
--      channel's signed feed and lists its releases.
--   5. Select a release and click Download - the file transfers peer-to-peer while
--      the publisher seeds. The Transfers table marks what you POSTED (green) vs
--      what you DOWNLOADED (blue), and fills in on both machines.
-- Followers see a UNIFIED feed of releases across every channel they follow, and
-- every entry is cryptographically signed by its channel (tamper-proof: only the
-- channel's secret key could have published it).
--
-- PRIVACY (optional): a channel is PUBLIC by default - anyone with its address
-- reads the file list, anyone with a magnet downloads the file. Click "Privacy"
-- to set a passphrase, and that channel encrypts BOTH its feed AND every file you
-- publish to it with SodiumXT (libsodium): the key is derived from the passphrase
-- with Argon2id (salted by the channel's public key), the feed is sealed with
-- crypto_secretbox before the DHT put (the file list is hidden), and each file is
-- sealed with crypto_secretstream before it is shared, so the torrent carries
-- AUTHENTICATED ciphertext under a neutral name - a leaked magnet is useless
-- without the passphrase, which followers get out-of-band, and tampering or
-- truncation is detected on decrypt. Downloads are decrypted automatically. It
-- still does NOT hide your IP or that you are sharing something. Private
-- publishing is one file at a time and pauses briefly on a very large file.
-- Fail-closed: a private channel that cannot be encrypted is never published in
-- the clear.
--
-- REQUIRES, for the privacy features only, the SodiumXT extension
-- (org.openxtalk.library.sodium) to be installed alongside this. Public channels
-- and all non-encryption features work without it.
--
-- SAVING AS A STANDALONE: standalone-ready - the UI self-builds in preOpenStack
-- every launch (nothing needs to persist in the stackfile), and quitting is
-- caught by shutdownRequest so the DHT routing table + prefs are saved and the
-- session shuts down cleanly even on Cmd-Q / Dock quit. In the builder: include
-- org.openxtalk.library.torrent (required) and org.openxtalk.library.sodium
-- (SodiumXT - OPTIONAL, only for private channels + identity lock; the app fails
-- closed with a clear message when it is absent). Identity, channels, and
-- subscriptions persist to a small per-user file (NOT the stackfile), so they
-- survive across runs and as a packaged app.
--
-- Click any transfer to see the files inside it with a live per-file progress
-- bar (btFileList); the transfers table shows inline progress bars too. Pause,
-- Resume, Remove (keep or delete files), or Open Folder act on the selected
-- transfer (double-click a row to open its folder), and the Add Magnet box adds
-- any magnet link or info-hash directly, not only releases from channels.
--
-- It also includes a "Quick drop" panel using IMMUTABLE items: pin a short text,
-- get a 40-character content-address code, and fetch any code back.
--
-- Design follows the single-thread playbook: a 250 ms poll drains events, a 1 s
-- loop repaints the transfers table, and a 60 s loop re-publishes your feed and
-- re-fetches your subscriptions so it stays live. The DHT routing table is saved
-- on close and reloaded on open for a faster bootstrap.
--
-- ANONYMOUS CHANNELS (optional, Tor): click "Anonymous..." on a channel and its
-- WHOLE feed + every file travel over the channel's own Tor onion service (both
-- IPs hidden, nothing on the DHT or a magnet), reachable from the channel card
-- alone - the onion address is derived from the channel's existing ed25519 key.
-- It composes with Privacy (Tor hides WHERE, SodiumXT hides WHAT + authenticates
-- WHO). Needs the OnionXT extension (org.openxtalk.library.onion) + SodiumXT + a
-- local Tor daemon (127.0.0.1:9050/9051 or Tor Browser 9150/9151). Fails closed:
-- with any piece missing, anon is inert and every public feature works normally.
-- Plaintext anon hides the route but does NOT authenticate the sender; anon is
-- only anonymous between the two onion endpoints. See docs/ONIONXT-INTEGRATION-PLAN.md.
--
-- HONESTY (the suite convention): the torrent + BEP44 surface this demo drives
-- is engine-proven (the member selftest and the demo passes recorded in
-- torrentxt/CLAUDE.md), but THIS stack's UI was unified onto the suite kit
-- 2026-08-14 - the rebuilt chrome and layout are verified statically; needs an
-- OXT re-pass. The OnionXT anon-channels layer (Model C, built 2026-08-15) is
-- verified STATICALLY (tools/check-livecodescript.py); every ox* call still needs
-- an on-engine OXT pass with a running Tor daemon before any runtime claim.
--
-- THE LOOK is the suite UI kit, carried verbatim between the marker lines
-- (master: tools/ui-kit.livecodescript; the drift gate holds every copy
-- byte-identical). Change the look in the master, never here.

-- ---- stack-local state -------------------------------------------------------

-- >>> BEGIN EMBEDDED LIBRARIES (tools/sync-demo-embeds.py) >>>
-- Pasted from the sources below so this demo runs with NO `start
-- using` wiring. Do not edit inside these sentinels: run
-- `python3 tools/sync-demo-embeds.py` instead. The sources under
-- src/ stay the single source of truth for real projects.
--
-- Libraries come FIRST because OXT resolves script-level constants
-- and locals by lexical position.

-- ---- onionxt/src/onionxt.livecodescript ----
-- onionxt.livecodescript - the OnionXT library.
--
-- OnionXT is a Tor transport and rendezvous layer for OpenXTalk / the xTalk
-- family. It speaks SOCKS5 (RFC 1928 + Tor extensions) and the Tor control
-- protocol to a LOCALLY-RUNNING tor daemon; it does not embed or ship Tor. It
-- adds no cryptography (SodiumXT does that) and, in this form, no native code:
-- the SOCKS5 and control clients are engine socket I/O, and base32 / the
-- ed25519 scalar clamp are pure byte manipulation.
--
-- STATUS: implemented AND run on a real OXT engine against a live tor daemon.
-- The core paths are confirmed on-engine: dialing through the SOCKS proxy, the
-- control-port connect + SAFECOOKIE auth, GETINFO / SETEVENTS, publishing a v3
-- onion service, accepting an inbound (Tor-forwarded) connection, streaming data
-- both ways, and bootstrap/HS_DESC events. The only path NOT yet exercised is the
-- optional Mode B (launching a bundled tor via `open process`), still flagged
-- "VERIFY:" below. The pure-compute paths are pinned by tools/onion-kat.py.
--
-- Conventions (see CLAUDE.md): public API oxPascalCase; locals t..., params
-- p..., script-locals s..., constants k...; SOCKS5 is BINARY (byte / numToByte /
-- byteToNum), the control protocol is CRLF text; every socket op is async
-- (open / read / accept with message) so the one interpreter thread never blocks
-- on the network; loopback (127.0.0.1) only; every open has an idempotent close;
-- every wire error fails closed and tears the resource down.
--
-- The async model (CLAUDE.md): oxDial and oxCreateService return a HANDLE
-- immediately and complete later; the app learns the outcome through the
-- callbacks below, never by a blocking return. The callback contracts are:
--   status callback  <handler> pKind, pInfo
--       pKind = "control"   pInfo = "connected"|"authenticated"|"disconnected"
--                                   |"authfailed: <reason>"|"error: <reason>"
--       pKind = "bootstrap" pInfo = 0..100          (coalesced to <= ~4 Hz)
--       pKind = "ready"     pInfo = empty           (bootstrap reached 100)
--       pKind = "service"   pInfo = <address>.onion (ADD_ONION returned it)
--       pKind = "serviceReady" pInfo = <address>    (descriptor uploaded)
--       pKind = "notice"    pInfo = <diagnostic>    (e.g. an accepted peer's raw id)
--       pKind = "event"     pInfo = <raw 650 line>  (advanced; opt-in noise)
--   stream callback  <handler> pStream, pEvent, pData
--       pEvent = "open"   the SOCKS tunnel (or inbound peer) is live
--       pEvent = "data"   pData is an inbound Data chunk (app frames its own)
--       pEvent = "closed" the peer closed the stream
--       pEvent = "error"  pData is the error; the stream has been torn down
--   peer callback    <handler> pStream, pService, pPeerAddr
--       a remote peer reached a published service; pStream is a fresh inbound
--       stream handle (register a stream callback on it), pService its service
--       handle, pPeerAddr the (loopback) peer address Tor forwarded from.
--
-- Callbacks are delivered with `dispatch` to the callback owner (oxSetCallbackOwner,
-- default the topStack); a missing handler is a clean no-op, so an app wires only
-- the callbacks it needs.

-- ==========================================================================
-- Constants. Loopback host is fixed; only the ports are configurable (and
-- loopback-locked). Declared before first use (OXT resolves a constant by
-- lexical position; a forward reference silently evaluates to nothing).
-- ==========================================================================

constant kOxHost = "127.0.0.1"
constant kOxSocksPortDefault = 9050
constant kOxControlPortDefault = 9051
constant kOxVersion = "1.0.0"

-- A bootstrapping daemon accepts the TCP connection then stalls; bound every
-- handshake so a silent stall becomes a clean error (docs/02 state machine).
constant kOxHandshakeTimeout = 20000     -- milliseconds
-- Coalesce bootstrap/status updates so a flood of 650 lines cannot thrash a
-- field (CLAUDE.md: <= ~4 Hz). 250 ms = 4 Hz.
constant kOxStatusThrottle = 250         -- milliseconds
-- RFC 4648 base32, lowercase, no padding (docs/04). Pure bytes, no crypto.
constant kOxBase32Alphabet = "abcdefghijklmnopqrstuvwxyz234567"
-- The v3 address checksum preimage prefix and version byte (docs/04). SHA3-256
-- of (kOxChecksumPrefix & pubkey & version) gives the 2-byte checksum; the hash
-- itself is a SodiumXT call, never hand-rolled here.
constant kOxChecksumPrefix = ".onion checksum"
-- The two SAFECOOKIE HMAC key strings, verbatim from the Tor control-spec.
constant kOxSafeCookieServerKey = "Tor safe cookie authentication server-to-controller hash"
constant kOxSafeCookieClientKey = "Tor safe cookie authentication controller-to-server hash"

-- ==========================================================================
-- Script-local state. Handle tables are LiveCode associative arrays keyed by a
-- small integer handle or by the engine's socket id; a stale or closed id must
-- be a clean no-op / error, never a crash.
-- ==========================================================================

-- Configurable ports (default to a system tor; Tor Browser uses 9150 / 9151).
local sSocksPort
local sControlPort

-- Control connection and bootstrap state (see docs/03-control-port.md).
local sControlSocket        -- engine id of the open control socket, or empty
local sControlState         -- disconnected|connecting|protocolinfo|authenticating|authenticated|failed
local sControlMethods       -- offered auth methods (comma list) from PROTOCOLINFO
local sControlCookieFile     -- cookie-file path from PROTOCOLINFO (unescaped)
local sControlPassword       -- app-set password for HASHEDPASSWORD auth
local sControlCookieBytes    -- the 32 raw cookie bytes (SAFECOOKIE flow)
local sControlClientNonce    -- our SAFECOOKIE client nonce (raw bytes)
local sControlTorVersion     -- tor version string from GETINFO version
local sBootstrap             -- 0..100 bootstrap percent from STATUS_CLIENT

-- Control command pipeline. One command in flight at a time so replies match
-- commands (docs/03); further commands queue. Reply lines accumulate until the
-- space-separated final line terminates the reply.
local sCtlInFlight           -- label of the in-flight command, or empty
local sCtlReplyLines         -- accumulated reply text (newline-joined)
local sCtlInData             -- true while inside a 250+ CmdData block
local sCtlData               -- accumulated CmdData block text
local sCtlQueue              -- pending commands: lines of "label" & TAB & "command"

-- App-registered callback handler names and the object they dispatch to.
local sStatusCallback
local sPeerCallback
local sCallbackOwner         -- long id of the object whose script has the callbacks
local sLastStatusTick        -- `the milliseconds` of the last coalesced update

-- Handle tables.
local sStreams               -- keyed by integer stream handle (nested array)
local sSockToStream          -- keyed by socket id string -> stream handle
local sServices              -- keyed by integer service handle (nested array)
local sLocalToService        -- keyed by local port -> service handle
local sNextHandle            -- monotonic handle allocator (0 is never valid)

-- ==========================================================================
-- Configuration.
-- ==========================================================================

command oxSetSocksPort pPort
   -- Loopback-locked: only the port is settable, never the host (CLAUDE.md
   -- socket gotcha 6). Take effect on the next oxDial.
   put pPort into sSocksPort
end oxSetSocksPort

command oxSetControlPort pPort
   put pPort into sControlPort
end oxSetControlPort

command oxSetControlPassword pPassword
   -- Only used if the daemon offers HASHEDPASSWORD auth (docs/03 step 2).
   put pPassword into sControlPassword
end oxSetControlPassword

command oxSetCallbackOwner pObjectLongId
   -- The object whose script holds the app callbacks. If unset, callbacks
   -- dispatch to the topStack; setting this explicitly (as the demo does) removes
   -- any ambiguity about which stack. Confirmed on-engine: with an explicit owner,
   -- onStatus / onPeer / onStreamData all resolve and fire.
   put pObjectLongId into sCallbackOwner
end oxSetCallbackOwner

command oxSetStatusCallback pHandlerName
   put pHandlerName into sStatusCallback
end oxSetStatusCallback

command oxSetPeerCallback pHandlerName
   put pHandlerName into sPeerCallback
end oxSetPeerCallback

function oxVersion
   -- The library version, plus the tor version once the control connection has
   -- answered GETINFO version (docs/05).
   if sControlTorVersion is empty then
      return kOxVersion
   end if
   return kOxVersion & " (tor " & sControlTorVersion & ")"
end oxVersion

-- ==========================================================================
-- Control connection, authentication, and the command pipeline
-- (docs/03-control-port.md). The connection is opened and authenticated
-- asynchronously; the app learns the outcome through the status callback.
-- ==========================================================================

command oxConnectControl
   -- Idempotent-ish: refuse a second concurrent connect rather than leak a
   -- socket. Disconnect first to reconnect.
   if sControlSocket is not empty then
      return "OnionXT: control connection already open (oxDisconnectControl first)"
   end if
   local tSocketID
   -- A named connection (|oxctl) so the id is stable and distinct from streams.
   put kOxHost & ":" & effectiveControlPort() & "|oxctl" into tSocketID
   put tSocketID into sControlSocket
   put "connecting" into sControlState
   put empty into sCtlInFlight
   put empty into sCtlReplyLines
   put false into sCtlInData
   put empty into sCtlQueue
   -- Bound the connect/handshake so a stalled daemon fails cleanly.
   set the socketTimeoutInterval to kOxHandshakeTimeout
   open socket to tSocketID with message "oxCtlOpened"
   -- A watchdog independent of the (repeating) socketTimeout: if we are not
   -- authenticated within the deadline, tear the connection down.
   send ("oxCtlDeadline " & quote & tSocketID & quote) to me in kOxHandshakeTimeout milliseconds
   return empty
end oxConnectControl

command oxDisconnectControl
   -- Idempotent close of the control socket and reset of all control state.
   if sControlSocket is not empty then
      oxSafeCloseSocket sControlSocket
   end if
   put empty into sControlSocket
   put "disconnected" into sControlState
   put empty into sCtlInFlight
   put empty into sCtlReplyLines
   put false into sCtlInData
   put empty into sCtlQueue
   put empty into sControlCookieBytes
   put empty into sControlClientNonce
end oxDisconnectControl

function oxIsControlAuthenticated
   return (sControlState is "authenticated")
end oxIsControlAuthenticated

function oxBootstrapProgress
   if sBootstrap is empty then
      return 0
   end if
   return sBootstrap
end oxBootstrapProgress

function oxIsReady
   -- Ready to carry traffic once bootstrapped to 100 and the control port is
   -- authenticated. A published service's own reachability is reported
   -- separately via the "serviceReady" status (HS_DESC UPLOADED).
   return (sBootstrap is 100) and (sControlState is "authenticated")
end oxIsReady

command oxCtlOpened pSocketID
   -- The control TCP connection is up. Start the single persistent line reader
   -- and kick the auth dance with PROTOCOLINFO (allowed pre-auth).
   if pSocketID is not sControlSocket then
      exit oxCtlOpened          -- a stale socket; ignore
   end if
   put "protocolinfo" into sControlState
   oxStatusUpdate "control", "connected"
   -- One outstanding CRLF read at a time; re-armed at the end of oxCtlLine.
   read from socket pSocketID until crlf with message "oxCtlLine"
   oxCtlSend "PROTOCOLINFO 1", "protocolinfo"
end oxCtlOpened

private command oxCtlSend pCommand, pLabel
   -- Send a control command, or queue it if one is already in flight so replies
   -- always match commands (docs/03: keep a single in-flight command queue).
   if sControlSocket is empty then
      exit oxCtlSend
   end if
   if sCtlInFlight is not empty then
      put pLabel & tab & pCommand & return after sCtlQueue
      exit oxCtlSend
   end if
   put pLabel into sCtlInFlight
   put empty into sCtlReplyLines
   put false into sCtlInData
   put empty into sCtlData
   -- Commands are ASCII text; textEncode gives the exact wire bytes, then the
   -- CRLF terminator (docs/03 line framing).
   write textEncode(pCommand & oxCrlf(), "UTF-8") to socket sControlSocket
end oxCtlSend

private command oxCtlDrainQueue
   -- Send the next queued command, if any. Called when a reply completes.
   if sCtlQueue is empty then
      exit oxCtlDrainQueue
   end if
   local tLine, tLabel, tCommand, tSaved
   put line 1 of sCtlQueue into tLine
   delete line 1 of sCtlQueue
   put the itemDelimiter into tSaved
   set the itemDelimiter to tab
   put item 1 of tLine into tLabel
   put item 2 to -1 of tLine into tCommand
   set the itemDelimiter to tSaved
   oxCtlSend tCommand, tLabel
end oxCtlDrainQueue

command oxCtlLine pSocketID, pData
   -- The persistent control-port line reader. Demultiplexes unsolicited 650
   -- events from command replies, reassembles multi-line replies, and honours
   -- the 250-/250+/'.'/250 space framing (docs/03).
   if pSocketID is not sControlSocket then
      exit oxCtlLine            -- a stale socket; ignore
   end if
   local tLine
   -- Control replies are ASCII; decode as text, then strip the line terminator.
   -- Confirmed on-engine: `read until crlf` returns the trailing CRLF and
   -- oxStripLineEnd removes it, so auth / GETINFO / events all parse correctly.
   put textDecode(pData, "UTF-8") into tLine
   put oxStripLineEnd(tLine) into tLine

   if sCtlInData then
      -- Inside a 250+ CmdData block: a lone "." ends it; other lines are data
      -- with any doubled leading dot un-stuffed (docs/03, RFC 2821 dot-stuffing).
      if tLine is "." then
         put false into sCtlInData
      else
         if char 1 to 2 of tLine is ".." then
            delete char 1 of tLine
         end if
         put tLine & return after sCtlData
      end if
      oxCtlRearm pSocketID
      exit oxCtlLine
   end if

   if the length of tLine < 3 then
      oxCtlRearm pSocketID      -- malformed / empty; skip
      exit oxCtlLine
   end if

   local tCode, tSep
   put char 1 to 3 of tLine into tCode
   put char 4 of tLine into tSep

   if tCode is "650" then
      -- An asynchronous event. Route it to the event handler, never to the
      -- pending-command continuation.
      oxHandleEvent tLine
      oxCtlRearm pSocketID
      exit oxCtlLine
   end if

   -- A command-reply line. Accumulate it and act on the frame control byte.
   put tLine & return after sCtlReplyLines
   if tSep is "+" then
      put true into sCtlInData
   else if tSep is space or tSep is empty then
      -- Space (or a 3-char line) terminates the reply.
      oxCtlReplyComplete
      put empty into sCtlInFlight
      put empty into sCtlReplyLines
      oxCtlDrainQueue
   end if
   -- "-" continuation: just keep reading.
   oxCtlRearm pSocketID
end oxCtlLine

private command oxCtlRearm pSocketID
   -- Keep exactly one read outstanding, but only while the socket is still ours.
   if pSocketID is sControlSocket then
      read from socket pSocketID until crlf with message "oxCtlLine"
   end if
end oxCtlRearm

private command oxCtlReplyComplete
   -- Dispatch the just-completed reply to the continuation for the in-flight
   -- command. if/else-if, not switch (the static gate rejects `end switch`).
   -- tReplyOp, NOT tOp: a t-prefixed "tOp" lowercases to `top`, a reserved OXT
   -- property, and the engine would parse it as the keyword, not this variable
   -- (the prefixed-token-shadow trap, CLAUDE.md gotcha 2).
   local tLabel, tReplyOp, tArg, tSaved
   put sCtlInFlight into tLabel
   put the itemDelimiter into tSaved
   set the itemDelimiter to ":"
   put item 1 of tLabel into tReplyOp
   put item 2 to -1 of tLabel into tArg
   set the itemDelimiter to tSaved

   if tReplyOp is "protocolinfo" then
      oxParseProtocolInfo sCtlReplyLines
      oxChooseAuthAndStart
   else if tReplyOp is "authchallenge" then
      oxHandleAuthChallenge sCtlReplyLines
   else if tReplyOp is "authenticate" then
      oxHandleAuthResult sCtlReplyLines
   else if tReplyOp is "setevents" then
      -- 250 OK expected; nothing to do on success.
   else if tReplyOp is "getinfo-version" then
      oxParseTorVersion sCtlReplyLines
   else if tReplyOp is "getinfo-bootstrap" then
      oxParseBootstrapPhase sCtlReplyLines
   else if tReplyOp is "add_onion" then
      oxHandleAddOnionReply tArg, sCtlReplyLines
   else if tReplyOp is "del_onion" then
      -- 250 OK on success, 552 if unknown; the removal already forgot local
      -- state, so nothing further is required here.
   end if
end oxCtlReplyComplete

private command oxParseProtocolInfo pReply
   -- Extract the offered auth methods and (for cookie auth) the cookie-file path
   -- from the PROTOCOLINFO reply (docs/03 step 1).
   put empty into sControlMethods
   put empty into sControlCookieFile
   local tLine
   repeat for each line tLine in pReply
      if "AUTH METHODS=" is in tLine then
         -- METHODS=<comma list> [COOKIEFILE="<quoted, C-escaped path>"]
         put oxFieldAfter(tLine, "METHODS=") into sControlMethods
         if "COOKIEFILE=" is in tLine then
            put oxCUnescape(oxQuotedValueAfter(tLine, "COOKIEFILE=")) into sControlCookieFile
         end if
      end if
   end repeat
end oxParseProtocolInfo

private command oxChooseAuthAndStart
   -- Priority SAFECOOKIE > COOKIE > NULL > HASHEDPASSWORD (docs/03), but degrade
   -- past any method whose prerequisite is missing rather than fail: SAFECOOKIE
   -- needs SodiumXT HMAC-SHA256 and randomness (docs/08), COOKIE needs the
   -- readable cookie file, HASHEDPASSWORD needs an app-set password.
   put "authenticating" into sControlState

   if oxMethodOffered("SAFECOOKIE") and oxSodiumHasHmac() and oxSodiumHasRandom() then
      if oxLoadCookie() then
         oxStartSafeCookie
         exit oxChooseAuthAndStart
      end if
   end if
   if oxMethodOffered("COOKIE") then
      if oxLoadCookie() then
         local tHex
         put oxBytesToHex(sControlCookieBytes) into tHex
         oxCtlSend "AUTHENTICATE " & tHex, "authenticate"
         exit oxChooseAuthAndStart
      end if
   end if
   if oxMethodOffered("NULL") then
      oxCtlSend "AUTHENTICATE", "authenticate"
      exit oxChooseAuthAndStart
   end if
   if oxMethodOffered("HASHEDPASSWORD") and sControlPassword is not empty then
      -- Quote the password; escape backslash and double-quote (docs/03).
      oxCtlSend "AUTHENTICATE " & quote & oxQuoteEscape(sControlPassword) & quote, "authenticate"
      exit oxChooseAuthAndStart
   end if

   put "failed" into sControlState
   oxStatusUpdate "control", "authfailed: no usable auth method (offered " & sControlMethods & ")"
   oxDisconnectControl
end oxChooseAuthAndStart

private command oxStartSafeCookie
   -- SAFECOOKIE step A: send a 32-byte client nonce as hex (docs/03 step 2).
   put oxRandomBytes(32) into sControlClientNonce
   oxCtlSend "AUTHCHALLENGE SAFECOOKIE " & oxBytesToHex(sControlClientNonce), "authchallenge"
end oxStartSafeCookie

private command oxHandleAuthChallenge pReply
   -- SAFECOOKIE step B/C/D. The reply is a SINGLE final line:
   -- 250 AUTHCHALLENGE SERVERHASH=<hex> SERVERNONCE=<hex> (docs/03; the reply is
   -- space-separated, not a 250- continuation).
   local tLine, tServerHashHex, tServerNonceHex
   put line 1 of pReply into tLine
   if char 1 to 3 of tLine is not "250" then
      put "failed" into sControlState
      oxStatusUpdate "control", "authfailed: AUTHCHALLENGE rejected (" & tLine & ")"
      oxDisconnectControl
      exit oxHandleAuthChallenge
   end if
   put oxFieldAfter(tLine, "SERVERHASH=") into tServerHashHex
   put oxFieldAfter(tLine, "SERVERNONCE=") into tServerNonceHex

   local tServerNonce, tMessage, tExpected, tOk
   put oxHexToBytes(tServerNonceHex) into tServerNonce
   -- HMAC message = CookieBytes || ClientNonce || ServerNonce (docs/03).
   put sControlCookieBytes & sControlClientNonce & tServerNonce into tMessage
   put oxHmac(kOxSafeCookieServerKey, tMessage) into tExpected
   -- Verify the server hash in constant time; a mismatch means the far end does
   -- not hold the cookie (not the real Tor), so abort and do NOT authenticate.
   put oxConstantTimeEqual(tExpected, oxHexToBytes(tServerHashHex)) into tOk
   if not tOk then
      put "failed" into sControlState
      oxStatusUpdate "control", "authfailed: SAFECOOKIE server hash mismatch (not the real Tor?)"
      oxDisconnectControl
      exit oxHandleAuthChallenge
   end if
   -- Step D: authenticate with the controller-to-server hash.
   local tClientHash
   put oxHmac(kOxSafeCookieClientKey, tMessage) into tClientHash
   oxCtlSend "AUTHENTICATE " & oxBytesToHex(tClientHash), "authenticate"
end oxHandleAuthChallenge

private command oxHandleAuthResult pReply
   -- 250 OK => authenticated; anything else (515 bad auth, 514 required) fails
   -- closed (docs/03; there is no unauthenticated fallback, CLAUDE.md rule 4).
   local tLine
   put line 1 of pReply into tLine
   if char 1 to 3 of tLine is "250" then
      put "authenticated" into sControlState
      oxStatusUpdate "control", "authenticated"
      -- Subscribe to the events we care about and learn the tor version.
      oxCtlSend "SETEVENTS STATUS_CLIENT HS_DESC CIRC STREAM", "setevents"
      oxCtlSend "GETINFO version", "getinfo-version"
      -- Query the CURRENT bootstrap phase once. STATUS_CLIENT BOOTSTRAP events
      -- only fire WHILE tor is bootstrapping, so a daemon already at 100% when we
      -- connect emits none and the UI would sit at 0. This one GETINFO seeds it.
      oxCtlSend "GETINFO status/bootstrap-phase", "getinfo-bootstrap"
   else
      put "failed" into sControlState
      oxStatusUpdate "control", "authfailed: " & tLine
      oxDisconnectControl
   end if
end oxHandleAuthResult

private command oxParseTorVersion pReply
   -- 250-version=<x> then 250 OK (docs/03). Pull the version value.
   local tLine
   repeat for each line tLine in pReply
      if "version=" is in tLine then
         put oxFieldAfter(tLine, "version=") into sControlTorVersion
      end if
   end repeat
end oxParseTorVersion

private command oxParseBootstrapPhase pReply
   -- Reply to GETINFO status/bootstrap-phase, carrying the CURRENT bootstrap state
   -- (unlike the STATUS_CLIENT event, which only fires while bootstrapping). Line:
   --   250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="..."
   -- Parse PROGRESS= the same way as the live event so the UI is seeded on connect.
   local tLine, tProgress
   repeat for each line tLine in pReply
      if "PROGRESS=" is in tLine then
         put oxFieldAfter(tLine, "PROGRESS=") into tProgress
         if tProgress is not empty and tProgress is an integer then
            put tProgress into sBootstrap
            oxStatusUpdate "bootstrap", tProgress
            if tProgress is 100 then
               oxStatusUpdate "ready", empty
            end if
         end if
      end if
   end repeat
end oxParseBootstrapPhase

command oxCtlDeadline pSocketID
   -- Handshake watchdog: if this control socket never reached authenticated,
   -- tear it down with a clean error (docs/07: a stalled bootstrap must not hang).
   if pSocketID is not sControlSocket then
      exit oxCtlDeadline
   end if
   if sControlState is not "authenticated" then
      oxStatusUpdate "control", "error: control authentication timed out"
      oxDisconnectControl
   end if
end oxCtlDeadline

-- ==========================================================================
-- Event handling: bootstrap progress and onion-descriptor readiness
-- (docs/03 step 5). 650 lines are tolerant-parsed; never hard-fail on an
-- unrecognized token (the control-spec requires controllers to tolerate them).
-- ==========================================================================

private command oxHandleEvent pLine
   local tType
   put word 2 of pLine into tType
   if tType is "STATUS_CLIENT" then
      if "BOOTSTRAP" is in pLine then
         local tProgress
         put oxFieldAfter(pLine, "PROGRESS=") into tProgress
         if tProgress is not empty and tProgress is an integer then
            put tProgress into sBootstrap
            oxStatusUpdate "bootstrap", tProgress
            if tProgress is 100 then
               oxStatusUpdate "ready", empty
            end if
         end if
      end if
   else if tType is "HS_DESC" then
      -- Positional: HS_DESC <Action> <HSAddress> ... . Our service is reachable
      -- once we see UPLOADED for its address (docs/03 step 5).
      local tAction, tAddress
      put word 3 of pLine into tAction
      put word 4 of pLine into tAddress
      if tAction is "UPLOADED" then
         oxMarkServiceReady tAddress
         oxStatusUpdate "serviceReady", tAddress
      end if
   else
      -- CIRC / STREAM and anything else are diagnostic; surface raw for advanced
      -- apps that opted into an "event" status, otherwise ignored.
      oxStatusUpdate "event", pLine
   end if
end oxHandleEvent

private command oxMarkServiceReady pAddress
   local tKey, tCore
   -- The event carries the ServiceID (no ".onion"); match either spelling.
   put pAddress into tCore
   if tCore ends with ".onion" then
      put char 1 to -7 of tCore into tCore
   end if
   repeat for each key tKey in sServices
      if sServices[tKey]["serviceID"] is tCore then
         put true into sServices[tKey]["ready"]
      end if
   end repeat
end oxMarkServiceReady

private command oxStatusUpdate pKind, pInfo
   -- Deliver a status update to the app, coalescing the high-frequency bootstrap
   -- stream to <= ~4 Hz (CLAUDE.md). Terminal/rare kinds are always delivered.
   if pKind is "bootstrap" and pInfo is not 100 then
      local tNow
      put the milliseconds into tNow
      if sLastStatusTick is not empty and (tNow - sLastStatusTick) < kOxStatusThrottle then
         exit oxStatusUpdate   -- coalesce: drop this intermediate tick
      end if
      put tNow into sLastStatusTick
   end if
   oxDispatch sStatusCallback, pKind, pInfo, empty
end oxStatusUpdate

-- ==========================================================================
-- Outbound: dialing through SOCKS5 (docs/02-socks5-client.md). A callback-driven
-- state machine: greet, CONNECT with ATYP=3 (Tor resolves the name; never a
-- local DNS lookup), parse the reply, hand up a raw byte-stream tunnel.
-- ==========================================================================

command oxDial pHost, pPort
   -- Reports a stream handle through `the result` immediately; the SOCKS
   -- handshake completes asynchronously and the stream's callback receives
   -- "open" or "error" (CLAUDE.md async model).
   if pHost is empty then
      return "OnionXT: oxDial needs a host (a .onion or clearnet name)"
   end if
   if pPort is not an integer or pPort < 1 or pPort > 65535 then
      return "OnionXT: oxDial needs a port in 1..65535"
   end if
   local tHandle, tConnName, tSocketID
   put oxAllocHandle() into tHandle
   -- A NON-numeric connection name so several streams to 127.0.0.1:9050 get
   -- distinct socket ids, and so they never collide with the numeric names the
   -- accept loop assigns (the id separator is a vertical bar, docs LiveCode ref).
   put "oxs" & tHandle into tConnName
   put kOxHost & ":" & effectiveSocksPort() & "|" & tConnName into tSocketID
   put tSocketID into sStreams[tHandle]["socketID"]
   put "connecting" into sStreams[tHandle]["state"]
   put pHost into sStreams[tHandle]["host"]
   put pPort into sStreams[tHandle]["port"]
   put "dial" into sStreams[tHandle]["kind"]
   put empty into sStreams[tHandle]["callback"]
   put tHandle into sSockToStream[tSocketID]
   set the socketTimeoutInterval to kOxHandshakeTimeout
   open socket to tSocketID with message "oxSocksOpened"
   send ("oxStreamDeadline " & tHandle) to me in kOxHandshakeTimeout milliseconds
   return tHandle
end oxDial

command oxSetStreamCallback pStream, pHandlerName
   if sStreams[pStream]["socketID"] is empty then
      return "OnionXT: unknown stream handle " & pStream
   end if
   put pHandlerName into sStreams[pStream]["callback"]
   return empty
end oxSetStreamCallback

command oxWrite pStream, pData
   -- Write app bytes (already sealed by the app via SodiumXT) to the
   -- tunnel. OnionXT does not encrypt (docs/02).
   if sStreams[pStream]["state"] is not "connected" then
      return "OnionXT: stream " & pStream & " is not open"
   end if
   write pData to socket sStreams[pStream]["socketID"]
   return empty
end oxWrite

command oxCloseStream pStream
   -- Idempotent close of the stream socket; forget the handle. A stale handle is
   -- a clean no-op.
   if sStreams[pStream]["socketID"] is empty then
      exit oxCloseStream
   end if
   oxSafeCloseSocket sStreams[pStream]["socketID"]
   delete variable sSockToStream[sStreams[pStream]["socketID"]]
   delete variable sStreams[pStream]
end oxCloseStream

function oxStreamState pStream
   if sStreams[pStream]["socketID"] is empty then
      return "unknown"
   end if
   return sStreams[pStream]["state"]
end oxStreamState

command oxSocksOpened pSocketID
   -- TCP up: send the method-negotiation greeting 05 01 00 (VER=5, 1 method,
   -- method 00 = no auth) and read the 2-byte method selection (docs/02 step 1).
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is empty then
      exit oxSocksOpened        -- stale
   end if
   put "greeting" into sStreams[tHandle]["state"]
   write numToByte(5) & numToByte(1) & numToByte(0) to socket pSocketID
   read from socket pSocketID for 2 with message "oxSocksMethod"
end oxSocksOpened

command oxSocksMethod pSocketID, pData
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is empty then
      exit oxSocksMethod
   end if
   if the number of bytes of pData < 2 then
      oxStreamFail tHandle, "SOCKS greeting reply truncated"
      exit oxSocksMethod
   end if
   local tVer, tMethod
   put byteToNum(byte 1 of pData) into tVer
   put byteToNum(byte 2 of pData) into tMethod
   if tVer is not 5 then
      oxStreamFail tHandle, "SOCKS server is not version 5"
      exit oxSocksMethod
   end if
   if tMethod is not 0 then
      -- 0xFF = no acceptable methods; anything non-zero we do not offer. Fail
      -- closed; on loopback no auth is needed and its absence is a misconfig to
      -- surface, not paper over (docs/02).
      oxStreamFail tHandle, "SOCKS server demands an auth method OnionXT does not offer (0x" & oxByteHex(tMethod) & ")"
      exit oxSocksMethod
   end if
   -- Method OK: send the CONNECT request with ATYP=3 (domain name) so TOR
   -- resolves pHost. This is the anonymity-critical choice (docs/02 step 2).
   put "connect" into sStreams[tHandle]["state"]
   local tHost, tHostBytes, tPort, tRequest
   put sStreams[tHandle]["host"] into tHost
   put textEncode(tHost, "UTF-8") into tHostBytes
   if the number of bytes of tHostBytes > 255 then
      oxStreamFail tHandle, "SOCKS host name exceeds 255 bytes"
      exit oxSocksMethod
   end if
   put sStreams[tHandle]["port"] into tPort
   -- 05 01 00 03 <len> <host bytes> <port-hi> <port-lo>. The port is 2 bytes
   -- big-endian; build it by hand so the wire bytes are self-evident (do not use
   -- binaryEncode "S", which is host order, docs LiveCode ref).
   put numToByte(5) & numToByte(1) & numToByte(0) & numToByte(3) into tRequest
   put numToByte(the number of bytes of tHostBytes) after tRequest
   put tHostBytes after tRequest
   put numToByte(tPort div 256) & numToByte(tPort mod 256) after tRequest
   write tRequest to socket pSocketID
   -- Read the fixed 4-byte reply head (VER REP RSV ATYP); the BND.ADDR that
   -- follows is variable and framed by ATYP (docs/02 step 3).
   put "replyhead" into sStreams[tHandle]["state"]
   read from socket pSocketID for 4 with message "oxSocksReplyHead"
end oxSocksMethod

command oxSocksReplyHead pSocketID, pData
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is empty then
      exit oxSocksReplyHead
   end if
   if the number of bytes of pData < 4 then
      oxStreamFail tHandle, "SOCKS reply head truncated"
      exit oxSocksReplyHead
   end if
   local tVer, tRep, tAtyp
   put byteToNum(byte 1 of pData) into tVer
   put byteToNum(byte 2 of pData) into tRep
   put byteToNum(byte 4 of pData) into tAtyp
   if tRep is not 0 then
      -- Any non-zero REP is failure. Map it (incl. Tor's onion 0xF0..0xF7) to a
      -- human message and tear down (docs/02 REP table; CLAUDE.md rule 4).
      oxStreamFail tHandle, oxSocksRepMessage(tRep)
      exit oxSocksReplyHead
   end if
   put tAtyp into sStreams[tHandle]["atyp"]
   -- Consume BND.ADDR + 2-byte BND.PORT. Length depends on ATYP: 01 -> 4, 04 ->
   -- 16, 03 -> one length byte then that many. We do not use BND.ADDR; we just
   -- frame past it so the socket is left at the start of the tunnel payload.
   if tAtyp is 1 then
      put "replyrest" into sStreams[tHandle]["state"]
      read from socket pSocketID for 6 with message "oxSocksReplyDone"     -- 4 + 2
   else if tAtyp is 4 then
      put "replyrest" into sStreams[tHandle]["state"]
      read from socket pSocketID for 18 with message "oxSocksReplyDone"    -- 16 + 2
   else if tAtyp is 3 then
      put "replylen" into sStreams[tHandle]["state"]
      read from socket pSocketID for 1 with message "oxSocksReplyLen"
   else
      oxStreamFail tHandle, "SOCKS reply has an unknown address type (" & tAtyp & ")"
   end if
end oxSocksReplyHead

command oxSocksReplyLen pSocketID, pData
   -- ATYP=3 domain BND.ADDR: one length byte, then that many, then 2 port bytes.
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is empty then
      exit oxSocksReplyLen
   end if
   if the number of bytes of pData < 1 then
      oxStreamFail tHandle, "SOCKS reply address length truncated"
      exit oxSocksReplyLen
   end if
   local tLen
   put byteToNum(byte 1 of pData) + 2 into tLen     -- address bytes + 2 port bytes
   put "replyrest" into sStreams[tHandle]["state"]
   read from socket pSocketID for tLen with message "oxSocksReplyDone"
end oxSocksReplyLen

command oxSocksReplyDone pSocketID, pData
   -- The SOCKS reply is fully consumed and REP was 0: the socket is now a
   -- transparent tunnel. Hand it up and start the streaming inbound reader.
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is empty then
      exit oxSocksReplyDone
   end if
   put "connected" into sStreams[tHandle]["state"]
   oxInvokeStreamCallback tHandle, "open", empty
   -- Begin the persistent read; each inbound chunk is delivered as "data".
   -- Confirmed on-engine: the no-quantifier `read ... with message` streams
   -- available bytes as they arrive (a dialed SOCKS tunnel and an inbound onion
   -- HTTP request both deliver chunk by chunk); it does not block to EOF.
   read from socket pSocketID with message "oxStreamData"
end oxSocksReplyDone

command oxStreamData pSocketID, pData
   -- Inbound bytes on a live stream (dialed OR inbound-accepted; both are unified
   -- through the stream tables). Deliver the chunk and re-arm the read.
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is empty then
      exit oxStreamData          -- stale / already torn down
   end if
   if the number of bytes of pData > 0 then
      oxInvokeStreamCallback tHandle, "data", pData
   end if
   -- Re-arm only if the stream is still live (the callback may have closed it).
   if sSockToStream[pSocketID] is not empty then
      read from socket pSocketID with message "oxStreamData"
   end if
end oxStreamData

command oxStreamDeadline pStream
   -- Handshake watchdog for a dialed stream: if it never reached "connected",
   -- tear it down (docs/02: a silent stall is the worst failure).
   if sStreams[pStream]["socketID"] is empty then
      exit oxStreamDeadline
   end if
   local tState
   put sStreams[pStream]["state"] into tState
   if tState is not "connected" and tState is not "closed" then
      oxStreamFail pStream, "SOCKS handshake timed out"
   end if
end oxStreamDeadline

private command oxStreamFail pStream, pError
   -- Fail closed: report the error to the app, then close and forget the stream.
   if sStreams[pStream]["socketID"] is empty then
      exit oxStreamFail
   end if
   put "failed" into sStreams[pStream]["state"]
   oxInvokeStreamCallback pStream, "error", pError
   oxSafeCloseSocket sStreams[pStream]["socketID"]
   delete variable sSockToStream[sStreams[pStream]["socketID"]]
   delete variable sStreams[pStream]
end oxStreamFail

private function oxSocksRepMessage pRep
   -- Map a SOCKS REP code to a clear message. Standard RFC 1928 0x00..0x08 plus
   -- Tor's onion extensions 0xF0..0xF7 (docs/02; the extended band only appears
   -- when the SocksPort has ExtendedErrors set, so 0x01/0x04 must map sensibly
   -- too, since without that flag Tor collapses onion failures onto them).
   if pRep is 1 then
      return "general SOCKS server failure"
   else if pRep is 2 then
      return "connection not allowed by ruleset"
   else if pRep is 3 then
      return "network unreachable"
   else if pRep is 4 then
      return "host unreachable"
   else if pRep is 5 then
      return "connection refused"
   else if pRep is 6 then
      return "TTL expired"
   else if pRep is 7 then
      return "command not supported"
   else if pRep is 8 then
      return "address type not supported"
   else if pRep is 240 then
      return "onion service not found (wrong or offline .onion address)"
   else if pRep is 241 then
      return "onion service descriptor is invalid"
   else if pRep is 242 then
      return "onion service introduction failed"
   else if pRep is 243 then
      return "onion service rendezvous failed"
   else if pRep is 244 then
      return "onion service missing client authorization"
   else if pRep is 245 then
      return "onion service wrong client authorization"
   else if pRep is 246 then
      return "onion service invalid address (malformed .onion)"
   else if pRep is 247 then
      return "onion service introduction timed out"
   end if
   return "SOCKS request failed (REP 0x" & oxByteHex(pRep) & ")"
end oxSocksRepMessage

-- ==========================================================================
-- Inbound: onion services (docs/03 step 3-4, docs/04). Listen on loopback
-- FIRST, then ADD_ONION, so a peer that connects the moment the descriptor
-- publishes is answered (CLAUDE.md socket gotcha 5).
-- ==========================================================================

command oxCreateService pVirtualPort, pLocalPort
   -- Ephemeral service, Tor generates the key. Reports a service handle through
   -- `the result`; the .onion address arrives asynchronously (status "service"
   -- and oxServiceAddress) once ADD_ONION replies.
   local tError
   put oxCheckServiceArgs(pVirtualPort, pLocalPort) into tError
   if tError is not empty then
      return tError
   end if
   local tHandle
   put oxStartService(pVirtualPort, pLocalPort) into tHandle
   if tHandle is not an integer then
      return tHandle          -- listener did not bind; surfaced verbatim
   end if
   -- Flags=Detach keeps the service published even if the control connection
   -- drops (a transient socketClosed/socketError, or a reconnect): without it, an
   -- ADD_ONION service dies with its control connection while its descriptor
   -- lingers in the DHT for ~3h, so a later visit hits "unable to find hidden
   -- service identity key" at rendezvous. oxRemoveService / oxShutdown DEL_ONION
   -- it explicitly; a hard crash leaves it until DEL_ONION or a tor restart.
   oxCtlSend "ADD_ONION NEW:ED25519-V3 Flags=Detach Port=" & pVirtualPort & ",127.0.0.1:" & pLocalPort, "add_onion:" & tHandle
   return tHandle
end oxCreateService

command oxCreateServiceFromSeed pSeed, pVirtualPort, pLocalPort
   -- Deterministic, reproducible address: derive the ed25519 identity from pSeed
   -- and pass Tor the 64-byte ED25519-V3 expanded key (docs/04). The expansion is
   -- SodiumXT's sxSignSeedToExpandedKey (docs/08 gap #1, SHIPPED in ABI 6); we
   -- compose it and fail with a clear message if it is absent, never hand-roll
   -- SHA-512. Same seed -> same .onion on every run.
   local tError
   put oxCheckServiceArgs(pVirtualPort, pLocalPort) into tError
   if tError is not empty then
      return tError
   end if
   if the number of bytes of pSeed is not 32 then
      return "OnionXT: oxCreateServiceFromSeed needs a 32-byte seed"
   end if
   local tExpanded
   put oxExpandedKeyFromSeed(pSeed) into tExpanded
   if the number of bytes of tExpanded is not 64 then
      return tExpanded          -- a capability error, surfaced verbatim
   end if
   -- Tor's ADD_ONION ED25519-V3: wants STANDARD RFC 4648 base64 (the +/ alphabet
   -- with = padding). The engine's base64Encode emits exactly that; do NOT use
   -- SodiumXT's sxBin2Base64, which is url-safe and unpadded and tor rejects.
   -- Strip any line-wrap whitespace the encoder may insert (docs/04 base64 note).
   local tBlob
   put oxStripWhitespace(base64Encode(tExpanded)) into tBlob
   local tHandle
   put oxStartService(pVirtualPort, pLocalPort) into tHandle
   if tHandle is not an integer then
      return tHandle          -- listener did not bind; surfaced verbatim
   end if
   -- Flags=Detach: keep the service alive across a control-connection drop (see
   -- oxCreateService); DEL_ONION on teardown still removes it.
   oxCtlSend "ADD_ONION ED25519-V3:" & tBlob & " Flags=Detach Port=" & pVirtualPort & ",127.0.0.1:" & pLocalPort, "add_onion:" & tHandle
   return tHandle
end oxCreateServiceFromSeed

command oxPublishService pVirtualPort, pLocalPort
   -- Publish an onion whose virtual port Tor forwards to a loopback port that
   -- SOMETHING ELSE is already accepting on (LiveCode's built-in HTTPD Library, or
   -- any local server). Unlike oxCreateService, OnionXT does NOT start its own
   -- accept loop: the external server owns the socket, parses the request, and
   -- replies. Teardown DEL_ONIONs the service but leaves that socket alone. Reports
   -- a service handle through `the result`; the .onion address arrives
   -- asynchronously (status "service", oxServiceAddress) once ADD_ONION replies.
   --
   -- SECURITY (the caller's responsibility): `accept connections on port` usually
   -- binds ALL interfaces, so the external server's local port may be reachable
   -- from the LAN, bypassing Tor. The external server MUST enforce loopback itself
   -- (reject any non-127.0.0.1 peer before responding), exactly as OnionXT's own
   -- oxPeerAccepted does. Bind the server to loopback if it supports it.
   local tError
   put oxCheckServiceArgs(pVirtualPort, pLocalPort) into tError
   if tError is not empty then
      return tError
   end if
   local tHandle
   put oxAllocHandle() into tHandle
   put pVirtualPort into sServices[tHandle]["virtualPort"]
   put pLocalPort into sServices[tHandle]["localPort"]
   put empty into sServices[tHandle]["serviceID"]
   put empty into sServices[tHandle]["address"]
   put empty into sServices[tHandle]["privateKey"]
   put false into sServices[tHandle]["ready"]
   -- Mark it external so oxRemoveService DEL_ONIONs it but does not close the
   -- socket (which OnionXT never opened; the external server owns it).
   put true into sServices[tHandle]["external"]
   -- No accept loop here (contrast oxStartService). Flags=Detach as in
   -- oxCreateService, so a control-connection blip does not un-publish it.
   oxCtlSend "ADD_ONION NEW:ED25519-V3 Flags=Detach Port=" & pVirtualPort & ",127.0.0.1:" & pLocalPort, "add_onion:" & tHandle
   return tHandle
end oxPublishService

private function oxCheckServiceArgs pVirtualPort, pLocalPort
   if sControlState is not "authenticated" then
      return "OnionXT: connect and authenticate the control port first (oxConnectControl)"
   end if
   if pVirtualPort is not an integer or pVirtualPort < 1 or pVirtualPort > 65535 then
      return "OnionXT: virtual port must be 1..65535"
   end if
   if pLocalPort is not an integer or pLocalPort < 1 or pLocalPort > 65535 then
      return "OnionXT: local port must be 1..65535"
   end if
   return empty
end oxCheckServiceArgs

private function oxStartService pVirtualPort, pLocalPort
   -- Allocate the handle and START the loopback listener before ADD_ONION so a
   -- forwarded connection is never refused (docs/03 step 4, ordering gotcha).
   local tHandle, tPrior
   put sLocalToService[pLocalPort] into tPrior
   if tPrior is not empty and sServices[tPrior]["localPort"] is not empty then
      -- Fail closed: a second service on an in-use local port would overwrite
      -- the port-to-service mapping, and removing either service would then
      -- close (or orphan) the shared listener out from under the other, so Tor
      -- keeps forwarding to a dead port - which looks exactly like a broken
      -- onion. One local port, one service; pick another local port.
      -- (Verified statically; needs an OXT pass.)
      return "OnionXT: local port " & pLocalPort & " already forwards for another service (one service per local port; pick another local port)"
   end if
   if tPrior is not empty then
      -- The mapping is stale (its service is gone); reclaim it and rebind below.
      delete variable sLocalToService[pLocalPort]
   end if
   put oxAllocHandle() into tHandle
   put pVirtualPort into sServices[tHandle]["virtualPort"]
   put pLocalPort into sServices[tHandle]["localPort"]
   put empty into sServices[tHandle]["serviceID"]
   put empty into sServices[tHandle]["address"]
   put empty into sServices[tHandle]["privateKey"]
   put false into sServices[tHandle]["ready"]
   if sLocalToService[pLocalPort] is empty then
      -- Bind loopback only. The classic `accept connections on port` has no
      -- bind-address argument (may listen on all interfaces), so oxPeerAccepted
      -- enforces loopback by rejecting any non-loopback peer before reading.
      -- Confirmed on-engine: Tor-forwarded onion connections are accepted here.
      accept connections on port pLocalPort with message "oxPeerAccepted"
      if the result is not empty then
         -- The listener did not bind (most often the local port is already in use
         -- by a prior run or another app). Fail closed: with no listener, Tor
         -- forwards inbound onion traffic to a dead port and the visitor gets an
         -- empty response, which looks exactly like a broken onion.
         delete variable sServices[tHandle]
         return "OnionXT: cannot listen on 127.0.0.1:" & pLocalPort & " (" & the result & ")"
      end if
      put true into sServices[tHandle]["listening"]
   end if
   put tHandle into sLocalToService[pLocalPort]
   return tHandle
end oxStartService

private command oxHandleAddOnionReply pHandle, pReply
   -- Parse ServiceID (and PrivateKey unless discarded) from the ADD_ONION reply
   -- (docs/03 step 3). On failure, fail closed and tear the half-built service.
   local tLine
   if char 1 to 3 of (line 1 of pReply) is not "250" and "ServiceID=" is not in pReply then
      oxRemoveService pHandle
      oxStatusUpdate "control", "error: ADD_ONION failed (" & (line 1 of pReply) & ")"
      exit oxHandleAddOnionReply
   end if
   repeat for each line tLine in pReply
      if "ServiceID=" is in tLine then
         put oxFieldAfter(tLine, "ServiceID=") into sServices[pHandle]["serviceID"]
      else if "PrivateKey=" is in tLine then
         put oxFieldAfter(tLine, "PrivateKey=") into sServices[pHandle]["privateKey"]
      end if
   end repeat
   if sServices[pHandle]["serviceID"] is not empty then
      put sServices[pHandle]["serviceID"] & ".onion" into sServices[pHandle]["address"]
      oxStatusUpdate "service", sServices[pHandle]["address"]
   end if
end oxHandleAddOnionReply

command oxRemoveService pService
   -- DEL_ONION and stop the listener. Idempotent: a stale handle is a no-op.
   if sServices[pService]["localPort"] is empty then
      exit oxRemoveService
   end if
   local tServiceID, tLocalPort
   put sServices[pService]["serviceID"] into tServiceID
   put sServices[pService]["localPort"] into tLocalPort
   if tServiceID is not empty and sControlState is "authenticated" then
      oxCtlSend "DEL_ONION " & tServiceID, "del_onion:" & pService
   end if
   -- Stop accepting on the loopback port, but ONLY if WE own the listener
   -- (oxCreateService / oxCreateServiceFromSeed). A publish-only service
   -- (oxPublishService) forwards to a socket an external server owns; leave it
   -- alone, or we would close it out from under that server.
   if sServices[pService]["external"] is not true then
      if sLocalToService[tLocalPort] is pService then
         oxSafeCloseSocket tLocalPort
         delete variable sLocalToService[tLocalPort]
      end if
   end if
   delete variable sServices[pService]
end oxRemoveService

function oxServiceAddress pService
   return sServices[pService]["address"]
end oxServiceAddress

function oxServiceIsReady pService
   return (sServices[pService]["ready"] is true)
end oxServiceIsReady

command oxPeerAccepted pSocketID
   -- Tor forwarded an inbound onion connection to our loopback listener. Enforce
   -- loopback (security-critical: reject any non-loopback peer before reading a
   -- byte), wrap the accepted socket as an inbound stream, and hand it to the app.
   -- Emit a diagnostic notice with the RAW accepted id so a misparse is visible.
   oxStatusUpdate "notice", "accepted connection id=[" & pSocketID & "]"
   local tPeerHost
   put oxHostOfSocket(pSocketID) into tPeerHost
   if not oxHostIsLoopback(tPeerHost) then
      -- Not a Tor-forwarded loopback connection: refuse it (docs LiveCode ref;
      -- the listener may be bound to all interfaces). Print the RAW id next to
      -- the parsed host, because since oxHostIsLoopback stopped treating an
      -- unparseable id as loopback this notice is also how a socket-id spelling
      -- oxHostOfSocket does not know announces itself (it arrives here with an
      -- empty host); one self-contained line is what a tester can act on.
      oxStatusUpdate "notice", "rejected non-loopback peer host [" & tPeerHost & \
         "] from id [" & pSocketID & "]"
      oxSafeCloseSocket pSocketID
      exit oxPeerAccepted
   end if
   local tHandle
   put oxAllocHandle() into tHandle
   put pSocketID into sStreams[tHandle]["socketID"]
   put "connected" into sStreams[tHandle]["state"]
   put "inbound" into sStreams[tHandle]["kind"]
   put empty into sStreams[tHandle]["callback"]
   put tHandle into sSockToStream[pSocketID]
   -- Hand the stream to the app FIRST so it can register a stream callback (the
   -- dispatch is synchronous), THEN arm the read so no inbound chunk is delivered
   -- before there is a callback to receive it.
   oxDispatch sPeerCallback, tHandle, oxGuessService(pSocketID), tPeerHost
   if sSockToStream[pSocketID] is not empty then
      read from socket pSocketID with message "oxStreamData"
   end if
end oxPeerAccepted

private function oxGuessService pSocketID
   -- Best-effort service association for the peer callback. The accept callback
   -- carries the PEER address, not our local port, so we cannot always know which
   -- service was reached (VERIFY the accepted-socket id format on-engine). If a
   -- single service is live, return it; otherwise return empty and let the app
   -- key on distinct local ports.
   local tKeys, tCount, tKey
   put the keys of sServices into tKeys
   put the number of lines of tKeys into tCount
   if tCount is 1 then
      return line 1 of tKeys
   end if
   return empty
end oxGuessService

private function oxHostIsLoopback pHost
   -- Accept a Tor-forwarded peer no matter how the engine spells the local
   -- address in the accepted-socket id, and NOTHING else: `accept connections on
   -- port` takes no bind address (see oxStartService), so the listener may be
   -- reachable from the network and this is the only thing standing between a
   -- routable peer and our stream tables. Takes the host oxHostOfSocket parsed,
   -- so the brackets of "[::1]" are already gone and there is exactly one
   -- spelling of each address to test. Comparisons are case-insensitive by
   -- default, so "::FFFF:" matches "::ffff:" without folding anything.
   --
   -- EMPTY IS A REFUSAL NOW, and that is the point of this change rather than a
   -- side effect. It used to return true, with "some engines report no host for
   -- a local accept" as the reason - but the old parser handed this guard an
   -- empty string for EVERY IPv6-shaped id, so "the engine reported no host" and
   -- "we could not parse this id" were indistinguishable, and the permissive
   -- branch let "::ffff:203.0.113.9:1234" - a routable peer wearing an
   -- IPv4-mapped hat - in as loopback. A guard whose default is accept is a
   -- fail-open guard; CLAUDE.md rule 4 says fail closed on anything we do not
   -- understand. So an unrecognized spelling is refused and oxPeerAccepted
   -- prints the RAW id alongside the parsed host: if a real engine is ever seen
   -- spelling an accepted id with no host at all (or with the fully expanded
   -- "0:0:0:0:0:0:0:1"), the fix is to teach oxHostOfSocket that spelling, never
   -- to re-open this branch.
   local tHost
   put pHost into tHost
   if tHost is empty then
      return false
   end if
   if tHost is kOxHost then
      return true
   end if
   if tHost begins with "127." then
      return true
   end if
   if tHost is "::1" then
      return true
   end if
   if tHost begins with "::ffff:" then
      -- The IPv4-mapped form a dual-stack listener can report. It is the SAME
      -- address with a prefix, so strip it and re-test the v4 rules: that admits
      -- "::ffff:127.0.0.1" (genuinely loopback, and unroutable) and refuses
      -- "::ffff:203.0.113.9" (genuinely routable), which the old empty-item-1
      -- parse could not tell apart.
      delete char 1 to 7 of tHost
      if tHost is kOxHost or tHost begins with "127." then
         return true
      end if
      return false
   end if
   if tHost is "localhost" then
      return true
   end if
   return false
end oxHostIsLoopback

-- ==========================================================================
-- Address helpers: a v3 .onion address IS an ed25519 public key
-- (docs/04-onion-rendezvous.md). base32 and the layout are pure byte work; only
-- the checksum needs SHA3-256, which is composed from SodiumXT (docs/08).
-- ==========================================================================

function oxPublicKeyFromAddress pOnionAddress
   -- Strip ".onion", base32-decode 56 chars -> 35 bytes, return the first 32 (the
   -- ed25519 public key). No crypto needed. Empty on a structural error.
   local tCore, tRaw
   put oxNormalizeAddress(pOnionAddress) into tCore
   if the number of chars of tCore is not 56 then
      return empty
   end if
   put oxBase32Decode(tCore) into tRaw
   if the number of bytes of tRaw is not 35 then
      return empty
   end if
   if byteToNum(byte 35 of tRaw) is not 3 then
      return empty            -- not a version-3 address
   end if
   return byte 1 to 32 of tRaw
end oxPublicKeyFromAddress

function oxAddressFromPublicKey pEd25519Pub
   -- base32( pubkey || checksum || 0x03 ) & ".onion" (docs/04). The checksum is
   -- SHA3-256(".onion checksum" || pubkey || 0x03)[:2], composed from SodiumXT;
   -- absent that primitive, return a clear error rather than a wrong address.
   if the number of bytes of pEd25519Pub is not 32 then
      return "OnionXT: oxAddressFromPublicKey needs a 32-byte ed25519 public key"
   end if
   local tChecksum
   put oxOnionChecksum(pEd25519Pub) into tChecksum
   if the number of bytes of tChecksum is not 2 then
      return tChecksum         -- capability error, surfaced verbatim
   end if
   return oxBase32Encode(pEd25519Pub & tChecksum & numToByte(3)) & ".onion"
end oxAddressFromPublicKey

function oxIsValidAddress pOnionAddress
   -- Structural checks always (length, alphabet, version byte); checksum
   -- verification too when SodiumXT SHA3-256 is available (docs/04, docs/08).
   local tCore, tRaw
   put oxNormalizeAddress(pOnionAddress) into tCore
   if the number of chars of tCore is not 56 then
      return false
   end if
   local tI, tCh
   repeat with tI = 1 to 56
      put char tI of tCore into tCh
      if offset(tCh, kOxBase32Alphabet) is 0 then
         return false
      end if
   end repeat
   put oxBase32Decode(tCore) into tRaw
   if the number of bytes of tRaw is not 35 then
      return false
   end if
   if byteToNum(byte 35 of tRaw) is not 3 then
      return false
   end if
   -- Checksum verification when we can compute it; otherwise structural-only
   -- (the real authentication is Tor's connect-time descriptor-signature check).
   local tChecksum
   put oxOnionChecksum(byte 1 to 32 of tRaw) into tChecksum
   if the number of bytes of tChecksum is not 2 then
      return true             -- no SHA3-256 available; accept the structure
   end if
   return oxConstantTimeEqual(tChecksum, byte 33 to 34 of tRaw)
end oxIsValidAddress

private function oxNormalizeAddress pOnionAddress
   -- Trim, lowercase, and strip a trailing ".onion".
   local tCore
   put oxTrim(pOnionAddress) into tCore
   put toLower(tCore) into tCore
   if tCore ends with ".onion" then
      put char 1 to -7 of tCore into tCore
   end if
   return tCore
end oxNormalizeAddress

private function oxPow2 pN
   -- 2 to the pN, as an exact integer, WITHOUT the ^ operator (some xTalk
   -- parsers reject `^` in a div/mod expression). pN is small in base32 (0..12),
   -- so this is a few multiplies and stays well within exact-integer range.
   local tR, tI
   put 1 into tR
   repeat with tI = 1 to pN
      multiply tR by 2
   end repeat
   return tR
end oxPow2

private function oxIntDiv pA, pB
   -- Integer division (floor, for the non-negative operands base32 uses) WITHOUT
   -- the `div` operator, to sidestep any xTalk parser that mishandles div/mod/^
   -- inside a compound expression. Operands here are small (base32 bit math).
   return trunc(pA / pB)
end oxIntDiv

private function oxIntMod pA, pB
   -- pA modulo pB WITHOUT the `mod` operator (see oxIntDiv).
   return pA - pB * oxIntDiv(pA, pB)
end oxIntMod

private function oxBase32Encode pData
   -- RFC 4648 base32, lowercase, no padding. Pure bit-packing: accumulate input
   -- bytes MSB-first into a small buffer and emit 5-bit groups. The buffer is
   -- masked to its pending bits each iteration so it never grows past ~13 bits
   -- (staying in exact-integer range; a 280-bit accumulator would lose precision).
   local tOut, tBits, tValue, tI, tN, tIndex
   put "" into tOut
   put 0 into tBits
   put 0 into tValue
   put the number of bytes of pData into tN
   repeat with tI = 1 to tN
      put tValue * 256 + byteToNum(byte tI of pData) into tValue
      add 8 to tBits
      repeat while tBits >= 5
         subtract 5 from tBits
         put oxIntMod(oxIntDiv(tValue, oxPow2(tBits)), 32) into tIndex
         put char (tIndex + 1) of kOxBase32Alphabet after tOut
      end repeat
      put oxIntMod(tValue, oxPow2(tBits)) into tValue        -- keep only the pending bits
   end repeat
   if tBits > 0 then
      -- Left-align the final partial group and emit it (canonical no-pad tail).
      put oxIntMod(tValue * oxPow2(5 - tBits), 32) into tIndex
      put char (tIndex + 1) of kOxBase32Alphabet after tOut
   end if
   return tOut
end oxBase32Encode

private function oxBase32Decode pText
   -- Inverse of oxBase32Encode. Accumulate 5 bits per input char and emit a byte
   -- whenever 8 bits are available; leftover (< 5) bits of the final group are
   -- discarded (canonical). Returns empty on any character outside the alphabet.
   local tOut, tBits, tValue, tI, tN, tCh, tIndex, tByteOut
   put "" into tOut
   put 0 into tBits
   put 0 into tValue
   put the number of chars of pText into tN
   repeat with tI = 1 to tN
      put char tI of pText into tCh
      put offset(tCh, kOxBase32Alphabet) into tIndex     -- 1..32, or 0 if absent
      if tIndex is 0 then
         return empty
      end if
      put tValue * 32 + (tIndex - 1) into tValue
      add 5 to tBits
      if tBits >= 8 then
         subtract 8 from tBits
         put oxIntMod(oxIntDiv(tValue, oxPow2(tBits)), 256) into tByteOut
         put numToByte(tByteOut) after tOut
         put oxIntMod(tValue, oxPow2(tBits)) into tValue
      end if
   end repeat
   return tOut
end oxBase32Decode

private function oxOnionChecksum pEd25519Pub
   -- SHA3-256(".onion checksum" || pubkey || 0x03)[:2] (docs/04). H = SHA3-256 is
   -- a SodiumXT primitive (docs/08); compose it and report a capability error if
   -- it is absent, never hand-roll a hash (CLAUDE.md rule 1).
   local tPreimage, tHash
   put textEncode(kOxChecksumPrefix, "UTF-8") & pEd25519Pub & numToByte(3) into tPreimage
   put oxSha3_256(tPreimage) into tHash
   -- A valid SHA3-256 is exactly 32 bytes; any other length is the capability
   -- error string from oxSha3_256, surfaced verbatim (robust against comparing a
   -- string prefix against binary data).
   if the number of bytes of tHash is not 32 then
      return tHash
   end if
   return byte 1 to 2 of tHash
end oxOnionChecksum

private function oxExpandedKeyFromSeed pSeed
   -- Compose SodiumXT's ABI-6 helper (docs/08 gap #1, now SHIPPED): a 32-byte seed
   -- becomes the 64-byte Tor ED25519-V3 expanded secret key (SHA-512(seed) with the
   -- ed25519 scalar clamp, all done inside SodiumXT so OnionXT hand-rolls nothing).
   -- This is exactly the key ADD_ONION ED25519-V3:<key> wants (docs/04), and its
   -- public key equals sxSignKeypairFromSeed(pSeed)'s, so the .onion address and the
   -- app's signing identity stay consistent. Requires SodiumXT ABI >= 6.
   local tExpanded
   try
      put sxSignSeedToExpandedKey(pSeed) into tExpanded
   catch tError
      return "OnionXT: oxCreateServiceFromSeed needs SodiumXT sxSignSeedToExpandedKey (requires SodiumXT ABI >= 6; see docs/08)"
   end try
   if the number of bytes of tExpanded is not 64 then
      return "OnionXT: sxSignSeedToExpandedKey returned " & the number of bytes of tExpanded & " bytes, expected 64"
   end if
   return tExpanded
end oxExpandedKeyFromSeed

-- ==========================================================================
-- Pluggable transport seam (docs/06). Thin wrappers so any higher-layer protocol
-- can treat OnionXT as a transport: dial by rendezvous address, listen at a
-- seed-derived address, send/recv bytes. OnionXT stays a transport: no crypto,
-- no framing opinion; the payload is sealed by the app via SodiumXT.
-- ==========================================================================

function oxTransportInfo
   -- Advertise the transport and which optional SodiumXT-backed capabilities are
   -- available, so a caller can negotiate transports and fall back visibly
   -- rather than silently (docs/06). Returns a LiveCode array.
   local tInfo
   put "ox" into tInfo["transport"]
   put kOxVersion into tInfo["version"]
   put (oxSodiumHasHmac() and oxSodiumHasRandom()) into tInfo["safeCookieAuth"]
   put oxSodiumHasExpansion() into tInfo["deterministicOnion"]
   put oxSodiumHasSha3() into tInfo["offlineAddress"]
   return tInfo
end oxTransportInfo

command oxTransportDial pAddress, pPort
   -- Dial a rendezvous address. Accepts a full <56>.onion, or a 32-byte ed25519
   -- public key / 64-hex string, which it maps to an address first (docs/06).
   local tPort, tHost
   if pPort is empty then
      put 80 into tPort
   else
      put pPort into tPort
   end if
   put pAddress into tHost
   if not (tHost ends with ".onion") then
      local tPub
      if the number of chars of tHost is 64 then
         put oxHexToBytes(tHost) into tPub
      else
         put tHost into tPub
      end if
      if the number of bytes of tPub is 32 then
         put oxAddressFromPublicKey(tPub) into tHost
         if tHost begins with "OnionXT:" then
            return tHost
         end if
      end if
   end if
   oxDial tHost, tPort
   return the result
end oxTransportDial

command oxTransportListen pSeed, pVirtualPort, pLocalPort
   -- Publish a reproducible rendezvous point from a seed (docs/06).
   oxCreateServiceFromSeed pSeed, pVirtualPort, pLocalPort
   return the result
end oxTransportListen

command oxTransportSend pStream, pData
   oxWrite pStream, pData
   return the result
end oxTransportSend

command oxTransportRecv pStream, pHandlerName
   -- Register where inbound bytes are delivered (the stream callback).
   oxSetStreamCallback pStream, pHandlerName
   return the result
end oxTransportRecv

-- ==========================================================================
-- Lifecycle and teardown. Central socket-message handlers and a master
-- oxShutdown so an app can free everything it opened, e.g. on closeStack (there
-- is no deterministic unload hook in OXT; CLAUDE.md handles-and-state).
-- ==========================================================================

command oxShutdown
   -- Idempotent: close every stream, remove every service, disconnect control.
   -- Safe to call twice.
   local tKey, tKeys
   put the keys of sStreams into tKeys
   repeat for each line tKey in tKeys
      oxCloseStream tKey
   end repeat
   put the keys of sServices into tKeys
   repeat for each line tKey in tKeys
      oxRemoveService tKey
   end repeat
   oxDisconnectControl
end oxShutdown

on socketError pSocketID, pError
   -- The engine's socket-failure message. If the socket closes because of an
   -- error, this arrives instead of socketClosed. Look up the owner and fail
   -- closed (docs LiveCode ref). A message for an unknown id is a clean no-op.
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is not empty then
      oxStreamFail tHandle, "socket error: " & pError
      exit socketError
   end if
   if pSocketID is sControlSocket then
      oxStatusUpdate "control", "error: " & pError
      oxDisconnectControl
   end if
end socketError

on socketClosed pSocketID
   -- The remote side closed cleanly. Deliver "closed" to a stream's app callback
   -- and forget it; for the control socket, mark disconnected.
   local tHandle
   put sSockToStream[pSocketID] into tHandle
   if tHandle is not empty then
      oxInvokeStreamCallback tHandle, "closed", empty
      delete variable sSockToStream[pSocketID]
      delete variable sStreams[tHandle]
      exit socketClosed
   end if
   if pSocketID is sControlSocket then
      oxStatusUpdate "control", "disconnected"
      oxDisconnectControl
   end if
end socketClosed

on socketTimeout pSocketID
   -- socketTimeout REPEATS every interval while a read/write is pending (docs
   -- LiveCode ref), so it is only fatal during a handshake; on a connected stream
   -- it is just an idle read and must be ignored. Tear down only handshakes.
   local tHandle, tState
   put sSockToStream[pSocketID] into tHandle
   if tHandle is not empty then
      put sStreams[tHandle]["state"] into tState
      if tState is not "connected" then
         oxStreamFail tHandle, "SOCKS handshake timed out"
      end if
      exit socketTimeout
   end if
   -- Control socket: only fatal before authentication completes.
   if pSocketID is sControlSocket and sControlState is not "authenticated" then
      oxStatusUpdate "control", "error: control handshake timed out"
      oxDisconnectControl
   end if
end socketTimeout

-- ==========================================================================
-- Optional Mode B: launch and supervise a bundled tor (docs/07). This is a
-- CONVENIENCE layer, NOT the default and NOT the tested path; the assume-running
-- daemon (Mode A) is the trusted, recommended base. VERIFY every step on-engine.
-- ==========================================================================

command oxLaunchTor pTorPath, pDataDir, pSocksPort, pControlPort
   -- Write a minimal torrc into pDataDir and launch pTorPath against it, so tor
   -- exits with the app (__OwningControllerProcess) and uses cookie auth. Returns
   -- empty on a clean launch attempt, or an error string. The caller then polls
   -- oxConnectControl / oxBootstrapProgress; this does not wait for bootstrap.
   if pTorPath is empty or pDataDir is empty then
      return "OnionXT: oxLaunchTor needs a tor binary path and a data directory"
   end if
   local tSocks, tControl, tTorrc, tRcPath
   if pSocksPort is empty then
      put kOxSocksPortDefault into tSocks
   else
      put pSocksPort into tSocks
   end if
   if pControlPort is empty then
      put kOxControlPortDefault into tControl
   else
      put pControlPort into tControl
   end if
   put "SocksPort " & tSocks & oxCrlf() after tTorrc
   put "ControlPort " & tControl & oxCrlf() after tTorrc
   put "CookieAuthentication 1" & oxCrlf() after tTorrc
   put "DataDirectory " & pDataDir & oxCrlf() after tTorrc
   -- Tie tor's lifetime to this process where the platform supports it.
   put "__OwningControllerProcess " & oxProcessId() & oxCrlf() after tTorrc
   put pDataDir & "/onionxt-torrc" into tRcPath
   put tTorrc into url ("binfile:" & tRcPath)
   oxSetSocksPort tSocks
   oxSetControlPort tControl
   -- open process is platform-specific; launch tor detached with -f <torrc>.
   -- QUOTE BOTH PATHS. The command line is split on whitespace, so an unquoted
   -- "C:/Program Files/Tor/tor.exe" arrives as the two arguments "C:/Program"
   -- and "Files/Tor/tor.exe" and the launch fails - and a data directory under
   -- "Application Support" or a user folder with a space in the name is the
   -- normal case on Windows and macOS, not an edge case. The same applies to
   -- the torrc path, which is derived from pDataDir.
   -- VERIFY: process launch and teardown on your target OXT build.
   open process (quote & pTorPath & quote & " -f " & quote & tRcPath & quote) for read
   return empty
end oxLaunchTor

command oxStopTor
   -- Ask tor to shut down over the control port, then disconnect. If Mode B was
   -- not used this simply disconnects control (idempotent).
   if sControlState is "authenticated" then
      oxCtlSend "SIGNAL SHUTDOWN", "signal"
   end if
   oxDisconnectControl
end oxStopTor

-- ==========================================================================
-- SodiumXT composition helpers (requires SodiumXT ABI >= 6 for the deterministic
-- onion and SAFECOOKIE paths). Each sx* primitive is called DIRECTLY and wrapped
-- in try/catch: an absent handler raises a catchable execution error, so a missing
-- primitive degrades to a clear capability error rather than crashing, and the
-- function's return value comes back unambiguously (CLAUDE.md rule 1; no crypto is
-- hand-rolled here). base32 and the base64 encode are pure byte ops, NOT here.
-- ==========================================================================

private function oxSha3_256 pData
   -- Composed since SodiumXT ABI 7 (docs/08 gap #2, closed 2026-08-11):
   -- sxSha3_256 is the vendored FIPS-202 primitive SodiumXT ships precisely
   -- for this checksum. Against an older installed SodiumXT the absent handler
   -- still raises here and degrades to the clear capability error below. The
   -- checksum is a nicety, not a security dependency (tor authenticates the
   -- onion at connect time), so callers degrade to structural-only checks.
   local tOut
   try
      put sxSha3_256(pData) into tOut
   catch tError
      return "OnionXT: the offline .onion checksum needs SodiumXT SHA3-256 (sxSha3_256, ABI 7+; this SodiumXT predates it - docs/08 #2)"
   end try
   return tOut
end oxSha3_256

private function oxHmac pKeyString, pMessage
   -- HMAC-SHA256 (SodiumXT ABI >= 6). The ASCII key string crosses as its bytes.
   local tOut
   try
      put sxHmacSha256(textEncode(pKeyString, "UTF-8"), pMessage) into tOut
   catch tError
      return "OnionXT: SAFECOOKIE auth needs SodiumXT HMAC-SHA256 (sxHmacSha256, SodiumXT ABI >= 6, docs/08)"
   end try
   return tOut
end oxHmac

private function oxRandomBytes pCount
   local tOut
   try
      put sxRandomBytes(pCount) into tOut
   catch tError
      return empty
   end try
   return tOut
end oxRandomBytes

private function oxConstantTimeEqual pA, pB
   -- Prefer SodiumXT's constant-time compare; fall back to a plain compare only
   -- when it is unavailable (acceptable on a loopback control port).
   local tOut
   try
      put sxMemEqual(pA, pB) into tOut
      return (tOut is true)
   catch tError
      return (pA is pB)
   end try
end oxConstantTimeEqual

private function oxSodiumHasHmac
   -- True if SodiumXT (ABI >= 6) provides HMAC-SHA256. A benign 1-byte probe.
   local tOut
   try
      put sxHmacSha256(numToByte(0), numToByte(0)) into tOut
      return (the number of bytes of tOut is 32)
   catch tError
      return false
   end try
end oxSodiumHasHmac

private function oxSodiumHasRandom
   local tOut
   try
      put sxRandomBytes(1) into tOut
      return (the number of bytes of tOut is 1)
   catch tError
      return false
   end try
end oxSodiumHasRandom

private function oxSodiumHasSha3
   -- Capability probe: true on SodiumXT ABI 7+ (sxSha3_256 shipped 2026-08-11,
   -- docs/08 #2 CLOSED); false only against an older installed SodiumXT.
   try
      get sxSha3_256(empty)
      return true
   catch tError
      return false
   end try
end oxSodiumHasSha3

private function oxSodiumHasExpansion
   -- True if SodiumXT (ABI >= 6) provides the seed -> expanded-key helper.
   local tOut
   try
      put sxSignSeedToExpandedKey(oxZeroBytes(32)) into tOut
      return (the number of bytes of tOut is 64)
   catch tError
      return false
   end try
end oxSodiumHasExpansion

private function oxLoadCookie
   -- Read the 32 raw cookie bytes from the authoritative PROTOCOLINFO path
   -- (docs/03). binfile is binary-safe. Returns true on a plausible 32-byte read.
   if sControlCookieFile is empty then
      return false
   end if
   local tBytes
   put url ("binfile:" & sControlCookieFile) into tBytes
   if the number of bytes of tBytes is not 32 then
      return false
   end if
   put tBytes into sControlCookieBytes
   return true
end oxLoadCookie

-- ==========================================================================
-- Small pure helpers.
-- ==========================================================================

private function effectiveSocksPort
   if sSocksPort is empty then
      return kOxSocksPortDefault
   end if
   return sSocksPort
end effectiveSocksPort

private function effectiveControlPort
   if sControlPort is empty then
      return kOxControlPortDefault
   end if
   return sControlPort
end effectiveControlPort

private function oxAllocHandle
   -- Monotonic; 0 is never a valid handle so a zero/empty is always a clean miss.
   if sNextHandle is empty then
      put 0 into sNextHandle
   end if
   add 1 to sNextHandle
   return sNextHandle
end oxAllocHandle

private command oxSafeCloseSocket pSocketID
   -- Idempotent close: only close ids the engine still lists as open, so closing
   -- a stale/unknown id is a clean no-op (VERIFY the engine tolerates it anyway).
   if pSocketID is empty then
      exit oxSafeCloseSocket
   end if
   if pSocketID is among the lines of the openSockets then
      close socket pSocketID
   end if
end oxSafeCloseSocket

private command oxInvokeStreamCallback pStream, pEvent, pData
   oxDispatch sStreams[pStream]["callback"], pStream, pEvent, pData
end oxInvokeStreamCallback

private command oxDispatch pHandlerName, pArg1, pArg2, pArg3
   -- Deliver to the app; a missing handler is a clean no-op so an app wires only
   -- the callbacks it uses. Guard the call so a throwing app handler cannot break
   -- the state machine.
   if pHandlerName is empty then
      exit oxDispatch
   end if
   local tTarget
   put oxCallbackTarget() into tTarget      -- a local, not a function call inline
   try
      dispatch pHandlerName to tTarget with pArg1, pArg2, pArg3
   catch tIgnore
      -- Swallow app-side callback errors; the transport must keep running.
   end try
end oxDispatch

private function oxCallbackTarget
   -- The object the app callbacks live in. Explicitly set is authoritative;
   -- otherwise the topStack is the best default (VERIFY it is the app's stack).
   if sCallbackOwner is not empty then
      return sCallbackOwner
   end if
   return the topStack
end oxCallbackTarget

private function oxCrlf
   -- The wire line terminator as explicit bytes-to-be (U+000D U+000A), so the
   -- byte value never depends on how the engine defines the `crlf` constant.
   return numToChar(13) & numToChar(10)
end oxCrlf

private function oxStripLineEnd pLine
   -- Strip a trailing LF and/or CR from a decoded reply line, in either order.
   -- A plain function (returns the trimmed line) rather than a @-by-reference
   -- command, to avoid the less-common reference-parameter construct.
   repeat while pLine is not empty and (the last char of pLine is numToChar(10) or the last char of pLine is numToChar(13))
      delete the last char of pLine
   end repeat
   return pLine
end oxStripLineEnd

private function oxFieldAfter pText, pMarker
   -- The whitespace-delimited token immediately following pMarker in pText, or
   -- empty. Used for METHODS=, PROGRESS=, ServiceID=, version=, SERVERHASH=, etc.
   -- itemDelimiter is global mutable state, so save and restore it (gotcha 7).
   local tPos, tRest, tSaved, tOut
   put offset(pMarker, pText) into tPos
   if tPos is 0 then
      return empty
   end if
   put char (tPos + the number of chars of pMarker) to -1 of pText into tRest
   -- Stop at the first space (values here are single tokens; quoted values use
   -- oxQuotedValueAfter instead).
   put the itemDelimiter into tSaved
   set the itemDelimiter to space
   put item 1 of tRest into tOut
   set the itemDelimiter to tSaved
   return tOut
end oxFieldAfter

private function oxQuotedValueAfter pText, pMarker
   -- The C-quoted string value following pMarker (e.g. COOKIEFILE="..."). Returns
   -- the raw (still-escaped) inside of the quotes; the caller un-escapes.
   local tPos, tRest, tOut, tI, tCh, tEsc
   put offset(pMarker, pText) into tPos
   if tPos is 0 then
      return empty
   end if
   put char (tPos + the number of chars of pMarker) to -1 of pText into tRest
   if char 1 of tRest is not quote then
      -- Unquoted value: take up to the next space (save/restore itemDelimiter).
      -- tOut is already declared at the handler top; only tSaved is new here.
      local tSaved
      put the itemDelimiter into tSaved
      set the itemDelimiter to space
      put item 1 of tRest into tOut
      set the itemDelimiter to tSaved
      return tOut
   end if
   -- Walk from just after the opening quote to the matching unescaped quote.
   put empty into tOut
   put false into tEsc
   repeat with tI = 2 to the number of chars of tRest
      put char tI of tRest into tCh
      if tEsc then
         put tCh after tOut
         put false into tEsc
      else if tCh is "\" then
         put tCh after tOut
         put true into tEsc
      else if tCh is quote then
         exit repeat
      else
         put tCh after tOut
      end if
   end repeat
   return tOut
end oxQuotedValueAfter

private function oxCUnescape pStr
   -- Undo Tor's C-style string escapes (docs/03): \n \t \r, octal \0..\377, and
   -- backslash-before-any-other-char is that literal char.
   local tOut, tI, tN, tCh, tNext, tOct
   put empty into tOut
   put the number of chars of pStr into tN
   put 1 into tI
   repeat while tI <= tN
      put char tI of pStr into tCh
      if tCh is "\" and tI < tN then
         put char (tI + 1) of pStr into tNext
         if tNext is "n" then
            put numToChar(10) after tOut
            add 2 to tI
         else if tNext is "t" then
            put numToChar(9) after tOut
            add 2 to tI
         else if tNext is "r" then
            put numToChar(13) after tOut
            add 2 to tI
         else if tNext is in "01234567" then
            -- Up to 3 octal digits.
            put empty into tOct
            add 1 to tI
            repeat while tI <= tN and (the number of chars of tOct) < 3 and (char tI of pStr) is in "01234567"
               put char tI of pStr after tOct
               add 1 to tI
            end repeat
            put numToChar(oxOctalToNum(tOct)) after tOut
         else
            put tNext after tOut
            add 2 to tI
         end if
      else
         put tCh after tOut
         add 1 to tI
      end if
   end repeat
   return tOut
end oxCUnescape

private function oxOctalToNum pOct
   local tVal, tI
   put 0 into tVal
   repeat with tI = 1 to the number of chars of pOct
      put tVal * 8 + (charToNum(char tI of pOct) - 48) into tVal
   end repeat
   return tVal
end oxOctalToNum

private function oxQuoteEscape pStr
   -- Escape backslash and double-quote for a control-port QuotedString.
   local tOut
   put pStr into tOut
   replace "\" with "\\" in tOut
   replace quote with ("\" & quote) in tOut
   return tOut
end oxQuoteEscape

private function oxBytesToHex pData
   -- Lowercase hex (high nibble first). H* unpacks the whole run. binaryDecode is
   -- a FUNCTION (it returns the count decoded and fills the output variable, which
   -- must already exist), so it must be called as a function; `get` discards the
   -- count into `it` while tHex is filled.
   local tHex
   get binaryDecode("H*", pData, tHex)
   return tHex
end oxBytesToHex

private function oxHexToBytes pHex
   return binaryEncode("H*", pHex)
end oxHexToBytes

private function oxByteHex pNum
   -- Two-digit hex for one byte value (for error messages).
   return oxBytesToHex(numToByte(pNum))
end oxByteHex

private function oxHostOfSocket pSocketID
   -- The HOST part of an engine socket id: "host:port", optionally with a
   -- "|name" suffix (we mint "127.0.0.1:9050|oxs3" ourselves; an ACCEPTED id is
   -- whatever the engine spells the PEER address as, so its shape is the
   -- engine's choice, not ours).
   --
   -- This is security-critical input, not a display helper: oxPeerAccepted feeds
   -- the result straight to oxHostIsLoopback, which decides whether an inbound
   -- peer is let in. The obvious "item 1 with the itemDelimiter set to colon"
   -- was wrong in BOTH directions on an IPv6 id, and one of those directions
   -- FAILED OPEN:
   --   "::1:54321"                -> item 1 is EMPTY, and the guard's old
   --                                 empty-is-loopback branch accepted it;
   --   "::ffff:203.0.113.9:1234"  -> item 1 is EMPTY too, so a ROUTABLE peer in
   --                                 IPv4-mapped form was accepted as loopback;
   --   "[::1]:54321"              -> item 1 is "[", so a real loopback peer was
   --                                 refused (the harmless direction).
   -- Parse by SHAPE instead, which also makes the guard's "::1" branch reachable
   -- for the first time (it never could be: item 1 of anything containing a
   -- colon cannot itself contain one):
   --   1. drop any "|name" suffix - the name half is ours and never part of the
   --      host, and it can carry digits that would otherwise look like a port;
   --   2. a bracketed group IS the host, verbatim and unbracketed - the brackets
   --      exist precisely to separate an IPv6 host's colons from the port colon,
   --      and stripping them here means the guard sees ONE spelling of ::1;
   --   3. otherwise the host is everything up to the LAST colon, which is right
   --      for "127.0.0.1:9050" and for a bare "::1:54321" alike;
   --   4. a colon-less id has no port to strip, so it is all host.
   -- Anything this cannot make sense of comes back EMPTY, which oxHostIsLoopback
   -- now REFUSES (it used to accept it); that is the fail-closed direction.
   local tSaved, tRaw, tCut, tOut
   put pSocketID into tRaw
   put offset("|", tRaw) into tCut
   if tCut > 0 then
      delete char tCut to -1 of tRaw
   end if
   if char 1 of tRaw is "[" then
      put offset("]", tRaw) into tCut
      if tCut < 3 then
         return empty              -- unclosed or empty brackets: not a host
      end if
      return char 2 to (tCut - 1) of tRaw
   end if
   if ":" is not in tRaw then
      return tRaw
   end if
   put the itemDelimiter into tSaved
   set the itemDelimiter to ":"
   -- `item 1 to -2` REJOINS its items with the delimiter, which is exactly what
   -- a bare IPv6 host needs: the three empty/short items of "::1:54321" come
   -- back as "::1", while "127.0.0.1:9050" comes back unchanged.
   put item 1 to -2 of tRaw into tOut
   set the itemDelimiter to tSaved
   return tOut
end oxHostOfSocket

private function oxMethodOffered pMethod
   -- sControlMethods is a comma list; force comma before testing membership.
   local tSaved, tResult
   put the itemDelimiter into tSaved
   set the itemDelimiter to comma
   put (pMethod is among the items of sControlMethods) into tResult
   set the itemDelimiter to tSaved
   return tResult
end oxMethodOffered

private function oxStripWhitespace pStr
   local tOut
   put pStr into tOut
   replace numToChar(10) with empty in tOut
   replace numToChar(13) with empty in tOut
   replace space with empty in tOut
   replace tab with empty in tOut
   return tOut
end oxStripWhitespace

private function oxTrim pStr
   -- The `tOut is not empty` guard is essential: the empty string is "in" every
   -- string, so without it an all-whitespace or empty input would loop forever
   -- (the first/last char of empty is empty, which `is in` any charset).
   local tOut, tWhite
   put pStr into tOut
   put space & tab & numToChar(10) & numToChar(13) into tWhite
   repeat while tOut is not empty and (the first char of tOut) is in tWhite
      delete the first char of tOut
   end repeat
   repeat while tOut is not empty and (the last char of tOut) is in tWhite
      delete the last char of tOut
   end repeat
   return tOut
end oxTrim

private function oxZeroBytes pCount
   local tOut, tI
   put empty into tOut
   repeat with tI = 1 to pCount
      put numToByte(0) after tOut
   end repeat
   return tOut
end oxZeroBytes

private function oxProcessId
   -- Best-effort current process id for __OwningControllerProcess (Mode B).
   -- VERIFY the available accessor on your OXT build; empty is tolerated by tor.
   return the processId
end oxProcessId

-- <<< END EMBEDDED LIBRARIES <<<

local sSession          -- the live session handle (0/empty = none)
local sVaultPass        -- master passphrase protecting the prefs file ("" = none)
local sPrefLockedOut    -- "true" if the prefs file is locked and we could NOT open
                        --   it this run, so chPrefSave must never overwrite it
local sPolling          -- "true" while the loops are armed
local sChannels         -- array: index -> {seed, name, releases, pass} - YOUR channels
local sActive           -- index of the active channel (drives the sMy* cache below)
local sCanEncrypt       -- "true" if SodiumXT (libsodium) is installed + working
local sKeyCache         -- array: pubkeyHex&":"&pass -> 32-byte master key (Argon2id is slow)
local sFollowPass       -- array: followed pubkey -> its passphrase ("" = public)
local sPub              -- active channel public key (hex) - shareable
local sSec              -- active channel secret key (hex) - script only, never shown
local sMyName           -- active channel display name
local sMyReleases       -- active feed: return-delimited "title TAB magnet", newest first
local sMyPost           -- the built feed value we publish (name + releases)
local sMineHashes       -- array: info-hash -> true for releases YOU posted this run
local sFollows          -- return-delimited list of public keys we follow
local sFollowFeeds      -- array: pubkey -> their raw feed value
local sFeedKey          -- array: feed-list line -> channel pubkey
local sFeedMag          -- array: feed-list line -> magnet
local sFeedTitle        -- array: feed-list line -> release title
local sXferHandle       -- array: transfers-list line -> torrent handle
-- Clipboard auto-detect (the newquickshare pattern): when the window opens or
-- refocuses and the clipboard holds a channel card / bare address, the Follow
-- box is pre-filled (never overwriting user input; one offer per value).
local sClipSuggested    -- the last clipboard text already offered (or dismissed)

local sFeedEnc          -- array: feed-list line -> "enc" if that release is encrypted
local sFeedOrigName     -- array: feed-list line -> original filename (encrypted release)
local sPendingKey       -- array: info-hash -> 32-byte file key, for a download to decrypt
local sPendingName      -- array: info-hash -> original filename, for a download to decrypt
local sXferName         -- array: info-hash -> real name to SHOW locally for an
                        --   encrypted transfer (the swarm only ever sees the .enc)
-- Fleet-audit fixes: DHT get/put refusals are logged ONCE per call site (a
-- refused request on the 60 s tick must not become a log flood), and a Follow
-- whose feed never arrives gets one spoken diagnosis after its window.
local sDhtErrHinted     -- array: call-site tag -> "true" once its refusal was logged
local sFeedWait         -- array: followed pubkey -> ms clock when Follow asked for it
local sFeedHinted       -- array: followed pubkey -> "true" once the no-feed hint ran

-- OnionXT (optional per-channel Tor anonymity, Model C - section 6 of
-- docs/ONIONXT-INTEGRATION-PLAN.md). When a channel's "anon" flag is set, its
-- signed feed AND every release travel over the channel's OWN Tor onion service,
-- never over DHT/BitTorrent (the mutual-exclusion invariant). The onion address
-- is derived from the channel's existing ed25519 pubkey (section 6.1), so a
-- follower reaches it from the channel card alone. All of this is inert unless
-- sHasOnion, and every anon action fails closed. The onion identity is the
-- channel's OWN key - no new key is minted.
local sHasOnion         -- "true" if OnionXT loads AND SodiumXT works (probed once at start)
local sTorReady         -- "true" if Tor is bootstrapped + ready (LIVE cache; re-checked at use)
local sOnionIdentityOk  -- "true" once the offline seed<->pubkey byte-compare passed (section 6.1)
local sOnionTriedTB     -- "true" once we retried the Tor Browser control port pair
local sFollowAnon       -- array: followed pubkey -> "true" if we follow it ANONYMOUSLY (over Tor)
local sFollowSvc        -- array: followed pubkey -> the svc= onion from its feed (fallback address)
-- publisher: one deterministic onion service per anon channel, keyed by pubkey hex
local sChanService      -- array: pubkey -> OnionXT service handle
local sChanServiceAddr  -- array: pubkey -> the channel's .onion address
local sChanServicePort  -- array: pubkey -> the ephemeral loopback port the service maps to
local sFeedStreams      -- array: pubkey -> return-delimited list of subscribed follower stream handles
-- publisher: the in-memory serve map (relId -> file), keyed "pub:relId". NOT
-- persisted (the demo prunes stranded onion releases on load; section 6.5).
local sOnionServe       -- array: "pub:relId" -> absolute path of the file to stream
local sOnionServeEnc    -- array: "pub:relId" -> kFlagEnc if that release is a SodiumXT .enc
local sOnionServeName   -- array: "pub:relId" -> the original filename (for the header)
local sOnionServeTotal  -- array: "pub:relId" -> total bytes to stream
-- follower: the live dial per anon channel we follow
local sFollowStream     -- array: followed pubkey -> the open feed-fetch stream (empty = reconnect)
-- per-stream state, keyed by the OnionXT stream handle (both serve + fetch sides)
local sOnRole           -- array: stream -> "serve-req"/"serve-feed"/"serve-file"/"follow-feed"/"download"
local sOnPub            -- array: stream -> the channel pubkey this stream serves or fetches
local sOnReq            -- array: stream -> accumulated inbound BTXC request bytes (serve side)
local sOnBuf            -- array: stream -> accumulated inbound BTXF/BTXO bytes (fetch side)
-- per send-stream state (re-open-per-read for fan-out; section 3.3 step 6b)
local sTxPath           -- array: stream -> path of the file we are streaming out
local sTxPos            -- array: stream -> next byte offset to read (0-based)
local sTxRemaining      -- array: stream -> bytes still to send
local sTxName           -- array: stream -> the release's display name (for the log)
local sTxDeadline       -- array: stream -> the milliseconds of the last send (idle watchdog)
-- per receive-stream state (section 3.3 receiver)
local sRxBuf            -- array: stream -> reassembly buffer (drained + compacted each call)
local sRxState          -- array: stream -> "header" / "body" / "done"
local sRxTmp            -- array: stream -> temp output path we are writing into
local sRxName           -- array: stream -> real (sanitized) filename to save as
local sRxEnc            -- array: stream -> nonzero if the payload is a SodiumXT .enc
local sRxTotal          -- array: stream -> total payload bytes expected
local sRxGot            -- array: stream -> payload bytes written so far
local sRxKey            -- array: stream -> 32-byte file key (encrypted receive), else empty
local sRxSave           -- array: stream -> save folder for this receive
local sRxDeadline       -- array: stream -> the milliseconds of the last data (idle watchdog)
-- the parallel in-script transfers model for onion rows (no torrent handle exists)
local sOnionXfer        -- array: stream -> {name, dir("up"/"down"), got, total, state}

-- The user-facing release version: shown in the OS title bar and the startup
-- log line, so a bug report always says which build it came from.
constant kChAppVersion = "1.0.0"

-- Bump this whenever the generated UI changes. chBuild rebuilds the controls when
-- the stack's stored version differs, so updating the script in a saved stack
-- picks up the new layout instead of keeping the old one.
constant kUiVersion = "channels-kit2-2"
-- prefs file header: an 8-byte magic, then a 1-byte mode ("P" plain / "E" sealed).
-- A SEALED file is [magic]["E"][salt 16][sxSecretBox], the same 16-byte-salt +
-- Argon2id convention SodiumXT's own file-encrypt demo uses.
constant kPrefMagic = "BTXPREF1"
-- seconds of followed-but-feedless silence before the one-time diagnosis line
-- (the fetch itself keeps retrying on the 60 s tick; nothing is aborted)
constant kChFeedHintSecs = 60

-- ---- adopter-owned colors ------------------------------------------------------
-- The chrome palette comes from the suite UI kit block below; only the
-- transfers-table ROW colors stay here, because the kit does not own row
-- colors. Aligned with the family set: err/posted/paused carry the kit's
-- bad/ok/muted values, downloaded is the accent blue the other demos use for
-- active rows. Literal RGB strings only (OXT constants must be literal and
-- declared before first use).
constant kChRowErr = "176,58,46"        -- errored transfer (kUiBad's value)
constant kChRowPaused = "138,146,158"   -- paused transfer (kUiMuted's value)
constant kChRowPosted = "23,128,63"     -- a file YOU posted (kUiOk's value)
constant kChRowDown = "43,108,196"      -- a file you downloaded (family accent)
constant kChRowOnion = "0,150,150"      -- an onion (Tor) transfer row (teal; section 6.8)

-- ---- OnionXT (optional Tor anonymity) constants ------------------------------
-- Model C: an anon channel's feed AND files ride an OnionXT onion stream (both
-- IPs hidden) and NO torrent / DHT put is ever made for them. Requires OnionXT +
-- SodiumXT + a LOCAL Tor daemon. Every ox* call is against OnionXT's published
-- ABI (onionxt/docs/05-api-reference.md); verified statically here, needs an
-- on-engine OXT pass with a running Tor daemon before any runtime claim. OXT
-- resolves constants by lexical position, so they are all declared here, once,
-- before first use. See docs/ONIONXT-INTEGRATION-PLAN.md sections 3 and 6.
constant kOnionMagic = "BTXO"          -- 4 ASCII bytes: file-stream frame sync
constant kOnionVer = 1                 -- file-stream protocol version
constant kOnionVPort = 80              -- the onion service's advertised virtual port
constant kOnionChunk = 65536           -- 64 KiB: max payload bytes in one data frame
constant kFlagEnc = 1                  -- header flags bit0: payload is a SodiumXT .enc
constant kOnionPumpTick = 15           -- ms between send-pump frames (never a tight loop)
constant kOnionSendTimeout = 30000     -- ms idle watchdog, sender
constant kOnionRecvTimeout = 60000     -- ms idle watchdog, receiver (Tor is slow)
constant kOnionPublishTimeout = 90000  -- ms to wait for the onion descriptor to upload
constant kOnionMaxName = 1024          -- reject a header nameLen beyond this (anti-DoS)
constant kOnionMaxTotal = 8589934592   -- 8 GiB payload ceiling; reject a larger header
constant kOnionFeedCap = 65536         -- reject a BTXF feed-value length beyond this (anti-DoS)
constant kAnonSizeWarn = 268435456     -- 256 MiB: warn (never block) above this on an anon publish
constant kTorSocksPort = "9050"        -- system/standalone tor
constant kTorControlPort = "9051"
constant kTorSocksPortTB = "9150"      -- Tor Browser
constant kTorControlPortTB = "9151"
-- The channels request layer (section 6.4), one level above the section-3.3
-- file framing. A follower sends a BTXC request; the publisher answers with a
-- BTXF feed frame (repeatable, for live push) and/or a BTXO file stream.
constant kChanReqMagic = "BTXC"        -- 4 ASCII bytes: channels request magic
constant kChanReqVer = 1
constant kFeedFrameMagic = "BTXF"      -- 4 ASCII bytes: feed-frame magic
constant kFeedFrameVer = 1
constant kVerbFeed = 1                 -- BTXC verb: fetch the signed feed
constant kVerbFile = 2                 -- BTXC verb: fetch a release's bytes

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
-- kUiVersion rebuild) never flashes an unstyled or mis-sized window; prefs
-- hydrate and the session starts in openStack once the window is up. chBuild is
-- ALSO called first in openStack (belt and suspenders): OXT sends openStack -
-- but NOT preOpenStack - when the stack SCRIPT is (re)compiled (the paste-into-
-- stack-script flow), so building only here would arm the loops (and run
-- chPrefLoad's UI updates) against a UI that was never built. chBuild is
-- idempotent, so preOpenStack builds it flash-free and openStack's call no-ops.
on preOpenStack
   chBuild
end preOpenStack

on openStack
   chBuild         -- no-op if preOpenStack already built it; the guaranteed build
                   -- on a stack-script recompile (openStack fires, preOpenStack does not)
   chPrefLoad      -- hydrate saved state (and unlock if sealed) BEFORE chStart reads it
   chStart
end openStack

on closeStack
   chStop
end closeStack

-- A standalone quits via shutdownRequest (Cmd-Q / Alt-F4 / Dock quit) WITHOUT
-- a guaranteed closeStack first - and chStop is where the DHT routing table
-- and prefs are saved and the session shuts down cleanly. chStop is idempotent,
-- so arriving here after closeStack already ran is a safe no-op.
on shutdownRequest
   chStop
   pass shutdownRequest
end shutdownRequest

on resumeStack
   -- the window came back to the front: a channel card may be on the clipboard
   chClipboardSuggest
   pass resumeStack
end resumeStack

on mouseUp
   switch the short name of the target
      case "chHelp"
         chHelp
         break
      case "chLock"
         chProtectIdentity
         break
      case "chCopyKey"
         chCopyKey
         break
      case "chMyKey"
         chCopyKey         -- the address box itself is click-to-copy
         break
      case "chPinCode"
         chPinCopy         -- the drop-code box is click-to-copy too
         break
      case "chNewChan"
         chNewChannel
         break
      case "chRename"
         chRenameChannel
         break
      case "chDelChan"
         chDeleteChannel
         break
      case "chPublish"
         chPublishFile
         break
      case "chPrivacy"
         chSetPrivacy
         break
      case "chAnon"
         chSetAnon
         break
      case "chFollow"
         chFollow
         break
      case "chRefresh"
         chRefreshAll
         break
      case "chDownload"
         chDownloadSelected
         break
      case "chCopyMag"
         chCopySelectedMagnet
         break
      case "chXfers"
         chShowFilesForSelection
         break
      case "chAddMagnet"
         chAddMagnetManual
         break
      case "chPauseXfer"
         chPauseSelected
         break
      case "chResumeXfer"
         chResumeSelected
         break
      case "chRemoveXfer"
         chRemoveSelected
         break
      case "chOpenFolder"
         chOpenSelectedFolder
         break
      case "chUnfollow"
         chUnfollow
         break
      case "chPin"
         chPin
         break
      case "chPinCopy"
         chPinCopy
         break
      case "chFetchBtn"
         chFetchCode
         break
      default
         pass mouseUp
   end switch
end mouseUp

on mouseDoubleUp
   switch the short name of the target
      case "chSubs"
         chDownloadSelected
         break
      case "chXfers"
         chOpenSelectedFolder
         break
      default
         pass mouseDoubleUp
   end switch
end mouseDoubleUp

-- the channel picker is an option menu; switching it activates that channel
on menuPick pItem
   if the short name of the target is "chChannelMenu" then
      chActivate (the menuHistory of button "chChannelMenu")
   else
      pass menuPick
   end if
end menuPick

-- Return/Enter in the single-line inputs ACTS instead of inserting a newline
-- (paste -> Enter, done - the newquickshare pattern).
on returnInField
   switch the short name of the target
      case "chFollowKey"
         chFollow
         break
      case "chMagnetField"
         chAddMagnetManual
         break
      case "chFetchCode"
         chFetchCode
         break
      case "chPinText"
         chPin
         break
      default
         pass returnInField
   end switch
end returnInField

on enterInField
   switch the short name of the target
      case "chFollowKey"
         chFollow
         break
      case "chMagnetField"
         chAddMagnetManual
         break
      case "chFetchCode"
         chFetchCode
         break
      case "chPinText"
         chPin
         break
      default
         pass enterInField
   end switch
end enterInField

-- ---- self-building UI (idempotent) -------------------------------------------
command chBuild
   -- Rebuild when the UI version changes (not just "is it built?"). Otherwise a
   -- stack saved by an OLDER version keeps its old controls - including buttons
   -- this script no longer handles (e.g. the old chNewId/chSetName) - and never
   -- gets the new ones. The second condition catches a stack whose property
   -- says current but whose controls were deleted (the guard the sibling demos
   -- already carried; version-only was this stack's audit finding).
   if the uUiVersion of this stack is kUiVersion and there is a field "chLog" then
      exit chBuild
   end if
   chClearGeneratedUI
   lock screen
   -- two columns so the whole app fits a 720p (1280x720) screen; the chrome is
   -- the suite UI kit (band + cards + hairline dividers)
   uiChrome "Decentralized Channels - share files with no server", 1180, 640
   -- the OS title bar carries the release version (bug reports name the build)
   set the title of this stack to ("TorrentXT - Decentralized Channels " & kChAppVersion)
   -- fixed-size dashboard: the layout is hand-placed, a free resize would tear it
   set the resizable of this stack to false
   -- the kit's status line: this packed two-column layout has no free strip
   -- under the band (the cards start at y 34), so the one status line lives
   -- where the transfers totals line always did, inside the transfers card -
   -- geometry is the caller's (kit rule 1); the semantics (uiStatus, semantic
   -- colors) stay the kit's
   set the rect of field "uiStatus" to "596,300,1164,318"
   uiButton "chHelp", "?  What is this?", "1000,4,1164,28"
   -- lock/unlock the saved identity with a passphrase (label tracks state)
   uiButton "chLock", "Lock Identity...", "820,4,994,28"
   -- the three cards, created BEFORE the controls that sit on them (z-order):
   -- left = your channels + follows; right = transfers; bottom = drop + log
   uiPanel "chCardLeft", "8,34,586,486"
   uiPanel "chCardRight", "588,34,1172,486"
   uiPanel "chCardBottom", "8,490,1172,638"
   -- ===== LEFT COLUMN (x 16..580): your channel + channels you follow =====
   uiSection "chSecMine", "1.  Your channels - publish files under a channel of your own", "16,38,580,58"
   -- channel picker: switch the active channel, or make / delete one
   uiWrap "chPickCap", "Active channel:", "16,63,116,81", 10
   set the foregroundColor of field "chPickCap" to kUiInkSoft
   uiButton "chChannelMenu", "", "118,62,346,84"
   set the style of button "chChannelMenu" to "menu"
   set the menuMode of button "chChannelMenu" to "option"
   uiButton "chNewChan", "New Channel", "352,62,452,84"
   uiButton "chDelChan", "Delete", "458,62,552,84"
   uiWrap "chMyKeyLabel", "This channel's address - Copy it so people can follow THIS channel and get its files:", "16,88,580,104", 10
   set the foregroundColor of field "chMyKeyLabel" to kUiInkSoft
   uiInput "chMyKey", "16,106,360,130"
   set the lockText of field "chMyKey" to true
   set the traversalOn of field "chMyKey" to false
   uiButton "chCopyKey", "Copy", "368,106,452,130"
   uiButton "chRename", "Rename", "458,106,552,130"
   uiButton "chPublish", "Publish a File...", "16,136,178,158"
   uiButton "chPrivacy", "Privacy...", "184,136,286,158"
   -- the per-channel anonymity control, beside Privacy (they compose - section 6.6).
   -- Built in the adopter's own builder section, NOT the ui-kit block.
   uiButton "chAnon", "Anonymous...", "292,136,396,158"
   uiWrap "chNowPub", "Not publishing yet.", "402,140,580,158", 9
   set the foregroundColor of field "chNowPub" to kUiInkSoft
   uiSection "chSecSubs", "2.  Channels you follow - download what they share", "16,168,580,188"
   uiInput "chFollowKey", "16,192,400,216"
   uiButton "chFollow", "Follow", "408,192,492,216"
   uiButton "chRefresh", "Refresh", "498,192,580,216"
   uiWrap "chFeedCaption", "Files shared by channels you follow. Each row is signed by its channel, so it cannot be faked. Pick one and Download:", "16,220,580,244", 9
   set the foregroundColor of field "chFeedCaption" to kUiMuted
   uiWrap "chSubsHeader", "Channel" & tab & "Release" & tab & "Signed by", "16,248,580,266", 10
   uiTable "chSubs", "16,268,580,452", "150,430"
   uiButton "chDownload", "Download", "16,458,180,482"
   uiButton "chCopyMag", "Copy Magnet", "188,458,300,482"
   uiButton "chUnfollow", "Unfollow", "308,458,448,482"
   set the tabStops of field "chSubsHeader" to "150,430"
   set the textFont of field "chSubsHeader" to uiMonoFont()
   set the foregroundColor of field "chSubsHeader" to kUiMuted
   -- a light selection colour so the dark/coloured row text stays readable
   set the hiliteColor of field "chSubs" to "208,226,245"
   -- ===== RIGHT COLUMN (x 596..1164): transfers + selected-transfer detail =====
   uiSection "chSecXfer", "3.  Transfers - green = files you POSTED, blue = files you DOWNLOADED", "596,38,1164,58"
   uiWrap "chXferHeader", "Source" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Peers", "596,62,1164,80", 10
   -- Source | Name | State | Progress | Peers (Peers kept clear of the scrollbar)
   uiTable "chXfers", "596,82,1164,238", "84,236,338,460"
   set the tabStops of field "chXferHeader" to "84,236,338,460"
   -- a light selection colour so the colour-coded row text stays readable
   set the hiliteColor of field "chXfers" to "208,226,245"
   set the textFont of field "chXferHeader" to uiMonoFont()
   set the foregroundColor of field "chXferHeader" to kUiMuted
   -- add any magnet link or info-hash directly, not only channel releases
   uiInput "chMagnetField", "596,244,948,266"
   uiButton "chAddMagnet", "Add Magnet", "954,244,1080,266"
   -- act on the selected transfer (click a row first)
   uiButton "chPauseXfer", "Pause", "596,272,690,294"
   uiButton "chResumeXfer", "Resume", "696,272,790,294"
   uiButton "chRemoveXfer", "Remove", "796,272,902,294"
   uiButton "chOpenFolder", "Open Folder", "908,272,1054,294"
   -- (the totals line that sat at 596,300 is now the kit's uiStatus, above)
   -- 3b. Contents of the selected transfer (live per-file progress via btFileList)
   uiWrap "chFilesCaption", "Click a transfer above to see the files inside it (double-click opens its folder).", "596,324,1164,340", 9
   set the foregroundColor of field "chFilesCaption" to kUiMuted
   uiWrap "chFilesHeader", "File" & tab & "Size" & tab & "Progress", "596,344,1164,362", 10
   uiArea "chFiles", "596,364,1164,470"
   set the tabStops of field "chFilesHeader" to "340,440"
   set the tabStops of field "chFiles" to "340,440"
   set the textFont of field "chFilesHeader" to uiMonoFont()
   set the foregroundColor of field "chFilesHeader" to kUiMuted
   set the text of field "chFiles" to "Click a transfer above to see its files and per-file progress."
   -- ===== FULL-WIDTH BOTTOM: quick drop + log =====
   uiSection "chSecDrop", "4.  Quick drop - paste text, get a code anyone can fetch back", "16,488,1164,508"
   uiInput "chPinText", "16,512,440,534"
   uiButton "chPin", "Pin", "448,512,530,534"
   uiInput "chPinCode", "538,512,810,534"
   set the lockText of field "chPinCode" to true
   set the traversalOn of field "chPinCode" to false
   uiButton "chPinCopy", "Copy", "818,512,910,534"
   uiInput "chFetchCode", "16,538,440,560"
   uiButton "chFetchBtn", "Fetch", "448,538,530,560"
   uiInput "chDropResult", "538,538,910,560"
   set the lockText of field "chDropResult" to true
   set the traversalOn of field "chDropResult" to false
   -- the honesty footer, in the bottom card's free right corner (the only
   -- clear space this packed layout has)
   uiFooter \
         "Decentralized-channels demo over TorrentXT. Torrent + BEP44 surface" \
         & " engine-proven; this kit-unified UI needs an OXT re-pass.", \
         "920,512,1164,560"
   uiArea "chLog", "16,564,1164,632"
   -- the read-only output boxes (address, drop-code, drop-result) get the quiet
   -- code-box fill so they read as "copyable output", not editable input
   set the backgroundColor of field "chMyKey" to kUiCodeBg
   set the borderColor of field "chMyKey" to kUiCodeLine
   set the backgroundColor of field "chPinCode" to kUiCodeBg
   set the borderColor of field "chPinCode" to kUiCodeLine
   set the backgroundColor of field "chDropResult" to kUiCodeBg
   set the borderColor of field "chDropResult" to kUiCodeLine
   set the dontWrap of field "chMyKey" to true
   set the dontWrap of field "chPinCode" to true
   set the textSize of field "chMyKey" to 9
   set the textSize of field "chFollowKey" to 9
   set the textSize of field "chMagnetField" to 9
   -- the live Tor status pill sits in the title band (left of the Lock button)
   -- and is created + repainted ONLY by chOnionPill (via the kit's uiPill), so
   -- its states can never disagree. Built here so chAddTips can set its tooltip.
   chOnionPill
   chAddTips
   set the uUiVersion of this stack to kUiVersion
   unlock screen
end chBuild

-- Remove the controls THIS script generates (all named with the "ch" prefix), so
-- chBuild can rebuild a clean current UI over a stack an older version built.
-- Iterates top-down so deleting by index never shifts an index we have yet to
-- visit; only ch-prefixed controls are touched, so anything else is left alone.
command chClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of controls of this card down to 1
      if the short name of control tI of this card begins with "ch" then
         delete control tI of this card
      end if
   end repeat
   unlock screen
end chClearGeneratedUI

-- The label/section/field/button/list/graphic/panel builders (and the mono-font
-- + copy-flash helpers) that used to live here collapsed onto the suite UI kit
-- above (uiWrap/uiSection/uiInput/uiButton/uiTable/uiArea/uiGfx/uiPanel/
-- uiMonoFont/uiCopyFlash); only genuinely channels-local helpers survive.

-- a hover hint on every control, so the app explains itself
command chAddTips
   set the tooltip of button "chHelp" to "What is this app? A plain-language overview."
   set the tooltip of button "chChannelMenu" to "Switch which of your channels is active (what you publish to)."
   set the tooltip of button "chNewChan" to "Create a new channel of your own. Your existing channels keep running."
   set the tooltip of button "chDelChan" to "Delete the active channel. Its followers stop seeing it once it expires."
   set the tooltip of field "chMyKey" to "The active channel's address. Share it (Copy) so people can follow THIS channel."
   set the tooltip of button "chCopyKey" to "Copy this channel's card (its name + address) to the clipboard."
   set the tooltip of button "chRename" to "Give the active channel a friendly display name its followers will see."
   set the tooltip of button "chPublish" to "Pick a folder. It is packaged, seeded, and added to the active channel's feed."
   set the tooltip of button "chPrivacy" to "Set a passphrase to encrypt this channel's feed AND the files you publish to it."
   set the tooltip of button "chAnon" to "Make this whole channel anonymous: its feed AND files travel over Tor (both IPs hidden, no DHT/magnet), reachable from the channel card alone. Needs OnionXT + SodiumXT + a local Tor daemon. Compose it with Privacy for encrypted contents too."
   set the tooltip of field "chTor" to "Status of your local Tor connection. 'ready' means anonymous channels can publish and be reached."
   set the tooltip of field "chFollowKey" to "Paste someone's channel card or 64-character address, then click Follow."
   set the tooltip of button "chFollow" to "Subscribe to that channel and fetch its signed list of files."
   set the tooltip of button "chRefresh" to "Re-fetch the latest files from every channel you follow."
   set the tooltip of button "chDownload" to "Download the selected file - it transfers peer-to-peer from the publisher."
   set the tooltip of button "chCopyMag" to "Copy the selected file's magnet link to the clipboard."
   set the tooltip of button "chUnfollow" to "Stop following the selected file's channel."
   set the tooltip of field "chXfers" to "Click a transfer to see its files below; double-click to open its folder."
   set the tooltip of field "chMagnetField" to "Paste any magnet link or info-hash to download it directly."
   set the tooltip of button "chAddMagnet" to "Add the pasted magnet/info-hash and start downloading it."
   set the tooltip of button "chPauseXfer" to "Pause the selected transfer (stops its upload + download)."
   set the tooltip of button "chResumeXfer" to "Resume the selected paused transfer."
   set the tooltip of button "chRemoveXfer" to "Remove the selected transfer; you choose whether to delete its files."
   set the tooltip of button "chOpenFolder" to "Open the selected transfer's download folder in your file manager."
   set the tooltip of field "chFiles" to "Files inside the selected transfer, with live per-file progress."
   set the tooltip of field "chPinText" to "Type any short text (up to 1000 bytes) to pin to the network."
   set the tooltip of button "chPin" to "Store the text on the DHT and get back a short share code."
   set the tooltip of button "chPinCopy" to "Copy the share code to the clipboard."
   set the tooltip of field "chFetchCode" to "Paste a 40-character drop code to fetch its text back."
   set the tooltip of button "chFetchBtn" to "Look up the text for that drop code."
end chAddTips

-- a plain-language overview, shown by the title-bar "What is this?" button
command chHelp
   local tMsg
   put "DECENTRALIZED CHANNELS - what this is" & return & return into tMsg
   put tMsg & "A tiny file-sharing app with NO central server. Two proven technologies do the work:" & return into tMsg
   put tMsg & "  - the DHT, a giant shared address book, remembers WHERE things are;" & return into tMsg
   put tMsg & "  - BitTorrent moves the actual files directly between computers." & return & return into tMsg
   put tMsg & "1) YOUR CHANNELS - each is a personal feed. Publish a file and it is shared under that" & return into tMsg
   put tMsg & "   channel's own cryptographic key, so nobody else can post to it or forge it. You can" & return into tMsg
   put tMsg & "   keep several channels (New Channel / Rename / Delete) and switch between them." & return & return into tMsg
   put tMsg & "   PRIVACY: by default a channel is PUBLIC - anyone with its address reads the file list" & return into tMsg
   put tMsg & "   and anyone with a magnet downloads the file. Click Privacy to set a passphrase, and that" & return into tMsg
   put tMsg & "   channel encrypts BOTH its feed AND the files you publish (the file is encrypted before" & return into tMsg
   put tMsg & "   it is shared; downloads decrypt automatically). Share the passphrase out-of-band, never" & return into tMsg
   put tMsg & "   on the DHT. It still does not hide your IP, and private publishing is one file at a time." & return & return into tMsg
   put tMsg & "   ANONYMOUS (Tor): click Anonymous to make a whole channel travel over Tor - its file" & return into tMsg
   put tMsg & "   list AND every file ride the channel's own onion service, both IPs hidden, nothing on" & return into tMsg
   put tMsg & "   the DHT or a magnet, reachable from the channel card alone. Needs OnionXT + SodiumXT +" & return into tMsg
   put tMsg & "   a local Tor daemon. The onion is bound to the channel key, so the address and the" & return into tMsg
   put tMsg & "   channel identity are linkable by design (use a separate channel for an unlinkable one)." & return into tMsg
   put tMsg & "   Tor is slow for large media, and PLAINTEXT anon hides the route but does NOT" & return into tMsg
   put tMsg & "   authenticate the sender - add Privacy (a passphrase) for encrypted, authenticated" & return into tMsg
   put tMsg & "   contents. The publisher must stay online for followers to reach it." & return & return into tMsg
   put tMsg & "2) CHANNELS YOU FOLLOW - paste someone's channel card to see their latest files. Pick" & return into tMsg
   put tMsg & "   one and Download; it transfers from them while they are online. Every entry is signed," & return into tMsg
   put tMsg & "   so it is tamper-proof. For a PRIVATE channel, Follow asks for its passphrase." & return & return into tMsg
   put tMsg & "3) TRANSFERS - a live view of what you are sending and receiving. GREEN rows are files" & return into tMsg
   put tMsg & "   you POSTED; BLUE rows are files you DOWNLOADED. Click one to see the files inside it" & return into tMsg
   put tMsg & "   (double-click opens its folder), and use Pause, Resume, Remove, or Open Folder. You" & return into tMsg
   put tMsg & "   can also paste any magnet link to download it directly." & return & return into tMsg
   put tMsg & "4) QUICK DROP - paste any text, get a short code; anyone with the code gets it back." & return & return into tMsg
   put tMsg & "TRY IT on two machines: Copy your card on one, Follow it on the other, then share a file." into tMsg
   answer tMsg with "Got it"
end chHelp

-- ---- session, identity, subscriptions, loops ---------------------------------
command chStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      chLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      uiStatus "No session (another TorrentXT stack open?) - see the log.", "bad"
      put 0 into sSession
      exit chStart
   end if
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   -- reload the saved DHT routing table (if any) for a faster bootstrap
   if the uDhtState of this stack is not empty then
      btDhtLoadState sSession, the uDhtState of this stack
   end if
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   -- can this build encrypt? gates the optional private-channel feature
   put chCanEncrypt() into sCanEncrypt
   -- probe OnionXT (needs SodiumXT) and run the OFFLINE seed<->pubkey byte-compare
   -- (section 6.1) BEFORE reading channels: a mismatch disables anon entirely, so
   -- a channel's derived .onion can never be wrong. Both are one-shot at start.
   put chHasOnion() into sHasOnion
   if sHasOnion then
      put chVerifyOnionIdentity() into sOnionIdentityOk
      if not sOnionIdentityOk then
         chLog "Anonymous channels are DISABLED: the libtorrent/libsodium ed25519 identities did not byte-match offline (or this SodiumXT is older than ABI 7). Public channels are unaffected."
      end if
   else
      put false into sOnionIdentityOk
   end if
   put empty into sFollowAnon
   put empty into sFollowSvc
   chEnsureIdentity
   chLoadFollows
   chPruneStrandedAnon     -- an in-memory serve map is empty after a restart (section 6.5)
   chUpdateNowPub
   chUpdateLockButton      -- reflect whether the saved identity is passphrase-locked
   if not sCanEncrypt then
      chLog "Note: SodiumXT (org.openxtalk.library.sodium) is not installed, so private channels are unavailable. Install it to use passphrases."
   end if
   -- bring up the Tor control link (non-blocking). The anon path is completely
   -- inert when OnionXT/SodiumXT/Tor are absent; nothing else changes.
   if sHasOnion then
      chOnionStart
   else
      chOnionPill
   end if
   chLog "Decentralized Channels " & kChAppVersion & " ready. DHT bootstrapping - give it a few seconds of peers before publishing or following."
   put "true" into sPolling
   -- a channel card may already be on the clipboard (copied from a chat)
   chClipboardSuggest
   send "chPollOnce" to me in 0 milliseconds
   send "chDashOnce" to me in 800 milliseconds
   send "chChannelTick" to me in 5000 milliseconds
end chStart

-- ---- clipboard auto-detect (the copy -> open -> Follow flow) -----------------
-- Does this text LOOK like something the Follow box accepts? A "Name | key"
-- channel card, or a bare 64-hex ed25519 public key.
function chLooksLikeCard pText
   local tKey, tI, tSavedID
   put pText into tKey
   if pText contains "|" then
      put the itemDelimiter into tSavedID
      set the itemDelimiter to "|"
      -- the key is ALWAYS item 2 ("Name | key" or "Name | key | anon"); names
      -- never contain "|" (chRenameChannel strips it), so item 2 is unambiguous
      put chTrim(item 2 of pText) into tKey
      set the itemDelimiter to tSavedID
   end if
   if the number of chars of tKey is not 64 then
      return false
   end if
   put toLower(tKey) into tKey
   repeat with tI = 1 to 64
      if char tI of tKey is not in "0123456789abcdef" then
         return false
      end if
   end repeat
   return true
end chLooksLikeCard

-- If the clipboard holds a channel card / bare key and the Follow box is empty,
-- pre-fill it so following collapses to copy -> open -> Follow. Runs at start
-- and on resumeStack. Polite: never overwrites user input, offers each value
-- once, and skips a card for a channel WE own (following yourself is nonsense).
-- The clipboard read is try-guarded (it can fail transiently on Windows).
command chClipboardSuggest
   local tClip, tErr, tI
   if there is no field "chFollowKey" then
      exit chClipboardSuggest
   end if
   put "" into tClip
   try
      put chTrim(the clipboardData["text"]) into tClip
   catch tErr
      exit chClipboardSuggest
   end try
   if tClip is empty or tClip is sClipSuggested then
      exit chClipboardSuggest
   end if
   put tClip into sClipSuggested   -- one offer per value, even if declined
   if not chLooksLikeCard(tClip) then
      exit chClipboardSuggest
   end if
   -- skip the ACTIVE channel's own card (following yourself is nonsense); a
   -- non-active own channel is harmless if it slips through (just your own feed)
   if sPub is not empty and tClip contains sPub then
      exit chClipboardSuggest
   end if
   if chTrim(field "chFollowKey") is not empty then
      exit chClipboardSuggest
   end if
   put tClip into field "chFollowKey"
   chLog "Found a channel address on your clipboard - check it, then click Follow."
end chClipboardSuggest

-- Load every channel you own (or migrate an old single-channel save / make a
-- first one), then activate one. Channels persist in the stack property
-- uChannels (an arrayEncoded array of {seed, name, releases}); uActiveChannel
-- remembers which was active.
command chEnsureIdentity
   local tEnc, tKey, tErr
   put empty into sChannels
   put the uChannels of this stack into tEnc
   if tEnc is not empty then
      -- a corrupt save must not wedge startup; fall through to a fresh channel
      try
         put arrayDecode(tEnc) into sChannels
      catch tErr
         put empty into sChannels
      end try
   end if
   if sChannels is not an array or chChannelCount() is 0 then
      put empty into sChannels
      if the uDhtSeed of this stack is not empty then
         -- migrate the previous single-channel identity into channel 1
         put the uDhtSeed of this stack into sChannels[1]["seed"]
         put the uChannelName of this stack into sChannels[1]["name"]
         put "" into sChannels[1]["releases"]
         put "" into sChannels[1]["anon"]
      else
         put btDhtKeypair("") into tKey
         put tKey["seed"] into sChannels[1]["seed"]
         put "" into sChannels[1]["name"]
         put "" into sChannels[1]["releases"]
         put "" into sChannels[1]["anon"]
      end if
   end if
   put (the uActiveChannel of this stack) into sActive
   if sActive is empty or sActive is not a number or sActive < 1 or sActive > chChannelCount() then
      put 1 into sActive
   end if
   chSaveChannels
   chActivate sActive
end chEnsureIdentity

-- how many channels you own
function chChannelCount
   if sChannels is not an array then
      return 0
   end if
   return the number of lines of the keys of sChannels
end chChannelCount

-- Make a channel the active one: derive its keys from its seed and fill the
-- sMy* cache the rest of the app reads, then refresh the picker + status.
command chActivate pIndex
   local tKey
   put pIndex into sActive
   put btDhtKeypair(sChannels[sActive]["seed"]) into tKey
   put tKey["publicKey"] into sPub
   put tKey["secretKey"] into sSec
   put sChannels[sActive]["name"] into sMyName
   put sChannels[sActive]["releases"] into sMyReleases
   put chBuildFeed(sMyName, sMyReleases) into sMyPost
   set the uActiveChannel of this stack to sActive
   set the text of field "chMyKey" to sPub
   chUpdateChannelMenu
   chUpdateNowPub
   -- if the active channel is anonymous, bring its onion service up (a no-op when
   -- Tor is not ready yet - chOnionBringUpServices retries after bootstrap)
   if chIsAnonChannel(sActive) then
      chOnionServiceFor sActive
   end if
end chActivate

-- repopulate the option menu with the channel names, active one selected
command chUpdateChannelMenu
   local tItems, tI, tName
   if there is no button "chChannelMenu" then
      exit chUpdateChannelMenu
   end if
   put "" into tItems
   repeat with tI = 1 to chChannelCount()
      put sChannels[tI]["name"] into tName
      if tName is empty then
         put ("(unnamed channel " & tI & ")") into tName
      end if
      if sChannels[tI]["pass"] is not empty then
         put tName && "(private)" into tName
      end if
      if sChannels[tI]["anon"] is "true" then
         put tName && "(anon)" into tName
      end if
      put tName & return after tItems
   end repeat
   if the last char of tItems is return then
      delete the last char of tItems
   end if
   -- a menu button's items live in its `text` (return-delimited); there is no
   -- `menuItems` property in xTalk. menuHistory then selects the active one.
   set the text of button "chChannelMenu" to tItems
   set the menuHistory of button "chChannelMenu" to sActive
end chUpdateChannelMenu

command chSaveChannels
   set the uChannels of this stack to arrayEncode(sChannels)
   set the uActiveChannel of this stack to sActive
   chPrefSave      -- mirror to the external prefs file (survives a standalone restart)
end chSaveChannels

-- create a brand-new channel (your other channels keep running) and switch to it
command chNewChannel
   local tKey, tN
   put btDhtKeypair("") into tKey
   put (chChannelCount() + 1) into tN
   put tKey["seed"] into sChannels[tN]["seed"]
   put ("Channel " & tN) into sChannels[tN]["name"]
   put "" into sChannels[tN]["releases"]
   put "" into sChannels[tN]["anon"]
   chSaveChannels
   chActivate tN
   chLog "Created a new channel. Rename it, then Publish a file to it - your other channels stay live."
end chNewChannel

-- rename the active channel (and re-announce so followers see the new name)
command chRenameChannel
   local tName
   ask "Name this channel (shown to its followers):" with sMyName
   put it into tName
   if tName is empty then
      exit chRenameChannel
   end if
   replace return with space in tName
   replace tab with space in tName
   replace "|" with "/" in tName   -- "|" is the channel-card delimiter
   put tName into sMyName
   put tName into sChannels[sActive]["name"]
   chSaveChannels
   get chPublishActiveFeed()   -- re-announce so followers see the new name
   chUpdateChannelMenu
   chUpdateNowPub
   chLog "Renamed this channel to '" & sMyName & "'."
end chRenameChannel

-- Make the active channel private (set a passphrase) or public again (clear it).
-- A private channel encrypts BOTH its feed AND every file published to it: the
-- file list is hidden, and each file is encrypted before sharing so a leaked
-- magnet is useless. Share the passphrase with followers out-of-band (never on
-- the DHT). It does not hide your IP, private publishing is one file at a time,
-- and the passphrase KDF is the engine's - use a long, random one.
command chSetPrivacy
   local tPass, tName, tR
   if not sCanEncrypt then
      answer "Private channels need SodiumXT (the org.openxtalk.library.sodium extension), which is not installed on this machine. Install it to use passphrases."
      exit chSetPrivacy
   end if
   ask "Passphrase for this channel (leave blank to make it PUBLIC)." & return & \
      "PRIVACY NOTE: a private channel encrypts its file list AND every file you publish to it. Share the passphrase out-of-band, never on the DHT. It does not hide your IP, and private publishing is one file at a time. Use a long, random passphrase." \
      with sChannels[sActive]["pass"]
   if it is empty and the result is "Cancel" then
      exit chSetPrivacy
   end if
   put it into tPass
   put tPass into sChannels[sActive]["pass"]
   chSaveChannels
   put chPublishActiveFeed() into tR   -- re-announce under the new privacy setting
   chUpdateChannelMenu
   chUpdateNowPub
   put sMyName into tName
   if tName is empty then
      put "(unnamed - click Rename)" into tName
   end if
   if tPass is empty then
      chLog "Channel '" & tName & "' is now PUBLIC."
   else if tR is 0 then
      -- the put was issued; the 'Announced to N node(s)' line confirms it landed
      chLog "Channel '" & tName & "' is now PRIVATE - its encrypted feed was just published, and files you Publish to it from now on are encrypted before sharing. Give followers the passphrase out-of-band."
   else
      chLog "Channel '" & tName & "' is set PRIVATE but its encrypted feed could not be published right now - it will retry on the next 60-second tick."
   end if
end chSetPrivacy

-- delete the active channel (you must always keep at least one)
command chDeleteChannel
   local tCount, tNew, tIdx, tI
   put chChannelCount() into tCount
   if tCount <= 1 then
      chLog "This is your only channel - make another before deleting this one."
      exit chDeleteChannel
   end if
   answer ("Delete the channel '" & sMyName & "'?") & return & \
      "Its followers stop seeing it once it expires from the DHT. Files you seeded stay until you Remove them in Transfers." \
      with "Cancel" or "Delete"
   if it is not "Delete" then
      exit chDeleteChannel
   end if
   -- if the deleted channel is anonymous, tear its onion service down first
   -- (section 6.3): stop serving it and drop its subscribers
   if chIsAnonChannel(sActive) then
      chOnionWithdrawService sPub
   end if
   -- rebuild the array without the active channel, keeping 1..N contiguous
   put empty into tNew
   put 0 into tIdx
   repeat with tI = 1 to tCount
      if tI is not sActive then
         add 1 to tIdx
         put sChannels[tI]["seed"] into tNew[tIdx]["seed"]
         put sChannels[tI]["name"] into tNew[tIdx]["name"]
         put sChannels[tI]["releases"] into tNew[tIdx]["releases"]
         put sChannels[tI]["pass"] into tNew[tIdx]["pass"]
         -- REQUIRED (section 6.2): copy anon too, else deleting any channel
         -- silently clears the anon flag of every survivor
         put sChannels[tI]["anon"] into tNew[tIdx]["anon"]
      end if
   end repeat
   put tNew into sChannels
   put 1 into sActive
   chSaveChannels
   chActivate 1
   chLog "Channel deleted. It fades from the DHT on its own once we stop re-announcing it."
end chDeleteChannel

command chLoadFollows
   local tKey, tEnc, tErr
   put the uFollows of this stack into sFollows
   put empty into sFollowFeeds
   -- restore the per-channel passphrases for private channels we follow
   put empty into sFollowPass
   put the uFollowPass of this stack into tEnc
   if tEnc is not empty then
      try
         put arrayDecode(tEnc) into sFollowPass
      catch tErr
         put empty into sFollowPass
      end try
   end if
   -- restore which follows are ANONYMOUS (over Tor). Backward-compat (section
   -- 6.2 #17): an old saved stack has no uFollowAnon, so this defaults empty.
   put empty into sFollowAnon
   put the uFollowAnon of this stack into tEnc
   if tEnc is not empty then
      try
         put arrayDecode(tEnc) into sFollowAnon
      catch tErr
         put empty into sFollowAnon
      end try
   end if
   chRefreshSubs
   repeat for each line tKey in sFollows
      if tKey is not empty then
         -- an anon follow is fetched over the onion, NEVER via btDhtGetMutable
         -- (which would leak our follow interest + real IP; section 6.7 guard 4)
         if sFollowAnon[tKey] is "true" then
            chOnionFollowFetch tKey
         else
            chDhtGetChecked tKey, "load"
         end if
      end if
   end repeat
end chLoadFollows

-- One guarded feed fetch, shared by every btDhtGetMutable site (fleet-audit
-- fix: all four were fire-and-forget, so a refused request - session gone,
-- malformed key - looked exactly like a slow DHT). A refusal is logged ONCE
-- per call site (pSite tags it): the load/tick sites re-run forever and a
-- flood would bury the log, while the once-line still names the first
-- failure with btLastError(). A queued request returns 0 and stays silent.
command chDhtGetChecked pKey, pSite
   local tR
   btDhtGetMutable sSession, pKey, ""
   put the result into tR
   if tR is not empty and tR < 0 and sDhtErrHinted[pSite] is not "true" then
      put "true" into sDhtErrHinted[pSite]
      chLog "* DHT feed fetch refused (site" && pSite & "," && tR & "):" && btLastError() && "- further refusals at this site stay quiet."
   end if
end chDhtGetChecked

command chStop
   local tErr
   put "false" into sPolling
   -- tear the onion subsystem down BEFORE btStopSession (all idempotent): close
   -- every stream, remove every service, disconnect control, sweep receive temps.
   chOnionStop
   -- try-guarded (fleet-audit fix): shutdownRequest can run this while the
   -- engine is already tearing extensions down, and a throw here would abort
   -- the quit path - losing the prefs flush below. The teardown and the
   -- prefs save are guarded separately so a failed save-state still lets the
   -- prefs (pure script + file IO) be written.
   try
      if sSession is not empty and sSession is not 0 then
         -- persist the DHT routing table so next launch bootstraps faster
         set the uDhtState of this stack to btDhtSaveState(sSession)
         btStopSession sSession
      end if
   catch tErr
   end try
   try
      chPrefSave      -- final flush to the external prefs file on close
   catch tErr
   end try
   put empty into sSession
end chStop

-- ---- persistence: keep state in an EXTERNAL file -----------------------------
-- A standalone app cannot save its own mainstack, so the stack custom properties
-- (channels, follows, passphrases, DHT cache) would reset every launch. We mirror
-- them to one file in a per-user folder: hydrated into the properties on open,
-- written on every change and on close. Optionally SEALED with SodiumXT, so the
-- ed25519 secret keys + passphrases are not left on disk in the clear. The sealed
-- layout ([magic]["E"][16-byte salt][secretbox]) matches SodiumXT's file-encrypt
-- demo: a random 16-byte salt + Argon2id (sxPwHash "2" / Interactive).

-- a writable per-user path for the prefs file (creates the folder if needed)
function chPrefFile
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
   return tBase & "/channels.prefs"
end chPrefFile

-- Load saved state into the stack properties the app reads. A SEALED file prompts
-- to unlock (up to 3 tries); a wrong passphrase or cancel sets sPrefLockedOut so
-- chPrefSave can never overwrite an identity we did not open. Talks to the user
-- only through modal dialogs, since it can run before the log field is ready.
command chPrefLoad
   local tPath, tRaw, tHeader, tSalt, tSealed, tBody, tA, tErr, tTries, tPass, tOk
   put empty into sVaultPass
   put empty into sPrefLockedOut
   put chPrefFile() into tPath
   if there is no file tPath then
      exit chPrefLoad
   end if
   put url ("binfile:" & tPath) into tRaw
   if (the number of bytes in tRaw) < 9 then
      exit chPrefLoad
   end if
   put textDecode(byte 1 to 9 of tRaw, "ASCII") into tHeader
   if tHeader is (kPrefMagic & "P") then
      put byte 10 to -1 of tRaw into tBody
   else if tHeader is (kPrefMagic & "E") then
      if not sCanEncrypt then
         answer "Your saved channels are passphrase-locked, but SodiumXT (org.openxtalk.library.sodium) is not installed, so they cannot be unlocked here."
         put "true" into sPrefLockedOut
         exit chPrefLoad
      end if
      if (the number of bytes in tRaw) < 26 then
         exit chPrefLoad
      end if
      put byte 10 to 25 of tRaw into tSalt
      put byte 26 to -1 of tRaw into tSealed
      put 0 into tTries
      repeat
         add 1 to tTries
         ask password "Enter your passphrase to unlock your channel identity:"
         if it is empty then
            put "true" into sPrefLockedOut   -- cancelled: keep the file, no identity
            exit chPrefLoad
         end if
         put it into tPass
         put 0 into tOk
         try
            put sxSecretBoxOpen(tSealed, sxPwHash(textEncode(tPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive())) into tBody
            put 1 into tOk
         catch tErr
         end try
         if tOk is 1 then
            put tPass into sVaultPass
            exit repeat
         end if
         if tTries >= 3 then
            answer "That passphrase did not unlock your channels. They stay safe in the file - reopen the app to try again."
            put "true" into sPrefLockedOut
            exit chPrefLoad
         end if
         answer "Wrong passphrase. Try again (" & (3 - tTries) && "left)." with "OK"
      end repeat
   else
      exit chPrefLoad    -- not our file / unknown header: leave it untouched
   end if
   try
      put arrayDecode(tBody) into tA
   catch tErr
      exit chPrefLoad
   end try
   set the uChannels of this stack to tA["uChannels"]
   set the uActiveChannel of this stack to tA["uActiveChannel"]
   set the uFollows of this stack to tA["uFollows"]
   set the uFollowPass of this stack to tA["uFollowPass"]
   set the uFollowAnon of this stack to tA["uFollowAnon"]
   set the uDhtState of this stack to tA["uDhtState"]
end chPrefLoad

-- Write current state to the prefs file (plaintext, or sealed if a passphrase is
-- set). Never overwrites a file we could not unlock this run.
command chPrefSave
   local tA, tBody, tOut, tSalt, tKey, tPath
   if sPrefLockedOut is "true" then
      exit chPrefSave
   end if
   put the uChannels of this stack into tA["uChannels"]
   put the uActiveChannel of this stack into tA["uActiveChannel"]
   put the uFollows of this stack into tA["uFollows"]
   put the uFollowPass of this stack into tA["uFollowPass"]
   put the uFollowAnon of this stack into tA["uFollowAnon"]
   put the uDhtState of this stack into tA["uDhtState"]
   put arrayEncode(tA) into tBody
   if sVaultPass is not empty and sCanEncrypt then
      put sxRandomBytes(16) into tSalt
      put sxPwHash(textEncode(sVaultPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tKey
      put textEncode(kPrefMagic & "E", "ASCII") & tSalt & sxSecretBox(tBody, tKey) into tOut
   else
      put textEncode(kPrefMagic & "P", "ASCII") & tBody into tOut
   end if
   put chPrefFile() into tPath
   put tOut into url ("binfile:" & tPath)
end chPrefSave

-- The "Lock Identity" button: set (or remove) a master passphrase that seals the
-- prefs file. Setting asks twice - a typo here would lock you out, with no recovery.
command chProtectIdentity
   local tP1, tP2
   if not sCanEncrypt then
      answer "Locking your identity needs SodiumXT (org.openxtalk.library.sodium), which is not installed."
      exit chProtectIdentity
   end if
   if sVaultPass is empty then
      ask password "Set a passphrase to protect your saved channel identity on this computer. You enter it each time you open the app, and there is NO recovery if you lose it:"
      if it is empty then
         exit chProtectIdentity
      end if
      put it into tP1
      ask password "Confirm the passphrase:"
      put it into tP2
      if tP1 is not tP2 then
         answer "Those did not match - nothing was changed."
         exit chProtectIdentity
      end if
      put tP1 into sVaultPass
      chPrefSave
      chUpdateLockButton
      answer "Your channel identity is now protected. You will be asked for this passphrase each time you open the app."
      chLog "Identity protection ON - the prefs file is now encrypted."
   else
      answer "Remove passphrase protection? Your identity will be stored unencrypted on this computer." with "Cancel" or "Remove"
      if it is not "Remove" then
         exit chProtectIdentity
      end if
      put empty into sVaultPass
      chPrefSave
      chUpdateLockButton
      chLog "Identity protection OFF - the prefs file is now stored unencrypted."
   end if
end chProtectIdentity

-- Reflect lock state on the button label.
command chUpdateLockButton
   if there is no button "chLock" then
      exit chUpdateLockButton
   end if
   if sVaultPass is not empty then
      set the label of button "chLock" to "Identity Locked"
   else
      set the label of button "chLock" to "Lock Identity..."
   end if
end chUpdateLockButton

command chPollOnce
   local tEvents, tEvent
   if sPolling is not "true" then
      exit chPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit chPollOnce
   end if
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      chHandleEvent tEvent
   end repeat
   send "chPollOnce" to me in 250 milliseconds
end chPollOnce

command chDashOnce
   local tNow, tKey
   if sPolling is not "true" then
      exit chDashOnce
   end if
   chRefreshTransfers
   chOnionPill      -- keep the live Tor pill (bootstrap %) current, 1 Hz
   -- the Follow watchdog (fleet-audit fix): "Fetching their feed..." used to
   -- wait in silence forever. One spoken diagnosis per followed key once its
   -- window passes; the fetch itself keeps retrying on the 60 s tick.
   put the milliseconds into tNow
   repeat for each key tKey in sFeedWait
      if sFeedHinted[tKey] is not "true" and (tNow - sFeedWait[tKey]) > (kChFeedHintSecs * 1000) then
         put "true" into sFeedHinted[tKey]
         chLog "* still nothing from" && chShortKey(tKey) && "after" && kChFeedHintSecs && "s - wrong code? publisher offline? DHT still warming up (watch the node count)? Still watching for it."
         -- section 6.8 stripped-tag mitigation: a public follow that never answers
         -- over the DHT might be an onion-only channel followed from an OLD 2-field
         -- card. Probe its onion once (fail-closed, no misleading placeholder); a
         -- feed over Tor promotes it to anon (chApplyAnonFeed), else nothing changes.
         if sHasOnion and sOnionIdentityOk and sFollowAnon[tKey] is not "true" and sFollowStream[tKey] is empty then
            chLog "  if" && chShortKey(tKey) && "is an anonymous channel, re-copy its current card (it now carries an anon tag). Trying its onion once..."
            chOnionFollowFetch tKey
         end if
      end if
   end repeat
   send "chDashOnce" to me in 1000 milliseconds
end chDashOnce

-- every 60 s: keep EVERY one of your channels alive in the DHT (not just the
-- active one, so they all stay reachable) and re-pull your subscriptions
command chChannelTick
   local tKey, tI, tKp, tFeed, tVal, tR
   if sPolling is not "true" then
      exit chChannelTick
   end if
   if sSession is not 0 and sSession is not empty then
      repeat with tI = 1 to chChannelCount()
         put btDhtKeypair(sChannels[tI]["seed"]) into tKp
         -- ANON channel (section 6.7 guard 3): NEVER btDhtPutMutable - its feed
         -- lives on the onion. Refresh live subscribers over Tor instead.
         if chIsAnonChannel(tI) then
            chOnionPushFeed tKp["publicKey"]
            next repeat
         end if
         put chBuildFeed(sChannels[tI]["name"], sChannels[tI]["releases"]) into tFeed
         -- encrypted for private channels; skip a private one we cannot encrypt
         -- rather than ever re-announcing it in the clear (fail-closed)
         put chFeedValue(tFeed, sChannels[tI]["pass"], tKp["publicKey"]) into tVal
         if tVal is not empty then
            btDhtPutMutable sSession, tKp["publicKey"], tKp["secretKey"], "", tVal
            -- a refused re-announce means the channel silently expires from
            -- the DHT in ~2 h; say so ONCE (this tick re-runs forever, and a
            -- once-per-site flag keeps the log readable) - fleet-audit fix
            put the result into tR
            if tR is not empty and tR < 0 and sDhtErrHinted["tick-put"] is not "true" then
               put "true" into sDhtErrHinted["tick-put"]
               chLog "* channel re-announce refused (" & tR & "):" && btLastError() && "- your channels stop being reachable if this keeps failing."
            end if
         end if
      end repeat
      repeat for each line tKey in sFollows
         if tKey is not empty then
            -- an anon follow re-pulls over the onion (only when its feed stream
            -- has dropped); a public follow re-pulls over the DHT as before
            if sFollowAnon[tKey] is "true" then
               if sFollowStream[tKey] is empty then
                  chOnionFollowFetch tKey
               end if
            else
               chDhtGetChecked tKey, "tick"
            end if
         end if
      end repeat
      -- bring anon services online after a Tor restart / bootstrap (no-op when up)
      chOnionBringUpServices
   end if
   send "chChannelTick" to me in 60000 milliseconds
end chChannelTick

-- ---- my channel --------------------------------------------------------------
-- A PRIVATE channel encrypts a single FILE before sharing it; a PUBLIC channel
-- packages a FOLDER in the clear, as before. The shared tail (feed update +
-- announce) is chAddReleaseAndPublish.
command chPublishFile
   local tPath, tParent, tTitle, tData, tH, tHash, tMagnet, tRel, tOrig, tEnc, tErr
   if sSession is 0 then
      chLog "No session."
      exit chPublishFile
   end if
   -- ANON channel (section 6.7 guard 1): the whole clearnet body below is
   -- UNREACHABLE. An anon release is streamed over the onion on demand, never
   -- packaged as a torrent - no btCreateTorrent / btAddTorrentFile / magnet.
   if chIsAnonChannel(sActive) then
      chOnionPublishFile
      exit chPublishFile
   end if
   if sChannels[sActive]["pass"] is not empty then
      -- ---- PRIVATE: encrypt one file (chunked) before sharing it ----
      if not sCanEncrypt then
         chLog "This channel is private but SodiumXT is not installed - publish is unavailable. Install org.openxtalk.library.sodium."
         exit chPublishFile
      end if
      answer file "Choose a FILE to share privately (it is encrypted before it leaves your machine):"
      put it into tPath
      if tPath is empty then
         exit chPublishFile
      end if
      replace "\" with "/" in tPath
      set the itemDelimiter to "/"
      put the last item of tPath into tOrig
      put tOrig into tTitle
      ask "Title for this release:" with tTitle
      if it is not empty then
         put it into tTitle
      end if
      replace return with space in tTitle
      replace tab with space in tTitle
      put chTempEncPath() into tEnc
      set the itemDelimiter to "/"
      put item 1 to -2 of tEnc into tParent   -- the temp folder the .enc lives in
      chLog "Encrypting '" & tTitle & "' before sharing - the app may pause briefly on a large file..."
      put chEncryptFile(tPath, tEnc, chFileKey(sChannels[sActive]["pass"], sPub)) into tErr
      if tErr is not empty then
         chLog "Could not encrypt:" && tErr
         exit chPublishFile
      end if
      put btCreateTorrent(tEnc, 0, 0, chTrackers()) into tData
      if tData is empty then
         chLog "Create failed:" && btLastError()
         exit chPublishFile
      end if
      put btAddTorrentFile(sSession, tData, tParent) into tH
      if tH is 0 then
         chLog "Seed-add failed:" && btLastError()
         exit chPublishFile
      end if
      put btInfoHash(tH) into tHash
      if tHash is empty then
         chLog "No info-hash yet - try Publish again in a moment."
         exit chPublishFile
      end if
      put true into sMineHashes[toLower(tHash)]
      -- show OURSELVES the real name for this transfer (the swarm only sees the .enc)
      put tTitle into sXferName[toLower(tHash)]
      put "magnet:?xt=urn:btih:" & tHash into tMagnet
      -- encrypted release entry: title TAB magnet TAB enc TAB originalFilename
      put chTrunc(tTitle, 60) & tab & tMagnet & tab & "enc" & tab & tOrig into tRel
      chAddReleaseAndPublish tRel, tTitle, "ENCRYPTED"
      exit chPublishFile
   end if
   -- ---- PUBLIC: package a folder in the clear (any size), as before ----
   answer folder "Choose a folder to publish to your channel:"
   put it into tPath
   if tPath is empty then
      exit chPublishFile
   end if
   replace "\" with "/" in tPath
   if the last char of tPath is "/" then
      delete the last char of tPath
   end if
   set the itemDelimiter to "/"
   put the last item of tPath into tTitle
   ask "Title for this release:" with tTitle
   if it is not empty then
      put it into tTitle
   end if
   replace return with space in tTitle
   replace tab with space in tTitle
   put item 1 to -2 of tPath into tParent
   if tParent is empty then
      put "/" into tParent
   end if
   chLog "Creating + seeding a torrent for" && tPath && "..."
   put btCreateTorrent(tPath, 0, 0, chTrackers()) into tData
   if tData is empty then
      chLog "Create failed:" && btLastError()
      exit chPublishFile
   end if
   put btAddTorrentFile(sSession, tData, tParent) into tH
   if tH is 0 then
      chLog "Seed-add failed:" && btLastError()
      exit chPublishFile
   end if
   put btInfoHash(tH) into tHash
   if tHash is empty then
      chLog "No info-hash yet - try Publish again in a moment."
      exit chPublishFile
   end if
   put true into sMineHashes[toLower(tHash)]
   put "magnet:?xt=urn:btih:" & tHash & "&dn=" & urlEncode(tTitle) into tMagnet
   put chTrunc(tTitle, 60) & tab & tMagnet into tRel
   chAddReleaseAndPublish tRel, tTitle, "PLAIN"
end chPublishFile

-- the active channel's name for display, or a placeholder when it is unnamed
function chActiveName
   if sMyName is empty then
      return "(unnamed)"
   end if
   return sMyName
end chActiveName

command chUpdateNowPub
   local tN, tName, tTotal, tMsg
   put the number of lines of sMyReleases into tN
   put sMyName into tName
   if tName is empty then
      put "(unnamed - click Rename)" into tName
   end if
   put chChannelCount() into tTotal
   if tN is 0 then
      put ("Active: " & tName & " - nothing published yet.") into tMsg
   else
      put ("Active: " & tName & " - seeding " & tN & " release(s).") into tMsg
   end if
   if sChannels[sActive]["pass"] is not empty then
      put tMsg && "[PRIVATE: file list hidden]" into tMsg
   end if
   if chIsAnonChannel(sActive) then
      if sChanService[sPub] is not empty and chOnionReadyNow() then
         put tMsg && "[ANON: served over Tor]" into tMsg
      else
         put tMsg && "[ANON: served over Tor - service offline]" into tMsg
      end if
   end if
   if tTotal > 1 then
      put tMsg && "(" & tTotal & " total)" into tMsg
   end if
   set the text of field "chNowPub" to tMsg
end chUpdateNowPub

command chCopyKey
   local tName, tCard
   if sPub is empty then
      exit chCopyKey
   end if
   -- copy a "Name | key" channel card; the Follow box accepts either that or a
   -- bare key, so the recipient sees who they are following, not just a hex blob.
   -- An ANON channel appends "| anon" (section 6.8) so the follower fetches it
   -- over Tor, not the DHT - the card always keeps its Name field first, so the
   -- key stays item 2 even when the name is blank.
   put sMyName into tName
   if chIsAnonChannel(sActive) then
      put tName & " | " & sPub & " | anon" into tCard
   else if tName is empty then
      put sPub into tCard
   else
      put tName & " | " & sPub into tCard
   end if
   set the clipboardData["text"] to tCard
   uiCopyFlash "chCopyKey"
   chLog "Copied your channel card (name + address) - paste it into someone's Follow box."
end chCopyKey

-- ---- subscriptions / unified feed --------------------------------------------
command chFollow
   local tKey, tRaw, tPass, tDup, tCardAnon
   if sSession is 0 then
      chLog "No session."
      exit chFollow
   end if
   -- accept a bare 64-hex key OR a shared "Name | key" / "Name | key | anon" card.
   -- The key is ALWAYS item 2 when a "|" is present; item 3 "anon" marks it as an
   -- anonymous channel to follow over Tor (section 6.8).
   put chTrim(field "chFollowKey") into tRaw
   put "" into tCardAnon
   if tRaw contains "|" then
      set the itemDelimiter to "|"
      if the number of items of tRaw >= 3 and chTrim(item 3 of tRaw) is "anon" then
         put "true" into tCardAnon
      end if
      put chTrim(item 2 of tRaw) into tRaw
   end if
   put toLower(tRaw) into tKey
   if the number of chars of tKey is not 64 then
      chLog "Paste a 64-character channel address (public key), or a 'Name | key' card, to follow."
      exit chFollow
   end if
   if tKey is sPub then
      chLog "That is your own channel."
      exit chFollow
   end if
   -- an anon card is un-followable without OnionXT: refuse with a clear reason
   -- rather than silently doing a DHT get for an onion-only channel
   if tCardAnon is "true" and not sHasOnion then
      chLog "That is an anonymous (Tor) channel, but OnionXT + SodiumXT are not installed here - it cannot be followed on this machine. Public channels are unaffected."
      exit chFollow
   end if
   put (tKey is among the lines of sFollows) into tDup
   -- a private channel needs its passphrase; blank = public. Pre-fills the
   -- existing one so following again is also how you set/change the passphrase.
   ask "If this is a PRIVATE channel, enter its passphrase (leave blank for a public channel):" with sFollowPass[tKey]
   if it is empty and the result is "Cancel" then
      exit chFollow
   end if
   put it into tPass
   put tPass into sFollowPass[tKey]
   set the uFollowPass of this stack to arrayEncode(sFollowPass)
   -- record + persist whether this follow is anonymous, in parallel to the
   -- passphrases (section 6.2). A stripped card (no "| anon") defaults public;
   -- the chDashOnce watchdog probes the onion for a silent public follow.
   put tCardAnon into sFollowAnon[tKey]
   set the uFollowAnon of this stack to arrayEncode(sFollowAnon)
   if not tDup then
      if sFollows is empty then
         put tKey into sFollows
      else
         put sFollows & return & tKey into sFollows
      end if
      set the uFollows of this stack to sFollows
   end if
   chPrefSave
   put empty into field "chFollowKey"
   chRefreshSubs
   -- fetch the feed the right way: an anon follow DIALS the onion (never the DHT,
   -- which would publish our follow interest + real IP - section 6.7 guard 4)
   if tCardAnon is "true" then
      chOnionFollowFetch tKey
   else
      chDhtGetChecked tKey, "follow"
   end if
   -- arm the no-feed watchdog for THIS key: cleared when its feed arrives (over
   -- the DHT or the onion) or on Unfollow, hinted once by chDashOnce if it never does
   put the milliseconds into sFeedWait[tKey]
   delete variable sFeedHinted[tKey]
   if tDup then
      chLog "Updated the passphrase for" && chShortKey(tKey) & ". Re-fetching its feed..."
   else
      chLog "Following" && chShortKey(tKey) & ". Fetching their feed..."
   end if
end chFollow

command chRefreshAll
   local tKey
   if sSession is 0 then
      exit chRefreshAll
   end if
   repeat for each line tKey in sFollows
      if tKey is not empty then
         -- anon follows re-pull over the onion (reconnecting if the feed stream
         -- dropped); public follows re-pull over the DHT
         if sFollowAnon[tKey] is "true" then
            if sFollowStream[tKey] is empty then
               chOnionFollowFetch tKey
            end if
         else
            chDhtGetChecked tKey, "refresh"
         end if
      end if
   end repeat
   chLog "Refreshing all followed channels..."
end chRefreshAll

command chUnfollow
   local tL, tKey, tLeft, tLine
   put chSelectedLine() into tL
   if tL is 0 then
      chLog "Select a release to unfollow its channel."
      exit chUnfollow
   end if
   put sFeedKey[tL] into tKey
   if tKey is empty then
      chLog "Select a release first."
      exit chUnfollow
   end if
   put empty into tLeft
   repeat for each line tLine in sFollows
      if tLine is not empty and tLine is not tKey then
         if tLeft is empty then
            put tLine into tLeft
         else
            put tLeft & return & tLine into tLeft
         end if
      end if
   end repeat
   put tLeft into sFollows
   set the uFollows of this stack to sFollows
   put empty into sFollowFeeds[tKey]
   put empty into sFollowPass[tKey]
   -- an anonymous follow also has a live onion stream and stored fallback address
   -- to drop, and its anon flag to clear + persist
   if sFollowStream[tKey] is not empty then
      chOnionCloseStream sFollowStream[tKey]
   end if
   delete variable sFollowStream[tKey]
   delete variable sFollowAnon[tKey]
   delete variable sFollowSvc[tKey]
   set the uFollowAnon of this stack to arrayEncode(sFollowAnon)
   -- a pending no-feed watchdog for this key would otherwise hint later
   -- about a channel we no longer follow
   delete variable sFeedWait[tKey]
   delete variable sFeedHinted[tKey]
   set the uFollowPass of this stack to arrayEncode(sFollowPass)
   chPrefSave
   chRefreshSubs
   chLog "Unfollowed" && chShortKey(tKey) & "."
end chUnfollow

command chDownloadSelected
   local tL, tMag, tTitle, tH, tKey, tHash
   if sSession is 0 then
      exit chDownloadSelected
   end if
   put chSelectedLine() into tL
   if tL is 0 then
      chLog "Select a release first."
      exit chDownloadSelected
   end if
   put sFeedMag[tL] into tMag
   put sFeedTitle[tL] into tTitle
   -- an ANON release carries an "onion:<relId>" locator: stream it over Tor,
   -- NEVER btAddMagnet (section 6.5 / 6.7 guard 3). The .onion is derived from
   -- the channel pubkey (sFeedKey[tL]); the locator only names the release.
   if tMag begins with "onion:" then
      chOnionDownload sFeedKey[tL], (char 7 to -1 of tMag), tTitle, sFeedEnc[tL], sFeedOrigName[tL]
      exit chDownloadSelected
   end if
   if tMag is empty or not (tMag begins with "magnet:") then
      chLog "That channel's feed has not arrived yet - try Refresh, and give the DHT a few seconds."
      exit chDownloadSelected
   end if
   put btAddMagnet(sSession, tMag, chDefaultSave()) into tH
   if tH is 0 then
      chLog "Download add failed:" && btLastError()
      exit chDownloadSelected
   end if
   if sFeedEnc[tL] is "enc" then
      -- encrypted release: derive the file key now (we hold the channel's
      -- passphrase, since we decrypted its feed to see this) and stash it so the
      -- download can decrypt itself once the .enc finishes.
      put sFeedKey[tL] into tKey
      put chHashFromMagnet(tMag) into tHash
      if tHash is not empty then
         put chFileKey(sFollowPass[tKey], tKey) into sPendingKey[tHash]
         put sFeedOrigName[tL] into sPendingName[tHash]
         -- show the real release name locally instead of the neutral .enc name
         put tTitle into sXferName[tHash]
      end if
      chLog "Downloading ENCRYPTED '" & tTitle & "' - it decrypts automatically when complete."
   else
      chLog "Downloading '" & tTitle & "'..."
   end if
end chDownloadSelected

command chCopySelectedMagnet
   local tL, tMag
   put chSelectedLine() into tL
   if tL is 0 then
      chLog "Select a release first."
      exit chCopySelectedMagnet
   end if
   put sFeedMag[tL] into tMag
   if tMag is empty then
      chLog "Nothing to copy yet for that row."
      exit chCopySelectedMagnet
   end if
   if tMag begins with "onion:" then
      chLog "This is an anonymous release; it has no magnet link (it streams over Tor). Copy the channel card to share the channel."
      exit chCopySelectedMagnet
   end if
   set the clipboardData["text"] to tMag
   uiCopyFlash "chCopyMag"
   chLog "Copied the magnet to the clipboard."
end chCopySelectedMagnet

-- Rebuild the unified, signed release feed across every channel we follow.
command chRefreshSubs
   local tKey, tFeed, tL, tName, tRel, tTitle, tMag, tRows, tLineNum, tSelMag, tEmpty, tErr, tRelCount
   put chSelectedMagnet() into tSelMag
   put "" into tRows
   put 0 into tLineNum
   put empty into sFeedKey
   put empty into sFeedMag
   put empty into sFeedTitle
   put empty into sFeedEnc
   put empty into sFeedOrigName
   repeat for each line tKey in sFollows
      if tKey is empty then
         next repeat
      end if
      put sFollowFeeds[tKey] into tFeed
      if tFeed is empty then
         add 1 to tLineNum
         put tKey into sFeedKey[tLineNum]
         put chShortKey(tKey) & tab & "(fetching feed...)" & tab & chShortKey(tKey) & return after tRows
         next repeat
      end if
      -- the channel display name (first "name=" line), else the short key
      put chShortKey(tKey) into tName
      repeat for each line tL in tFeed
         if tL begins with "name=" then
            if (char 6 to -1 of tL) is not empty then
               put char 6 to -1 of tL into tName
            end if
            exit repeat
         end if
      end repeat
      -- stash the feed's svc= onion (section 6.1 fallback address); harmless for
      -- a public feed, which never carries one
      repeat for each line tL in tFeed
         if tL begins with "svc=" then
            put char 5 to -1 of tL into sFollowSvc[tKey]
            exit repeat
         end if
      end repeat
      -- tag an anonymous follow's rows (section 6.8); a connecting/offline
      -- placeholder name already says "anonymous", so do not double-tag it
      if sFollowAnon[tKey] is "true" and not (tName contains "anon") then
         put tName && "(anon)" into tName
      end if
      -- one row per "r=title TAB magnet" release line
      put 0 into tRelCount
      repeat for each line tL in tFeed
         if tL begins with "r=" then
            set the itemDelimiter to tab
            put char 3 to -1 of tL into tRel
            put item 1 of tRel into tTitle
            put item 2 of tRel into tMag
            add 1 to tLineNum
            add 1 to tRelCount
            put tKey into sFeedKey[tLineNum]
            put tMag into sFeedMag[tLineNum]
            put tTitle into sFeedTitle[tLineNum]
            -- item 3 = "enc" marker, item 4 = original filename (encrypted release)
            put item 3 of tRel into sFeedEnc[tLineNum]
            put item 4 of tRel into sFeedOrigName[tLineNum]
            if sFeedEnc[tLineNum] is "enc" then
               put tName & tab & "[encrypted] " & chTrunc(tTitle, 38) & tab & chShortKey(tKey) & return after tRows
            else
               put tName & tab & chTrunc(tTitle, 50) & tab & chShortKey(tKey) & return after tRows
            end if
         end if
      end repeat
      -- an ANON follow with no release rows (its name= is a connecting/offline
      -- placeholder, or the channel has published nothing) still needs to be
      -- VISIBLE - a name=-only feed would otherwise render no row. Public follows
      -- keep their exact prior rendering (this branch is anon-only).
      if sFollowAnon[tKey] is "true" and tRelCount is 0 then
         add 1 to tLineNum
         put tKey into sFeedKey[tLineNum]
         put tName & tab & "(no releases yet)" & tab & chShortKey(tKey) & return after tRows
      end if
   end repeat
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   put false into tEmpty
   if tRows is empty then
      -- friendly empty state instead of a blank list
      put true into tEmpty
      put "   You are not following anyone yet. Paste a channel card or key above and click Follow." into tRows
   end if
   lock screen
   set the text of field "chSubs" to tRows
   if tEmpty then
      try
         set the foregroundColor of line 1 of field "chSubs" to "130,130,130"
      catch tErr
      end try
   end if
   -- keep the same release selected across the rebuild, by its magnet
   if tSelMag is not empty then
      repeat with tLineNum = 1 to (the number of lines of field "chSubs")
         if sFeedMag[tLineNum] is tSelMag then
            set the hilitedLines of field "chSubs" to tLineNum
            exit repeat
         end if
      end repeat
   end if
   unlock screen
end chRefreshSubs

-- ---- transfers dashboard -----------------------------------------------------
command chRefreshTransfers
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tLineNum, tD, tNodes, tDht, tKind
   local tColors, tErr, tSelH, tSelLine, tSource, tDispName, tIH, tK, tOx, tOxState
   if sSession is 0 or sSession is empty then
      exit chRefreshTransfers
   end if
   -- defensive: never touch the table before the UI is built (a stale refresh
   -- tick could otherwise arrive between session start and build - see openStack)
   if there is no field "chXfers" then
      exit chRefreshTransfers
   end if
   -- remember which transfer is selected (by handle) so the 1 s repaint keeps it
   put chSelectedXferHandle() into tSelH
   put btTorrentCount(sSession) into tCount
   put "" into tRows
   put 0 into tDown
   put 0 into tUp
   put 0 into tLineNum
   put 0 into tSelLine
   put empty into sXferHandle
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is 0 then
         next repeat
      end if
      put btTorrentStatus(tH) into tS
      add 1 to tLineNum
      put tH into sXferHandle[tLineNum]
      if tH is tSelH then
         put tLineNum into tSelLine
      end if
      put (the round of (tS["progress"] * 1000) / 10) into tPct
      put chSource(tS) into tSource
      -- Colour the row by SOURCE so posted vs downloaded is obvious at a glance:
      -- red = error, grey = paused, green = YOU posted it, blue = you downloaded
      -- it (named adopter constants, aligned with the family's row-color set).
      if tS["error"] is not empty then
         put kChRowErr into tColors[tLineNum]
      else if tS["isPaused"] is true or tS["isPaused"] is 1 then
         put kChRowPaused into tColors[tLineNum]
      else if tSource is "Posted" then
         put kChRowPosted into tColors[tLineNum]
      else
         put kChRowDown into tColors[tLineNum]
      end if
      -- Show the real name for our own/known encrypted transfers; the swarm only
      -- ever sees the neutral .enc name, but we should not hide it from ourselves.
      put tS["name"] into tDispName
      put toLower(tS["infoHashV1"]) into tIH
      if tIH is not empty and sXferName[tIH] is not empty then
         put sXferName[tIH] into tDispName
      end if
      -- Source | Name | State | Progress | Peers (monospaced; Name trimmed to fit)
      put tSource & tab & chTrunc(tDispName, 21) & tab & chXferState(tS) & tab & \
          chProgressBar(tPct) & tab & tS["numPeers"] & return after tRows
      add tS["downloadRate"] to tDown
      add tS["uploadRate"] to tUp
   end repeat
   -- append the onion (Tor) transfer rows AFTER the swarm rows, before the empty
   -- check (section 6.8). These have no torrent handle - their whole progress is
   -- the in-script sOnionXfer model - so the source column reads "Onion" (teal)
   -- and the mode is never visually confused with a swarm transfer.
   repeat for each key tK in sOnionXfer
      put sOnionXfer[tK] into tOx
      add 1 to tLineNum
      put kChRowOnion into tColors[tLineNum]
      put chOnionXferState(tOx) into tOxState
      if tOx["total"] is empty or tOx["total"] is 0 or tOx["state"] is "connecting" then
         put 0 into tPct
      else
         put (the round of (tOx["got"] / tOx["total"] * 1000) / 10) into tPct
      end if
      put "Onion" & tab & chTrunc(tOx["name"], 21) & tab & tOxState & tab & \
          chProgressBar(tPct) & tab & "-" & return after tRows
   end repeat
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   put btDhtState(sSession) into tD
   put tD["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("DHT:" && tNodes && "nodes") into tDht
      put "ok" into tKind
   else
      put "DHT: connecting..." into tDht
      put "" into tKind
   end if
   lock screen
   set the text of field "chXfers" to tRows
   if tLineNum is 0 then
      -- friendly empty state instead of a blank table
      set the text of field "chXfers" to \
         "Nothing transferring yet. Publish a file above, or Download a release from a channel you follow."
      try
         set the foregroundColor of line 1 of field "chXfers" to "130,130,130"
      catch tErr
      end try
   end if
   -- color each row by state (green=seeding/done, blue=downloading, amber=checking,
   -- grey=queued, red=error). Wrapped so a platform that dislikes per-line coloring
   -- still shows the table, just monochrome.
   try
      repeat with tI = 1 to tLineNum
         set the foregroundColor of line tI of field "chXfers" to tColors[tI]
      end repeat
   catch tErr
   end try
   -- keep the selected transfer highlighted across the repaint
   if tSelLine > 0 then
      set the hilitedLines of field "chXfers" to tSelLine
   end if
   -- the one status line is the kit's (green once the DHT actually has nodes)
   uiStatus (tLineNum && "transfers     down" && (chFmtBytes(tDown) & "/s") && "    up" \
      && (chFmtBytes(tUp) & "/s") && "     " & tDht), tKind
   unlock screen
   -- refresh the file detail for whatever transfer is selected (live per-file %)
   chShowFiles tSelH
end chRefreshTransfers

-- ---- selected-transfer detail: the file table (btFileList) -------------------

-- The 0-based line of the selected transfer, or 0 if none.
function chSelectedXferLine
   local tNum
   set the itemDelimiter to comma   -- the hilitedLines is comma-delimited
   put item 1 of (the hilitedLines of field "chXfers") into tNum
   if tNum is empty or tNum is not a number then
      return 0
   end if
   return tNum
end chSelectedXferLine

-- The torrent handle of the selected transfer, or 0 if none / stale.
function chSelectedXferHandle
   local tL
   put chSelectedXferLine() into tL
   if tL is 0 or sXferHandle[tL] is empty then
      return 0
   end if
   return sXferHandle[tL]
end chSelectedXferHandle

-- Show the file table of a torrent: name, size, and a live per-file progress
-- bar (btFileList - the marquee v5 inspection call). Empty until metadata
-- arrives (a magnet fetches its file list over the swarm).
command chShowFiles pHandle
   local tFiles, tFile, tRows, tPct, tIH, tFileName
   if there is no field "chFiles" then
      exit chShowFiles
   end if
   if pHandle is 0 or pHandle is empty then
      put "   Click a transfer above to see its files and per-file progress." into tRows
   else
      put toLower(btInfoHash(pHandle)) into tIH
      put btFileList(pHandle) into tFiles
      put "" into tRows
      repeat for each element tFile in tFiles
         if tFile["size"] > 0 then
            put (the round of (tFile["progress"] * 1000 / tFile["size"]) / 10) into tPct
         else
            put 0 into tPct
         end if
         -- an encrypted release is a single .enc file; show its real name to us
         put tFile["path"] into tFileName
         if tIH is not empty and sXferName[tIH] is not empty then
            put sXferName[tIH] into tFileName
         end if
         put chTrunc(tFileName, 60) & tab & chFmtBytes(tFile["size"]) & tab \
             & chProgressBar(tPct) & return after tRows
      end repeat
      if the last char of tRows is return then
         delete the last char of tRows
      end if
      if tRows is empty then
         put "   No file list yet - metadata still arriving (a magnet fetches it over the swarm)." into tRows
      end if
   end if
   -- repaint only when the contents actually changed (single-thread playbook)
   if the text of field "chFiles" is not tRows then
      set the text of field "chFiles" to tRows
   end if
end chShowFiles

command chShowFilesForSelection
   chShowFiles chSelectedXferHandle()
end chShowFilesForSelection

-- ---- transfer actions (operate on the selected transfer) --------------------

-- Add any magnet link or 40/64-char info-hash directly, not only the releases
-- shared by channels you follow. The download lands in the same default folder.
-- Intentionally UNAFFECTED by anon mode (section 6.7 guard 7): this is a manual,
-- user-chosen clearnet download into the user's own folder, never a channel
-- publish - do not "fix" it to route through Tor.
command chAddMagnetManual
   local tMag, tH
   if sSession is 0 then
      chLog "No session."
      exit chAddMagnetManual
   end if
   put chTrim(field "chMagnetField") into tMag
   if tMag is empty then
      chLog "Paste a magnet link or info-hash into the box first."
      exit chAddMagnetManual
   end if
   -- accept a bare 40-hex (v1) or 64-hex (v2) info-hash by wrapping it as a magnet
   if not (tMag begins with "magnet:") then
      if the number of chars of tMag is 40 or the number of chars of tMag is 64 then
         put "magnet:?xt=urn:btih:" & tMag into tMag
      else
         chLog "That is not a magnet link or a 40/64-character info-hash."
         exit chAddMagnetManual
      end if
   end if
   put btAddMagnet(sSession, tMag, chDefaultSave()) into tH
   if tH is 0 then
      chLog "Add failed:" && btLastError()
      exit chAddMagnetManual
   end if
   put empty into field "chMagnetField"
   chLog "Added a magnet - downloading to" && chDefaultSave() & "."
   chRefreshTransfers
end chAddMagnetManual

command chPauseSelected
   local tH, tR
   put chSelectedXferHandle() into tH
   if tH is 0 then
      chLog "Select a transfer to pause."
      exit chPauseSelected
   end if
   put btPause(tH) into tR
   if tR is 0 then
      chLog "Paused that transfer."
   else
      chLog "Pause failed:" && btLastError()
   end if
   chRefreshTransfers
end chPauseSelected

command chResumeSelected
   local tH, tR
   put chSelectedXferHandle() into tH
   if tH is 0 then
      chLog "Select a transfer to resume."
      exit chResumeSelected
   end if
   put btResume(tH) into tR
   if tR is 0 then
      chLog "Resumed that transfer."
   else
      chLog "Resume failed:" && btLastError()
   end if
   chRefreshTransfers
end chResumeSelected

-- Remove the selected transfer from the session. The user chooses whether to
-- also delete the downloaded files from disk (a deliberate, separate choice).
command chRemoveSelected
   local tH, tS, tName, tDelete, tR
   put chSelectedXferHandle() into tH
   if tH is 0 then
      chLog "Select a transfer to remove."
      exit chRemoveSelected
   end if
   put btTorrentStatus(tH) into tS
   put tS["name"] into tName
   if tName is empty then
      put "this transfer" into tName
   end if
   answer "Remove" && quote & chTrunc(tName, 40) & quote & "?" & return & \
      "Keep the downloaded files, or delete them from disk?" with \
      "Cancel" or "Keep Files" or "Delete Files"
   if it is "Cancel" then
      exit chRemoveSelected
   end if
   put (it is "Delete Files") into tDelete
   put btRemoveTorrent(sSession, tH, tDelete) into tR
   if tR is not 0 then
      chLog "Remove failed:" && btLastError()
      exit chRemoveSelected
   end if
   if tDelete then
      chLog "Removed" && quote & tName & quote && "and deleted its files."
   else
      chLog "Removed" && quote & tName & quote && "(files kept on disk)."
   end if
   chRefreshTransfers
end chRemoveSelected

-- Open the selected transfer's download folder in the OS file manager, and log
-- the path regardless (so the user always knows where the files landed).
command chOpenSelectedFolder
   local tH, tS, tFolder, tErr
   put chSelectedXferHandle() into tH
   if tH is 0 then
      chLog "Select a transfer, then click Open Folder (or double-click the row)."
      exit chOpenSelectedFolder
   end if
   put btTorrentStatus(tH) into tS
   put tS["savePath"] into tFolder
   if tFolder is empty then
      chLog "No download location for that transfer yet."
      exit chOpenSelectedFolder
   end if
   try
      launch document tFolder
   catch tErr
   end try
   chLog "Download folder:" && tFolder
end chOpenSelectedFolder

-- State text for a transfer row: "paused" overrides the activity phase, since a
-- paused seeding/downloading torrent is stopped even though its phase is set.
function chXferState pStatus
   if pStatus["isPaused"] is true or pStatus["isPaused"] is 1 then
      return "paused"
   end if
   return chStateName(pStatus["state"])
end chXferState

-- Is a transfer something YOU posted to a channel, or something you downloaded?
-- We record the info-hash of every file we publish (sMineHashes), so a match
-- means it is ours; anything else arrived via Download or Add Magnet. Reads the
-- hash from the status record we already fetched (no extra FFI round-trip).
function chSource pStatus
   if pStatus["infoHashV1"] is not empty and sMineHashes[toLower(pStatus["infoHashV1"])] is true then
      return "Posted"
   end if
   if pStatus["infoHashV2"] is not empty and sMineHashes[toLower(pStatus["infoHashV2"])] is true then
      return "Posted"
   end if
   return "Downloaded"
end chSource

-- a 10-segment ASCII progress bar, e.g. [####------] 42%  (monospaced fields)
function chProgressBar pPct
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
end chProgressBar

-- ---- quick drop (immutable) --------------------------------------------------
command chPin
   local tData, tTarget
   if sSession is 0 then
      exit chPin
   end if
   put textEncode(field "chPinText", "UTF-8") into tData
   if the number of bytes in tData is 0 then
      chLog "Type some text to pin first."
      exit chPin
   end if
   if the number of bytes in tData > 1000 then
      chLog "Too big to pin:" && (the number of bytes in tData) && "bytes (max 1000)."
      exit chPin
   end if
   put btDhtPutImmutable(sSession, tData) into tTarget
   if tTarget is empty then
      chLog "Pin failed:" && btLastError()
      exit chPin
   end if
   set the text of field "chPinCode" to tTarget
   chLog "Pinned. Share this code:" && tTarget
end chPin

command chPinCopy
   if field "chPinCode" is empty then
      exit chPinCopy
   end if
   set the clipboardData["text"] to field "chPinCode"
   uiCopyFlash "chPinCopy"
   chLog "Copied the drop code to the clipboard."
end chPinCopy

command chFetchCode
   local tTarget, tR
   if sSession is 0 then
      exit chFetchCode
   end if
   put chTrim(field "chFetchCode") into tTarget
   if the number of chars of tTarget is not 40 then
      chLog "Paste a 40-character drop code first."
      exit chFetchCode
   end if
   put btDhtGetImmutable(sSession, tTarget) into tR
   if tR is not 0 then
      chLog "Fetch failed:" && btLastError()
      exit chFetchCode
   end if
   chLog "Looking up drop" && tTarget & "... (returns as an event)"
end chFetchCode

-- ---- events (drained by the poll loop) ---------------------------------------
command chHandleEvent pEvent
   local tKey, tVal, tN
   switch pEvent["name"]
      case "dhtMutableItem"
         put pEvent["publicKey"] into tKey
         -- ignore any DHT value for a channel we follow ANONYMOUSLY: a stale
         -- artifact of its public past must not overwrite the onion feed
         -- (section 6.7 guard 5)
         if sFollowAnon[tKey] is "true" then
            break
         end if
         -- the feed arrived: the Follow watchdog for this key is satisfied
         delete variable sFeedWait[tKey]
         delete variable sFeedHinted[tKey]
         -- decrypt if this is a private channel we hold the passphrase for;
         -- libtorrent only surfaces a mutable item after verifying its ed25519
         -- signature, so arrival == cryptographically authentic (encryption rides
         -- on top of that for confidentiality).
         put chReadFeed(pEvent["value"], sFollowPass[tKey], tKey) into tVal
         if tVal is "LOCKED" then
            put ("name=" & chShortKey(tKey) & " (private - needs passphrase)") into sFollowFeeds[tKey]
            chRefreshSubs
            chLog "Channel" && chShortKey(tKey) && "is private. Click Follow again with its passphrase to read it."
         else if tVal is "BADPASS" then
            put ("name=" & chShortKey(tKey) & " (wrong passphrase)") into sFollowFeeds[tKey]
            chRefreshSubs
            chLog "Channel" && chShortKey(tKey) && ": that passphrase did not unlock the feed."
         else
            put tVal into sFollowFeeds[tKey]
            chRefreshSubs
            put chCountReleases(tVal) into tN
            chLog "Channel" && chShortKey(tKey) && "feed: signature verified, v" & pEvent["seq"] & "," && tN && "release(s)."
         end if
         break
      case "dhtImmutableItem"
         set the text of field "chDropResult" to textDecode(pEvent["value"], "UTF-8")
         chLog "Fetched drop" && pEvent["target"] & "."
         break
      case "dhtPut"
         chLog "Announced to" && pEvent["numSuccess"] && "DHT node(s)."
         break
      case "torrentAdded"
         chLog "+ added torrent" && pEvent["torrent"]
         chRefreshTransfers
         break
      case "metadataReceived"
         chLog "  metadata:" && pEvent["torrentName"]
         break
      case "torrentFinished"
         chLog "* finished - now seeding torrent" && pEvent["torrent"]
         -- if it was an encrypted download we tracked, decrypt it now
         chMaybeDecryptFinished pEvent["torrent"]
         break
      default
         break
   end switch
end chHandleEvent

-- ---- helpers -----------------------------------------------------------------
function chBuildFeed pName, pReleases
   local tFeed, tLine
   put "name=" & pName into tFeed
   repeat for each line tLine in pReleases
      if tLine is not empty then
         put tFeed & return & "r=" & tLine into tFeed
      end if
   end repeat
   return tFeed
end chBuildFeed

-- ---- OPTIONAL feed encryption (the channel's file LIST) ----------------------
-- A channel can carry a passphrase. If it does, its feed is encrypted with
-- SodiumXT (libsodium crypto_secretbox, XSalsa20-Poly1305) before the DHT put, so
-- only someone with the passphrase can read the file LIST (the FILES are
-- encrypted separately - see "Phase 2: actual FILE encryption" below). The
-- symmetric key is derived from the passphrase with Argon2id (sxPwHash), salted
-- by the channel's public key so publisher and followers derive the SAME key. The
-- feed stays ed25519-signed on top, so authenticity is unchanged. Requires the
-- org.openxtalk.library.sodium extension (SodiumXT) to be installed.

-- the 8-byte tag that marks an encrypted feed value on the wire (v2 = libsodium;
-- the old v1 AES format is intentionally not readable by this build)
function chEncMarker
   return "BTXENC2:"
end chEncMarker

-- A symmetric master key from the channel passphrase + the channel's PUBLIC key
-- as the salt. The public key is shareable, which is fine for a salt: it just
-- makes the derivation per-channel (the same passphrase on two channels yields
-- different keys). Argon2id is deliberately slow, so cache the result per
-- (pubkey, passphrase) and never re-derive it on the feed-refresh timer.
function chMasterKey pPass, pPubHex
   local tSalt, tCacheKey, tMaster
   put pPubHex & ":" & pPass into tCacheKey
   if sKeyCache[tCacheKey] is not empty then
      return sKeyCache[tCacheKey]
   end if
   put byte 1 to 16 of sxHex2Bin(textEncode(pPubHex, "ASCII")) into tSalt
   put sxPwHash(textEncode(pPass, "UTF-8"), tSalt, 32, "2", sxPwMemInteractive()) into tMaster
   put tMaster into sKeyCache[tCacheKey]
   return tMaster
end chMasterKey

-- Distinct 32-byte subkeys for the feed vs the files, from the one master key, so
-- a feed key never doubles as a file key. crypto_kdf (sxKdfDerive) is fast.
function chFeedKey pPass, pPubHex
   return sxKdfDerive(chMasterKey(pPass, pPubHex), "1", textEncode("btxfeed1", "ASCII"), 32)
end chFeedKey

function chFileKey pPass, pPubHex
   return sxKdfDerive(chMasterKey(pPass, pPubHex), "2", textEncode("btxfile1", "ASCII"), 32)
end chFileKey

-- one-time capability probe: is SodiumXT (libsodium) installed and working? We do
-- a real secretbox round-trip with a random key (fast - no Argon2id), wrapped in a
-- try so a missing org.openxtalk.library.sodium is a clean "no", not an error.
-- Result is cached in sCanEncrypt at startup.
function chCanEncrypt
   local tKey, tBox, tOut, tErr
   try
      put sxRandomBytes(32) into tKey
      put sxSecretBox(textEncode("probe", "ASCII"), tKey) into tBox
      put sxSecretBoxOpen(tBox, tKey) into tOut
   catch tErr
      return false
   end try
   return (textDecode(tOut, "ASCII") is "probe")
end chCanEncrypt

-- The bytes to publish for a feed: plaintext UTF-8 when public; marker+secretbox
-- when the channel has a passphrase (the secretbox output is nonce || ciphertext
-- || MAC, a fresh random nonce each publish). Returns EMPTY for a private channel
-- we cannot encrypt, so the caller refuses to publish in the clear (fail-closed).
function chFeedValue pFeed, pPass, pPubHex
   local tBox, tErr
   if pPass is empty then
      return textEncode(pFeed, "UTF-8")
   end if
   if not sCanEncrypt then
      return ""
   end if
   try
      put sxSecretBox(textEncode(pFeed, "UTF-8"), chFeedKey(pPass, pPubHex)) into tBox
   catch tErr
      return ""
   end try
   return (textEncode(chEncMarker(), "ASCII") & tBox)
end chFeedValue

-- Turn a received feed value back into feed text. Returns the plaintext feed, or
-- the sentinel "LOCKED" (encrypted, no passphrase) / "BADPASS" (passphrase did
-- not work, OR the value was tampered - secretbox authenticates). A valid feed
-- always begins with "name=", so it never collides with a sentinel.
function chReadFeed pRaw, pPass, pPubHex
   local tBox, tPlainData, tPlain, tErr
   if (the number of bytes in pRaw) > 8 and (textDecode(byte 1 to 8 of pRaw, "ASCII") is chEncMarker()) then
      if pPass is empty or not sCanEncrypt then
         return "LOCKED"
      end if
      put byte 9 to -1 of pRaw into tBox
      try
         put sxSecretBoxOpen(tBox, chFeedKey(pPass, pPubHex)) into tPlainData
      catch tErr
         return "BADPASS"
      end try
      put textDecode(tPlainData, "UTF-8") into tPlain
      if not (tPlain begins with "name=") then
         return "BADPASS"
      end if
      return tPlain
   end if
   return textDecode(pRaw, "UTF-8")
end chReadFeed

-- Build the active channel's feed value and publish it (encrypted if private).
-- Returns 0 on success, -1 if a private feed could not be encrypted (so it was
-- NOT published), or the DHT put's own non-zero error code.
function chPublishActiveFeed
   local tVal
   if sSession is 0 or sSession is empty then
      return 0
   end if
   -- ANON channel (section 6.7 guard 2): NEVER btDhtPutMutable - the feed lives on
   -- the onion. Push it to live subscribers instead. Public channels fall through.
   if chIsAnonChannel(sActive) then
      chOnionPushFeed sPub
      return 0
   end if
   put chBuildFeed(sMyName, sMyReleases) into sMyPost
   put chFeedValue(sMyPost, sChannels[sActive]["pass"], sPub) into tVal
   if tVal is empty then
      return -1
   end if
   return btDhtPutMutable(sSession, sPub, sSec, "", tVal)
end chPublishActiveFeed

-- ---- Phase 2: actual FILE encryption (SodiumXT secretstream) -----------------
-- A private channel encrypts the FILE itself, not just the feed. SodiumXT streams
-- it through libsodium's crypto_secretstream (XChaCha20-Poly1305) entirely C-side
-- (sxEncryptFile), so a big file never enters a LiveCode Data and the per-chunk
-- authentication + FINAL tag make truncation or tampering detectable on decrypt.
-- The torrent then carries CIPHERTEXT under a neutral name, so a leaked magnet is
-- useless; the real filename rides in the (encrypted) feed and is restored on
-- download. The file key is chFileKey (derived from the passphrase, distinct from
-- the feed key). NOTE: encryption is synchronous, so the UI pauses on a very large
-- file. Requires the org.openxtalk.library.sodium extension (SodiumXT).

-- a unique temp path with a NEUTRAL name (the torrent name leaks nothing)
function chTempEncPath
   local tBase
   put specialFolderPath("temporary") into tBase
   if tBase is empty then
      put specialFolderPath("documents") into tBase
   end if
   return tBase & "/btxshare-" & the milliseconds & "-" & random(999999) & ".enc"
end chTempEncPath

-- the v1 info-hash inside a magnet, lowercased, or "" if none
function chHashFromMagnet pMag
   local tHash
   if pMag contains "btih:" then
      set the itemDelimiter to "btih:"
      put item 2 of pMag into tHash
      set the itemDelimiter to "&"
      put item 1 of tHash into tHash
      return toLower(tHash)
   end if
   return ""
end chHashFromMagnet

-- Encrypt pSrc to pDst with the 32-byte file key pKey (SodiumXT secretstream,
-- streamed C-side). Returns "" on success, else an error string.
function chEncryptFile pSrc, pDst, pKey
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
end chEncryptFile

-- Decrypt pSrc (a .enc) to pDst with the 32-byte file key pKey. SodiumXT throws on
-- a wrong key or a truncated/corrupt input. Returns "" on success, else the error.
function chDecryptFile pSrc, pDst, pKey
   local tErr
   try
      sxDecryptFile pSrc, pDst, pKey
   catch tErr
      return tErr
   end try
   return ""
end chDecryptFile

-- Shared publish tail: prepend a release to the active channel's feed, trim it to
-- the BEP44 budget, persist, and announce (encrypted if the channel is private).
command chAddReleaseAndPublish pRel, pTitle, pKind
   local tR
   if sMyReleases is empty then
      put pRel into sMyReleases
   else
      put pRel & return & sMyReleases into sMyReleases
   end if
   put chBuildFeed(sMyName, sMyReleases) into sMyPost
   -- 920, not the full ~1000 BEP44 budget: a private channel's secretbox adds 48
   -- bytes (8 marker + 24 nonce + 16 MAC), so the encrypted value still fits.
   repeat while (the number of bytes in textEncode(sMyPost, "UTF-8")) > 920 and the number of lines of sMyReleases > 1
      delete the last line of sMyReleases
      put chBuildFeed(sMyName, sMyReleases) into sMyPost
   end repeat
   put sMyReleases into sChannels[sActive]["releases"]
   chSaveChannels
   put chPublishActiveFeed() into tR
   if tR is -1 then
      chLog "Seeding, but this PRIVATE channel's feed could not be encrypted, so it was NOT announced. Fix its passphrase (Privacy) or make it public."
      exit chAddReleaseAndPublish
   end if
   if tR is not 0 then
      chLog "Publish to DHT failed:" && btLastError()
      exit chAddReleaseAndPublish
   end if
   chUpdateNowPub
   if pKind is "ANON" then
      chLog "Published '" & pTitle & "' ANONYMOUSLY to channel '" & chActiveName() & "' - it streams over Tor on demand and was pushed to onion followers. Keep this window open."
   else if pKind is "ANONENC" then
      chLog "Published '" & pTitle & "' ANONYMOUSLY + ENCRYPTED to channel '" & chActiveName() & "' - it streams (sealed) over Tor and was pushed to onion followers. Keep this window open."
   else if pKind is "ENCRYPTED" then
      chLog "Published '" & pTitle & "' ENCRYPTED to channel '" & chActiveName() & "' and seeding it."
   else
      chLog "Published '" & pTitle & "' to channel '" & chActiveName() & "' and seeding it."
   end if
   if sMyName is empty then
      chLog "Tip: click Rename to give this channel a name your followers will see."
   end if
end chAddReleaseAndPublish

-- A download just finished: if we were tracking it as an encrypted release,
-- decrypt the .enc to its original filename next to the download.
command chMaybeDecryptFinished pTorrent
   local tS, tHash, tSave, tEncName, tEncPath, tOut, tErr
   put btTorrentStatus(pTorrent) into tS
   put toLower(tS["infoHashV1"]) into tHash
   if tHash is empty or sPendingKey[tHash] is empty then
      exit chMaybeDecryptFinished   -- not an encrypted download we are tracking
   end if
   put tS["savePath"] into tSave
   put tS["name"] into tEncName        -- the neutral .enc filename
   put tSave & "/" & tEncName into tEncPath
   put tSave & "/" & sPendingName[tHash] into tOut
   chLog "Decrypting '" & sPendingName[tHash] & "' - the app may pause briefly on a large file..."
   put chDecryptFile(tEncPath, tOut, sPendingKey[tHash]) into tErr
   -- drop the torrent and DELETE the downloaded .enc so no encrypted blob is left
   -- in the user's folder. btRemoveTorrent (deleteFiles = true) removes the .enc;
   -- the decrypted real file is not part of the torrent, so it stays.
   btRemoveTorrent sSession, pTorrent, true
   if tErr is not empty then
      chLog "Could not decrypt '" & sPendingName[tHash] & "':" && tErr & " (the encrypted copy was removed)."
   else
      chLog "Decrypted to '" & sPendingName[tHash] & "' in" && tSave & ". (Encrypted copy cleaned up.)"
   end if
   put empty into sPendingKey[tHash]
   put empty into sPendingName[tHash]
end chMaybeDecryptFinished

-- ==== OnionXT: optional per-channel Tor anonymity (Model C) ===================
-- The whole block below is inert unless sHasOnion. It NEVER touches libtorrent
-- for an anon channel: no btCreateTorrent / btAddTorrentFile / btAddMagnet /
-- btDhtPutMutable / btDhtGetMutable (the mutual-exclusion invariant, section 6.7).
-- Every ox* handler is OnionXT's published ABI (onionxt/docs/05-api-reference.md);
-- verified statically (tools/check-livecodescript.py) and NEEDS an on-engine OXT
-- pass with a running Tor daemon before any runtime claim. See the suite's
-- docs/ONIONXT-INTEGRATION-PLAN.md section 6 and its VERIFY register (12.3).

-- Is OnionXT installed AND SodiumXT working? OnionXT depends on SodiumXT, so both
-- must be present for any anonymous transfer (even a plaintext one). A guarded
-- oxVersion() probe, mirroring chCanEncrypt.
function chHasOnion
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
end chHasOnion

-- Live, authoritative Tor readiness, re-read at the moment of use (never trust
-- the cached sTorReady for a go/no-go). oxIsReady() is true only at 100% bootstrap.
function chOnionReadyNow
   if not sHasOnion then
      return false
   end if
   return oxIsReady()
end chOnionReadyNow

function chIsAnonChannel pIndex
   return (sChannels[pIndex]["anon"] is "true")
end chIsAnonChannel

-- The channel's onion address is DERIVED from its ed25519 pubkey alone (section
-- 6.1): the follower computes the identical .onion locally from the channel card.
-- Empty when the address codec is unavailable (SodiumXT older than ABI 7) - which
-- makes chVerifyOnionIdentity fail and anon disable, fail-closed.
function chChannelOnionAddr pPubHex
   local tAddr, tErr
   try
      put oxAddressFromPublicKey(sxHex2Bin(textEncode(pPubHex, "ASCII"))) into tAddr
   catch tErr
      return ""
   end try
   if tAddr is empty or not (tAddr ends with ".onion") then
      return ""   -- a capability error string is not a valid address
   end if
   return tAddr
end chChannelOnionAddr

-- The HARD Phase-2 gate (section 6.1), run once at startup, OFFLINE (no daemon):
-- prove libtorrent's and libsodium's ed25519 seed->pubkey agree byte for byte, so
-- a follower can never derive and dial the WRONG onion. Any failure disables anon.
function chVerifyOnionIdentity
   local tSeed, tKp, tBtPub, tSxPub, tSxSec, tAddr, tRecovered, tErr
   try
      put "0000000000000000000000000000000000000000000000000000000000000000" into tSeed
      put btDhtKeypair(tSeed) into tKp
      put tKp["publicKey"] into tBtPub
      -- the real cross-impl check: btDhtKeypair vs sxSignKeypairFromSeed, byte-equal
      sxSignKeypairFromSeed sxHex2Bin(textEncode(tSeed, "ASCII")), tSxPub, tSxSec
      if sxHex2Bin(textEncode(tBtPub, "ASCII")) is not tSxPub then
         return false
      end if
      -- and the address codec is self-consistent for that key
      put chChannelOnionAddr(tBtPub) into tAddr
      if tAddr is empty then
         return false
      end if
      put oxPublicKeyFromAddress(tAddr) into tRecovered
      if tRecovered is not sxHex2Bin(textEncode(tBtPub, "ASCII")) then
         return false
      end if
   catch tErr
      return false
   end try
   return true
end chVerifyOnionIdentity

-- A 16-hex release id (section 6.5): names the release inside the feed; the .onion
-- is derived from the channel pubkey, so the locator never carries an address.
function chAllocRelId
   return toLower(textDecode(sxBin2Hex(sxRandomBytes(8)), "ASCII"))
end chAllocRelId

-- Reduce an attacker-chosen name (feed origName OR stream header) to a safe
-- filename LEAF (section 3.3): basename only, no drive/colon, no leading dots, no
-- separators or controls. Empty becomes "shared-file". Applied before opening any
-- temp and before the final move - closes path traversal / arbitrary write.
function chSafeLeaf pName
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
end chSafeLeaf

-- Byte size of a file WITHOUT loading it whole (bounded 4 MiB chunks): O(size) I/O,
-- O(1) memory. Used for the header totalLen and the large-file warning.
function chFileSize pPath
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
end chFileSize

-- A pseudo-random high loopback port for OnionXT's internal listener. A collision
-- surfaces as an oxCreateService error string, and the caller reports it.
function chPickPort
   return (20000 + random(40000))
end chPickPort

-- Move a finished plaintext temp to its real name (rename avoids a full read).
function chMoveFile pSrc, pDst
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
end chMoveFile

-- Decode a big-endian unsigned u16 / u32 from raw bytes (matches onion_frame_golden).
function chBEu16 pBytes
   return (byteToNum(byte 1 of pBytes) * 256 + byteToNum(byte 2 of pBytes))
end chBEu16

function chBEu32 pBytes
   local tA, tB, tC, tD
   put byteToNum(byte 1 of pBytes) into tA
   put byteToNum(byte 2 of pBytes) into tB
   put byteToNum(byte 3 of pBytes) into tC
   put byteToNum(byte 4 of pBytes) into tD
   return (((tA * 256 + tB) * 256 + tC) * 256 + tD)
end chBEu32

-- The section-3.3 file header: magic(4) ver(1) flags(1) nameLen(u16 BE) name(UTF-8)
-- totalLen(u64 BE as hi:u32 then lo:u32). Binary discipline throughout.
function chOnionHeader pName, pEnc, pTotal
   local tNameB, tFlags, tHi, tLo, tOut
   put textEncode(chSafeLeaf(pName), "UTF-8") into tNameB
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
end chOnionHeader

-- The section-6.4 BTXC request frame (follower -> publisher).
function chChanRequest pVerb, pKeyHex, pRelId
   local tKeyB, tIdB, tOut
   put textEncode(pKeyHex, "ASCII") into tKeyB
   put textEncode(pRelId, "ASCII") into tIdB
   put kChanReqMagic into tOut
   put numToByte(kChanReqVer) after tOut
   put numToByte(pVerb) after tOut
   put binaryEncode("n", the number of bytes in tKeyB) after tOut
   put tKeyB after tOut
   put binaryEncode("n", the number of bytes in tIdB) after tOut
   put tIdB after tOut
   return tOut
end chChanRequest

-- The section-6.4 BTXF feed frame (publisher -> follower; repeatable for push).
function chFeedFrame pValue
   local tOut
   put kFeedFrameMagic into tOut
   put numToByte(kFeedFrameVer) after tOut
   put binaryEncode("N", the number of bytes in pValue) after tOut
   put pValue after tOut
   return tOut
end chFeedFrame

-- The feed TEXT served over the onion: the normal name=/r= feed PLUS the svc=<onion>
-- corroboration/fallback line (section 6.1). Never put on the DHT.
function chAnonFeedText pIndex
   local tKp, tPub, tFeed, tAddr
   put btDhtKeypair(sChannels[pIndex]["seed"]) into tKp
   put tKp["publicKey"] into tPub
   put chBuildFeed(sChannels[pIndex]["name"], sChannels[pIndex]["releases"]) into tFeed
   put sChanServiceAddr[tPub] into tAddr
   if tAddr is empty then
      put chChannelOnionAddr(tPub) into tAddr
   end if
   if tAddr is not empty then
      put tFeed & return & "svc=" & tAddr into tFeed
   end if
   return tFeed
end chAnonFeedText

-- The channel index whose ed25519 pubkey matches pPubHex, or 0 (used to validate a
-- BTXC request names a channel WE own).
function chChannelIndexForPub pPubHex
   local tI, tKp
   repeat with tI = 1 to chChannelCount()
      put btDhtKeypair(sChannels[tI]["seed"]) into tKp
      if toLower(tKp["publicKey"]) is toLower(pPubHex) then
         return tI
      end if
   end repeat
   return 0
end chChannelIndexForPub

-- The live torrent handle whose info-hash matches pHash (lowercased), or 0.
function chFindTorrentByHash pHash
   local tCount, tI, tH, tS
   put btTorrentCount(sSession) into tCount
   repeat with tI = 0 to (tCount - 1)
      put btTorrentHandleAt(sSession, tI) into tH
      if tH is not 0 then
         put btTorrentStatus(tH) into tS
         if toLower(tS["infoHashV1"]) is pHash or toLower(tS["infoHashV2"]) is pHash then
            return tH
         end if
      end if
   end repeat
   return 0
end chFindTorrentByHash

-- ---- Tor lifecycle -----------------------------------------------------------
-- Bring up the OnionXT control connection at startup (only when sHasOnion).
-- Non-blocking: bootstrap takes tens of seconds and is surfaced by the status
-- callback + the 1 s dash pill. Connects on the stock tor control port (9051);
-- the status callback retries the Tor Browser port pair (9151) once on failure.
command chOnionStart
   if not sHasOnion then
      exit chOnionStart
   end if
   put "false" into sOnionTriedTB
   oxSetCallbackOwner the long id of me
   oxSetStatusCallback "chOnionStatus"
   oxSetPeerCallback "chOnionPeer"
   oxSetControlPort kTorControlPort
   oxSetSocksPort kTorSocksPort
   oxConnectControl
   if the result is not empty then
      chOnionTryTB
   end if
   chOnionPill
end chOnionStart

-- Retry the control connection on the Tor Browser port pair, exactly once.
command chOnionTryTB
   local tR
   if sOnionTriedTB is "true" then
      exit chOnionTryTB
   end if
   put "true" into sOnionTriedTB
   oxSetControlPort kTorControlPortTB
   oxSetSocksPort kTorSocksPortTB
   oxConnectControl
   put the result into tR
   if tR is not empty then
      chLog "No Tor control port answered on 127.0.0.1:9051 or 9151 (" & tR & ") - start Tor (or Tor Browser) and reopen this stack to use anonymous channels."
   end if
end chOnionTryTB

-- OnionXT status callback (pKind, pInfo). Coalesced bootstrap + event updates on
-- the main thread. On the FIRST transition to ready, bring anon services online.
command chOnionStatus pKind, pInfo
   local tWasReady
   put sTorReady into tWasReady
   if pKind is "control" then
      if pInfo is "authenticated" then
         chLog "Tor control connected - bootstrapping (this can take a minute)..."
      else if (pInfo is "authfailed" or pInfo is "error") then
         chOnionTryTB
      end if
   else if pKind is "serviceReady" then
      chLog "An anonymous channel is now reachable over Tor (" & pInfo & ")."
      chUpdateNowPub
   end if
   put chOnionReadyNow() into sTorReady
   if sTorReady and not tWasReady then
      chOnionBringUpServices
   end if
   chOnionPill
end chOnionStatus

-- Repaint the live Tor pill (created + repainted ONLY here so its states cannot
-- disagree). The kinds map the states semantically: ready=ok, connecting=wait,
-- and every cannot-run state=bad. The chAnon button stays enabled so a click
-- gives chSetAnon's informative answer even when Tor is absent.
command chOnionPill
   local tState, tKind
   if there is no button "chAnon" then
      exit chOnionPill
   end if
   if not sHasOnion then
      if sCanEncrypt then
         put "Tor: no extension" into tState
      else
         put "Tor: needs SodiumXT" into tState
      end if
      put "bad" into tKind
   else if not oxIsControlAuthenticated() then
      put "Tor: no daemon" into tState
      put "bad" into tKind
   else if not oxIsReady() then
      put ("Tor: connecting " & oxBootstrapProgress() & "%") into tState
      put "wait" into tKind
   else
      put "Tor: ready" into tState
      put "ok" into tKind
   end if
   uiPill "chTor", tState, "648,4,812,26", tKind
end chOnionPill

-- Tear the onion subsystem down on close, BEFORE btStopSession. All idempotent.
command chOnionStop
   local tK, tErr
   if not sHasOnion then
      exit chOnionStop
   end if
   repeat for each key tK in sOnRole
      try
         oxCloseStream tK
      catch tErr
      end try
   end repeat
   repeat for each key tK in sChanService
      try
         oxRemoveService sChanService[tK]
      catch tErr
      end try
   end repeat
   try
      oxDisconnectControl
   catch tErr
   end try
   -- sweep receive temps and the .enc temps we created for anon-encrypted serves
   -- (never the user's plaintext originals - only Enc entries are our temps)
   repeat for each key tK in sRxTmp
      try
         if sRxTmp[tK] is not empty and there is a file sRxTmp[tK] then
            delete file sRxTmp[tK]
         end if
      catch tErr
      end try
   end repeat
   repeat for each key tK in sOnionServe
      try
         if sOnionServeEnc[tK] is kFlagEnc and there is a file sOnionServe[tK] then
            delete file sOnionServe[tK]
         end if
      catch tErr
      end try
   end repeat
   put empty into sChanService
   put empty into sChanServiceAddr
   put empty into sChanServicePort
   put empty into sFeedStreams
   put empty into sFollowStream
   put empty into sOnRole
   put empty into sOnPub
   put empty into sOnReq
   put empty into sOnBuf
   put empty into sOnionServe
   put empty into sOnionServeEnc
   put empty into sOnionServeName
   put empty into sOnionServeTotal
   put empty into sOnionXfer
end chOnionStop

-- ---- publisher: per-channel onion service lifecycle (section 6.3) ------------
-- Create (idempotently) the deterministic onion service for one anon channel, on
-- its OWN ephemeral loopback port. The address is derived from the channel key, so
-- we VERIFY-on-service that the .onion the daemon produced equals the derived one
-- (section 6.1 step 4) - a mismatch is a hard safety stop.
command chOnionServiceFor pIndex
   local tKp, tPub, tPort, tSvc, tAddr, tDerived, tErr
   if not sHasOnion or not sOnionIdentityOk then
      exit chOnionServiceFor
   end if
   if not chIsAnonChannel(pIndex) then
      exit chOnionServiceFor
   end if
   if not chOnionReadyNow() then
      exit chOnionServiceFor   -- retried by chOnionBringUpServices after bootstrap
   end if
   put btDhtKeypair(sChannels[pIndex]["seed"]) into tKp
   put tKp["publicKey"] into tPub
   if sChanService[tPub] is not empty then
      exit chOnionServiceFor   -- idempotent: already up
   end if
   put chPickPort() into tPort
   oxCreateServiceFromSeed sChannels[pIndex]["seed"], kOnionVPort, tPort
   put the result into tSvc
   if tSvc is not an integer then
      chLog "Could not publish the Tor service for this anonymous channel:" && tSvc
      exit chOnionServiceFor
   end if
   put oxServiceAddress(tSvc) into tAddr
   put chChannelOnionAddr(tPub) into tDerived
   if tAddr is not empty and tDerived is not empty and tAddr is not tDerived then
      try
         oxRemoveService tSvc
      catch tErr
      end try
      put false into sOnionIdentityOk
      chLog "Anonymous channels DISABLED: the Tor service address did not match the address the channel key predicts (seed<->onion mismatch). This is a hard safety stop; public channels are unaffected."
      exit chOnionServiceFor
   end if
   put tSvc into sChanService[tPub]
   if tAddr is not empty then
      put tAddr into sChanServiceAddr[tPub]
   else
      put tDerived into sChanServiceAddr[tPub]
   end if
   put tPort into sChanServicePort[tPub]
   chLog "Publishing the Tor service for an anonymous channel - reachable in up to a minute."
end chOnionServiceFor

-- Bring every anon channel's service online (called on the first ready + each
-- 60 s tick, so services recover after a Tor restart without blocking chStart).
command chOnionBringUpServices
   local tI
   if not sHasOnion or not sOnionIdentityOk then
      exit chOnionBringUpServices
   end if
   if not chOnionReadyNow() then
      exit chOnionBringUpServices
   end if
   repeat with tI = 1 to chChannelCount()
      if chIsAnonChannel(tI) then
         chOnionServiceFor tI
      end if
   end repeat
end chOnionBringUpServices

-- Withdraw one channel's service and drop its subscribers (Off / delete / stop).
command chOnionWithdrawService pPubHex
   local tErr, tLine, tList
   put sFeedStreams[pPubHex] into tList
   repeat for each line tLine in tList
      if tLine is not empty then
         chOnionCloseStream tLine
      end if
   end repeat
   delete variable sFeedStreams[pPubHex]
   if sChanService[pPubHex] is not empty then
      try
         oxRemoveService sChanService[pPubHex]
      catch tErr
      end try
   end if
   delete variable sChanService[pPubHex]
   delete variable sChanServiceAddr[pPubHex]
   delete variable sChanServicePort[pPubHex]
end chOnionWithdrawService

-- ---- publisher: serve a follower's request (section 6.4) ---------------------
-- A follower dialed one of our channel onions. Wait for its BTXC request (which
-- names the target channel) before serving anything; refuse a non-BTXC opener.
command chOnionPeer pStream, pService, pPeerAddr
   put "serve-req" into sOnRole[pStream]
   put "" into sOnReq[pStream]
   put the milliseconds into sTxDeadline[pStream]
   oxSetStreamCallback pStream, "chOnionServeStream"
   send ("chOnionSendWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
end chOnionPeer

-- Serve-side per-stream handler. Accumulate the request; once a full BTXC has
-- arrived, dispatch it. A serve-feed subscriber and an in-flight file send send
-- nothing more, so their data events are ignored.
command chOnionServeStream pStream, pEvent, pData
   if pEvent is "data" then
      if sOnRole[pStream] is "serve-req" then
         put pData after sOnReq[pStream]
         put the milliseconds into sTxDeadline[pStream]
         if the number of bytes in sOnReq[pStream] >= 4 then
            if (byte 1 to 4 of sOnReq[pStream]) is not kChanReqMagic then
               chOnionServeAbort pStream   -- junk from a local process
               exit chOnionServeStream
            end if
         end if
         chOnionServeRequest pStream
      else if sOnRole[pStream] is "serve-file" then
         put the milliseconds into sTxDeadline[pStream]
      end if
   else if pEvent is "closed" or pEvent is "error" then
      chOnionServeAbort pStream
   end if
end chOnionServeStream

-- Parse an accumulated BTXC request and dispatch FEED / FILE. Exits early (and
-- is re-entered) until the whole self-delimiting frame has arrived.
command chOnionServeRequest pStream
   local tBuf, tVer, tVerb, tKeyLen, tKeyHex, tIdLen, tRelId, tNeed, tPub, tIdx
   put sOnReq[pStream] into tBuf
   if the number of bytes in tBuf < 8 then
      exit chOnionServeRequest
   end if
   if (byte 1 to 4 of tBuf) is not kChanReqMagic then
      chOnionServeAbort pStream
      exit chOnionServeRequest
   end if
   put byteToNum(byte 5 of tBuf) into tVer
   put byteToNum(byte 6 of tBuf) into tVerb
   put chBEu16(byte 7 to 8 of tBuf) into tKeyLen
   if tKeyLen > 128 then
      chOnionServeAbort pStream
      exit chOnionServeRequest
   end if
   put (8 + tKeyLen + 2) into tNeed
   if the number of bytes in tBuf < tNeed then
      exit chOnionServeRequest
   end if
   put textDecode(byte 9 to (8 + tKeyLen) of tBuf, "ASCII") into tKeyHex
   put chBEu16(byte (9 + tKeyLen) to (10 + tKeyLen) of tBuf) into tIdLen
   if tIdLen > 64 then
      chOnionServeAbort pStream
      exit chOnionServeRequest
   end if
   put (tNeed + tIdLen) into tNeed
   if the number of bytes in tBuf < tNeed then
      exit chOnionServeRequest
   end if
   if tIdLen > 0 then
      put textDecode(byte (11 + tKeyLen) to (10 + tKeyLen + tIdLen) of tBuf, "ASCII") into tRelId
   else
      put "" into tRelId
   end if
   if tVer is not kChanReqVer then
      chOnionServeAbort pStream
      exit chOnionServeRequest
   end if
   put toLower(tKeyHex) into tPub
   -- validate we OWN this pubkey AND it is an anon channel with a live service
   put chChannelIndexForPub(tPub) into tIdx
   if tIdx is 0 or not chIsAnonChannel(tIdx) or sChanService[tPub] is empty then
      chOnionServeAbort pStream
      exit chOnionServeRequest
   end if
   put tPub into sOnPub[pStream]
   if tVerb is kVerbFeed then
      chOnionServeFeed pStream, tIdx
      put "serve-feed" into sOnRole[pStream]
      chOnionSubscribe tPub, pStream
   else if tVerb is kVerbFile then
      chOnionServeFile pStream, tPub, tRelId
   else
      chOnionServeAbort pStream
   end if
end chOnionServeRequest

-- Build + send one BTXF feed frame for a channel (never in the clear for a private
-- channel we cannot encrypt).
command chOnionServeFeed pStream, pIndex
   local tKp, tPub, tText, tVal
   put btDhtKeypair(sChannels[pIndex]["seed"]) into tKp
   put tKp["publicKey"] into tPub
   put chAnonFeedText(pIndex) into tText
   put chFeedValue(tText, sChannels[pIndex]["pass"], tPub) into tVal
   if tVal is empty then
      exit chOnionServeFeed
   end if
   if the number of bytes in tVal > kOnionFeedCap then
      exit chOnionServeFeed
   end if
   oxWrite pStream, chFeedFrame(tVal)
end chOnionServeFeed

-- Add a feed stream as a live subscriber: de-dup by handle, cap per channel
-- (evict the oldest at the cap). Prunes happen here AND on close (section 6.4).
command chOnionSubscribe pPubHex, pStream
   local tList, tLine, tNew, tCount
   put sFeedStreams[pPubHex] into tList
   put "" into tNew
   put 0 into tCount
   repeat for each line tLine in tList
      if tLine is not empty and tLine is not pStream then
         if tNew is empty then
            put tLine into tNew
         else
            put tNew & return & tLine into tNew
         end if
         add 1 to tCount
      end if
   end repeat
   repeat while tCount >= 32
      chOnionCloseStream (line 1 of tNew)
      delete line 1 of tNew
      subtract 1 from tCount
   end repeat
   if tNew is empty then
      put pStream into tNew
   else
      put tNew & return & pStream into tNew
   end if
   put tNew into sFeedStreams[pPubHex]
end chOnionSubscribe

-- Push a fresh feed frame to every live subscriber of a channel (section 6.4).
-- Re-seals with a FRESH nonce (chFeedValue) each push - no keystream reuse (M9).
-- Dead handles are pruned here, not only lazily.
command chOnionPushFeed pPubHex
   local tIdx, tText, tVal, tFrame, tList, tLine, tNew, tErr
   if not sHasOnion then
      exit chOnionPushFeed
   end if
   put chChannelIndexForPub(pPubHex) into tIdx
   if tIdx is 0 then
      exit chOnionPushFeed
   end if
   put sFeedStreams[pPubHex] into tList
   if tList is empty then
      exit chOnionPushFeed
   end if
   put chAnonFeedText(tIdx) into tText
   put chFeedValue(tText, sChannels[tIdx]["pass"], pPubHex) into tVal
   if tVal is empty then
      exit chOnionPushFeed
   end if
   if the number of bytes in tVal > kOnionFeedCap then
      exit chOnionPushFeed
   end if
   put chFeedFrame(tVal) into tFrame
   put "" into tNew
   repeat for each line tLine in tList
      if tLine is not empty then
         oxWrite tLine, tFrame
         if the result is empty then
            if tNew is empty then
               put tLine into tNew
            else
               put tNew & return & tLine into tNew
            end if
         else
            try
               oxCloseStream tLine
            catch tErr
            end try
            chOnionServeCleanup tLine
         end if
      end if
   end repeat
   put tNew into sFeedStreams[pPubHex]
end chOnionPushFeed

-- Serve a release's bytes (section 6.4 FILE / section 3.3 sender). A missing serve
-- entry (e.g. a restart lost the map) replies with an empty header + FINISH so the
-- follower shows "release not available", never a hang.
command chOnionServeFile pStream, pPubHex, pRelId
   local tMapKey, tPath, tEnc, tName, tTotal
   put pPubHex & ":" & pRelId into tMapKey
   put sOnionServe[tMapKey] into tPath
   if tPath is empty or there is no file tPath then
      put sOnionServeName[tMapKey] into tName
      if tName is empty then
         put "unavailable" into tName
      end if
      oxWrite pStream, chOnionHeader(tName, 0, 0)
      oxWrite pStream, binaryEncode("N", 0)
      oxCloseStream pStream
      chOnionServeCleanup pStream
      exit chOnionServeFile
   end if
   put sOnionServeEnc[tMapKey] into tEnc
   put sOnionServeName[tMapKey] into tName
   put sOnionServeTotal[tMapKey] into tTotal
   put "serve-file" into sOnRole[pStream]
   put tPath into sTxPath[pStream]
   put 0 into sTxPos[pStream]
   put tTotal into sTxRemaining[pStream]
   put tName into sTxName[pStream]
   put the milliseconds into sTxDeadline[pStream]
   put tName into sOnionXfer[pStream]["name"]
   put "up" into sOnionXfer[pStream]["dir"]
   put tTotal into sOnionXfer[pStream]["total"]
   put 0 into sOnionXfer[pStream]["got"]
   put "active" into sOnionXfer[pStream]["state"]
   oxWrite pStream, chOnionHeader(tName, tEnc, tTotal)
   if the result is not empty then
      chOnionServeAbort pStream
      exit chOnionServeFile
   end if
   send ("chOnionSendPump " & pStream) to me in kOnionPumpTick milliseconds
end chOnionServeFile

-- One frame per tick (never a tight loop). The file is opened/seeked/read/closed
-- WITHIN this tick (re-open-per-read; section 3.3 step 6b), so a popular release
-- can fan out to concurrent receivers without sharing a cursor. No writability
-- gate (the quickshare false-stall lesson): pace on the timer + oxWrite's error.
command chOnionSendPump pStream
   local tWant, tSlice, tErr
   if sTxPath[pStream] is empty then
      exit chOnionSendPump
   end if
   put kOnionChunk into tWant
   if sTxRemaining[pStream] < tWant then
      put sTxRemaining[pStream] into tWant
   end if
   if tWant <= 0 then
      oxWrite pStream, binaryEncode("N", 0)   -- zero-length terminator
      put "done" into sOnionXfer[pStream]["state"]
      chLog "Served '" & sTxName[pStream] & "' over Tor."
      oxCloseStream pStream
      chOnionServeCleanup pStream
      exit chOnionSendPump
   end if
   open file sTxPath[pStream] for binary read
   if the result is not empty then
      chOnionServeAbort pStream
      exit chOnionSendPump
   end if
   seek to sTxPos[pStream] in file sTxPath[pStream]
   read from file sTxPath[pStream] for tWant
   put it into tSlice
   try
      close file sTxPath[pStream]
   catch tErr
   end try
   if tSlice is empty then
      oxWrite pStream, binaryEncode("N", 0)
      put "done" into sOnionXfer[pStream]["state"]
      oxCloseStream pStream
      chOnionServeCleanup pStream
      exit chOnionSendPump
   end if
   oxWrite pStream, (binaryEncode("N", the number of bytes in tSlice) & tSlice)
   if the result is not empty then
      chOnionServeAbort pStream
      exit chOnionSendPump
   end if
   add (the number of bytes in tSlice) to sTxPos[pStream]
   subtract (the number of bytes in tSlice) from sTxRemaining[pStream]
   put sTxPos[pStream] into sOnionXfer[pStream]["got"]
   put the milliseconds into sTxDeadline[pStream]
   send ("chOnionSendPump " & pStream) to me in kOnionPumpTick milliseconds
end chOnionSendPump

-- Idle watchdog for a serve stream, armed at accept. A serve-feed SUBSCRIBER is
-- allowed to idle between pushes (re-arm, never abort); a serve-req that never
-- sends a request, or a stalled serve-file, is aborted.
command chOnionSendWatchdog pStream
   if sOnRole[pStream] is empty then
      exit chOnionSendWatchdog
   end if
   if sOnRole[pStream] is "serve-feed" then
      send ("chOnionSendWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
      exit chOnionSendWatchdog
   end if
   if (the milliseconds - sTxDeadline[pStream]) > kOnionSendTimeout then
      chLog "An anonymous transfer stalled - closing it."
      chOnionServeAbort pStream
      exit chOnionSendWatchdog
   end if
   send ("chOnionSendWatchdog " & pStream) to me in kOnionSendTimeout milliseconds
end chOnionSendWatchdog

-- Clear serve per-stream state and drop the stream from its channel's subscriber
-- list. Keeps its sOnionXfer row (pruned in chOnionStop) so a finished/failed
-- transfer stays visible for the session.
command chOnionServeCleanup pStream
   local tErr, tPub, tLine, tNew
   try
      close file sTxPath[pStream]
   catch tErr
   end try
   put sOnPub[pStream] into tPub
   if tPub is not empty and sFeedStreams[tPub] is not empty then
      put "" into tNew
      repeat for each line tLine in sFeedStreams[tPub]
         if tLine is not empty and tLine is not pStream then
            if tNew is empty then
               put tLine into tNew
            else
               put tNew & return & tLine into tNew
            end if
         end if
      end repeat
      put tNew into sFeedStreams[tPub]
   end if
   delete variable sTxPath[pStream]
   delete variable sTxPos[pStream]
   delete variable sTxRemaining[pStream]
   delete variable sTxName[pStream]
   delete variable sTxDeadline[pStream]
   delete variable sOnReq[pStream]
   delete variable sOnRole[pStream]
   delete variable sOnPub[pStream]
end chOnionServeCleanup

command chOnionServeAbort pStream
   if sOnionXfer[pStream] is not empty then
      put "error" into sOnionXfer[pStream]["state"]
   end if
   oxCloseStream pStream
   chOnionServeCleanup pStream
end chOnionServeAbort

-- Close + fully clear any stream (either side); idempotent.
command chOnionCloseStream pStream
   local tErr
   try
      oxCloseStream pStream
   catch tErr
   end try
   chOnionServeCleanup pStream
   chOnionRecvClear pStream
end chOnionCloseStream

-- ---- publisher: turn Anonymous on/off + publish anon releases ----------------
-- Set (or clear) the whole-channel anon flag (section 6.2), modeled on chSetPrivacy.
-- Turning ON hard-blocks on any live clearnet magnet release (section 6.7 guard 6):
-- an anon badge over a still-seeding torrent is real-IP-on-the-DHT mixing.
command chSetAnon
   local tGo, tMagCount, tRel, tLoc, tSavedID, tHash, tH
   if not sHasOnion then
      answer "Anonymous channels need OnionXT + SodiumXT and a local Tor daemon (127.0.0.1:9050/9051 or 9150/9151). Public channels are unaffected."
      exit chSetAnon
   end if
   if not sOnionIdentityOk then
      answer "Anonymous channels are disabled on this machine: the libtorrent and libsodium ed25519 identities did not byte-match offline (or SodiumXT is older than ABI 7). A channel's derived .onion could be wrong, so anon is refused. Public channels work normally."
      exit chSetAnon
   end if
   answer ("Make the channel '" & chActiveName() & "' ANONYMOUS?" & return & return & \
      "An anonymous channel serves its file list AND every file over Tor: both IPs are hidden, nothing is put on the DHT or a magnet, and it is reachable from the channel card alone. The publisher must stay online for followers to reach it, large media is slow, and Tor only anonymizes BETWEEN the two onion endpoints. Compose it with Privacy (a passphrase) to also encrypt the contents and authenticate the sender - recommended.") \
      with "Cancel" or "Off" or "On"
   put it into tGo
   if tGo is "Cancel" then
      exit chSetAnon
   end if
   put the itemDelimiter into tSavedID
   if tGo is "On" then
      if chIsAnonChannel(sActive) then
         chLog "This channel is already anonymous."
         exit chSetAnon
      end if
      -- count live clearnet magnet releases; refuse until they are removed
      put 0 into tMagCount
      set the itemDelimiter to tab
      repeat for each line tRel in sChannels[sActive]["releases"]
         if tRel is not empty then
            put item 2 of tRel into tLoc
            if tLoc begins with "magnet:" then
               add 1 to tMagCount
            end if
         end if
      end repeat
      set the itemDelimiter to tSavedID
      if tMagCount > 0 then
         answer ("This channel has " & tMagCount & " public release(s) on the swarm/DHT under your real IP. Turning it anonymous while they are still seeded would MIX modes and leak your IP." & return & return & \
            "Remove those " & tMagCount & " public release(s) and stop seeding them, then make the channel anonymous?") \
            with "Cancel" or "Remove and continue"
         if it is not "Remove and continue" then
            exit chSetAnon
         end if
         set the itemDelimiter to tab
         repeat for each line tRel in sChannels[sActive]["releases"]
            if tRel is not empty then
               put item 2 of tRel into tLoc
               if tLoc begins with "magnet:" then
                  put chHashFromMagnet(tLoc) into tHash
                  if tHash is not empty then
                     put chFindTorrentByHash(tHash) into tH
                     if tH is not 0 then
                        btRemoveTorrent sSession, tH, false
                     end if
                     delete variable sMineHashes[tHash]
                  end if
               end if
            end if
         end repeat
         set the itemDelimiter to tSavedID
         -- every release was public: clear them; anon starts a fresh onion feed
         put "" into sChannels[sActive]["releases"]
         put "" into sMyReleases
         put chBuildFeed(sMyName, sMyReleases) into sMyPost
      end if
      put "true" into sChannels[sActive]["anon"]
      chSaveChannels
      chOnionServiceFor sActive
      chLog "Channel '" & chActiveName() & "' is now ANONYMOUS. Publish a file to stream it over Tor; share the channel card (it carries the anon tag). Add Privacy for encrypted, authenticated contents."
   else
      set the itemDelimiter to tSavedID
      if not chIsAnonChannel(sActive) then
         chLog "This channel is already public."
         exit chSetAnon
      end if
      put "" into sChannels[sActive]["anon"]
      chSaveChannels
      chOnionWithdrawService sPub
      get chPublishActiveFeed()   -- resume normal DHT announce for the public channel
      chLog "Channel '" & chActiveName() & "' is public again. Its (onion-less) feed re-announces on the DHT."
   end if
   chUpdateChannelMenu
   chUpdateNowPub
end chSetAnon

-- The anon replacement for chPublishFile's clearnet body (section 6.5): pick ONE
-- file, encrypt it when the channel is private (recommended), record it in the
-- in-memory serve map under a fresh relId, and publish an "onion:<relId>" locator.
-- NO btCreateTorrent / btAddTorrentFile / sMineHashes / magnet.
command chOnionPublishFile
   local tPath, tTitle, tOrig, tTotal, tEnc, tEncFlag, tStreamFile, tRelId
   local tMapKey, tRel, tKind, tErr, tSafe
   if not chOnionReadyNow() then
      chLog "Tor is still connecting - watch the pill, then Publish again."
      exit chOnionPublishFile
   end if
   chOnionServiceFor sActive
   if sChanService[sPub] is empty then
      chLog "This channel's Tor service is not up yet - wait for 'Tor: ready', then Publish again."
      exit chOnionPublishFile
   end if
   answer file "Choose a FILE to share anonymously over Tor (a folder is not supported - zip it first):"
   put it into tPath
   if tPath is empty then
      exit chOnionPublishFile
   end if
   if there is a folder tPath then
      chLog "Anonymous publishing handles one file at a time; zip the folder first."
      exit chOnionPublishFile
   end if
   replace "\" with "/" in tPath
   set the itemDelimiter to "/"
   put the last item of tPath into tOrig
   put tOrig into tTitle
   ask "Title for this release:" with tTitle
   if it is not empty then
      put it into tTitle
   end if
   replace return with space in tTitle
   replace tab with space in tTitle
   put chFileSize(tPath) into tTotal
   if tTotal is empty or tTotal < 0 then
      chLog "Could not read that file's size."
      exit chOnionPublishFile
   end if
   if tTotal > kAnonSizeWarn then
      answer ("This file is large for an anonymous Tor transfer and will be slow." & return & \
         "For big media, publish it on a PUBLIC channel instead (that reveals your IP).") with "Cancel" or "Publish over Tor anyway"
      if it is not "Publish over Tor anyway" then
         exit chOnionPublishFile
      end if
   end if
   put chSafeLeaf(tOrig) into tSafe
   put tPath into tStreamFile
   put 0 into tEncFlag
   -- compose with encryption when the channel is private (recommended): reuse the
   -- existing chFileKey / chEncryptFile path, stream the .enc under a neutral name
   if sChannels[sActive]["pass"] is not empty and sCanEncrypt then
      put chTempEncPath() into tEnc
      chLog "Encrypting '" & tTitle & "' before the anonymous transfer - the app may pause briefly on a large file..."
      put chEncryptFile(tPath, tEnc, chFileKey(sChannels[sActive]["pass"], sPub)) into tErr
      if tErr is not empty then
         chLog "Could not encrypt '" & tTitle & "':" && tErr
         try
            if there is a file tEnc then
               delete file tEnc
            end if
         catch tErr
         end try
         exit chOnionPublishFile
      end if
      put tEnc into tStreamFile
      put kFlagEnc into tEncFlag
      put chFileSize(tEnc) into tTotal
   end if
   put chAllocRelId() into tRelId
   put sPub & ":" & tRelId into tMapKey
   put tStreamFile into sOnionServe[tMapKey]
   put tEncFlag into sOnionServeEnc[tMapKey]
   put tSafe into sOnionServeName[tMapKey]
   put tTotal into sOnionServeTotal[tMapKey]
   if tEncFlag is kFlagEnc then
      put chTrunc(tTitle, 60) & tab & ("onion:" & tRelId) & tab & "enc" & tab & tOrig into tRel
      put "ANONENC" into tKind
   else
      put chTrunc(tTitle, 60) & tab & ("onion:" & tRelId) into tRel
      put "ANON" into tKind
   end if
   chAddReleaseAndPublish tRel, tTitle, tKind
end chOnionPublishFile

-- ---- follower: fetch the feed + files over the onion (section 6.4 / 6.5) ------
-- The onion address for a followed key: derived from the pubkey (primary), or the
-- feed's svc= line (fallback if the derivation ever fell back; section 6.1).
function chOnionAddrForKey pKey
   local tAddr
   put chChannelOnionAddr(pKey) into tAddr
   if tAddr is empty or not oxIsValidAddress(tAddr) then
      if sFollowSvc[pKey] is not empty then
         return sFollowSvc[pKey]
      end if
      return ""
   end if
   return tAddr
end chOnionAddrForKey

-- Dial an anon channel's onion and subscribe to its feed. Fail-closed at every
-- step: never a swarm fallback. Writes a name= placeholder for the offline cases
-- (section 6.8) that chRefreshSubs renders, retried on the 60 s tick.
command chOnionFollowFetch pKey
   local tAddr, tStream, tConfirmed
   if not sHasOnion then
      exit chOnionFollowFetch
   end if
   -- a placeholder is only written for a CONFIRMED anon follow; a stripped-card
   -- PROBE (section 6.8, pKey not yet marked anon) must not overwrite the feed of
   -- what might be a genuinely public, just-slow channel - a success promotes it
   -- via chApplyAnonFeed, a failure stays silent.
   put (sFollowAnon[pKey] is "true") into tConfirmed
   if not chOnionReadyNow() then
      if tConfirmed then
         put ("name=" & chShortKey(pKey) & " (anonymous - Tor still connecting)") into sFollowFeeds[pKey]
         chRefreshSubs
      end if
      exit chOnionFollowFetch
   end if
   if sFollowStream[pKey] is not empty then
      exit chOnionFollowFetch   -- a live subscription already keeps the feed fresh
   end if
   put chOnionAddrForKey(pKey) into tAddr
   if tAddr is empty then
      if tConfirmed then
         put ("name=" & chShortKey(pKey) & " (anonymous - no valid address)") into sFollowFeeds[pKey]
         chRefreshSubs
      end if
      exit chOnionFollowFetch
   end if
   oxDial tAddr, kOnionVPort
   put the result into tStream
   if tStream is not an integer then
      if tConfirmed then
         put ("name=" & chShortKey(pKey) & " (anonymous - offline)") into sFollowFeeds[pKey]
         chRefreshSubs
         chLog "Channel " & chShortKey(pKey) & " is anonymous and its publisher is not reachable over Tor right now (" & tStream & "). Its releases appear when it comes online."
      end if
      exit chOnionFollowFetch
   end if
   put tStream into sFollowStream[pKey]
   put "follow-feed" into sOnRole[tStream]
   put pKey into sOnPub[tStream]
   put "" into sOnBuf[tStream]
   put chChanRequest(kVerbFeed, pKey, "") into sOnReq[tStream]   -- sent on "open"
   put the milliseconds into sRxDeadline[tStream]
   oxSetStreamCallback tStream, "chOnionFetchStream"
   send ("chOnionRecvWatchdog " & tStream) to me in kOnionRecvTimeout milliseconds
end chOnionFollowFetch

-- Dial an anon channel's onion and request ONE release's bytes (section 6.5).
command chOnionDownload pKey, pRelId, pTitle, pEnc, pOrigName
   local tAddr, tStream, tName
   if not sHasOnion then
      chLog "This is an anonymous release, but OnionXT + SodiumXT are not installed here."
      exit chOnionDownload
   end if
   if not chOnionReadyNow() then
      chLog "Tor still connecting - try Download again in a moment."
      exit chOnionDownload
   end if
   put chOnionAddrForKey(pKey) into tAddr
   if tAddr is empty then
      chLog "Could not resolve that anonymous channel's Tor address."
      exit chOnionDownload
   end if
   oxDial tAddr, kOnionVPort
   put the result into tStream
   if tStream is not an integer then
      chLog "Could not open a Tor connection to that channel:" && tStream
      exit chOnionDownload
   end if
   put chSafeLeaf(pOrigName) into tName
   if tName is "shared-file" and pTitle is not empty then
      put chSafeLeaf(pTitle) into tName
   end if
   put "download" into sOnRole[tStream]
   put pKey into sOnPub[tStream]
   put chChanRequest(kVerbFile, pKey, pRelId) into sOnReq[tStream]   -- sent on "open"
   put "header" into sRxState[tStream]
   put "" into sRxBuf[tStream]
   put 0 into sRxGot[tStream]
   put tName into sRxName[tStream]
   put chDefaultSave() into sRxSave[tStream]
   if pEnc is "enc" then
      put chFileKey(sFollowPass[pKey], pKey) into sRxKey[tStream]
   else
      put "" into sRxKey[tStream]
   end if
   put the milliseconds into sRxDeadline[tStream]
   put tName into sOnionXfer[tStream]["name"]
   put "down" into sOnionXfer[tStream]["dir"]
   put 0 into sOnionXfer[tStream]["total"]
   put 0 into sOnionXfer[tStream]["got"]
   put "connecting" into sOnionXfer[tStream]["state"]
   oxSetStreamCallback tStream, "chOnionFetchStream"
   send ("chOnionRecvWatchdog " & tStream) to me in kOnionRecvTimeout milliseconds
   chLog "Downloading '" & pTitle & "' anonymously over Tor..."
end chOnionDownload

-- Fetch-side per-stream handler (dialed streams). On "open", send the pending BTXC
-- request; on "data", route to the BTXF feed parser or the BTXO file receiver.
command chOnionFetchStream pStream, pEvent, pData
   if pEvent is "open" then
      if sOnReq[pStream] is not empty then
         oxWrite pStream, sOnReq[pStream]
         put "" into sOnReq[pStream]
      end if
      put the milliseconds into sRxDeadline[pStream]
   else if pEvent is "data" then
      if sOnRole[pStream] is "follow-feed" then
         chOnionFeedData pStream, pData
      else if sOnRole[pStream] is "download" then
         chOnionRecvData pStream, pData
      end if
   else if pEvent is "closed" or pEvent is "error" then
      if sOnRole[pStream] is "download" then
         if sRxState[pStream] is not "done" and sRxState[pStream] is not empty then
            chOnionRecvAbort pStream, "The publisher went offline before the anonymous download finished. Try again."
         end if
      else if sOnRole[pStream] is "follow-feed" then
         chOnionFetchClear pStream   -- the next tick re-dials
      end if
   end if
end chOnionFetchStream

-- Clear a fetch stream's state and, for a feed stream, drop its follow mapping so
-- the next tick reconnects.
command chOnionFetchClear pStream
   local tKey
   put sOnPub[pStream] into tKey
   if tKey is not empty and sFollowStream[tKey] is pStream then
      delete variable sFollowStream[tKey]
   end if
   delete variable sOnBuf[pStream]
   delete variable sOnReq[pStream]
   delete variable sOnRole[pStream]
   delete variable sOnPub[pStream]
end chOnionFetchClear

command chOnionFetchAbort pStream, pMsg
   local tErr
   try
      oxCloseStream pStream
   catch tErr
   end try
   chOnionFetchClear pStream
   if pMsg is not empty then
      chLog pMsg
   end if
end chOnionFetchAbort

-- BTXF feed-frame parser (section 6.4), draining every complete frame each call so
-- a real-time push reassembles across reads. Each value goes through the EXISTING
-- chReadFeed (plaintext / LOCKED / BADPASS) - only the byte source moved.
command chOnionFeedData pStream, pData
   local tBuf, tVer, tValLen, tNeed, tValue, tKey, tFeed
   put pData after sOnBuf[pStream]
   put the milliseconds into sRxDeadline[pStream]
   put sOnPub[pStream] into tKey
   repeat
      put sOnBuf[pStream] into tBuf
      if the number of bytes in tBuf < 9 then
         exit repeat
      end if
      if (byte 1 to 4 of tBuf) is not kFeedFrameMagic then
         chOnionFetchAbort pStream, "Unexpected data on the anonymous feed stream (bad magic)."
         exit chOnionFeedData
      end if
      put byteToNum(byte 5 of tBuf) into tVer
      if tVer is not kFeedFrameVer then
         chOnionFetchAbort pStream, "Unsupported anonymous feed frame version."
         exit chOnionFeedData
      end if
      put chBEu32(byte 6 to 9 of tBuf) into tValLen
      if tValLen > kOnionFeedCap then
         chOnionFetchAbort pStream, "Anonymous feed frame too large - aborting."
         exit chOnionFeedData
      end if
      put (9 + tValLen) into tNeed
      if the number of bytes in tBuf < tNeed then
         exit repeat
      end if
      put byte 10 to (9 + tValLen) of tBuf into tValue
      delete byte 1 to (9 + tValLen) of sOnBuf[pStream]
      put chReadFeed(tValue, sFollowPass[tKey], tKey) into tFeed
      chApplyAnonFeed tKey, tFeed
   end repeat
end chOnionFeedData

-- Apply a feed that arrived over Tor (mirrors the dhtMutableItem handler). Also
-- PROMOTES a stripped-card follow to anon now that it proved onion-only (section
-- 6.8), so the tick stops doing DHT gets for it.
command chApplyAnonFeed pKey, pFeed
   local tN
   delete variable sFeedWait[pKey]
   delete variable sFeedHinted[pKey]
   if sFollowAnon[pKey] is not "true" then
      put "true" into sFollowAnon[pKey]
      set the uFollowAnon of this stack to arrayEncode(sFollowAnon)
      chPrefSave
   end if
   if pFeed is "LOCKED" then
      put ("name=" & chShortKey(pKey) & " (private - needs passphrase)") into sFollowFeeds[pKey]
      chRefreshSubs
      chLog "Anonymous channel " & chShortKey(pKey) & " is private. Follow again with its passphrase to read it."
   else if pFeed is "BADPASS" then
      put ("name=" & chShortKey(pKey) & " (wrong passphrase)") into sFollowFeeds[pKey]
      chRefreshSubs
      chLog "Anonymous channel " & chShortKey(pKey) & ": that passphrase did not unlock the feed."
   else
      put pFeed into sFollowFeeds[pKey]
      chRefreshSubs
      put chCountReleases(pFeed) into tN
      chLog "Anonymous feed " & chShortKey(pKey) & ": verified over Tor," && tN && "release(s)."
   end if
end chApplyAnonFeed

-- ---- follower: the section-3.3 BTXO file receiver ----------------------------
command chOnionRecvData pStream, pData
   local tNameLen, tName, tHi, tLo, tTotal, tFlags, tLen, tPayload
   if sRxState[pStream] is empty or sRxState[pStream] is "done" then
      exit chOnionRecvData
   end if
   put pData after sRxBuf[pStream]
   put the milliseconds into sRxDeadline[pStream]
   if sRxState[pStream] is "header" then
      if the number of bytes in sRxBuf[pStream] < 8 then
         exit chOnionRecvData
      end if
      if (byte 1 to 4 of sRxBuf[pStream]) is not kOnionMagic then
         chOnionRecvAbort pStream, "Unexpected data on the Tor stream (bad magic)."
         exit chOnionRecvData
      end if
      if byteToNum(byte 5 of sRxBuf[pStream]) is not kOnionVer then
         chOnionRecvAbort pStream, "Unsupported Tor stream version."
         exit chOnionRecvData
      end if
      put byteToNum(byte 6 of sRxBuf[pStream]) into tFlags
      put chBEu16(byte 7 to 8 of sRxBuf[pStream]) into tNameLen
      if tNameLen > kOnionMaxName then
         chOnionRecvAbort pStream, "Tor stream header looks malformed (name too long)."
         exit chOnionRecvData
      end if
      if the number of bytes in sRxBuf[pStream] < (8 + tNameLen + 8) then
         exit chOnionRecvData
      end if
      put textDecode(byte 9 to (8 + tNameLen) of sRxBuf[pStream], "UTF-8") into tName
      put chBEu32(byte (9 + tNameLen) to (12 + tNameLen) of sRxBuf[pStream]) into tHi
      put chBEu32(byte (13 + tNameLen) to (16 + tNameLen) of sRxBuf[pStream]) into tLo
      put (tHi * 4294967296 + tLo) into tTotal
      if tTotal > kOnionMaxTotal then
         chOnionRecvAbort pStream, "Refusing an oversized Tor transfer."
         exit chOnionRecvData
      end if
      if sRxKey[pStream] is not empty and (tFlags bitAnd kFlagEnc) is 0 then
         chOnionRecvAbort pStream, "This release was supposed to be encrypted but arrived unencrypted - do not trust it."
         exit chOnionRecvData
      end if
      if (tFlags bitAnd kFlagEnc) is not 0 and sRxKey[pStream] is empty then
         chOnionRecvAbort pStream, "This release is encrypted but no passphrase is set - Follow the channel again with its passphrase."
         exit chOnionRecvData
      end if
      put (tFlags bitAnd kFlagEnc) into sRxEnc[pStream]
      if tName is not empty then
         put chSafeLeaf(tName) into sRxName[pStream]
      end if
      put tTotal into sRxTotal[pStream]
      put tTotal into sOnionXfer[pStream]["total"]
      put 0 into sRxGot[pStream]
      put chTempEncPath() into sRxTmp[pStream]
      open file sRxTmp[pStream] for binary write
      if the result is not empty then
         chOnionRecvAbort pStream, "Could not open a temp file to receive into."
         exit chOnionRecvData
      end if
      delete byte 1 to (16 + tNameLen) of sRxBuf[pStream]
      put "body" into sRxState[pStream]
      put "active" into sOnionXfer[pStream]["state"]
   end if
   repeat while sRxState[pStream] is "body"
      if the number of bytes in sRxBuf[pStream] < 4 then
         exit repeat
      end if
      put chBEu32(byte 1 to 4 of sRxBuf[pStream]) into tLen
      if tLen is 0 then
         delete byte 1 to 4 of sRxBuf[pStream]
         put "done" into sRxState[pStream]
         exit repeat
      end if
      if tLen > kOnionChunk then
         chOnionRecvAbort pStream, "Tor stream frame too large - aborting."
         exit chOnionRecvData
      end if
      if the number of bytes in sRxBuf[pStream] < (4 + tLen) then
         exit repeat
      end if
      put byte 5 to (4 + tLen) of sRxBuf[pStream] into tPayload
      write tPayload to file sRxTmp[pStream]
      if the result is not empty then
         chOnionRecvAbort pStream, "Could not write the received data to disk:" && the result
         exit chOnionRecvData
      end if
      add tLen to sRxGot[pStream]
      put sRxGot[pStream] into sOnionXfer[pStream]["got"]
      delete byte 1 to (4 + tLen) of sRxBuf[pStream]
   end repeat
   -- belt and suspenders: finish on the byte count even if the terminator is lost
   if sRxState[pStream] is "body" and sRxGot[pStream] >= sRxTotal[pStream] then
      put "done" into sRxState[pStream]
   end if
   if sRxState[pStream] is "done" then
      chOnionRecvFinish pStream
   end if
end chOnionRecvData

command chOnionRecvFinish pStream
   local tSave, tOut, tErr, tErr2
   close file sRxTmp[pStream]
   if sRxGot[pStream] is not sRxTotal[pStream] then
      chOnionRecvAbort pStream, "The anonymous download ended early (incomplete) - nothing was saved."
      exit chOnionRecvFinish
   end if
   put sRxSave[pStream] into tSave
   put tSave & "/" & chSafeLeaf(sRxName[pStream]) into tOut
   if sRxEnc[pStream] is not 0 then
      put chDecryptFile(sRxTmp[pStream], tOut, sRxKey[pStream]) into tErr
      try
         if there is a file sRxTmp[pStream] then
            delete file sRxTmp[pStream]
         end if
      catch tErr2
      end try
      if tErr is not empty then
         put "error" into sOnionXfer[pStream]["state"]
         chLog "Downloaded over Tor but could not unlock '" & sRxName[pStream] & "':" && tErr
         chOnionRecvClear pStream
         oxCloseStream pStream
         exit chOnionRecvFinish
      end if
   else
      put chMoveFile(sRxTmp[pStream], tOut) into tErr
      if tErr is not empty then
         put "error" into sOnionXfer[pStream]["state"]
         chLog "Downloaded over Tor but could not save the file:" && tErr
         chOnionRecvClear pStream
         oxCloseStream pStream
         exit chOnionRecvFinish
      end if
   end if
   put "done" into sOnionXfer[pStream]["state"]
   chLog "Received '" & sRxName[pStream] & "' anonymously over Tor into" && tSave & "."
   chOnionRecvClear pStream
   oxCloseStream pStream
end chOnionRecvFinish

command chOnionRecvClear pStream
   delete variable sRxBuf[pStream]
   delete variable sRxState[pStream]
   delete variable sRxTmp[pStream]
   delete variable sRxName[pStream]
   delete variable sRxEnc[pStream]
   delete variable sRxTotal[pStream]
   delete variable sRxGot[pStream]
   delete variable sRxKey[pStream]
   delete variable sRxSave[pStream]
   delete variable sRxDeadline[pStream]
   delete variable sOnRole[pStream]
   delete variable sOnPub[pStream]
   delete variable sOnReq[pStream]
   delete variable sOnBuf[pStream]
end chOnionRecvClear

command chOnionRecvAbort pStream, pMsg
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
   put "error" into sOnionXfer[pStream]["state"]
   chLog pMsg
   chOnionRecvClear pStream
   oxCloseStream pStream
end chOnionRecvAbort

-- Idle watchdog for a fetch stream (armed at dial). A follow-feed SUBSCRIPTION
-- idles between pushes, so it only gives up after long silence (the publisher
-- likely went away) and the next tick re-dials; a download aborts on a stall.
command chOnionRecvWatchdog pStream
   local tGap
   if sOnRole[pStream] is empty then
      exit chOnionRecvWatchdog
   end if
   put (the milliseconds - sRxDeadline[pStream]) into tGap
   if sOnRole[pStream] is "follow-feed" then
      if tGap > (2 * kOnionRecvTimeout) then
         chOnionFetchAbort pStream, ""
         exit chOnionRecvWatchdog
      end if
      send ("chOnionRecvWatchdog " & pStream) to me in kOnionRecvTimeout milliseconds
      exit chOnionRecvWatchdog
   end if
   if tGap > kOnionRecvTimeout then
      chOnionRecvAbort pStream, "The anonymous (Tor) download stalled - closing it. Try again."
      exit chOnionRecvWatchdog
   end if
   send ("chOnionRecvWatchdog " & pStream) to me in kOnionRecvTimeout milliseconds
end chOnionRecvWatchdog

-- The row state text for an onion transfer.
function chOnionXferState pOx
   if pOx["state"] is "done" then
      return "onion done"
   end if
   if pOx["state"] is "error" then
      return "onion error"
   end if
   if pOx["dir"] is "up" then
      return "onion up"
   end if
   return "onion down"
end chOnionXferState

-- On startup an in-memory serve map is empty, so an anon channel's stored
-- onion:<relId> releases can no longer be served (section 6.5). Prune them (the
-- demo default) with a log, so a restarted publisher never advertises a release
-- it cannot deliver.
command chPruneStrandedAnon
   local tI, tRel, tLoc, tKept, tPruned, tSavedID, tChanged
   if chChannelCount() is 0 then
      exit chPruneStrandedAnon
   end if
   put 0 into tPruned
   put false into tChanged
   put the itemDelimiter into tSavedID
   repeat with tI = 1 to chChannelCount()
      if chIsAnonChannel(tI) then
         put "" into tKept
         set the itemDelimiter to tab
         repeat for each line tRel in sChannels[tI]["releases"]
            if tRel is not empty then
               put item 2 of tRel into tLoc
               if tLoc begins with "onion:" then
                  add 1 to tPruned
               else
                  if tKept is empty then
                     put tRel into tKept
                  else
                     put tKept & return & tRel into tKept
                  end if
               end if
            end if
         end repeat
         set the itemDelimiter to tSavedID
         if tKept is not sChannels[tI]["releases"] then
            put tKept into sChannels[tI]["releases"]
            put true into tChanged
         end if
      end if
   end repeat
   set the itemDelimiter to tSavedID
   if tChanged then
      chSaveChannels
      chActivate sActive   -- refresh the cache for the (possibly pruned) active channel
      chLog "* " & tPruned & " anonymous release(s) could not be restored after restart (their files are no longer served); re-publish them."
   end if
end chPruneStrandedAnon

function chTrackers
   return "udp://tracker.opentrackr.org:1337/announce"
end chTrackers

function chDefaultSave
   local tBase
   put specialFolderPath("documents") into tBase
   if tBase is empty then
      put specialFolderPath("desktop") into tBase
   end if
   return tBase & "/torrentxt-channels"
end chDefaultSave

function chSelectedLine
   local tNum
   set the itemDelimiter to comma   -- the hilitedLines is comma-delimited; itemDelimiter is global
   put item 1 of (the hilitedLines of field "chSubs") into tNum
   if tNum is empty or tNum is not a number then
      return 0
   end if
   return tNum
end chSelectedLine

function chSelectedMagnet
   local tL
   put chSelectedLine() into tL
   if tL is 0 then
      return ""
   end if
   return sFeedMag[tL]
end chSelectedMagnet

function chShortKey pKey
   if the number of chars of pKey < 14 then
      return pKey
   end if
   return (char 1 to 8 of pKey) & ".." & (char -4 to -1 of pKey)
end chShortKey

function chStateName pState
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
end chStateName

-- count the "r=" release lines in a channel feed value
function chCountReleases pFeed
   local tLine, tN
   put 0 into tN
   repeat for each line tLine in pFeed
      if tLine begins with "r=" then
         add 1 to tN
      end if
   end repeat
   return tN
end chCountReleases

function chFmtBytes pBytes
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
end chFmtBytes

function chTrunc pText, pLen
   if the number of chars of pText <= pLen then
      return pText
   end if
   return (char 1 to (pLen - 1) of pText) & "..."
end chTrunc

function chTrim pText
   local tT
   put pText into tT
   repeat while tT begins with space or tT begins with tab or tT begins with return
      delete char 1 of tT
   end repeat
   repeat while tT ends with space or tT ends with tab or tT ends with return
      delete the last char of tT
   end repeat
   return tT
end chTrim

command chLog pMsg
   if there is no field "chLog" then
      exit chLog
   end if
   put the time & "  " & pMsg & return after field "chLog"
   if the number of lines of field "chLog" > 250 then
      delete line 1 to (the number of lines of field "chLog" - 250) of field "chLog"
   end if
   set the vScroll of field "chLog" to the formattedHeight of field "chLog"
end chLog
