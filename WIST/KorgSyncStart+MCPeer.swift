import Foundation
import UIKit
import MultipeerConnectivity




extension KorgWirelessSyncStart:MCBrowserViewControllerDelegate,MCSessionDelegate,MCAdvertiserAssistantDelegate {
    
    
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
    
    
    
    
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        print("session didReceive!!")
        if isMaster {
            receiveData(inMasterMode: data)
        } else {
            receiveData(inSlaveMode: data)
        }
    }
    
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        print("session!!")
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
        print("session!!")
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
    func browserViewControllerDidFinish(_ browserViewController: MCBrowserViewController) {
        isMaster = true
        isConnected = true
        delegate?.wistConnectionEstablished()
        NotificationCenter.default.post(name: kMCBrowserDismissNotification, object: nil)
    }
    
    func browserViewControllerWasCancelled(_ browserViewController: MCBrowserViewController) {
        isMaster = false
        delegate?.wistConnectionCancelled()
        NotificationCenter.default.post(name: kMCBrowserDismissNotification, object: nil)
    }
    
}
