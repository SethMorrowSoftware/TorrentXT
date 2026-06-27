script "dhtChannelsApp"

-- torrent-dht-channels.livecodescript - a self-building, MULTI-MACHINE TorrentXT
-- demo that combines the BEP44 DHT key-value store with BitTorrent file transfer
-- into one decentralized "channel" app. NO SERVER anywhere: the DHT is the
-- directory, BitTorrent moves the bytes.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI and starts a
-- TorrentXT session. Needs only the loaded org.openxtalk.library.torrent (v3+).
-- Save the stack to keep your channel identity / name / subscriptions across runs.
--
-- THE DEMO (run it on two or more machines):
--   1. (Optional) click "Set Name" to give your channel a display name.
--   2. Click "Publish a File to My Channel" - it creates a torrent, seeds it, and
--      publishes the magnet in your channel FEED, signed under your ed25519 key on
--      the DHT. Publish more files - your channel keeps a feed of recent releases.
--   3. Click "Copy" to put your channel CARD ("Name | public key") on the
--      clipboard, and send it to another machine.
--   4. There, paste the card (or a bare key) and click Follow - it fetches that
--      channel's signed feed and lists its releases.
--   5. Select a release and click Download - the file transfers peer-to-peer while
--      the publisher seeds. Watch the color-coded Transfers table (green=seeding,
--      blue=downloading) fill in on both machines.
-- Followers see a UNIFIED feed of releases across every channel they follow, and
-- every entry is cryptographically signed by its channel (tamper-proof: only the
-- channel's secret key could have published it).
--
-- Click any transfer to see the files inside it with a live per-file progress
-- bar (btFileList), or hit "Stream" to download it in order (btSetSequentialDownload)
-- so a media release plays as it arrives. The transfers table shows inline bars.
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
local sPolling          -- "true" while the loops are armed
local sPub              -- our channel public key (hex) - shareable
local sSec              -- our secret key (hex) - script only, never shown
local sMyName           -- our channel display name
local sMyReleases       -- our feed: return-delimited "title TAB magnet", newest first
local sMyPost           -- the built feed value we publish (name + releases)
local sFollows          -- return-delimited list of public keys we follow
local sFollowFeeds      -- array: pubkey -> their raw feed value
local sFeedKey          -- array: feed-list line -> channel pubkey
local sFeedMag          -- array: feed-list line -> magnet
local sFeedTitle        -- array: feed-list line -> release title
local sXferHandle       -- array: transfers-list line -> torrent handle

-- ---- lifecycle ---------------------------------------------------------------
on openStack
   chBuild
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
      case "chCopyKey"
         chCopyKey
         break
      case "chNewId"
         chNewIdentity
         break
      case "chSetName"
         chSetName
         break
      case "chPublish"
         chPublishFile
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
      case "chStream"
         chStreamSelected
         break
      case "chXfers"
         chShowFilesForSelection
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
   if the short name of the target is "chSubs" then
      chDownloadSelected
   else
      pass mouseDoubleUp
   end if
end mouseDoubleUp

-- ---- self-building UI (idempotent) -------------------------------------------
command chBuild
   if there is a field "chLog" then
      exit chBuild
   end if
   lock screen
   set the width of this stack to 880
   set the height of this stack to 900
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - Decentralized Channels"
   chMakeLabel "chTitle", "  Decentralized Channels - share files with no server", "0,0,880,30", 14
   set the opaque of field "chTitle" to true
   set the backgroundColor of field "chTitle" to "44,90,160"
   set the foregroundColor of field "chTitle" to "255,255,255"
   set the textStyle of field "chTitle" to "bold"
   chMakeButton "chHelp", "?  What is this?", "700,4,864,26"
   -- 1. My channel
   chSection "chSecMine", "1.  Your channel - publish files for people to download", "16,40,864,60"
   chMakeLabel "chMyKeyLabel", "Your channel address. Click Copy to share it - that is how people follow you and get your files:", "16,64,864,82", 10
   chMakeField "chMyKey", "16,84,524,108", true
   chMakeButton "chCopyKey", "Copy", "532,84,620,108"
   chMakeButton "chNewId", "New ID", "626,84,728,108"
   chMakeButton "chSetName", "Set Name", "734,84,842,108"
   chMakeButton "chPublish", "Publish a File to My Channel...", "16,116,300,142"
   chMakeLabel "chNowPub", "Not publishing yet.", "310,120,864,140", 10
   -- 2. Subscriptions / unified feed
   chSection "chSecSubs", "2.  Channels you follow - download what they share", "16,150,864,170"
   chMakeField "chFollowKey", "16,176,640,200", false
   chMakeButton "chFollow", "Follow", "648,176,742,200"
   chMakeButton "chRefresh", "Refresh", "748,176,842,200"
   chMakeLabel "chFeedCaption", "Files shared by channels you follow. Each row is signed by its channel, so it cannot be faked. Pick one and Download:", "16,204,864,220", 9
   chMakeLabel "chSubsHeader", "Channel" & tab & "Release" & tab & "Signed by (key)", "16,222,864,240", 10
   chMakeList "chSubs", "16,242,864,316", false
   chMakeButton "chDownload", "Download Selected", "16,322,180,348"
   chMakeButton "chCopyMag", "Copy Magnet", "188,322,300,348"
   chMakeButton "chUnfollow", "Unfollow Channel", "308,322,448,348"
   set the tabStops of field "chSubsHeader" to "160,580"
   set the tabStops of field "chSubs" to "160,580"
   -- 3. Transfers
   chSection "chSecXfer", "3.  Transfers - live upload + download activity", "16,358,864,378"
   chMakeLabel "chXferHeader", "#" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Peers", "16,384,864,402", 10
   chMakeList "chXfers", "16,404,864,490", false
   chMakeLabel "chTotals", "", "16,494,864,514", 10
   set the tabStops of field "chXferHeader" to "26,400,500,640"
   set the tabStops of field "chXfers" to "26,400,500,640"
   set the textFont of field "chXferHeader" to "Courier"
   set the textFont of field "chXfers" to "Courier"
   set the textSize of field "chXferHeader" to 10
   set the textSize of field "chXfers" to 10
   -- 3b. Contents of the selected transfer (live per-file progress) + streaming
   chMakeButton "chStream", "Stream Selected (in order)", "16,520,300,544"
   chMakeLabel "chFilesCaption", "Click a transfer above to see its files. Stream downloads in order so media can play as it arrives.", "308,524,864,542", 9
   chMakeLabel "chFilesHeader", "File" & tab & "Size" & tab & "Progress", "16,548,864,566", 10
   chMakeList "chFiles", "16,568,864,662", true
   set the tabStops of field "chFilesHeader" to "440,540"
   set the tabStops of field "chFiles" to "440,540"
   set the textFont of field "chFilesHeader" to "Courier"
   set the textFont of field "chFiles" to "Courier"
   set the textSize of field "chFilesHeader" to 10
   set the textSize of field "chFiles" to 10
   set the text of field "chFiles" to "   Click a transfer above to see its files and per-file progress."
   -- 4. Quick drop (immutable)
   chSection "chSecDrop", "4.  Quick drop - paste text, get a code anyone can fetch back", "16,672,864,692"
   chMakeField "chPinText", "16,698,430,722", false
   chMakeButton "chPin", "Pin", "438,698,510,722"
   chMakeField "chPinCode", "518,698,790,722", true
   chMakeButton "chPinCopy", "Copy", "794,698,864,722"
   chMakeField "chFetchCode", "16,726,430,750", false
   chMakeButton "chFetchBtn", "Fetch", "438,726,510,750"
   chMakeField "chDropResult", "518,726,864,750", true
   -- Log
   chMakeList "chLog", "16,758,864,888", true
   set the textFont of field "chMyKey" to "Courier"
   set the textFont of field "chFollowKey" to "Courier"
   set the textFont of field "chPinCode" to "Courier"
   set the textFont of field "chFetchCode" to "Courier"
   set the textSize of field "chMyKey" to 9
   set the textSize of field "chFollowKey" to 9
   chAddTips
   unlock screen
end chBuild

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
   set the tooltip of field "chMyKey" to "Your channel address. Share it (Copy) so people can follow you."
   set the tooltip of button "chCopyKey" to "Copy your channel card (your name + address) to the clipboard."
   set the tooltip of button "chNewId" to "Start over with a brand-new identity. Your current followers will lose you."
   set the tooltip of button "chSetName" to "Give your channel a friendly display name your followers will see."
   set the tooltip of button "chPublish" to "Pick a folder. It is packaged, seeded, and added to your channel feed."
   set the tooltip of field "chFollowKey" to "Paste someone's channel card or 64-character address, then click Follow."
   set the tooltip of button "chFollow" to "Subscribe to that channel and fetch its signed list of files."
   set the tooltip of button "chRefresh" to "Re-fetch the latest files from every channel you follow."
   set the tooltip of button "chDownload" to "Download the selected file - it transfers peer-to-peer from the publisher."
   set the tooltip of button "chCopyMag" to "Copy the selected file's magnet link to the clipboard."
   set the tooltip of button "chUnfollow" to "Stop following the selected file's channel."
   set the tooltip of field "chXfers" to "Click a transfer to see its files and per-file progress below."
   set the tooltip of button "chStream" to "Download the selected transfer in order, so media plays as it arrives."
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
   put tMsg & "1) YOUR CHANNEL - like a personal feed. Publish a file and it is shared under your own" & return into tMsg
   put tMsg & "   cryptographic key, so nobody else can post to your channel or forge it." & return & return into tMsg
   put tMsg & "2) CHANNELS YOU FOLLOW - paste someone's channel card to see their latest files. Pick" & return into tMsg
   put tMsg & "   one and Download; it transfers from them while they are online. Every entry is signed," & return into tMsg
   put tMsg & "   so it is tamper-proof." & return & return into tMsg
   put tMsg & "3) TRANSFERS - a live view of what you are sending and receiving. Click one to see" & return into tMsg
   put tMsg & "   the files inside it with per-file progress, or Stream it to download in order." & return & return into tMsg
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
   chEnsureIdentity
   chLoadFollows
   chUpdateNowPub
   chLog "Session ready. DHT bootstrapping - give it a few seconds of peers before publishing or following."
   put "true" into sPolling
   send "chPollOnce" to me in 0 milliseconds
   send "chDashOnce" to me in 800 milliseconds
   send "chChannelTick" to me in 5000 milliseconds
end chStart

command chEnsureIdentity
   local tKey, tSeed
   put the uChannelName of this stack into sMyName
   put the uDhtSeed of this stack into tSeed
   if tSeed is not empty then
      put btDhtKeypair(tSeed) into tKey
   else
      put btDhtKeypair("") into tKey
      set the uDhtSeed of this stack to tKey["seed"]
   end if
   put tKey["publicKey"] into sPub
   put tKey["secretKey"] into sSec
   set the text of field "chMyKey" to sPub
end chEnsureIdentity

command chLoadFollows
   local tKey
   put the uFollows of this stack into sFollows
   put empty into sFollowFeeds
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
   put empty into sSession
end chStop

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

-- every 60 s: keep our feed alive in the DHT and re-pull our subscriptions
command chChannelTick
   local tKey
   if sPolling is not "true" then
      exit chChannelTick
   end if
   if sSession is not 0 and sSession is not empty then
      if sMyPost is not empty then
         btDhtPutMutable sSession, sPub, sSec, "", textEncode(sMyPost, "UTF-8")
      end if
      repeat for each line tKey in sFollows
         if tKey is not empty then
            btDhtGetMutable sSession, tKey, ""
         end if
      end repeat
   end if
   send "chChannelTick" to me in 60000 milliseconds
end chChannelTick

-- ---- my channel --------------------------------------------------------------
command chSetName
   local tName
   ask "Name your channel (shown to your followers):" with sMyName
   put it into tName
   if tName is empty then
      exit chSetName
   end if
   replace return with space in tName
   replace tab with space in tName
   replace "|" with "/" in tName   -- "|" is the channel-card delimiter
   put tName into sMyName
   set the uChannelName of this stack to sMyName
   if sMyReleases is not empty and sSession is not 0 then
      put chBuildFeed(sMyName, sMyReleases) into sMyPost
      btDhtPutMutable sSession, sPub, sSec, "", textEncode(sMyPost, "UTF-8")
   end if
   chUpdateNowPub
   chLog "Channel name set to '" & sMyName & "'."
end chSetName

command chPublishFile
   local tPath, tParent, tTitle, tData, tH, tHash, tMagnet, tRel, tR
   if sSession is 0 then
      chLog "No session."
      exit chPublishFile
   end if
   answer folder "Choose a folder to publish to your channel:"
   put it into tPath
   if tPath is empty then
      exit chPublishFile
   end if
   -- separator-agnostic: normalise to "/" so the parent split works on Windows too
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
   put "magnet:?xt=urn:btih:" & tHash & "&dn=" & urlEncode(tTitle) into tMagnet
   -- prepend to our feed (newest first); each entry is "title TAB magnet"
   put chTrunc(tTitle, 60) & tab & tMagnet into tRel
   if sMyReleases is empty then
      put tRel into sMyReleases
   else
      put tRel & return & sMyReleases into sMyReleases
   end if
   put chBuildFeed(sMyName, sMyReleases) into sMyPost
   -- drop the oldest releases until the feed fits the BEP44 1000-byte limit
   repeat while (the number of bytes in textEncode(sMyPost, "UTF-8")) > 950 and the number of lines of sMyReleases > 1
      delete the last line of sMyReleases
      put chBuildFeed(sMyName, sMyReleases) into sMyPost
   end repeat
   put btDhtPutMutable(sSession, sPub, sSec, "", textEncode(sMyPost, "UTF-8")) into tR
   if tR is not 0 then
      chLog "Publish to DHT failed:" && btLastError()
      exit chPublishFile
   end if
   chUpdateNowPub
   chLog "Published '" & tTitle & "' to your channel feed and seeding it."
end chPublishFile

command chUpdateNowPub
   local tN, tName
   put the number of lines of sMyReleases into tN
   put sMyName into tName
   if tName is empty then
      put "(unnamed - click Set Name)" into tName
   end if
   if tN is 0 then
      set the text of field "chNowPub" to ("Channel: " & tName & " - nothing published yet.")
   else
      set the text of field "chNowPub" to ("Channel: " & tName & " - publishing + seeding " & tN & " release(s).")
   end if
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

command chNewIdentity
   local tKey
   answer "Generate a NEW channel identity? Anyone following your current address will stop seeing your releases." with "Cancel" or "New identity"
   if it is not "New identity" then
      exit chNewIdentity
   end if
   put btDhtKeypair("") into tKey
   set the uDhtSeed of this stack to tKey["seed"]
   put tKey["publicKey"] into sPub
   put tKey["secretKey"] into sSec
   put empty into sMyReleases
   put empty into sMyPost
   set the text of field "chMyKey" to sPub
   chUpdateNowPub
   chLog "New channel identity:" && sPub
end chNewIdentity

-- ---- subscriptions / unified feed --------------------------------------------
command chFollow
   local tKey, tRaw
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
   if tKey is among the lines of sFollows then
      chLog "Already following that channel."
      exit chFollow
   end if
   if sFollows is empty then
      put tKey into sFollows
   else
      put sFollows & return & tKey into sFollows
   end if
   set the uFollows of this stack to sFollows
   put empty into field "chFollowKey"
   chRefreshSubs
   btDhtGetMutable sSession, tKey, ""
   chLog "Following" && chShortKey(tKey) & ". Fetching their feed..."
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
   chRefreshSubs
   chLog "Unfollowed" && chShortKey(tKey) & "."
end chUnfollow

command chDownloadSelected
   local tL, tMag, tTitle, tH
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
   chLog "Downloading '" & tTitle & "'..."
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
            put tName & tab & chTrunc(tTitle, 50) & tab & chShortKey(tKey) & return after tRows
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
   local tColors, tErr, tSelH, tSelLine
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
      put chStateColor(tS["state"], tS["error"]) into tColors[tLineNum]
      -- Progress column is now an inline ASCII bar (the field is monospaced)
      put tLineNum & tab & chTrunc(tS["name"], 40) & tab & chStateName(tS["state"]) & tab & \
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

-- ---- selected-transfer detail: the file table + streaming --------------------

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
   local tFiles, tFile, tRows, tPct
   if there is no field "chFiles" then
      exit chShowFiles
   end if
   if pHandle is 0 or pHandle is empty then
      put "   Click a transfer above to see its files and per-file progress." into tRows
   else
      put btFileList(pHandle) into tFiles
      put "" into tRows
      repeat for each element tFile in tFiles
         if tFile["size"] > 0 then
            put (the round of (tFile["progress"] * 1000 / tFile["size"]) / 10) into tPct
         else
            put 0 into tPct
         end if
         put chTrunc(tFile["path"], 60) & tab & chFmtBytes(tFile["size"]) & tab \
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

-- Turn on sequential (in-order) download for the selected transfer, so a media
-- release can play as it arrives instead of downloading pieces at random.
command chStreamSelected
   local tH, tR
   put chSelectedXferHandle() into tH
   if tH is 0 then
      chLog "Select a transfer first, then click Stream."
      exit chStreamSelected
   end if
   put btSetSequentialDownload(tH, true) into tR
   if tR is 0 then
      chLog "Streaming on: transfer" && tH && "now downloads in order (play-as-it-arrives)."
   else
      chLog "Could not enable streaming:" && btLastError()
   end if
end chStreamSelected

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
         put textDecode(pEvent["value"], "UTF-8") into tVal
         put tVal into sFollowFeeds[tKey]
         chRefreshSubs
         -- libtorrent only surfaces a mutable item after verifying its ed25519
         -- signature against the public key, so arrival == cryptographically verified
         put chCountReleases(tVal) into tN
         chLog "Channel" && chShortKey(tKey) && "feed: signature verified, v" & pEvent["seq"] & "," && tN && "release(s)."
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

-- row color by state, mirroring the main client's palette
function chStateColor pState, pError
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
end chStateColor

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
