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
-- that file with a passphrase via cryptoXT (Argon2id + secretbox); you then enter
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
-- publish to it with cryptoXT (libsodium): the key is derived from the passphrase
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
-- REQUIRES, for the privacy features only, the cryptoXT extension
-- (org.openxtalk.library.sodium) to be installed alongside this. Public channels
-- and all non-encryption features work without it.
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

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sVaultPass        -- master passphrase protecting the prefs file ("" = none)
local sPrefLockedOut    -- "true" if the prefs file is locked and we could NOT open
                        --   it this run, so chPrefSave must never overwrite it
local sPolling          -- "true" while the loops are armed
local sChannels         -- array: index -> {seed, name, releases, pass} - YOUR channels
local sActive           -- index of the active channel (drives the sMy* cache below)
local sCanEncrypt       -- "true" if cryptoXT (libsodium) is installed + working
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

local sFeedEnc          -- array: feed-list line -> "enc" if that release is encrypted
local sFeedOrigName     -- array: feed-list line -> original filename (encrypted release)
local sPendingKey       -- array: info-hash -> 32-byte file key, for a download to decrypt
local sPendingName      -- array: info-hash -> original filename, for a download to decrypt
local sXferName         -- array: info-hash -> real name to SHOW locally for an
                        --   encrypted transfer (the swarm only ever sees the .enc)

-- Bump this whenever the generated UI changes. chBuild rebuilds the controls when
-- the stack's stored version differs, so updating the script in a saved stack
-- picks up the new layout instead of keeping the old one.
constant kUiVersion = "channels-ui-2025-07"
-- prefs file header: an 8-byte magic, then a 1-byte mode ("P" plain / "E" sealed).
-- A SEALED file is [magic]["E"][salt 16][sxSecretBox], the same 16-byte-salt +
-- Argon2id convention cryptoXT's own file-encrypt demo uses.
constant kPrefMagic = "BTXPREF1"

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   chBuild
   chPrefLoad      -- hydrate saved state (and unlock if sealed) BEFORE chStart reads it
   chStart
end openStack

on closeStack
   chStop
end closeStack

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

