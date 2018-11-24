import Foundation
import UIKit
import MultipeerConnectivity


let kSessionType = "wist-session"
let kMCFileReceivedURL = "FileReceivedURL"
let kServiceType = "wist-service"
let kMCBrowserDismissNotification =  NSNotification.Name(rawValue:"kMCBrowserDismissNotification")
let kMCFileReceivedNotification =  NSNotification.Name(rawValue:"kMCFileReceivedNotification")


@objc protocol KorgWirelessSyncStartDelegate {
    //  Indicates a command was received from master
    func wistStartCommandReceived(_ hostTime: UInt64, withTempo tempo: Float)
    func wistStopCommandReceived(_ hostTime: UInt64)
    
    //  Indicates a state change
    func wistConnectionCancelled()
    func wistConnectionEstablished()
    func wistConnectionLost()
}

var timeInfo = mach_timebase_info_data_t()
func hostTime2NanoSec(_ hostTime: UInt64) -> UInt64 {
    mach_timebase_info(&timeInfo)
    return hostTime * UInt64(timeInfo.numer / timeInfo.denom)
}
//  ---------------------------------------------------------------------------
//      nanoSec2HostTime
//  ---------------------------------------------------------------------------
func nanoSec2HostTime(_ nanosec: UInt64) -> UInt64 {
    mach_timebase_info(&timeInfo)
    return nanosec * UInt64(timeInfo.denom / timeInfo.numer)
}


let beaconCommand:Int = 0 //  master -> slave -> master
let startSlaveCommand:Int = 1
let stopSlaveCommand:Int = 2
let requestLatencyCommand:Int = 3
let latencyCommand:Int = 4
let peersLatencyChangedCommand:Int = 5
let requestDelayCommand:Int = 6
let delayCommand:Int = 7

@objcMembers
class KorgWirelessSyncStart:NSObject{
    var mutableBlockedPeers: [AnyHashable] = []
    
    
    var browser: MCBrowserViewController?
    var peerID: MCPeerID?
    var advertiser: MCAdvertiserAssistant?
    var session: MCSession?
    var delegate: KorgWirelessSyncStartDelegate?
    
    var doDisconnectByMyself = false
    var delay: UInt64 = 0
    var peerdelay: UInt64 = 0
    var gotPeerdelay = false
    var gkWorstdelay: UInt64 = 0
    var beaconReceived = false
    var timeDiff: Double = 0.0
    
    var peerlatency: UInt64 = 0
    var gotPeerlatency = false
    var timer: Timer?
    var isConnected = false
    var isMaster = false
    
    private var _latency: UInt64 = 0
    var latency: UInt64  {
        get {
            return _latency
        }
        set {
            if _latency != newValue {
                _latency = newValue
                
                if isConnected {
                    let commands = [peersLatencyChangedCommand]
                    let data = NSKeyedArchiver.archivedData(withRootObject: commands)
                    self.send(data, with: MCSessionSendDataMode.reliable)
                }
            }
        }
    }
    
    //  ---------------------------------------------------------------------------
    //      init
    //  ---------------------------------------------------------------------------
    
    override init() {
        super.init()
        isConnected = false
        isMaster = false
        doDisconnectByMyself = false
        
        resetTime()
        
        let interval: TimeInterval = 1.0 / 8.0
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(self.timerFired(_:)), userInfo: nil, repeats: true)
        
