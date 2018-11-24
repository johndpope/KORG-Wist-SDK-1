import Foundation
import UIKit
import MultipeerConnectivity

//#import <stdint.h>


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


enum GKCommand : Int {
    case beacon = 0 //  master -> slave -> master
    case startSlave = 1
    case stopSlave = 2
    case requestLatency = 3
    case latency = 4
    case peersLatencyChanged = 5
    case requestDelay = 6
    case delay = 7
}

@objcMembers
public class KorgWirelessSyncStart:NSObject,MCBrowserViewControllerDelegate,MCSessionDelegate,MCAdvertiserAssistantDelegate {
    private var mutableBlockedPeers: [AnyHashable] = []


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
                    let commands:[GKCommand] = [.peersLatencyChanged]
                    send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
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

    func setupPeerAndSession(withDisplayName displayName: String?) {
        peerID = MCPeerID(displayName: displayName ?? "")
        mutableBlockedPeers.append(peerID)

        session = MCSession(peer:peerID!, securityIdentity: nil, encryptionPreference: MCEncryptionPreference.none)
        session?.delegate = self
    }

    func setupMCBrowser() {
        browser = MCBrowserViewController(serviceType: kServiceType, session: session!)
        browser?.minimumNumberOfPeers = 0
        browser?.delegate = self
    }

    func advertiseSelf(_ shouldAdvertise: Bool) {
        if shouldAdvertise {
            advertiser = MCAdvertiserAssistant(serviceType: kServiceType, discoveryInfo: nil, session: session!)
            advertiser?.start()
        } else {
            advertiser?.stop()
            advertiser = nil
        }
    }

    // MARK: - Connecting and sending data
    //  ---------------------------------------------------------------------------
    //      sendData:withDataMode
    //  ---------------------------------------------------------------------------

    func send(_ data: Data?, with dataMode: MCSessionSendDataMode) {
        if isConnected {
     
            if let aData = data {
                try? session!.send(aData, toPeers: session!.connectedPeers, with: dataMode)
            }
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
        
        if let command0 = array[0] as? GKCommand{
            let command:GKCommand = command0
            switch command {
            case .requestLatency:
                let commands = [latency, latency]
                send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
            case .latency:
                if let latencyNano = array[1] as? UInt64{
                    peerlatency = latencyNano
                    gotPeerlatency = true
                }
                
            case .peersLatencyChanged:
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
            
            if let command:GKCommand = array?[0] as? GKCommand{
                switch command {
                case .delay:
                    if !gotPeerdelay {
                        if let delay = array?[1] as? UInt64{
                            peerdelay = delay
                            gotPeerdelay = true
                        }
                    }
                case .beacon:
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
                   
                case .requestLatency, .latency, .peersLatencyChanged:
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
            if let command = dataArray?[0] as? GKCommand{
                switch command {
                case .beacon:
                    if let beaconData = dataArray?[1] as? UInt64{
                        let commands:[Any] = [GKCommand.beacon, beaconData, hostTime2NanoSec(mach_absolute_time())]
                        send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.unreliable)
                    }
                    
                case .requestDelay:
                    let commands = [delay, delay]
                    send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
                case .startSlave:
                    
                    if let nanoSec = dataArray?[1] as? UInt64{
                        if let tempo = dataArray?[2] as? Float{
                             delegate?.wistStartCommandReceived(nanoSec2HostTime(nanoSec), withTempo: tempo)
                        }
                    }
                case .stopSlave:
                    if let nanoSec = dataArray?[1] as? UInt64{
                        delegate?.wistStopCommandReceived(nanoSec2HostTime(nanoSec))
                    }
                case .requestLatency, .latency, .peersLatencyChanged:
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
            let commands:[Any] = [GKCommand.startSlave, slaveNanoSec, tempo]
            send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
        }
    }


    func sendStopCommand(_ hostTime: UInt64) {
        if isConnected && isMaster {
            let slaveNanoSec: UInt64 = beaconReceived ? (hostTime2NanoSec(estimatedRemoteHostTime(hostTime)) + UInt64(timeDiff)) : 0
            let commands:[Any] = [GKCommand.stopSlave, slaveNanoSec]
            send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.reliable)
        }
    }

    @objc func timerFired(_ timer: Timer?) {
        //  send beacon
        if isConnected {
            if !gotPeerlatency {
                let request = [GKCommand.requestLatency]
                send(NSKeyedArchiver.archivedData(withRootObject: request), with: MCSessionSendDataMode.reliable)
            }
            if isMaster {
                if !gotPeerdelay {
                    let request = [GKCommand.requestDelay]
                    send(NSKeyedArchiver.archivedData(withRootObject: request), with: MCSessionSendDataMode.reliable)
                }

                let commands:[Any] = [GKCommand.beacon, hostTime2NanoSec(mach_absolute_time())]
                send(NSKeyedArchiver.archivedData(withRootObject: commands), with: MCSessionSendDataMode.unreliable)
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        if isMaster {
            receiveData(inMasterMode: data)
        } else {
            receiveData(inSlaveMode: data)
        }
    }

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
            case .connected:
                break
            case .connecting:
                break
            case .notConnected:
                DispatchQueue.main.async(execute: {
                    if !self.doDisconnectByMyself {
                        let message = "Lost connection with \(self.isMaster ? "slave" : "master")."
                        let alert = UIAlertView(title: "", message: message, delegate: nil, cancelButtonTitle: "OK", otherButtonTitles: "")
                        alert.show()
                    }
                    self.forceDisconnect()
                })
            default:
                break
        }
    }
    // Received a byte stream from remote peer

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
    }
    // Start receiving a resource from remote peer

    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        print("Receiving file: \(resourceName ?? "")")//" from: \(peerID?.displayName ?? "")")
    }


    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        let searchPaths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)
        let documentPath = searchPaths[0]

        let destinationURL = URL(fileURLWithPath: documentPath)

        var managerError: Error?

        if let anURL = localURL {
            if (try? FileManager.default.moveItem(at: anURL, to: destinationURL)) == nil {
                if let anError = managerError {
                    print("[Error] \(anError)")
                }
            }
        }

        let resultURL = URL(string: "\(destinationURL.absoluteString)\(resourceName)")
        print("result url: \(resultURL?.absoluteString ?? "")")

        if let anURL = resultURL {
            NotificationCenter.default.post(name: kMCFileReceivedNotification, object: nil, userInfo: [kMCFileReceivedURL: anURL])
        }
    }

    // MARK: - Browser delegate
    public func browserViewControllerDidFinish(_ browserViewController: MCBrowserViewController) {
        isMaster = true
        isConnected = true
        delegate?.wistConnectionEstablished()
        NotificationCenter.default.post(name: kMCBrowserDismissNotification, object: nil)
    }

    public func browserViewControllerWasCancelled(_ browserViewController: MCBrowserViewController) {
        isMaster = false
        delegate?.wistConnectionCancelled()
        NotificationCenter.default.post(name: kMCBrowserDismissNotification, object: nil)
    }

}