-- ---- self-building UI (idempotent) -------------------------------------------
command chBuild
   -- Rebuild when the UI version changes (not just "is it built?"). Otherwise a
   -- stack saved by an OLDER version keeps its old controls - including buttons
   -- this script no longer handles (e.g. the old chNewId/chSetName) - and never
   -- gets the new ones. Wipe our generated controls and rebuild on any mismatch.
   if the uUiVersion of this stack is kUiVersion then
      exit chBuild
   end if
   chClearGeneratedUI
   lock screen
   -- two columns so the whole app fits a 720p (1280x720) screen
   set the width of this stack to 1180
   set the height of this stack to 648
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - Decentralized Channels"
   chMakeLabel "chTitle", "  Decentralized Channels - share files with no server", "0,0,1180,30", 14
   set the opaque of field "chTitle" to true
   set the backgroundColor of field "chTitle" to "44,90,160"
   set the foregroundColor of field "chTitle" to "255,255,255"
   set the textStyle of field "chTitle" to "bold"
   chMakeButton "chHelp", "?  What is this?", "1000,4,1164,26"
   -- lock/unlock the saved identity with a passphrase (label tracks state)
   chMakeButton "chLock", "Lock Identity...", "820,4,994,26"
   -- ===== LEFT COLUMN (x 16..580): your channel + channels you follow =====
   chSection "chSecMine", "1.  Your channels - publish files under a channel of your own", "16,38,580,58"
   -- channel picker: switch the active channel, or make / delete one
   chMakeLabel "chPickCap", "Active channel:", "16,63,116,81", 10
   chMakeButton "chChannelMenu", "", "118,62,346,84"
   set the style of button "chChannelMenu" to "menu"
   set the menuMode of button "chChannelMenu" to "option"
   chMakeButton "chNewChan", "New Channel", "352,62,452,84"
   chMakeButton "chDelChan", "Delete", "458,62,552,84"
   chMakeLabel "chMyKeyLabel", "This channel's address - Copy it so people can follow THIS channel and get its files:", "16,88,580,104", 10
   chMakeField "chMyKey", "16,106,360,130", true
   chMakeButton "chCopyKey", "Copy", "368,106,452,130"
   chMakeButton "chRename", "Rename", "458,106,552,130"
   chMakeButton "chPublish", "Publish a File...", "16,136,250,158"
   chMakeButton "chPrivacy", "Privacy...", "256,136,372,158"
   chMakeLabel "chNowPub", "Not publishing yet.", "378,140,580,158", 9
   chSection "chSecSubs", "2.  Channels you follow - download what they share", "16,168,580,188"
   chMakeField "chFollowKey", "16,192,400,216", false
   chMakeButton "chFollow", "Follow", "408,192,492,216"
   chMakeButton "chRefresh", "Refresh", "498,192,580,216"
   chMakeLabel "chFeedCaption", "Files shared by channels you follow. Each row is signed by its channel, so it cannot be faked. Pick one and Download:", "16,220,580,244", 9
   chMakeLabel "chSubsHeader", "Channel" & tab & "Release" & tab & "Signed by", "16,248,580,266", 10
   chMakeList "chSubs", "16,268,580,452", false
   chMakeButton "chDownload", "Download", "16,458,180,482"
   chMakeButton "chCopyMag", "Copy Magnet", "188,458,300,482"
   chMakeButton "chUnfollow", "Unfollow", "308,458,448,482"
   set the tabStops of field "chSubsHeader" to "150,430"
   set the tabStops of field "chSubs" to "150,430"
   -- a light selection colour so the dark/coloured row text stays readable
   set the hiliteColor of field "chSubs" to "208,226,245"
   -- ===== RIGHT COLUMN (x 596..1164): transfers + selected-transfer detail =====
   chSection "chSecXfer", "3.  Transfers - green = files you POSTED, blue = files you DOWNLOADED", "596,38,1164,58"
   chMakeLabel "chXferHeader", "Source" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Peers", "596,62,1164,80", 10
   chMakeList "chXfers", "596,82,1164,238", false
   -- Source | Name | State | Progress | Peers (Peers kept clear of the scrollbar)
   set the tabStops of field "chXferHeader" to "84,236,338,460"
   set the tabStops of field "chXfers" to "84,236,338,460"
   -- a light selection colour so the colour-coded row text stays readable
   set the hiliteColor of field "chXfers" to "208,226,245"
   set the textFont of field "chXferHeader" to "Courier"
   set the textFont of field "chXfers" to "Courier"
   set the textSize of field "chXferHeader" to 10
   set the textSize of field "chXfers" to 10
   -- add any magnet link or info-hash directly, not only channel releases
   chMakeField "chMagnetField", "596,244,948,266", false
   chMakeButton "chAddMagnet", "Add Magnet", "954,244,1080,266"
   -- act on the selected transfer (click a row first)
   chMakeButton "chPauseXfer", "Pause", "596,272,690,294"
   chMakeButton "chResumeXfer", "Resume", "696,272,790,294"
   chMakeButton "chRemoveXfer", "Remove", "796,272,902,294"
   chMakeButton "chOpenFolder", "Open Folder", "908,272,1054,294"
   chMakeLabel "chTotals", "", "596,300,1164,318", 10
   -- 3b. Contents of the selected transfer (live per-file progress via btFileList)
   chMakeLabel "chFilesCaption", "Click a transfer above to see the files inside it (double-click opens its folder).", "596,324,1164,340", 9
   chMakeLabel "chFilesHeader", "File" & tab & "Size" & tab & "Progress", "596,344,1164,362", 10
   chMakeList "chFiles", "596,364,1164,470", true
   set the tabStops of field "chFilesHeader" to "340,440"
   set the tabStops of field "chFiles" to "340,440"
   set the textFont of field "chFilesHeader" to "Courier"
   set the textFont of field "chFiles" to "Courier"
   set the textSize of field "chFilesHeader" to 10
   set the textSize of field "chFiles" to 10
   set the text of field "chFiles" to "   Click a transfer above to see its files and per-file progress."
   -- ===== FULL-WIDTH BOTTOM: quick drop + log =====
   chSection "chSecDrop", "4.  Quick drop - paste text, get a code anyone can fetch back", "16,488,1164,508"
   chMakeField "chPinText", "16,512,440,534", false
   chMakeButton "chPin", "Pin", "448,512,530,534"
   chMakeField "chPinCode", "538,512,810,534", true
   chMakeButton "chPinCopy", "Copy", "818,512,910,534"
   chMakeField "chFetchCode", "16,538,440,560", false
   chMakeButton "chFetchBtn", "Fetch", "448,538,530,560"
   chMakeField "chDropResult", "538,538,910,560", true
   chMakeList "chLog", "16,564,1164,640", true
   set the textFont of field "chMyKey" to "Courier"
   set the textFont of field "chFollowKey" to "Courier"
   set the textFont of field "chPinCode" to "Courier"
   set the textFont of field "chFetchCode" to "Courier"
   set the textFont of field "chMagnetField" to "Courier"
   set the textSize of field "chMyKey" to 9
   set the textSize of field "chFollowKey" to 9
   set the textSize of field "chMagnetField" to 9
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

command chMakeLabel pName, pText, pRect, pSize
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
end chMakeLabel

command chSection pName, pText, pRect
   chMakeLabel pName, ("  " & pText), pRect, 11
   set the opaque of field pName to true
   set the backgroundColor of field pName to "210,216,226"
   set the foregroundColor of field pName to "30,40,60"
   set the textStyle of field pName to "bold"
