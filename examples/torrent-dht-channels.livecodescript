script "dhtChannelsApp"

-- torrent-dht-channels.livecodescript - a self-building, MULTI-MACHINE TorrentXT
-- demo that combines the BEP44 DHT key-value store with BitTorrent file transfer
-- into one decentralized "channel" app. NO SERVER anywhere: the DHT is the
-- directory, BitTorrent moves the bytes.
--
-- HOW TO USE: open OXT, make a one-card stack, paste THIS into the STACK script
-- (Object > Stack Script), then close+reopen. It builds its own UI and starts a
-- TorrentXT session. Needs only the loaded org.openxtalk.library.torrent (v3+).
--
-- THE DEMO (run it on two or more machines):
--   1. On machine A, click "Publish a File to My Channel" - it creates a torrent,
--      seeds it, and publishes the magnet (signed) under A's public key on the DHT.
--   2. Copy A's channel address (its public key) to machine B.
--   3. On machine B, paste A's key and click Follow - B fetches A's latest release
--      from the DHT and shows it.
--   4. B clicks Download - it adds A's magnet and the file transfers peer-to-peer
--      while A seeds. Watch the Transfers table fill in on both machines.
-- Your channel ADDRESS (key) is permanent and remembered across launches; your
-- subscriptions are remembered too. (Publishing is per-session - re-publish a file
-- each run, since seeding stops when the app closes.)
--
-- It also includes a "Quick drop" panel using IMMUTABLE items: pin a short text,
-- get a 40-character content-address code, and fetch any code back.
--
-- Design follows the single-thread playbook: a 250 ms poll drains events, a 1 s
-- loop repaints the transfers table, and a 60 s loop re-publishes your release and
-- re-fetches your subscriptions so the feed stays live.

-- ---- stack-local state -------------------------------------------------------
local sSession          -- the live session handle (0/empty = none)
local sPolling          -- "true" while the loops are armed
local sPub              -- our channel public key (hex) - shareable
local sSec              -- our secret key (hex) - script only, never shown
local sMyPost           -- our current published release ("title" & return & magnet)
local sFollows          -- return-delimited list of public keys we follow
local sFollowPosts       -- array: pubkey -> their latest release post
local sSubKeys          -- array: subscriptions table line number -> pubkey

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
      case "chCopyKey"
         chCopyKey
         break
      case "chNewId"
         chNewIdentity
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
   set the height of this stack to 748
   set the backgroundColor of this card to "237,239,243"
   set the title of this stack to "TorrentXT - Decentralized Channel"
   chMakeLabel "chTitle", "  TorrentXT - Decentralized Channel (DHT directory + BitTorrent transfer, no server)", "0,0,880,30", 14
   set the opaque of field "chTitle" to true
   set the backgroundColor of field "chTitle" to "44,90,160"
   set the foregroundColor of field "chTitle" to "255,255,255"
   set the textStyle of field "chTitle" to "bold"
   -- 1. My channel
   chSection "chSecMine", "1.  Your channel", "16,40,864,60"
   chMakeLabel "chMyKeyLabel", "Your channel address (public key) - share it so people can follow you:", "16,64,864,82", 10
   chMakeField "chMyKey", "16,84,640,108", true
   chMakeButton "chCopyKey", "Copy", "648,84,742,108"
   chMakeButton "chNewId", "New ID", "748,84,842,108"
   chMakeButton "chPublish", "Publish a File to My Channel...", "16,116,300,142"
   chMakeLabel "chNowPub", "Not publishing yet - click Publish to seed a file and announce it.", "310,120,864,140", 10
   -- 2. Subscriptions
   chSection "chSecSubs", "2.  Channels you follow", "16,150,864,170"
   chMakeField "chFollowKey", "16,176,640,200", false
   chMakeButton "chFollow", "Follow", "648,176,742,200"
   chMakeButton "chRefresh", "Refresh", "748,176,842,200"
   chMakeLabel "chSubsHeader", "Channel" & tab & "Latest release" & tab & "Status", "16,206,864,224", 10
   chMakeList "chSubs", "16,226,864,318", false
   chMakeButton "chDownload", "Download Selected", "16,324,180,350"
   chMakeButton "chCopyMag", "Copy Magnet", "188,324,300,350"
   chMakeButton "chUnfollow", "Unfollow", "308,324,400,350"
   set the tabStops of field "chSubsHeader" to "120,640"
   set the tabStops of field "chSubs" to "120,640"
   -- 3. Transfers
   chSection "chSecXfer", "3.  Transfers (your seed + your downloads)", "16,360,864,380"
   chMakeLabel "chXferHeader", "#" & tab & "Name" & tab & "State" & tab & "Progress" & tab & "Peers", "16,384,864,402", 10
   chMakeList "chXfers", "16,404,864,490", false
   chMakeLabel "chTotals", "", "16,494,864,514", 10
   set the tabStops of field "chXferHeader" to "26,430,540,650"
   set the tabStops of field "chXfers" to "26,430,540,650"
   set the textFont of field "chXferHeader" to "Courier"
   set the textFont of field "chXfers" to "Courier"
   set the textSize of field "chXferHeader" to 10
   set the textSize of field "chXfers" to 10
   -- 4. Quick drop (immutable)
   chSection "chSecDrop", "4.  Quick drop (immutable: pin text, share a 40-char code)", "16,522,864,542"
   chMakeField "chPinText", "16,548,430,572", false
   chMakeButton "chPin", "Pin", "438,548,510,572"
   chMakeField "chPinCode", "518,548,790,572", true
   chMakeButton "chPinCopy", "Copy", "794,548,864,572"
   chMakeField "chFetchCode", "16,576,430,600", false
   chMakeButton "chFetchBtn", "Fetch", "438,576,510,600"
   chMakeField "chDropResult", "518,576,864,600", true
   -- Log
   chMakeList "chLog", "16,608,864,738", true
   set the textFont of field "chMyKey" to "Courier"
   set the textFont of field "chFollowKey" to "Courier"
   set the textFont of field "chPinCode" to "Courier"
   set the textFont of field "chFetchCode" to "Courier"
   set the textSize of field "chMyKey" to 9
   set the textSize of field "chFollowKey" to 9
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
   btDhtAddBootstrap sSession, "router.bittorrent.com", 6881
   btDhtAddBootstrap sSession, "router.utorrent.com", 6881
   btDhtAddBootstrap sSession, "dht.transmissionbt.com", 6881
   chEnsureIdentity
   chLoadFollows
   chLog "Session ready. DHT bootstrapping - give it a few seconds of peers before publishing or following."
   put "true" into sPolling
   send "chPollOnce" to me in 0 milliseconds
   send "chDashOnce" to me in 800 milliseconds
   send "chChannelTick" to me in 5000 milliseconds
