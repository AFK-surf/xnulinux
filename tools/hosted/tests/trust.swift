import Foundation
import Security
// Does Security.framework's trust evaluation (trustd) work? URLSession HTTPS uses it; curl does not.
let sem = DispatchSemaphore(value: 0)
let task = URLSession.shared.dataTask(with: URL(string: "https://www.apple.com/")!) { data, resp, err in
    print("URLSession https:", (resp as? HTTPURLResponse)?.statusCode ?? -1, data?.count ?? 0, err.map { "\($0)" } ?? "no error")
    sem.signal()
}
task.resume(); _ = sem.wait(timeout: .now() + 30)
