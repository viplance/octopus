import Network
import Foundation

let txtRecord = NWTXTRecord(["id": "123"])
let service = NWListener.Service(name: "Test", type: "_test._tcp", txtRecord: txtRecord)