end chStart

command chEnsureIdentity
   local tKey, tSeed
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
   put empty into sFollowPosts
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

-- every 60 s: keep our release alive in the DHT and re-pull our subscriptions
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
command chPublishFile
   local tPath, tParent, tTitle, tData, tH, tHash, tMagnet, tR
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
   put tTitle & return & tMagnet into sMyPost
   put btDhtPutMutable(sSession, sPub, sSec, "", textEncode(sMyPost, "UTF-8")) into tR
   if tR is not 0 then
      chLog "Publish to DHT failed:" && btLastError()
      exit chPublishFile
   end if
   set the text of field "chNowPub" to ("Now publishing + seeding: " & tTitle)
   chLog "Published '" & tTitle & "' to your channel and seeding it. Followers will see it on their next refresh."
end chPublishFile

command chCopyKey
   if sPub is empty then
      exit chCopyKey
   end if
   set the clipboardData["text"] to sPub
   chLog "Copied your channel address to the clipboard - share it so people can follow you."
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
   put empty into sMyPost
   set the text of field "chMyKey" to sPub
   set the text of field "chNowPub" to "Not publishing yet - click Publish to seed a file and announce it."
   chLog "New channel identity:" && sPub
end chNewIdentity

-- ---- subscriptions -----------------------------------------------------------
command chFollow
   local tKey
   if sSession is 0 then
      chLog "No session."
      exit chFollow
   end if
   put toLower(chTrim(field "chFollowKey")) into tKey
   if the number of chars of tKey is not 64 then
      chLog "Paste a 64-character channel address (public key) to follow."
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
   chLog "Following" && chShortKey(tKey) & ". Fetching their latest release..."
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
   local tKey, tLeft, tLine
   put chSelectedSubKey() into tKey
   if tKey is empty then
      chLog "Select a channel to unfollow."
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
   put empty into sFollowPosts[tKey]   -- the row is gone (chRefreshSubs walks sFollows)
   chRefreshSubs
   chLog "Unfollowed" && chShortKey(tKey) & "."