end chSection

command chMakeField pName, pRect, pLocked
   if there is no field pName then
      create field
      set the name of the last field to pName
   end if
   set the rect of field pName to pRect
   set the lockText of field pName to pLocked
   set the traversalOn of field pName to (not pLocked)
end chMakeField

command chMakeButton pName, pLabel, pRect
   if there is no button pName then
      create button
      set the name of the last button to pName
   end if
   set the rect of button pName to pRect
   set the label of button pName to pLabel
end chMakeButton

command chMakeList pName, pRect, pIsLog
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
end chMakeList

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
   chEnsureIdentity
   chLoadFollows
   chUpdateNowPub
   chUpdateLockButton      -- reflect whether the saved identity is passphrase-locked
   if not sCanEncrypt then
      chLog "Note: cryptoXT (org.openxtalk.library.sodium) is not installed, so private channels are unavailable. Install it to use passphrases."
   end if
   chLog "Session ready. DHT bootstrapping - give it a few seconds of peers before publishing or following."
   put "true" into sPolling
   send "chPollOnce" to me in 0 milliseconds
   send "chDashOnce" to me in 800 milliseconds
   send "chChannelTick" to me in 5000 milliseconds
end chStart

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
      else
         put btDhtKeypair("") into tKey
         put tKey["seed"] into sChannels[1]["seed"]
         put "" into sChannels[1]["name"]
         put "" into sChannels[1]["releases"]
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
      answer "Private channels need cryptoXT (the org.openxtalk.library.sodium extension), which is not installed on this machine. Install it to use passphrases."
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
   chRefreshSubs
   repeat for each line tKey in sFollows
      if tKey is not empty then
         btDhtGetMutable sSession, tKey, ""
      end if
   end repeat
end chLoadFollows

command chStop
   put "false" into sPolling
   if sSession is not empty and sSession is not 0 then
      -- persist the DHT routing table so next launch bootstraps faster
      set the uDhtState of this stack to btDhtSaveState(sSession)
      btStopSession sSession
   end if
   chPrefSave      -- final flush to the external prefs file on close
   put empty into sSession
end chStop

-- ---- persistence: keep state in an EXTERNAL file -----------------------------
-- A standalone app cannot save its own mainstack, so the stack custom properties
-- (channels, follows, passphrases, DHT cache) would reset every launch. We mirror
-- them to one file in a per-user folder: hydrated into the properties on open,
-- written on every change and on close. Optionally SEALED with cryptoXT, so the
-- ed25519 secret keys + passphrases are not left on disk in the clear. The sealed
-- layout ([magic]["E"][16-byte salt][secretbox]) matches cryptoXT's file-encrypt
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
         answer "Your saved channels are passphrase-locked, but cryptoXT (org.openxtalk.library.sodium) is not installed, so they cannot be unlocked here."
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
      answer "Locking your identity needs cryptoXT (org.openxtalk.library.sodium), which is not installed."
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
   if sPolling is not "true" then
      exit chDashOnce
   end if
   chRefreshTransfers
   send "chDashOnce" to me in 1000 milliseconds
end chDashOnce

-- every 60 s: keep EVERY one of your channels alive in the DHT (not just the
-- active one, so they all stay reachable) and re-pull your subscriptions
command chChannelTick
   local tKey, tI, tKp, tFeed, tVal
   if sPolling is not "true" then
      exit chChannelTick
   end if
   if sSession is not 0 and sSession is not empty then
      repeat with tI = 1 to chChannelCount()
         put chBuildFeed(sChannels[tI]["name"], sChannels[tI]["releases"]) into tFeed
         put btDhtKeypair(sChannels[tI]["seed"]) into tKp
         -- encrypted for private channels; skip a private one we cannot encrypt
         -- rather than ever re-announcing it in the clear (fail-closed)
         put chFeedValue(tFeed, sChannels[tI]["pass"], tKp["publicKey"]) into tVal
         if tVal is not empty then
            btDhtPutMutable sSession, tKp["publicKey"], tKp["secretKey"], "", tVal
         end if
      end repeat
      repeat for each line tKey in sFollows
         if tKey is not empty then
            btDhtGetMutable sSession, tKey, ""
         end if
      end repeat
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
   if sChannels[sActive]["pass"] is not empty then
      -- ---- PRIVATE: encrypt one file (chunked) before sharing it ----
      if not sCanEncrypt then
         chLog "This channel is private but cryptoXT is not installed - publish is unavailable. Install org.openxtalk.library.sodium."
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
   -- bare key, so the recipient sees who they are following, not just a hex blob
   put sMyName into tName
   if tName is empty then
      put sPub into tCard
   else
      put tName & " | " & sPub into tCard
   end if
   set the clipboardData["text"] to tCard
   chLog "Copied your channel card (name + address) - paste it into someone's Follow box."
