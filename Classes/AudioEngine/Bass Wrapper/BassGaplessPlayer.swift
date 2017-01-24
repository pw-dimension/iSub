//
//  BassGaplessPlayer.swift
//  iSub
//
//  Created by Benjamin Baron on 1/20/17.
//  Copyright © 2017 Ben Baron. All rights reserved.
//

import Foundation
import AVFoundation

// TODO: Audit all numeric types, doing way too much casting
// TODO: Audit use of stream gcd queue, I left out all syncing when dealing with the streams array
// TODO: Audit all access to PlayQueue

fileprivate let deviceNumber: UInt32 = 1
fileprivate let bufferSize: UInt32 = 800
fileprivate let defaultSampleRate: UInt32 = 44100

fileprivate let retryDelay = 2.0
fileprivate let minSizeToFail: Int64 = 15 * 1024 * 1024 // 15MB

@objc class BassGaplessPlayer: NSObject {
    struct Notifications {
        static let songStarted          = Notification.Name("BassGaplessPlayer_songStarted")
        static let songPaused           = Notification.Name("BassGaplessPlayer_songPaused")
        static let songEnded            = Notification.Name("BassGaplessPlayer_songEnded")
    }
    
    static let si = BassGaplessPlayer()
    
    let bassStreamsQueue = DispatchQueue(label: "com.einsteinx2.BassStreamsQueue")
    var bassStreams = [BassStream]()
    var currentBassStream: BassStream? { return bassStreams.first }
    var bitRate: Int { return currentBassStream != nil ? estimateBitRate(bassStream: currentBassStream!) : 0 }
    var bassOutputBufferLengthMillis: UInt32 = 0
    
    let ringBuffer = EX2RingBuffer(bufferLength: 640 * 1024) // 640KB
    let ringBufferFillQueue = DispatchQueue(label: "com.einsteinx2.RingBufferQueue")
    var ringBufferFillWorkItem: DispatchWorkItem?
    var waitLoopBassStream: BassStream?
    
    var outStream: HSTREAM = 0
    var mixerStream: HSTREAM = 0
    
    let equalizer = BassEqualizer()
    let visualizer = BassVisualizer()
    
    var isPlaying = false
    var startByteOffset: Int64 = 0
    
    var ringBufferFillThread: Thread?
    
    var startSongRetryWorkItem = DispatchWorkItem(block: {})
    
    // TODO: Get rid of this
    var previousSongForProgress: Song?
    
    var lastProgressSaveDate = Date.distantPast
    let progressSaveInterval = 10.0
    