        peerID = nil
        session = nil
        browser = nil
        advertiser = nil
        mutableBlockedPeers = [AnyHashable]()
        
    }
    
    
    deinit {
        timer?.invalidate()
        forceDisconnect()
        
        delegate = nil
    }
    
    //  ---------------------------------------------------------------------------
    //      resetTime
    //  ---------------------------------------------------------------------------
    
    func resetTime() {
        delay = 0
        peerdelay = 0
        gotPeerdelay = false
        gkWorstdelay = 0
        beaconReceived = false
        latency = 0
        peerlatency = 0
        gotPeerlatency = false
        timeDiff = 0
    }
    
    //  ---------------------------------------------------------------------------
    //      forceDisconnect
    //  ---------------------------------------------------------------------------
    func forceDisconnect() {
        let prevStatus = isConnected
        doDisconnectByMyself = true
        
        session?.disconnect()
        resetTime()
        
        isConnected = false
        
        if prevStatus {
            delegate?.wistConnectionLost()
        }
    }
    
    
    
    
    
    
    //  ---------------------------------------------------------------------------
    //      searchPeer
    //  ---------------------------------------------------------------------------
    func searchPeer() {
        if !isConnected {
            doDisconnectByMyself = false
            isMaster = false
        }
    }
    
    //  ---------------------------------------------------------------------------
    //      disconnect
    //  ---------------------------------------------------------------------------
    func disconnect() {
        forceDisconnect()
    }
    
    
    
    func processLatencyCommand(_ data: Data?) {
        var _array: [Any]? = nil
        if let aData = data {
            _array = NSKeyedUnarchiver.unarchiveObject(with: aData) as? [Any]
        }
        guard let array = _array else {return}
        
        if let command = array[0] as? Int{
            
            switch command {
            case requestLatencyCommand:
                let commands:[Any] = [latencyCommand, latency]
                send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
            case latencyCommand:
                if let latencyNano = array[1] as? UInt64{
                    peerlatency = latencyNano
                    gotPeerlatency = true
                }
                
            case peersLatencyChangedCommand:
                peerlatency = 0
                gotPeerlatency = false
            default:
                break
            }
        }
        
    }
    
    func receiveData(inMasterMode data: Data?) {
        defer {
        }
        do {
            var array: [Any]? = nil
            if let aData = data {
                array = NSKeyedUnarchiver.unarchiveObject(with: aData) as? [Any]
            }
            
            if let command = array?[0] as? Int{
                switch command {
                case delayCommand:
                    if !gotPeerdelay {
                        if let delay = array?[1] as? UInt64{
                            peerdelay = delay
                            gotPeerdelay = true
                        }
                    }
                case beaconCommand:
                    if let sentNano = array?[1] as? UInt64{
                        
                        if let remoteSentNano = array?[2] as? UInt64{
                            let receivedNano = hostTime2NanoSec( mach_absolute_time())
                            let elapseOnewayNano:UInt64 = UInt64(Int((receivedNano - sentNano)) / 2)
                            if Int(elapseOnewayNano) < 4000000000 as UInt64{
                                if gkWorstdelay < elapseOnewayNano {
                                    gkWorstdelay = elapseOnewayNano
                                }
                                
                                let diff = Double(remoteSentNano) - Double(elapseOnewayNano) - Double(sentNano)
                                if beaconReceived {
                                    timeDiff = (timeDiff + diff) / 2
                                } else {
                                    timeDiff = diff
                                    beaconReceived = true
                                }
                            }
                        }
                        
                    }else{
                        print("FAIL!!! array?1 aint uint64")
                    }
                    
                case requestLatencyCommand, latencyCommand, peersLatencyChangedCommand:
                    processLatencyCommand(data)
                default:
                    break
                }
            }
            
        }
    }
    
    func receiveData(inSlaveMode data: Data?) {
        defer {
        }
        do {
            var dataArray: [Any]? = nil
            if let aData = data {
                dataArray = NSKeyedUnarchiver.unarchiveObject(with: aData) as? [Any]
            }
            if let command = dataArray?[0] as? Int{
                switch command {
                case beaconCommand:
                    if let beaconData = dataArray?[1] as? UInt64{
                        let commands:[Any] = [beaconCommand, beaconData, hostTime2NanoSec(mach_absolute_time())]
                        send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.unreliable)
                    }
                    
                case requestDelayCommand:
                    let commands:[Any] = [delayCommand, delay]
                    send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
                case startSlaveCommand:
                    
                    if let nanoSec = dataArray?[1] as? UInt64{
                        if let tempo = dataArray?[2] as? Float{
                            delegate?.wistStartCommandReceived(nanoSec2HostTime(nanoSec), withTempo: tempo)
                        }
                    }
                case stopSlaveCommand:
                    if let nanoSec = dataArray?[1] as? UInt64{
                        delegate?.wistStopCommandReceived(nanoSec2HostTime(nanoSec))
                    }
                case requestLatencyCommand, latencyCommand, peersLatencyChangedCommand:
                    processLatencyCommand(data)
                default:
                    break
                }
                
            }
        }
    }
    //  ---------------------------------------------------------------------------
    //      estimatedLocalHostTime
    //  ---------------------------------------------------------------------------
    func estimatedLocalHostTime(_ hostTime: UInt64) -> UInt64 {
        let delayMax = (delay < peerdelay) ? peerdelay : delay
        let audioLatencyMax = (latency < peerlatency) ? peerlatency : latency
        let latencyNano: UInt64 = audioLatencyMax - latency
        return hostTime + nanoSec2HostTime(gkWorstdelay + delayMax + latencyNano)
    }
    //  ---------------------------------------------------------------------------
    //      estimatedRemoteHostTime
    //  ---------------------------------------------------------------------------
    
    func estimatedRemoteHostTime(_ hostTime: UInt64) -> UInt64 {
        let delayMax = (delay < peerdelay) ? peerdelay : delay
        let audioLatencyMax = (latency < peerlatency) ? peerlatency : latency
        let latencyNano: UInt64 = audioLatencyMax - peerlatency
        return hostTime + nanoSec2HostTime(gkWorstdelay + delayMax + latencyNano)
    }
    
    
    func sendStartCommand(_ hostTime: UInt64, withTempo tempo: Float) {
        if isConnected && isMaster {
            let slaveNanoSec: UInt64 = beaconReceived ? (hostTime2NanoSec(estimatedRemoteHostTime(hostTime)) + UInt64(timeDiff)) : 0
            let commands:[Any] = [startSlaveCommand, slaveNanoSec, tempo]
            let data = NSKeyedArchiver.archivedData(withRootObject: commands)
            self.send(data, with: MCSessionSendDataMode.reliable)
        }
    }
    
    
    func sendStopCommand(_ hostTime: UInt64) {
        if isConnected && isMaster {
            let slaveNanoSec: UInt64 = beaconReceived ? (hostTime2NanoSec(estimatedRemoteHostTime(hostTime)) + UInt64(timeDiff)) : 0
            let commands:[Any] = [stopSlaveCommand, slaveNanoSec] 
            let data = NSKeyedArchiver.archivedData(withRootObject: commands)
            self.send(data, with: MCSessionSendDataMode.reliable)
        }
    }
    
    @objc func timerFired(_ timer: Timer?) {
        //  send beacon
        if isConnected {
            if !gotPeerlatency {
                let request = NSArray.init(array: [requestLatencyCommand])
                let data = NSKeyedArchiver.archivedData(withRootObject: request)
                send(data, with: MCSessionSendDataMode.reliable)
            }
            if isMaster {
                if !gotPeerdelay {
                    let request =  NSArray.init(array: [requestDelayCommand])
                    let data = NSKeyedArchiver.archivedData(withRootObject: request)
                    send(data, with: MCSessionSendDataMode.reliable)
                }
                
                let commands =  NSArray.init(array: [beaconCommand, hostTime2NanoSec(mach_absolute_time())])
                let data = NSKeyedArchiver.archivedData(withRootObject: commands)
                send(data, with: MCSessionSendDataMode.unreliable)
            }
        }
    }
    
    
}
