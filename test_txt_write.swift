import Network
import Foundation

var txtRecord = NWTXTRecord()
txtRecord.dictionary["id"] = "123"
let service = NWListener.Service(name: "Test", type: "_test._tcp", txtRecord: txtRecord.dictionary)