    override init() {
        super.init()
        NotificationCenter.addObserverOnMainThread(self, selector: #selector(handleInterruption(_:)), name: NSNotification.Name.AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
        NotificationCenter.addObserverOnMainThread(self, selector: #selector(routeChanged(_:)), name: NSNotification.Name.AVAudioSessionRouteChange, object: AVAudioSession.sharedInstance())
    }
    
    fileprivate var shouldResumeFromInterruption = false
    @objc fileprivate func handleInterruption(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSessionInterruptionType.began.rawValue {
            shouldResumeFromInterruption = isPlaying
            pause()
        } else {
            let shouldResume = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt == AVAudioSessionInterruptionOptions.shouldResume.rawValue
            if shouldResumeFromInterruption && shouldResume {
                play()
            }
            
            shouldResumeFromInterruption = false
        }
    }
    
    @objc fileprivate func routeChanged(_ notification: Notification) {
        if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSessionRouteChangeReason.oldDeviceUnavailable.rawValue {
            pause()
        }
    }
    
    deinit {
        NotificationCenter.removeObserverOnMainThread(self, name: NSNotification.Name.AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
        NotificationCenter.removeObserverOnMainThread(self, name: NSNotification.Name.AVAudioSessionRouteChange, object: AVAudioSession.sharedInstance())
    }
    
    // MARK: - Output Stream -
    
    func bassGetOutputData(buffer: UnsafeMutableRawPointer?, length: UInt32) -> UInt32 {
        guard let currentBassStream = currentBassStream, let buffer = buffer else {
            return 0
        }
        
        let bytesRead = ringBuffer.drainBytes(buffer, length: Int(length))
        
        if currentBassStream.isEnded {
            currentBassStream.bufferSpaceTilSongEnd -= bytesRead
            if currentBassStream.bufferSpaceTilSongEnd <= 0 {
                songEnded(bassStream: currentBassStream)
                currentBassStream.isEndedCalled = true
            }
        }
        
        let currentSong = currentBassStream.song
        if bytesRead == 0 && BASS_ChannelIsActive(currentBassStream.stream) == UInt32(BASS_ACTIVE_STOPPED) && (currentSong.isFullyCached || currentSong.isTempCached) {
            isPlaying = false
            
            if !currentBassStream.isEndedCalled {
                // Somehow songEnded: was never called
                // TODO: Is this necessary?
                songEnded(bassStream: currentBassStream)
                currentBassStream.isEndedCalled = true
            }
            
            NotificationCenter.postOnMainThread(name: Notifications.songEnded)
            
            DispatchQueue.main.async {
                self.cleanup()
            }
            
            // Start the next song if for some reason this one isn't ready
            PlayQueue.si.startSong()
            
            return BASS_STREAMPROC_END
        }
        
        let now = Date()
        if now.timeIntervalSince(lastProgressSaveDate) > progressSaveInterval {
            SavedSettings.si.seekTime = progress
            lastProgressSaveDate = now
        }
        
        return UInt32(bytesRead)
    }
    
    func moveToNextSong() {
        if PlayQueue.si.nextSong != nil {
            PlayQueue.si.playNextSong()
        } else {
            cleanup()
        }
    }
    
    // songEnded: is called AFTER MyStreamEndCallback, so the next song is already actually decoding into the ring buffer
    func songEnded(bassStream: BassStream) {
        BASS_SetDevice(deviceNumber)
        
        autoreleasepool {
            self.previousSongForProgress = bassStream.song
            self.ringBuffer.totalBytesDrained = 0
            
            bassStream.isEndedCalled = true
            
            // Remove the stream from the queue
            BASS_StreamFree(bassStream.stream)
            if let index = self.bassStreams.index(of: bassStream) {
                self.bassStreamsQueue.async {
                    self.bassStreams.remove(at: index)
                }
            }
            
            // Send song end notification
            NotificationCenter.postOnMainThread(name: Notifications.songEnded)
            
            if self.isPlaying {
                self.startByteOffset = 0
                
                // Send song start notification
                NotificationCenter.postOnMainThread(name: Notifications.songStarted)
                
                // Mark the last played time in the database for cache cleanup
                self.currentBassStream?.song.lastPlayed = Date()
            }
            
            if bassStream.isNextSongStreamFailed {
                nextSongStreamFailed()
            }
        }
    }
    
    func nextSongStreamFailed() {
        // The song ended, and we tried to make the next stream but it failed
        if let song = PlayQueue.si.currentSong {
            if let handler = StreamManager.si.streamHandler, song == StreamManager.si.song {
                if handler.isReadyForPlayback {
                    // If the song is downloading and it already informed the player to play (i.e. the playlist will stop if we don't force a retry), then retry
                    DispatchQueue.main.async {
                        PlayQueue.si.startSong()
                    }
                }
            } else if song.isFullyCached {
                DispatchQueue.main.async {
                    PlayQueue.si.startSong()
                }
            } else {
                StreamManager.si.start()
            }
        }
    }
    
    func bytesToBuffer(forKiloBitRate rate: Int, speedInBytesPerSec: Int) -> Int {
        // If start date is nil somehow, or total bytes transferred is 0 somehow, return the default of 10 seconds worth of audio
        if rate == 0 || speedInBytesPerSec == 0 {
            return Int(BytesForSecondsAtBitRate(seconds: 10, bitRate: rate))
        }
        
        // Get the download speed in KB/sec
        let kiloBytesPerSec = Double(speedInBytesPerSec) / 1024.0
        
        // Find out out many bytes equals 1 second of audio
        let bytesForOneSecond = Double(BytesForSecondsAtBitRate(seconds: 1, bitRate: rate))
        let kiloBytesForOneSecond = bytesForOneSecond / 1024.0
        
        // Calculate the amount of seconds to start as a factor of how many seconds of audio are being downloaded per second
        let secondsPerSecondFactor = kiloBytesPerSec / kiloBytesForOneSecond
        
        var numberOfSecondsToBuffer: Double
        if secondsPerSecondFactor < 0.5 {
            // Downloading very slow, buffer for a while
            numberOfSecondsToBuffer = 20
        } else if secondsPerSecondFactor >= 0.5 && secondsPerSecondFactor < 0.7 {
            // Downloading faster, but not much faster, allow for a long buffer period
            numberOfSecondsToBuffer = 12
        } else if secondsPerSecondFactor >= 0.7 && secondsPerSecondFactor < 0.9 {
            // Downloading not much slower than real time, use a smaller buffer period
            numberOfSecondsToBuffer = 8
        } else if secondsPerSecondFactor >= 0.9 && secondsPerSecondFactor < 1.0 {
            // Almost downloading full speed, just buffer for a short time
            numberOfSecondsToBuffer = 5
        } else {
            // We're downloading over the speed needed, so probably the connection loss was temporary? Just buffer for a very short time
            numberOfSecondsToBuffer = 2
        }
        
        // Convert from seconds to bytes
        let numberOfBytesToBuffer = numberOfSecondsToBuffer * bytesForOneSecond
        return Int(numberOfBytesToBuffer)
    }
    
    func keepRingBufferFilled() {
        // TODO: Will this self referencing of the work item actually work?
        var workItem: DispatchWorkItem! = nil
        workItem = DispatchWorkItem {
            // Make sure we're using the right device
            BASS_SetDevice(deviceNumber)
            
            // Grab the mixerStream and ringBuffer as local references, so that if cleanup is run, and we're still inside this loop
            // it won't start filling the new buffer
            let ringBuffer = self.ringBuffer
            let mixerStream = self.mixerStream
            
            autoreleasepool {
                let readSize = 64 * 1024
                while !workItem.isCancelled {
                    // Fill the buffer if there is empty space
                    if ringBuffer.freeSpaceLength > readSize {
                        autoreleasepool {
                            /*
                             * Read data to fill the buffer
                             */
                            
                            if let bassStream = self.currentBassStream {
                                let tempBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: readSize)
                                let tempLength = BASS_ChannelGetData(mixerStream, tempBuffer, UInt32(readSize))
                                if tempLength > 0 {
                                    bassStream.isSongStarted = true
                                    ringBuffer.fill(withBytes: tempBuffer, length: Int(tempLength))
                                }
                                tempBuffer.deallocate(capacity: readSize)
                                
                                /*
                                 * Handle pausing to wait for more data
                                 */
                                
                                if bassStream.isFileUnderrun && BASS_ChannelIsActive(bassStream.stream) != UInt32(BASS_ACTIVE_STOPPED) {
                                    // Get a strong reference to the current song's userInfo object, so that
                                    // if the stream is freed while the wait loop is sleeping, the object will
                                    // still be around to respond to shouldBreakWaitLoop
                                    self.waitLoopBassStream = bassStream
                                    
                                    // Mark the stream as waiting
                                    bassStream.isWaiting = true
                                    bassStream.isFileUnderrun = false
                                    bassStream.wasFileJustUnderrun = true
                                    
                                    // Handle waiting for additional data
                                    if !bassStream.song.isFullyCached {
                                        // Bail if the thread was canceled
                                        if workItem.isCancelled {
                                            return
                                        }
                                        
                                        if SavedSettings.si.isOfflineMode {
                                            // This is offline mode and the song can not continue to play
                                            self.moveToNextSong()
                                        } else {
                                            // Calculate the needed size:
                                            // Choose either the current player bitRate, or if for some reason it is not detected properly,
                                            // use the best estimated bitRate. Then use that to determine how much data to let download to continue.
                                            
                                            let size = bassStream.song.localFileSize
                                            let bitRate = self.estimateBitRate(bassStream: bassStream)
                                            
                                            // Get the stream for this song
                                            var recentDownloadSpeedInBytesPerSec = 0
                                            if StreamManager.si.song == bassStream.song, let handler = StreamManager.si.streamHandler {
                                                recentDownloadSpeedInBytesPerSec = handler.recentDownloadSpeedInBytesPerSec
                                            } else if CacheQueueManager.si.currentSong == bassStream.song, let handler = CacheQueueManager.si.streamHandler {
                                                recentDownloadSpeedInBytesPerSec = handler.recentDownloadSpeedInBytesPerSec
                                            }
                                            
                                            // Calculate the bytes to wait based on the recent download speed. If the handler is nil or recent download speed is 0
                                            // it will just use the default (currently 10 seconds)
                                            let bytesToWait = self.bytesToBuffer(forKiloBitRate: bitRate, speedInBytesPerSec: recentDownloadSpeedInBytesPerSec)
                                            
                                            bassStream.neededSize = size + bytesToWait
                                            
                                            // Sleep for 100000 microseconds, or 1/10th of a second
                                            let sleepTime: UInt32 = 100000
                                            // Check file size every second, so 1000000 microseconds
                                            let fileSizeCheckWait: UInt32 = 1000000
                                            var totalSleepTime: UInt32 = 0
                                            while true {
                                                // Bail if the thread was canceled
                                                if workItem.isCancelled {
                                                    return
                                                }
                                                
                                                // Check if we should break every 10th of a second
                                                usleep(sleepTime)
                                                totalSleepTime += sleepTime
                                                if bassStream.shouldBreakWaitLoop || bassStream.shouldBreakWaitLoopForever {
                                                    return
                                                }
                                                
                                                // Bail if the thread was canceled
                                                if workItem.isCancelled {
                                                    return
                                                }
                                                
                                                // Only check the file size every second
                                                if totalSleepTime >= fileSizeCheckWait {
                                                    autoreleasepool {
                                                        totalSleepTime = 0
                                                        
                                                        if bassStream.localFileSize >= bassStream.neededSize {
                                                            // If enough of the file has downloaded, break the loop
                                                            return
                                                        } else if bassStream.song.isTempCached && bassStream.song != StreamManager.si.song {
                                                            // Handle temp cached songs ending. When they end, they are set as the last temp cached song, so we know it's done and can stop waiting for data.
                                                            return
                                                        } else if bassStream.song.isFullyCached {
                                                            // If the song has finished caching, we can stop waiting
                                                            return
                                                        } else if SavedSettings.si.isOfflineMode {
                                                            // If we're not in offline mode, stop waiting and try next song
                                                            // Bail if the thread was canceled
                                                            if workItem.isCancelled {
                                                                return
                                                            }
                                                            
                                                            self.moveToNextSong()
                                                            return
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    
                                    // Bail if the thread was canceled
                                    if workItem.isCancelled {
                                        return
                                    }
                                    
                                    bassStream.isWaiting = false
                                    bassStream.shouldBreakWaitLoop = false
                                    self.waitLoopBassStream = nil
                                }
                            }
                        }
                    }
                    
                    // Bail if the thread was canceled
                    if workItem.isCancelled {
                        return
                    }
                    
                    // Sleep for 1/4th of a second to prevent a tight loop
                    usleep(150000)
                }
            }
        }
        ringBufferFillWorkItem = workItem
    }
    
    // MARK: - BASS Methods -
    
    fileprivate func bassInit() {
        // Free BASS just in case we use this after launch
        BASS_Free()
        
        // Disable mixing. To be called before BASS_Init.
        BASS_SetConfig(UInt32(BASS_CONFIG_IOS_MIXAUDIO), 0)
        // Set the buffer length to the minimum amount + bufferSize
        BASS_SetConfig(UInt32(BASS_CONFIG_BUFFER), BASS_GetConfig(UInt32(BASS_CONFIG_UPDATEPERIOD)) + bufferSize)
        // Set DSP effects to use floating point math to avoid clipping within the effects chain
        BASS_SetConfig(UInt32(BASS_CONFIG_FLOATDSP), 1)
        // Initialize default device.
        if (BASS_Init(1, defaultSampleRate, 0, nil, nil))
        {
            bassOutputBufferLengthMillis = BASS_GetConfig(UInt32(BASS_CONFIG_BUFFER))
            
            // Load the Flac plugin
            BASS_PluginLoad(BASSFLACplugin.assumingMemoryBound(to: Int8.self), 0)
            // Load the WavePack plugin
            BASS_PluginLoad(BASSWVplugin.assumingMemoryBound(to: Int8.self), 0)
            // Load the Monkey's Audio plugin
            BASS_PluginLoad(BASS_APEplugin.assumingMemoryBound(to: Int8.self), 0)
            // Load the MusePack plugin
            //BASS_PluginLoad(BASS_MPCplugin.assumingMemoryBound(to: Int8.self), 0)
            // load the OPUS plugin
            BASS_PluginLoad(BASSOPUSplugin.assumingMemoryBound(to: Int8.self), 0)
        }
        else
        {
            bassOutputBufferLengthMillis = 0
            printError("Can't initialize device")
            printBassError()
        }

    }
    
    fileprivate func printChannelInfo(_ channel: HSTREAM) {
        var i = BASS_CHANNELINFO()
        BASS_ChannelGetInfo(channel, &i)
        let bytes = BASS_ChannelGetLength(channel, UInt32(BASS_POS_BYTE))
        let time = BASS_ChannelBytes2Seconds(channel, bytes)
        print("channel type = \(i.ctype) (\(formatForChannel(channel)))\nlength = \(bytes) (seconds: \(time)  flags: \(i.flags)  freq: \(i.freq)  origres: \(i.origres)")
    }
    
    fileprivate func formatForChannel(_ channel: HSTREAM) -> String {
        var i = BASS_CHANNELINFO()
        BASS_ChannelGetInfo(channel, &i)
        
        /*if (plugin)
         {
         // using a plugin
         const BASS_PLUGININFO *pinfo=BASS_PluginGetInfo(plugin) // get plugin info
         int a
         for (a=0a<pinfo->formatca++)
         {
         if (pinfo->formats[a].ctype==ctype) // found a "ctype" match...
         return [NSString stringWithFormat:"%s", pinfo->formats[a].name] // return it's name
         }
         }*/
        
        switch Int32(i.ctype) {
        case BASS_CTYPE_STREAM_WV:        return "WV"
        case BASS_CTYPE_STREAM_MPC:       return "MPC"
        case BASS_CTYPE_STREAM_APE:       return "APE"
        case BASS_CTYPE_STREAM_FLAC:      return "FLAC"
        case BASS_CTYPE_STREAM_FLAC_OGG:  return "FLAC"
        case BASS_CTYPE_STREAM_OGG:       return "OGG"
        case BASS_CTYPE_STREAM_MP1:       return "MP1"
        case BASS_CTYPE_STREAM_MP2:       return "MP2"
        case BASS_CTYPE_STREAM_MP3:       return "MP3"
        case BASS_CTYPE_STREAM_AIFF:      return "AIFF"
        case BASS_CTYPE_STREAM_OPUS:      return "Opus"
        case BASS_CTYPE_STREAM_WAV_PCM:   return "PCM WAV"
        case BASS_CTYPE_STREAM_WAV_FLOAT: return "Float WAV"
        // Check if WAV case works
        case BASS_CTYPE_STREAM_WAV: return "WAV"
        case BASS_CTYPE_STREAM_CA:
            // CoreAudio codec
            guard let tags = BASS_ChannelGetTags(channel, UInt32(BASS_TAG_CA_CODEC)) else {
                return ""
            }
            
            return tags.withMemoryRebound(to: TAG_CA_CODEC.self, capacity: 1) { pointer in
                let codec: TAG_CA_CODEC = pointer.pointee
                switch codec.atype {
                case kAudioFormatLinearPCM:            return "LPCM"
                case kAudioFormatAC3:                  return "AC3"
                case kAudioFormat60958AC3:             return "AC3"
                case kAudioFormatAppleIMA4:            return "IMA4"
                case kAudioFormatMPEG4AAC:             return "AAC"
                case kAudioFormatMPEG4CELP:            return "CELP"
                case kAudioFormatMPEG4HVXC:            return "HVXC"
                case kAudioFormatMPEG4TwinVQ:          return "TwinVQ"
                case kAudioFormatMACE3:                return "MACE 3:1"
                case kAudioFormatMACE6:                return "MACE 6:1"
                case kAudioFormatULaw:                 return "μLaw 2:1"
                case kAudioFormatALaw:                 return "aLaw 2:1"
                case kAudioFormatQDesign:              return "QDMC"
                case kAudioFormatQDesign2:             return "QDM2"
                case kAudioFormatQUALCOMM:             return "QCPV"
                case kAudioFormatMPEGLayer1:           return "MP1"
                case kAudioFormatMPEGLayer2:           return "MP2"
                case kAudioFormatMPEGLayer3:           return "MP3"
                case kAudioFormatTimeCode:             return "TIME"
                case kAudioFormatMIDIStream:           return "MIDI"
                case kAudioFormatParameterValueStream: return "APVS"
                case kAudioFormatAppleLossless:        return "ALAC"
                case kAudioFormatMPEG4AAC_HE:          return "AAC-HE"
                case kAudioFormatMPEG4AAC_LD:          return "AAC-LD"
                case kAudioFormatMPEG4AAC_ELD:         return "AAC-ELD"
                case kAudioFormatMPEG4AAC_ELD_SBR:     return "AAC-SBR"
                case kAudioFormatMPEG4AAC_HE_V2:       return "AAC-HEv2"
                case kAudioFormatMPEG4AAC_Spatial:     return "AAC-S"
                case kAudioFormatAMR:                  return "AMR"
                case kAudioFormatAudible:              return "AUDB"
                case kAudioFormatiLBC:                 return "iLBC"
                case kAudioFormatDVIIntelIMA:          return "ADPCM"
                case kAudioFormatMicrosoftGSM:         return "GSM"
                case kAudioFormatAES3:                 return "AES3"
                default: return ""
                }
            }
        default: return ""
        }
    }
    
    // TODO: Double check this logic
    func estimateBitRate(bassStream: BassStream) -> Int {
        // Default to the player bitRate
        let startFilePosition: UInt64 = 0
        let currentFilePosition = BASS_StreamGetFilePosition(bassStream.stream, UInt32(BASS_FILEPOS_CURRENT))
        let filePosition = currentFilePosition - startFilePosition
        let decodedPosition = BASS_ChannelGetPosition(bassStream.stream, UInt32(BASS_POS_BYTE|BASS_POS_DECODE)) // decoded PCM position
        let bitRateDouble = Double(filePosition) * 8.0 / Double(BASS_ChannelBytes2Seconds(bassStream.stream, decodedPosition))
        var bitRate = Int(bitRateDouble / 1000.0)
        bitRate = bitRate > 1000000 ? -1 : bitRate
        
        var i = BASS_CHANNELINFO()
        BASS_ChannelGetInfo(bassStream.stream, &i)
        
        // Check the current stream format, and make sure that the bitRate is in the correct range
        // otherwise use the song's estimated bitRate instead (to keep something like a 10000 kbitRate on an mp3 from being used for buffering)
        switch Int32(i.ctype) {
        case BASS_CTYPE_STREAM_WAV_PCM,
             BASS_CTYPE_STREAM_WAV_FLOAT,
             BASS_CTYPE_STREAM_WAV,
             BASS_CTYPE_STREAM_AIFF,
             BASS_CTYPE_STREAM_WV,
             BASS_CTYPE_STREAM_FLAC,
             BASS_CTYPE_STREAM_FLAC_OGG:
            if bitRate < 330 || bitRate > 12000 {
                bitRate = bassStream.song.estimatedBitRate
            }
        case BASS_CTYPE_STREAM_OGG,
             BASS_CTYPE_STREAM_MP1,
             BASS_CTYPE_STREAM_MP2,
             BASS_CTYPE_STREAM_MP3,
             BASS_CTYPE_STREAM_MPC:
            if bitRate > 450 {
                bitRate = bassStream.song.estimatedBitRate
            }
        case BASS_CTYPE_STREAM_CA:
            // CoreAudio codec
            guard let tags = BASS_ChannelGetTags(bassStream.stream, UInt32(BASS_TAG_CA_CODEC)) else {
                bitRate = bassStream.song.estimatedBitRate
                break
            }
            
            tags.withMemoryRebound(to: TAG_CA_CODEC.self, capacity: 1) { pointer in
                let codec: TAG_CA_CODEC = pointer.pointee
                switch codec.atype {
                case kAudioFormatLinearPCM,
                     kAudioFormatAppleLossless:
                    if bitRate < 330 || bitRate > 12000 {
                        bitRate = bassStream.song.estimatedBitRate
                    }
                case kAudioFormatMPEG4AAC,
                     kAudioFormatMPEG4AAC_HE,
                     kAudioFormatMPEG4AAC_LD,
                     kAudioFormatMPEG4AAC_ELD,
                     kAudioFormatMPEG4AAC_ELD_SBR,
                     kAudioFormatMPEG4AAC_HE_V2,
                     kAudioFormatMPEG4AAC_Spatial,
                     kAudioFormatMPEGLayer1,
                     kAudioFormatMPEGLayer2,
                     kAudioFormatMPEGLayer3:
                    if bitRate > 450 {
                        bitRate = bassStream.song.estimatedBitRate;
                    }
                default:
                    // If we can't detect the format, use the estimated bitRate instead of player to be safe
                    bitRate = bassStream.song.estimatedBitRate
                }
            }
        default:
            // If we can't detect the format, use the estimated bitRate instead of player to be safe
            bitRate = bassStream.song.estimatedBitRate
        }
        
        return bitRate
    }
    
    func string(fromErrorCode errorCode: Int32) -> String {
        switch errorCode {
        case BASS_OK:             return "No error! All OK"
        case BASS_ERROR_MEM:      return "Memory error"
        case BASS_ERROR_FILEOPEN: return "Can't open the file"
        case BASS_ERROR_DRIVER:   return "Can't find a free/valid driver"
        case BASS_ERROR_BUFLOST:  return "The sample buffer was lost"
        case BASS_ERROR_HANDLE:   return "Invalid handle"
        case BASS_ERROR_FORMAT:   return "Unsupported sample format"
        case BASS_ERROR_POSITION: return "Invalid position"
        case BASS_ERROR_INIT:     return "BASS_Init has not been successfully called"
        case BASS_ERROR_START:    return "BASS_Start has not been successfully called"
        case BASS_ERROR_ALREADY:  return "Already initialized/paused/whatever"
        case BASS_ERROR_NOCHAN:   return "Can't get a free channel"
        case BASS_ERROR_ILLTYPE:  return "An illegal type was specified"
        case BASS_ERROR_ILLPARAM: return "An illegal parameter was specified"
        case BASS_ERROR_NO3D:     return "No 3D support"
        case BASS_ERROR_NOEAX:    return "No EAX support"
        case BASS_ERROR_DEVICE:   return "Illegal device number"
        case BASS_ERROR_NOPLAY:   return "Not playing"
        case BASS_ERROR_FREQ:     return "Illegal sample rate"
        case BASS_ERROR_NOTFILE:  return "The stream is not a file stream"
        case BASS_ERROR_NOHW:     return "No hardware voices available"
        case BASS_ERROR_EMPTY:    return "The MOD music has no sequence data"
        case BASS_ERROR_NONET:    return "No internet connection could be opened"
        case BASS_ERROR_CREATE:   return "Couldn't create the file"
        case BASS_ERROR_NOFX:     return "Effects are not available"
        case BASS_ERROR_NOTAVAIL: return "Requested data is not available"
        case BASS_ERROR_DECODE:   return "The channel is a 'decoding channel'"
        case BASS_ERROR_DX:       return "A sufficient DirectX version is not installed"
        case BASS_ERROR_TIMEOUT:  return "Connection timedout"
        case BASS_ERROR_FILEFORM: return "Unsupported file format"
        case BASS_ERROR_SPEAKER:  return "Unavailable speaker"
        case BASS_ERROR_VERSION:  return "Invalid BASS version (used by add-ons)"
        case BASS_ERROR_CODEC:    return "Codec is not available/supported"
        case BASS_ERROR_ENDED:    return "The channel/file has ended"
        case BASS_ERROR_BUSY:     return "The device is busy"
        default:                  return "Unknown error."
        }
    }
    
    func printBassError(file: String = #file, line: Int = #line, function: String = #function) {
        let errorCode = BASS_ErrorGetCode()
        printError("BASS error: \(errorCode) - \(string(fromErrorCode: errorCode))", file: file, line: line, function: function)
    }
    
    fileprivate func cleanup() {
        BASS_SetDevice(deviceNumber)
        
        bassStreamsQueue.async {
            autoreleasepool {
                self.startSongRetryWorkItem.cancel()
                self.ringBufferFillThread?.cancel()
                
                for bassStream in self.bassStreams {
                    bassStream.shouldBreakWaitLoopForever = true
                    BASS_Mixer_ChannelRemove(bassStream.stream)
                    BASS_StreamFree(bassStream.stream)
                }
                
                self.equalizer.removeValues()
                
                BASS_StreamFree(self.mixerStream)
                BASS_StreamFree(self.outStream)
                
                self.ringBuffer.reset()
                self.bassStreams.removeAll()
                
                do {
                    try AVAudioSession.sharedInstance().setActive(false)
                } catch {
                    printError(error)
                }
                
                self.isPlaying = false
            }
        }
    }
    
    func testStream(forSong song: Song) -> Bool {
        guard song.fileExists else {
            return false
        }
        
        BASS_SetDevice(deviceNumber)
        
        var fileStream: HSTREAM = 0
        song.currentPath.withCString { unsafePointer in
            fileStream = BASS_StreamCreateFile(false, unsafePointer, 0, UInt64(song.size), UInt32(BASS_STREAM_DECODE|BASS_SAMPLE_FLOAT))
            if fileStream == 0 {
                fileStream = BASS_StreamCreateFile(false, unsafePointer, 0, UInt64(song.size), UInt32(BASS_STREAM_DECODE|BASS_SAMPLE_SOFTWARE|BASS_SAMPLE_FLOAT))
            }
        }
        return fileStream > 0
    }
    
    func prepareStream(forSong song: Song) -> BassStream? {
        guard song.fileExists, let bassStream = BassStream(song: song) else {
            return nil
        }
        
        BASS_SetDevice(deviceNumber)
        
        var fileStream = BASS_StreamCreateFileUser(UInt32(STREAMFILE_NOBUFFER), UInt32(BASS_STREAM_DECODE|BASS_SAMPLE_FLOAT), &fileProcs, bridge(obj: bassStream))
        
        // First check if the stream failed because of a BASS_Init error
        if fileStream == 0 && BASS_ErrorGetCode() == BASS_ERROR_INIT {
            // Retry the regular hardware sampling stream
            bassInit()
            fileStream = BASS_StreamCreateFileUser(UInt32(STREAMFILE_NOBUFFER), UInt32(BASS_STREAM_DECODE|BASS_SAMPLE_FLOAT), &fileProcs, bridge(obj: bassStream))
        }
        
        if fileStream == 0 {
            printBassError()
            fileStream = BASS_StreamCreateFileUser(UInt32(STREAMFILE_NOBUFFER), UInt32(BASS_STREAM_DECODE|BASS_SAMPLE_SOFTWARE|BASS_SAMPLE_FLOAT), &fileProcs, bridge(obj: bassStream))
        }
        
        if fileStream > 0 {
            // Add the stream free callback
            BASS_ChannelSetSync(fileStream, UInt32(BASS_SYNC_END|BASS_SYNC_MIXTIME), 0, endSyncProc, bridge(obj: bassStream))
            
            // Ask BASS how many channels are on this stream
            var info = BASS_CHANNELINFO()
            BASS_ChannelGetInfo(fileStream, &info)
            bassStream.channelCount = Int(info.chans)
            bassStream.sampleRate = Int(info.freq)
            
            // Stream successfully created
            bassStream.stream = fileStream
            // TODO: Uncomment
//            bassStream.player = self
            return bassStream
        }
        
        printBassError()
        return nil
    }
    
    func start(song: Song, index: Int, byteOffset: Int64) {
        bassStreamsQueue.async {
            autoreleasepool {
                BASS_SetDevice(deviceNumber)
                
                self.startByteOffset = 0
                self.cleanup()
                
                guard song.fileExists else {
                    return
                }
                
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    printError(error)
                }
                
                if let bassStream = self.prepareStream(forSong: song) {
                    self.mixerStream = BASS_Mixer_StreamCreate(UInt32(defaultSampleRate), 2, UInt32(BASS_STREAM_DECODE))
                    BASS_Mixer_StreamAddChannel(self.mixerStream, bassStream.stream, UInt32(BASS_MIXER_NORAMPIN))
                    
                    func streamProc(handle: HSYNC, buffer: UnsafeMutableRawPointer?, length: UInt32, userInfo: UnsafeMutableRawPointer?) -> UInt32 {
                        var bytesRead: UInt32 = 0
                        if let userInfo = userInfo {
                            autoreleasepool {
                                let player: BassGaplessPlayer = bridge(ptr: userInfo)
                                bytesRead = player.bassGetOutputData(buffer: buffer, length: length)
                            }
                        }
                        return bytesRead
                    }
                    self.outStream = BASS_StreamCreate(UInt32(defaultSampleRate), 2, 0, streamProc, bridge(obj: self))
                    
                    if SavedSettings.si.isEqualizerOn {
                        self.equalizer.channel  = self.outStream
                        self.equalizer.applyValues()
                    }
                    
                    self.ringBuffer.totalBytesDrained = 0
                    
                    BASS_Start()
                    
                    // Add the slide callback to handle fades
                    BASS_ChannelSetSync(self.outStream, UInt32(BASS_SYNC_SLIDE), 0, slideSyncProc, bridge(obj: self))
                    
                    self.visualizer.channel = self.outStream
                    self.equalizer.channel = self.outStream
                    
                    // Add gain amplification
                    //self.equalizer.createVolumeFx()
                    
                    // Add the stream to the queue
                    self.bassStreams.append(bassStream)
                    
                    // Skip to the byte offset
                    self.startByteOffset = byteOffset
                    self.ringBuffer.totalBytesDrained = byteOffset
                    if byteOffset > 0 {
                        self.seek(bytes: byteOffset, fade: false)
                    }
                    
                    // Start filling the ring buffer
                    self.keepRingBufferFilled()
                    
                    // Start playback
                    BASS_ChannelPlay(self.outStream, false)
                    self.isPlaying = true
                    
                    // Notify listeners that playback has started
                    NotificationCenter.postOnMainThread(name: Notifications.songStarted)
                    
                    song.lastPlayed = Date()
                } else if !song.isFullyCached && song.localFileSize < minSizeToFail {
                    if SavedSettings.si.isOfflineMode {
                        self.moveToNextSong()
                    } else if !song.fileExists {
                        // File was removed, so start again normally
                        _ = song.deleteCache()
                        PlayQueue.si.startSong()
                    } else {
                        // Failed to create the stream, retrying
                        self.startSongRetryWorkItem = DispatchWorkItem {
                            self.start(song: song, index: index, byteOffset: byteOffset)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: self.startSongRetryWorkItem)
                    }
                } else {
                    _ = song.deleteCache()
                    PlayQueue.si.startSong()
                }
            }
        }
    }
    
    // MARK: - Audio Engine Properties -
    
    var isStarted: Bool {
        if let currentBassStream = currentBassStream, currentBassStream.stream != 0 {
            return true
        }
        return false
    }
    
    var currentByteOffset: Int64 {
        if let currentBassStream = currentBassStream {
            return Int64(BASS_StreamGetFilePosition(currentBassStream.stream, DWORD(BASS_FILEPOS_CURRENT))) + startByteOffset
        }
        return 0
    }
    
    var rawProgress: Double {
        guard let currentBassStream = currentBassStream else {
            return 0
        }
        
        BASS_SetDevice(deviceNumber)
        
        var pcmBytePosition = Int64(BASS_Mixer_ChannelGetPosition(currentBassStream.stream, DWORD(BASS_POS_BYTE)))
        
        let chanCount = currentBassStream.channelCount
        let denom = (2.0 * (1.0 / Double(chanCount)))
        let realPosition = pcmBytePosition - Int64(Double(ringBuffer.filledSpaceLength) / denom)
        
        let sampleRateRatio = Double(currentBassStream.sampleRate) / Double(defaultSampleRate)
        
        pcmBytePosition = realPosition
        pcmBytePosition = pcmBytePosition < 0 ? 0 : pcmBytePosition
        let seconds = BASS_ChannelBytes2Seconds(currentBassStream.stream, UInt64(Double(ringBuffer.totalBytesDrained) * sampleRateRatio * Double(chanCount)))
        
        return seconds
    }
    
    // TODO: Prevent divide by 0
    var progress: Double {
        guard let currentBassStream = currentBassStream else {
            return 0
        }
        
        let seconds = rawProgress
        if seconds < 0 {
            // Use the previous song (i.e the one still coming out of the speakers), since we're actually finishing it right now
            let prevDuration = previousSongForProgress?.duration ?? 0
            return Double(prevDuration) + seconds
        }
        
        return seconds + BASS_ChannelBytes2Seconds(currentBassStream.stream, QWORD(startByteOffset))
    }
    
    var progressPercent: Double {
        guard let currentBassStream = currentBassStream else {
            return 0
        }
        
        var seconds = rawProgress
        if seconds < 0 {
            if let duration = previousSongForProgress?.duration {
                seconds = Double(duration) + seconds
                return seconds / Double(duration)
            }
            return 0
        }
        
        if let duration = currentBassStream.song.duration {
            return seconds / Double(duration)
        }
        return 0
    }
    
    // MARK: - Playback Methods -
    
    func stop() {
        BASS_SetDevice(deviceNumber)
        
        if isPlaying {
            BASS_Pause()
            isPlaying = false
            NotificationCenter.postOnMainThread(name: Notifications.songEnded)
        }
        
        cleanup()
    }
    
    func play() {
        if !isPlaying {
            playPause()
        }
    }
    
    func pause() {
        if isPlaying {
            playPause()
        }
    }
    
    // TODO: Refactor how this delegate shit works
    func playPause() {
        BASS_SetDevice(deviceNumber)
        
        if isPlaying {
            BASS_Pause()
            isPlaying = false
            NotificationCenter.postOnMainThread(name: Notifications.songPaused)
        } else if currentBassStream == nil {
            // See if we're at the end of the playlist
            if PlayQueue.si.currentSong != nil {
                PlayQueue.si.startSong(byteOffset: BassGaplessPlayer.si.startByteOffset)
            } else {
                DispatchQueue.main.async {
                    PlayQueue.si.playPreviousSong()
                }
            }
        } else {
            BASS_Start()
            isPlaying = true
            NotificationCenter.postOnMainThread(name: Notifications.songStarted)
        }
    }
    
    func seek(bytes: Int64, fade: Bool = true) {
        BASS_SetDevice(deviceNumber)
        
        guard let currentBassStream = currentBassStream else {
            return
        }
        
        currentBassStream.isEnded = false
        
        if BASS_Mixer_ChannelSetPosition(currentBassStream.stream, UInt64(bytes), UInt32(BASS_POS_BYTE)) {
            currentBassStream.neededSize = Int64.max
            if currentBassStream.isWaiting {
                currentBassStream.shouldBreakWaitLoop = true
            }
            
            ringBuffer.reset()
            
            if fade {
                BASS_ChannelSlideAttribute(outStream, UInt32(BASS_ATTRIB_VOL), 0, bassOutputBufferLengthMillis)
            }
            
            ringBuffer.totalBytesDrained = Int64(Double(bytes) / Double(currentBassStream.channelCount) / (Double(currentBassStream.sampleRate) / Double(defaultSampleRate)))
        } else {
            printBassError()
        }
    }
    
    func seek(seconds: Double, fade: Bool = true) {
        if let currentBassStream = currentBassStream {
            BASS_SetDevice(deviceNumber)
            
            let bytes = BASS_ChannelSeconds2Bytes(currentBassStream.stream, seconds)
            seek(bytes: Int64(bytes), fade: fade)
        }
    }
    
    func seek(percent: Double, fade: Bool = true) {
        if let currentBassStream = currentBassStream, let duration = currentBassStream.song.duration {
            let seconds = Double(duration) * percent
            seek(seconds: seconds, fade: fade)
        }
    }
}

// MARK: - File Procs -

var fileProcs = BASS_FILEPROCS(close: closeProc, length: lengthProc, read: readProc, seek: seekProc)

func closeProc(userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo = userInfo else {
        return
    }
    
    autoreleasepool {
        // Get the user info object
        let bassStream: BassStream = bridge(ptr: userInfo)
        
        // Tell the read wait loop to break in case it's waiting
        bassStream.shouldBreakWaitLoop = true
        bassStream.shouldBreakWaitLoopForever = true
        
        do {
            try ObjC.catchException({bassStream.fileHandle.closeFile()})
        } catch {
            printError(error)
        }
    }
}

func lengthProc(userInfo: UnsafeMutableRawPointer?) -> UInt64 {
    guard let userInfo = userInfo else {
        return 0
    }
    
    var length: Int64 = 0
    autoreleasepool {
        let bassStream: BassStream = bridge(ptr: userInfo)
        if bassStream.shouldBreakWaitLoopForever {
            // TODO: Why do we return 0 here?
            length = 0
        } else if bassStream.song.isFullyCached || bassStream.isTempCached {
            // Return actual file size on disk
            length = bassStream.song.localFileSize
        } else {
            // Return server reported file size
            length = bassStream.song.size
        }
    }
    
    return UInt64(length)
}

func readProc(buffer: UnsafeMutableRawPointer?, length: UInt32, userInfo: UnsafeMutableRawPointer?) -> UInt32 {
    guard let buffer = buffer, let userInfo = userInfo else {
        return 0
    }
    
    let bufferPointer = UnsafeMutableBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: Int(length))
    var bytesRead: UInt32 = 0
    autoreleasepool {
        let bassStream: BassStream = bridge(ptr: userInfo)
        
        // Read from the file
        var readData = Data()
        do {
            try ObjC.catchException {
                readData = bassStream.fileHandle.readData(ofLength: Int(length))
            }
        } catch {
            printError(error)
        }
        
        bytesRead = UInt32(readData.count)
        if bytesRead > 0 {
            // Copy the data to the buffer
            bytesRead = UInt32(readData.copyBytes(to: bufferPointer))
        }
        
        if bytesRead < length && bassStream.isSongStarted && !bassStream.wasFileJustUnderrun {
            bassStream.isFileUnderrun = true
        }
        
        bassStream.wasFileJustUnderrun = false
    }
    
    return bytesRead
}

func seekProc(offset: UInt64, userInfo: UnsafeMutableRawPointer?) -> ObjCBool {
    guard let userInfo = userInfo else {
        return false
    }
    
    var success = false
    autoreleasepool {
        // Seek to the requested offset (returns false if data not downloaded that far)
        let userInfo: BassStream = bridge(ptr: userInfo)
        
        // First check the file size to make sure we don't try and skip past the end of the file
        if userInfo.song.localFileSize >= Int64(offset) {
            // File size is valid, so assume success unless the seek operation throws an exception
            success = true
            do {
                try ObjC.catchException {
                    userInfo.fileHandle.seek(toFileOffset: offset)
                }
            } catch {
                success = false
            }
        }
    }
    return ObjCBool(success)
}

// MARK: - Sync Procs -

func slideSyncProc(handle: HSYNC, channel: UInt32, data: UInt32, userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo = userInfo else {
        return
    }
    
    BASS_SetDevice(deviceNumber)
    
    autoreleasepool {
        let player: BassGaplessPlayer = bridge(ptr: userInfo)
        
        var volumeLevel: Float = 0
        let success = BASS_ChannelGetAttribute(player.outStream, UInt32(BASS_ATTRIB_VOL), &volumeLevel)
        
        if success && volumeLevel == 0.0 {
            BASS_ChannelSlideAttribute(player.outStream, UInt32(BASS_ATTRIB_VOL), 1, 200)
        }
    }
}

func endSyncProc(handle: HSYNC, channel: UInt32, data: UInt32, userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo = userInfo else {
        return
    }
    
    // Make sure we're using the right device
    BASS_SetDevice(deviceNumber)
    
    autoreleasepool {
        // This must be done in the stream GCD queue because if we do it in this thread
        // it will pause the audio output momentarily while it's loading the stream
        let bassStream: BassStream = bridge(ptr: userInfo)
        if let player = bassStream.player, let nextSong = PlayQueue.si.nextSong {
            player.bassStreamsQueue.async {
                // Prepare the next song in the queue
                let nextStream = player.prepareStream(forSong: nextSong)
                if let nextStream = nextStream {
                    player.bassStreams.append(nextStream)
                    BASS_Mixer_StreamAddChannel(player.mixerStream, nextStream.stream, UInt32(BASS_MIXER_NORAMPIN))
                } else {
                    bassStream.isNextSongStreamFailed = true
                }
                
                // Mark as ended and set the buffer space til end for the UI
                bassStream.bufferSpaceTilSongEnd = player.ringBuffer.filledSpaceLength
                bassStream.isEnded = true
            }
        }
    }
}
