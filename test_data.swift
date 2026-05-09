import Foundation

var data = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
data.removeFirst(2)
print("count:", data.count)
print("startIndex:", data.startIndex)
let slice = data.subdata(in: 4..<6)
print("slice count:", slice.count)
