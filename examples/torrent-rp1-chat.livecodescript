script "rp1ChatApp"

-- torrent-rp1-chat.livecodescript - a two-machine test harness for the rp1
-- custom BEP10 extension (the Riptide transport). It is the smallest thing that
-- exercises the WHOLE peer-wire path end to end:
--
--   btRp1Enable      -> turn the rp1 extension on for the session
--   btAddInfohash    -> join a metadata-less "phantom swarm" at a room id
--   btDhtAnnounce    -> advertise ourselves at that id so the other side finds us
--   (DHT rendezvous)  the two phantom swarms auto-connect peer to peer
--   rp1Handshake     -> each side learns the other is rp1-capable
--   btRp1Send /      -> opaque bytes travel under the rp1 extension id, with NO
--   rp1Message          tracker, NO server, and NO content
--
-- This is a PLAINTEXT chat on purpose: the point is to watch the transport work,
-- so what crosses the wire is exactly what you type. Riptide layers its crypto
-- (SodiumXT sxSecretStream) on top of this same btRp1Send/rp1Message channel; the
-- transport under test here is identical.
--
-- HOW TO USE (two machines, ideally on different networks):
--   1. Install the TorrentXT extension on both, paste this script into a stack,
--      and reopen the stack (that fires openStack and builds the UI).
--   2. On BOTH sides type the SAME room name (any shared phrase) and click Join.
--   3. Give the DHT a few seconds to introduce the peers. When you see
--      "Peer N is rp1-capable" on both sides, type a message and Send.
--   4. The message appears on the other machine. That round trip is the proof.
--
-- One live peer is required to see anything, which is why this ships as a demo to
-- run on the engine rather than a unit test: the native framing and control paths
-- are covered by tests/torrent_smoke_test.cpp, but the actual peer exchange only
-- happens between two running instances.
--
-- HONESTY (the suite convention): the rp1 surface is engine-proven in the
-- member selftest, but this stack's two-machine exchange has no recorded
-- engine run and the UI was unified onto the suite kit 2026-08-14 - verified
-- statically; needs an OXT pass (the closing pass's section D is this same
-- leg).
--
-- THE LOOK is the suite UI kit, carried verbatim between the marker lines
-- (master: tools/ui-kit.livecodescript; the drift gate holds every copy
-- byte-identical). Change the look in the master, never here.

-- Bump when the generated UI changes so a saved stack rebuilds its controls.
constant kRcUiVersion = "rp1-kit2-1"
-- Seconds of joined-but-peerless silence before the watchdog names the usual
-- causes (the wait itself continues - a peer can still arrive late).
constant kRcLonelySecs = 45

-- ---- script-local state (declared at top) ------------------------------------
local sSession        -- the live session handle (0/empty = none)
local sPolling        -- "true" while the poll loops are armed
local sRoomId         -- the 40-hex rendezvous id we joined (empty = not joined)
local sTorrent        -- the phantom-swarm torrent handle
local sPeers          -- array peerId -> "1" for rp1-capable connected peers
local sJoinedAt       -- ms clock when Join succeeded (drives the watchdog)
local sLonelyHinted   -- "true" once the no-peer hint has been given for this join

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
on preOpenStack
   -- build before first paint so the window never flashes unstyled
   rcBuild
end preOpenStack

on openStack
   rcBuild
   rcStart
   -- LAST, not first: the check reads the state rcStart establishes.
   rcScRun
end openStack

on closeStack
   rcStop
end closeStack

on shutdownRequest
   -- a quit does not always deliver closeStack, and a leaked session blocks
   -- the whole process (one session per process)
   rcStop
   pass shutdownRequest
end shutdownRequest

on mouseUp
   switch the short name of the target
      case "rcJoin"
         rcJoin
         break
      case "rcSend"
         rcSendMessage
         break
      default
         pass mouseUp
   end switch
end mouseUp

-- Enter in the message box sends; Enter in the room box joins.
on returnInField
   switch the short name of the target
      case "rcMsg"
         rcSendMessage
         break
      case "rcRoom"
         rcJoin
         break
      default
         pass returnInField
   end switch
end returnInField