end chUnfollow

command chDownloadSelected
   local tKey, tPost, tMag, tH
   if sSession is 0 then
      exit chDownloadSelected
   end if
   put chSelectedSubKey() into tKey
   if tKey is empty then
      chLog "Select a channel first."
      exit chDownloadSelected
   end if
   put sFollowPosts[tKey] into tPost
   if tPost is empty then
      chLog "No release fetched for that channel yet - try Refresh, and give the DHT a few seconds."
      exit chDownloadSelected
   end if
   put line 2 of tPost into tMag
   if tMag is empty or not (tMag begins with "magnet:") then
      chLog "That channel has not published a downloadable magnet."
      exit chDownloadSelected
   end if
   put btAddMagnet(sSession, tMag, chDefaultSave()) into tH
   if tH is 0 then
      chLog "Download add failed:" && btLastError()
      exit chDownloadSelected
   end if
   chLog "Downloading '" & (line 1 of tPost) & "' from channel" && chShortKey(tKey) & "..."
end chDownloadSelected

command chCopySelectedMagnet
   local tKey, tPost, tMag
   put chSelectedSubKey() into tKey
   if tKey is empty then
      chLog "Select a channel first."
      exit chCopySelectedMagnet
   end if
   put sFollowPosts[tKey] into tPost
   put line 2 of tPost into tMag
   if tMag is empty then
      chLog "Nothing to copy yet for that channel."
      exit chCopySelectedMagnet
   end if
   set the clipboardData["text"] to tMag
   chLog "Copied the magnet for" && chShortKey(tKey) & "."
end chCopySelectedMagnet

command chRefreshSubs
   local tKey, tRows, tLineNum, tPost, tTitle, tStatus, tMap, tSel
   put chSelectedSubKey() into tSel
   put "" into tRows
   put 0 into tLineNum
   put empty into tMap
   repeat for each line tKey in sFollows
      if tKey is empty then
         next repeat
      end if
      add 1 to tLineNum
      put tKey into tMap[tLineNum]
      put sFollowPosts[tKey] into tPost
      if tPost is empty then
         put "(no release fetched yet)" into tTitle
         put "-" into tStatus
      else
         put line 1 of tPost into tTitle
         if line 2 of tPost begins with "magnet:" then
            put "ready to download" into tStatus
         else
            put "no magnet" into tStatus
         end if
      end if
      put chShortKey(tKey) & tab & chTrunc(tTitle, 60) & tab & tStatus & return after tRows
   end repeat
   put tMap into sSubKeys
   if the last char of tRows is return then
      delete the last char of tRows
   end if
   lock screen
   set the text of field "chSubs" to tRows
   -- keep the previous selection on the same key if it is still present
   if tSel is not empty then
      repeat with tLineNum = 1 to (the number of lines of field "chSubs")
         if sSubKeys[tLineNum] is tSel then
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
   if sSession is 0 or sSession is empty then
      exit chRefreshTransfers
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
      put tLineNum & tab & chTrunc(tS["name"], 44) & tab & chStateName(tS["state"]) & tab & \
          tPct & "%" & tab & tS["numPeers"] & return after tRows
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
      put "DHT: on" into tDht
   end if
   lock screen
   set the text of field "chXfers" to tRows
   put tLineNum && "transfers     down" && (chFmtBytes(tDown) & "/s") && "    up" \
      && (chFmtBytes(tUp) & "/s") && "     " & tDht into field "chTotals"
   unlock screen
end chRefreshTransfers

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
   local tKey, tVal
   switch pEvent["name"]
      case "dhtMutableItem"
         put pEvent["publicKey"] into tKey
         put textDecode(pEvent["value"], "UTF-8") into tVal
         put tVal into sFollowPosts[tKey]
         chRefreshSubs
         chLog "Channel" && chShortKey(tKey) && "latest (v" & pEvent["seq"] & "):" && (line 1 of tVal)
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

function chSelectedSubKey
   local tNum
   set the itemDelimiter to comma   -- the hilitedLines is comma-delimited; itemDelimiter is global
   put item 1 of (the hilitedLines of field "chSubs") into tNum
   if tNum is empty or tNum is not a number then
      return ""
   end if
   if sSubKeys[tNum] is empty then
      return ""
   end if
   return sSubKeys[tNum]
end chSelectedSubKey

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
