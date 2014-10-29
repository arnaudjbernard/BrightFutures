////////////////////////////////////////////////////////////////////////////////////////////////////
//  Created by Arnaud Bernard on 8/15/14.
//  All rights reserved.
////////////////////////////////////////////////////////////////////////////////////////////////////

import Foundation

public class Progressor<T>: Future<T> {

    public typealias ProgressCallback = (delta: Int64, done: Int64, total: Int64) -> ()
    typealias PCallbackInternal = Progressor<T> -> ()

    var progress: (delta: Int64, done: Int64, total: Int64) = (0, 0, 0)
    var progressCallbacks = [PCallbackInternal]()

    public func onProgress(callback: ProgressCallback) -> Progressor<T> {

        return self.onProgress(context: self.defaultCallbackExecutionContext, callback: callback)
    }

    public func onProgress(context c: ExecutionContext, callback: ProgressCallback) -> Progressor<T> {
        q.sync {
            let wrappedCallback: Progressor<T> -> () = { progressor in
                c.execute {
                    callback(delta: progressor.progress.delta, done: progressor.progress.done, total: progressor.progress.total)
                }
            }

            if self.result == nil {
                self.progressCallbacks.append(wrappedCallback)
            } else {
                wrappedCallback(self)
            }
        }

        return self
    }

    func updateProgress(#delta: Int64, done: Int64, total: Int64) {

        progress = (delta: delta, done: done, total: total)

        q.async {

            for callback in self.progressCallbacks {
                callback(self)
            }
        }
    }

    override func runCallbacks() {
        super.runCallbacks()

        q.async {

            self.progressCallbacks.removeAll()
        }
    }
}

public class ProgressorPromise<T> {

    public let progressor = Progressor<T>()

    public func updateProgress(#delta: Int64, done: Int64, total: Int64) {

        progressor.updateProgress(delta: delta, done: done, total: total)
    }
    public func completeWith(future: Future<T>) {
        future.onComplete { result in
            switch result {
            case .Success(let val):
                self.success(val.value)
            case .Failure(let err):
                self.error(err)
            }
        }
    }

    public func success(value: T) {
        self.progressor.success(value)
    }

    public func trySuccess(value: T) -> Bool {
        return self.progressor.trySuccess(value)
    }

    public func error(error: NSError) {
        self.progressor.error(error)
    }

    public func tryError(error: NSError) -> Bool {
        return self.progressor.tryError(error)
    }

    public func tryComplete(result: Result<T>) -> Bool {
        return self.progressor.tryComplete(result)
    }
}