-- ---- self-building UI (idempotent; rebuilds on a version bump) ----------------
command rcBuild
   if the uUiVersion of this stack is kRcUiVersion and there is a field "rcMsg" then
      exit rcBuild
   end if
   rcClearGeneratedUI
   lock screen
   uiChrome "rp1 chat - serverless peer-to-peer over a phantom swarm", 560, 576
   uiCap "rcTagline", "Type the SAME room name on two machines and Join. No tracker, no server, no content - the DHT introduces you and messages ride the rp1 BEP10 extension.", "16,56,544,92"
   -- room + name + join
   uiCap "rcRoomCap", "Room (a shared phrase, or a 40-hex id):", "16,96,360,114"
   uiInput "rcRoom", "16,118,400,142"
   uiButton "rcJoin", "Join", "410,116,544,146"
   uiCap "rcNameCap", "Your name:", "16,152,120,170"
   uiInput "rcName", "120,150,300,174"
   -- combined event + chat log (the status line is the kit's, under the band)
   uiArea "rcLog", "16,182,544,476"
   -- message box + send
   uiInput "rcMsg", "16,484,420,510"
   uiButton "rcSend", "Send", "430,482,544,512"
   uiFooter \
         "PLAINTEXT on purpose: what you type is what crosses the wire, so" \
         & " you can watch the transport work. Riptide layers its crypto on" \
         & " this same channel. Verified statically; needs an OXT pass.", \
         "16,518,544,570"
   rcAddTips
   set the uUiVersion of this stack to kRcUiVersion
   unlock screen
end rcBuild

command rcClearGeneratedUI
   local tI
   lock screen
   repeat with tI = the number of fields of this card down to 1
      if the short name of field tI of this card begins with "rc" then
         delete field tI of this card
      end if
   end repeat
   repeat with tI = the number of buttons of this card down to 1
      if the short name of button tI of this card begins with "rc" then
         delete button tI of this card
      end if
   end repeat
   unlock screen
end rcClearGeneratedUI

command rcAddTips
   set the tooltip of field "rcRoom" to "A phrase both sides share becomes the rendezvous id (its SHA-1). Or paste a 40-hex id directly."
   set the tooltip of button "rcJoin" to "Join the phantom swarm for this room and start looking for peers."
   set the tooltip of field "rcName" to "A display name prepended to your messages."
   set the tooltip of field "rcMsg" to "Type a message and press Enter (or Send) to broadcast it to every rp1 peer in the room."
end rcAddTips

-- ---- session + poll loops ----------------------------------------------------
command rcStart
   btStartSession
   put the result into sSession
   if sSession is 0 or sSession is empty then
      rcLog "Could not start a session (is another TorrentXT stack open?):" && btLastError()
      uiStatus "No session (another TorrentXT stack open?) - see the log.", "bad"
      put 0 into sSession
      exit rcStart
   end if
   btSetBool sSession, "enable_dht", true
   btSetBool sSession, "enable_lsd", true
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   -- turn on rp1 BEFORE adding the swarm, so the swarm advertises the
   -- extension. This call IS the demo - a refused enable would previously
   -- have "worked" all the way to two peers ignoring each other.
   btRp1Enable sSession
   if the result is not empty and the result < 0 then
      rcLog "Could not enable rp1 (" & the result & "):" && btLastError()
      uiStatus "rp1 enable FAILED - see the log.", "bad"
      exit rcStart
   end if
   put "true" into sPolling
   put empty into sPeers
   rcLog "Ready. Type a room name and Join. Then wait for the DHT to find a peer."
   uiStatus "Ready. Type a room name and Join.", "ok"
   send "rcPollOnce" to me in 0 milliseconds
   send "rcDashOnce" to me in 800 milliseconds
end rcStart

command rcStop
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      btStopSession sSession
   end if
   put empty into sSession
   put empty into sRoomId
   put empty into sPeers
end rcStop

-- Join a room: derive the 40-hex rendezvous id, add the phantom swarm, and
-- announce ourselves so the other side's DHT lookup finds us.
command rcJoin
   local tRoom, tName
   if sSession is 0 or sSession is empty then
      rcLog "No session; cannot join."
      exit rcJoin
   end if
   put rcTrim(the text of field "rcRoom") into tRoom
   if tRoom is empty then
      rcLog "Type a room name first."
      exit rcJoin
   end if
   put rcRoomId(tRoom) into sRoomId
   -- a phantom swarm has no real data; any valid save path will do
   put rcSaveFolder() into tName
   put btAddInfohash(sSession, sRoomId, tName) into sTorrent
   if sTorrent is 0 or sTorrent is empty then
      rcLog "Could not join the room:" && btLastError()
      exit rcJoin
   end if
   -- advertise ourselves at the id right away (the torrent also announces on its
   -- own DHT schedule; this just makes the first meeting faster)
   btDhtAnnounce sSession, sRoomId, 0
   if the result is not empty and the result < 0 then
      rcLog "* announce refused (" & the result & "):" && btLastError() && "- the torrent's own schedule still announces"
   end if
   put empty into sPeers
   put the milliseconds into sJoinedAt
   put empty into sLonelyHinted
   rcLog "Joined room" && tRoom & "  (id" && sRoomId & ")."
   rcLog "Waiting for a peer... give the DHT a few seconds."
   uiStatus "In the room - waiting for a peer...", empty
end rcJoin

command rcPollOnce
   local tEvents, tEvent
   -- pin the stack: a `send ... in` tick has no defaultStack guarantee, and every
   -- control this reaches is named unqualified (OXT-ENGINE-NOTES 5.3)
   set the defaultStack to the short name of this stack
   if sPolling is not "true" then
      exit rcPollOnce
   end if
   if sSession is 0 or sSession is empty then
      exit rcPollOnce
   end if
   -- drain the normal event stream (DHT/torrent) for status...
   put btPoll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      if tEvent["name"] is "dhtBootstrap" then
         rcLog "DHT is up."
      end if
   end repeat
   -- ...and the rp1 event stream (peer up/down, handshake, message)
   put btRp1Poll(sSession) into tEvents
   repeat for each element tEvent in tEvents
      rcHandleRp1 tEvent
   end repeat
   send "rcPollOnce" to me in 200 milliseconds
end rcPollOnce

-- One rp1 event. The peer id is stable for the connection's lifetime, so we key
-- our send list on it and clear it on disconnect.
command rcHandleRp1 pEvent
   local tName, tPeer, tMsg
   put pEvent["name"] into tName
   put pEvent["peer"] into tPeer
   switch tName
      case "rp1PeerConnected"
         rcLog "* peer" && tPeer && "connected (" & pEvent["endpoint"] & ")"
         break
      case "rp1Handshake"
         if pEvent["supportsRp1"] is "1" then
            put "1" into sPeers[tPeer]
            rcLog "* peer" && tPeer && "is rp1-capable - you can chat now"
         else
            rcLog "* peer" && tPeer && "is not rp1-capable (ignored)"
         end if
         break
      case "rp1Message"
         put textDecode(pEvent["payload"], "utf-8") into tMsg
         rcChatLine tMsg
         break
      case "rp1PeerDisconnected"
         delete variable sPeers[tPeer]
         rcLog "* peer" && tPeer && "left"
         break
   end switch
end rcHandleRp1

-- Broadcast the message box to every rp1-capable peer in the room.
command rcSendMessage
   local tBody, tName, tLine, tPeer, tSent
   if sSession is 0 or sSession is empty then
      exit rcSendMessage
   end if
   put rcTrim(the text of field "rcMsg") into tBody
   if tBody is empty then
      exit rcSendMessage
   end if
   if the number of lines of the keys of sPeers is 0 then
      rcLog "No rp1 peers yet - wait for a handshake before sending."
      exit rcSendMessage
   end if
   put rcTrim(the text of field "rcName") into tName
   if tName is empty then
      put "me" into tName
   end if
   put tName & ": " & tBody into tLine
   put 0 into tSent
   repeat for each key tPeer in sPeers
      btRp1Send sSession, tPeer, textEncode(tLine, "utf-8")
      -- count only what the binding ACCEPTED: the old version incremented
      -- unconditionally, so a total send failure still read as success
      if the result is empty or the result >= 0 then
         add 1 to tSent
      else
         rcLog "* send to peer" && tPeer && "refused (" & the result & "):" && btLastError()
      end if
   end repeat
   if tSent > 0 then
      rcChatLine ("You: " & tBody)
      set the text of field "rcMsg" to ""
   else
      rcLog "* nothing sent - every peer refused; see the lines above"
   end if
end rcSendMessage

command rcDashOnce
   local tDht, tCount, tNodes
   -- pin the stack: a `send ... in` tick has no defaultStack guarantee, and every
   -- control this reaches is named unqualified (OXT-ENGINE-NOTES 5.3)
   set the defaultStack to the short name of this stack
   if sPolling is not "true" then
      exit rcDashOnce
   end if
   send "rcDashOnce" to me in 1000 milliseconds
   put the number of lines of the keys of sPeers into tCount
   if sRoomId is empty then
      exit rcDashOnce
   end if
   put btDhtState(sSession) into tDht
   put 0 into tNodes
   if the number of lines of the keys of tDht > 0 then
      put tDht["nodes"] into tNodes
   end if
   if tCount > 0 then
      uiStatus "In a room - rp1 peers:" && tCount && "- DHT nodes:" && tNodes, "ok"
   else
      uiStatus "In a room - no peers yet - DHT nodes:" && tNodes, empty
   end if
   -- the lonely watchdog: a joined room with zero peers past the window gets
   -- ONE spoken diagnosis (the wait continues; a peer can still arrive)
   if tCount is 0 and sLonelyHinted is not "true" and sJoinedAt is a number then
      if the milliseconds - sJoinedAt > kRcLonelySecs * 1000 then
         put "true" into sLonelyHinted
         rcLog "* no peer after" && kRcLonelySecs && "s. Checklist: same EXACT room phrase on both sides? Both stacks say DHT nodes > 0? UDP not firewalled? Both sides clicked Join?"
         uiStatus "Still no peer - see the checklist in the log.", "warn"
      end if
   end if
end rcDashOnce

-- ---- small helpers -----------------------------------------------------------
-- A received chat line (bold-ish marker so it stands out from system "*" lines).
command rcChatLine pText
   rcLog pText
end rcChatLine

command rcLog pMsg
   if there is no field "rcLog" then
      exit rcLog
   end if
   put pMsg & return after field "rcLog"
   -- bounded like every other family log (this one could grow forever)
   if the number of lines of field "rcLog" > 250 then
      delete line 1 to 50 of field "rcLog"
   end if
   set the vscroll of field "rcLog" to the formattedHeight of field "rcLog"
end rcLog

-- Turn a room phrase into a 40-hex rendezvous id. A value that is ALREADY a
-- 40-hex id is used verbatim (so two power users can share a raw id); anything
-- else is hashed with SHA-1 to 20 bytes (matching how a phantom-swarm id is
-- "any 20 bytes"). Both sides must derive the SAME id, so the rule is fixed.
function rcRoomId pRoom
   if the length of pRoom is 40 and matchText(pRoom, "^[0-9a-fA-F]{40}$") then
      return toLower(pRoom)
   end if
   return rcToHex(sha1Digest(pRoom))
end rcRoomId

-- Lower-case hex of a binary string, using only basic byte ops (no dependency on
-- binaryEncode format codes, which vary).
function rcToHex pData
   local tHex, tI, tByte, tDigits
   put "0123456789abcdef" into tDigits
   put "" into tHex
   repeat with tI = 1 to the number of bytes in pData
      put byteToNum(byte tI of pData) into tByte
      put char ((tByte div 16) + 1) of tDigits after tHex
      put char ((tByte mod 16) + 1) of tDigits after tHex
   end repeat
   return tHex
end rcToHex

-- A folder for the phantom swarm's (nonexistent) content. Nothing is written
-- there; libtorrent just needs a valid save path for the add.
function rcSaveFolder
   local tBase, tErr
   put specialFolderPath("temporary") & "/TorrentXT-rp1" into tBase
   if there is no folder tBase then
      try
         create folder tBase
      catch tErr
         -- fall back to the temp dir itself; nothing is ever written for a
         -- phantom swarm, so any valid path serves
         return specialFolderPath("temporary")
      end try
   end if
   return tBase
end rcSaveFolder

function rcTrim pText
   return word 1 to -1 of pText
end rcTrim

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

-- Every control name this script references, derived from the source rather
-- than hand-picked: a subset would go stale the first time somebody renames
-- one, and a missing control is not cosmetic - it is the "Chunk: error in
-- object expression" class, found at boot instead of when somebody clicks.
constant kRcScControls = "rcJoin,rcLog,rcMsg,rcName,rcNameCap,rcRoom,rcRoomCap,rcSend,rcTagline,uiFooter,uiStatus,uiTitle"

command rcScRun
   local tMissing, tPort, tErr, tCount
   scBegin "rcLog"
   put scMissing(kRcScControls) into tMissing
   scAssert "all 12 controls this script names exist (missing: " \
         & scShow(tMissing) & ")", (tMissing is empty)

   scAssert "not joined to a room at boot (sRoomId is " & scShow(sRoomId) & ")", \
         (sRoomId is empty)
   scAssert "no peers at boot", (sPeers is empty)

   if sSession is empty or sSession is 0 then
      scSkip "the torrentxt session and rp1 surface", \
            "no session - the extension is absent, or another TorrentXT stack " \
            & "holds THE session (runbook trap 5.1)"
   else
      put btListenPort(sSession) into tPort
      scAssert "the session is listening (handle " & scShow(sSession) \
            & ", port " & scShow(tPort) & ")", (tPort > 0)
      put btLastError() into tErr
      scAssert "btLastError is empty after a clean boot (" & scShow(tErr) & ")", \
            (tErr is empty)
      -- rcStart joins no swarm; the phantom swarm arrives with Join. A count
      -- above zero here means a previous run left one behind.
      put btTorrentCount(sSession) into tCount
      scAssert "no swarm joined yet (btTorrentCount " & scShow(tCount) & ")", \
            (tCount is 0)
      -- btRp1Enable is THE demo: a refused enable used to "work" all the way to
      -- two peers silently ignoring each other, so rcStart bails on it. Reaching
      -- here with the loops armed is that bail-out not having happened.
      scAssert "rp1 was enabled and the poll loops are armed", (sPolling is "true")
   end if
   scArmProbe
end rcScRun
