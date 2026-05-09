import Network
import Foundation

let browser = NWBrowser(for: .bonjour(type: "_test._tcp", domain: "local."), using: .tcp)
browser.browseResultsChangedHandler = { results, _ in
    for result in results {
        if case .bonjour(let txt) = result.metadata {
            print(txt.dictionary["id"])
        }
    }
}