end chCopyKey

-- ---- subscriptions / unified feed --------------------------------------------
command chFollow
   local tKey, tRaw, tPass, tDup
   if sSession is 0 then
      chLog "No session."
      exit chFollow
   end if
   -- accept a bare 64-hex key OR a shared "Name | key" channel card
   put chTrim(field "chFollowKey") into tRaw
   if tRaw contains "|" then
      set the itemDelimiter to "|"
      put chTrim(the last item of tRaw) into tRaw
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
   btDhtGetMutable sSession, tKey, ""
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
         btDhtGetMutable sSession, tKey, ""
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
   set the clipboardData["text"] to tMag
   chLog "Copied the magnet to the clipboard."
end chCopySelectedMagnet

-- Rebuild the unified, signed release feed across every channel we follow.
command chRefreshSubs
   local tKey, tFeed, tL, tName, tRel, tTitle, tMag, tRows, tLineNum, tSelMag, tEmpty, tErr
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
      -- one row per "r=title TAB magnet" release line
      repeat for each line tL in tFeed
         if tL begins with "r=" then
            set the itemDelimiter to tab
            put char 3 to -1 of tL into tRel
            put item 1 of tRel into tTitle
            put item 2 of tRel into tMag
            add 1 to tLineNum
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
   local tCount, tI, tH, tS, tRows, tPct, tDown, tUp, tLineNum, tD, tNodes, tDht
   local tColors, tErr, tSelH, tSelLine, tSource, tDispName, tIH
   if sSession is 0 or sSession is empty then
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
      -- red = error, grey = paused, green = YOU posted it, blue = you downloaded it.
      if tS["error"] is not empty then
         put "200,40,40" into tColors[tLineNum]
      else if tS["isPaused"] is true or tS["isPaused"] is 1 then
         put "120,120,120" into tColors[tLineNum]
      else if tSource is "Posted" then
         put "0,140,70" into tColors[tLineNum]
      else
         put "30,90,200" into tColors[tLineNum]
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
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   put btDhtState(sSession) into tD
   put tD["nodes"] into tNodes
   if tNodes is a number and tNodes > 0 then
      put ("DHT:" && tNodes && "nodes") into tDht
   else
      put "DHT: connecting..." into tDht
   end if
   lock screen
   set the text of field "chXfers" to tRows
   if tLineNum is 0 then
      -- friendly empty state instead of a blank table
      set the text of field "chXfers" to \
         "   Nothing transferring yet. Publish a file above, or Download a release from a channel you follow."
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
   put tLineNum && "transfers     down" && (chFmtBytes(tDown) & "/s") && "    up" \
      && (chFmtBytes(tUp) & "/s") && "     " & tDht into field "chTotals"
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
-- cryptoXT (libsodium crypto_secretbox, XSalsa20-Poly1305) before the DHT put, so
-- only someone with the passphrase can read the file LIST (the FILES are
-- encrypted separately - see "Phase 2: actual FILE encryption" below). The
-- symmetric key is derived from the passphrase with Argon2id (sxPwHash), salted
-- by the channel's public key so publisher and followers derive the SAME key. The
-- feed stays ed25519-signed on top, so authenticity is unchanged. Requires the
-- org.openxtalk.library.sodium extension (cryptoXT) to be installed.

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

-- one-time capability probe: is cryptoXT (libsodium) installed and working? We do
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
   put chBuildFeed(sMyName, sMyReleases) into sMyPost
   put chFeedValue(sMyPost, sChannels[sActive]["pass"], sPub) into tVal
   if tVal is empty then
      return -1
   end if
   return btDhtPutMutable(sSession, sPub, sSec, "", tVal)
end chPublishActiveFeed

-- ---- Phase 2: actual FILE encryption (cryptoXT secretstream) -----------------
-- A private channel encrypts the FILE itself, not just the feed. cryptoXT streams
-- it through libsodium's crypto_secretstream (XChaCha20-Poly1305) entirely C-side
-- (sxEncryptFile), so a big file never enters a LiveCode Data and the per-chunk
-- authentication + FINAL tag make truncation or tampering detectable on decrypt.
-- The torrent then carries CIPHERTEXT under a neutral name, so a leaked magnet is
-- useless; the real filename rides in the (encrypted) feed and is restored on
-- download. The file key is chFileKey (derived from the passphrase, distinct from
-- the feed key). NOTE: encryption is synchronous, so the UI pauses on a very large
-- file. Requires the org.openxtalk.library.sodium extension (cryptoXT).

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

-- Encrypt pSrc to pDst with the 32-byte file key pKey (cryptoXT secretstream,
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

-- Decrypt pSrc (a .enc) to pDst with the 32-byte file key pKey. cryptoXT throws on
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
   if pKind is "ENCRYPTED" then
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
