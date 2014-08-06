// The MIT License (MIT)
//
// Copyright (c) 2014 Thomas Visser
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

public func future<T>(context c: ExecutionContext = Queue.global, task: (inout NSError?) -> T?) -> Future<T> {
    let promise = Promise<T>();
    
    c.execute {
        var error: NSError?
        let result = task(&error)
        
        if let certainError = error {
            promise.error(certainError)
        } else if let certainResult = result {
            promise.success(certainResult)
        }
    }
    
    return promise.future
}

public func future<T>(context c: ExecutionContext = Queue.global, task: @auto_closure () -> T?) -> Future<T> {
    return future(context: c) { error in
        return task()
    }
}

/**
 * The domain of the NSError that indicates that an operation failed with no result.
 */
public let NoSuchElementError = "NoSuchElementError"

/**
* A `Future` represents the result of an asynchronous operation.
*/
public class Future<T> {
    
    typealias CallbackInternal = (future: Future<T>) -> ()
    typealias CompletionCallback = (result: TaskResult<T>) -> ()
    typealias SuccessCallback = (T) -> ()
    public typealias FailureCallback = (NSError) -> ()
    
    let q = Queue()
    
    var result: TaskResult<T>? = nil
    
    var callbacks: [CallbackInternal] = Array<CallbackInternal>()
    
    let defaultCallbackExecutionContext = Queue()
    
    /**
     * Returns whether the Future succeeded with a result. If present, the
     * given closure will be called with the result. This is a convenient alternative
     * for a switch statement on the `TaskResult`.
     *
     * The difference with `onComplete` is that this method evaluates and acts on the current state
     * of the Future and does not register a callback.
     * 
     * Since the `fn` closure is optional, this method can be used in two ways. The first way is
     * as a check if the Future succeeded:
     *
     * ```
     * if future.succeeded() {
     *
     * }
     * ```
     * The second way is to quickly and safely access the result:
     * 
     * ```
     * future.succeeded { val in
     *    // called immediately if the future has succeeded
     * }
     * ```
     */
    public func succeeded(fn: (T -> ())? = nil) -> Bool {
        if let res = self.result {
            return res.succeeded(fn)
        }
        return false
    }
    
    /**
     * Returns whether the Future failed. If present, the
     * given closure will be called with the result. This is a convenient alternative
     * for a switch statement on the `TaskResult`.
     *
     * The difference with `onFailure` is that this method evaluates and acts on the current state
     * of the Future and does not register a callback.
     *
     * Since the `fn` closure is optional, this method can be used in two ways. The first way is
     * as a check if the Future failed:
     *
     * ```
     * if future.failed() {
     *
     * }
     * ```
     * The second way is to quickly and safely access the error:
     *
     * ```
     * future.failed { err in
     *    // called immediately if the future has failed
     * }
     * ```
     */
    public func failed(fn: (NSError -> ())? = nil) -> Bool {
        if let res = self.result {
            return res.failed(fn)
        }
        return false
    }
    
    /**
     * Returns whether the Future completed. If present, the
     * given closures will be called with the value or error. This is a convenient alternative
     * for a switch statement on the `TaskResult`.
     *
     * The difference with `onComplete` is that this method evaluates and acts on the current state
     * of the Future and does not register a callback.
     *
     * Since both parameters are optional, this method can be used in two ways. The first way is
     * as a check if the Future completed:
     *
     * ```
     * if future.completed() {
     *
     * }
     * ```
     * The second way is to quickly and safely access the value or the error:
     *
     * ```
     * future.completed(success: { val in
     *   // called immediately if the future has succeeded
     * }, failure: { err in
     *   // called immediately if the future has failed
     * }
     * ```
     */
    public func completed(success: (T->())? = nil, failure: (NSError->())? = nil) -> Bool {
        if let res = self.result {
            res.handle(success: success, failure: failure)
            return true
        }
        return false
    }
    
    /**
     * Returns a succeeded Future with the given value
     */
    public class func succeeded(value: T) -> Future<T> {
        let res = Future<T>();
        res.result = TaskResult(value)
        
        return res
    }
    
    /**
     * Returns a failed Future with the given error
     */
    public class func failed(error: NSError) -> Future<T> {
        let res = Future<T>();
        res.result = TaskResult(error)
        
        return res
    }
    
    public class func completeAfter(delay: NSTimeInterval, withValue value: T) -> Future<T> {
        let res = Future<T>()
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(delay * NSTimeInterval(NSEC_PER_SEC))), Queue.global.queue) {
            res.success(value)
        }
        
        return res
    }
    
    /**
     * Returns a Future that will never succeed
     */
    public class func never() -> Future<T> {
        return Future<T>()
    }
    
    /**
     * Called by the Promise to complete the Future. If the Future is already completed,
     * this method throws an exception (TODO).
     */
    func complete(result: TaskResult<T>) {
        let succeeded = tryComplete(result)
        assert(succeeded)
    }
    
    /**
     * Tries to complete the Future, returns whether this succeeded.
     * Completing will succeed if the Future is not yet complete.
     */
    func tryComplete(result: TaskResult<T>) -> Bool {
        switch result {
        case .Success(let val):
            return self.trySuccess(val)
        case .Failure(let err):
            return self.tryError(err)
        }
    }
    
    /**
     * Called by the Promise to complete the Future with success. If the Future is already completed,
     * this method throws an exception (TODO).
     */
    func success(value: T) {
        let succeeded = self.trySuccess(value)
        assert(succeeded)
    }
    
    /**
     * Tries to complete the Future with success, returns whether this succeeded.
     * Completing will succeed if the Future is not yet complete.
     */
    func trySuccess(value: T) -> Bool {
        return q.sync {
            if self.result {
                return false;
            }
            
            self.result = TaskResult(value)
            self.runCallbacks()
            return true;
        };
    }
    
    /**
     * Called by the Promise to complete the Future with an error. If the Future is already completed,
     * this method throws an exception (TODO).
     */
    func error(error: NSError) {
        let succeeded = self.tryError(error)
        assert(succeeded)
    }
    
    /**
     * Tries to complete the Future with success, returns whether this succeeded.
     * Completing will succeed if the Future is not yet complete.
     */
    func tryError(error: NSError) -> Bool {
        return q.sync {
            if self.result {
                return false;
            }
            
            self.result = TaskResult(error)
            self.runCallbacks()
            return true;
        };
    }

    /**
     * Returns the result of this future by blocking until the future completed.
     * Using the asynchronous methods is preferred.
     */
    public func forced() -> TaskResult<T> {
        return forced(Double.infinity)!
    }

    /**
     * Returns the result of this future by blocking until the future completed or
     * nil if the given time runs out.
     * Using the asynchronous methods is preferred.
     *
     * @param time The number of nanoseconds to wait
     */
    public func forced(time: NSTimeInterval) -> TaskResult<T>? {
        if let certainResult = self.result {
            return certainResult
        } else {
            let sema = dispatch_semaphore_create(0)
            var res: TaskResult<T>? = nil
            self.onComplete {
                res = $0
                dispatch_semaphore_signal(sema)
            }

            var timeout: dispatch_time_t
            if time.isFinite {
                timeout = dispatch_time(DISPATCH_TIME_NOW, Int64(time * NSTimeInterval(NSEC_PER_SEC)))
            } else {
                timeout = DISPATCH_TIME_FOREVER
            }
            
            dispatch_semaphore_wait(sema, timeout)
            
            return res
        }
    }
    
    public func onComplete(callback: CompletionCallback) -> Future<T> {
        return self.onComplete(context: self.defaultCallbackExecutionContext, callback: callback)
    }
    
    public func onComplete(context c: ExecutionContext, callback: CompletionCallback) -> Future<T> {
        q.sync {
            let wrappedCallback : Future<T> -> () = { future in
                if let realRes = self.result {
                    c.execute {
                        callback(result: realRes)
                    }
                }
            }
            
            if !self.result {
                self.callbacks.append(wrappedCallback)
            } else {
                wrappedCallback(self)
            }
        }
        
        return self
    }

    public func flatMap<U>(f: T -> Future<U>) -> Future<U> {
        return self.flatMap(context: self.defaultCallbackExecutionContext, f)
    }

    public func flatMap<U>(context c: ExecutionContext, f: T -> Future<U>) -> Future<U> {
        let p: Promise<U> = Promise()
        self.onComplete(context: c) { res in
            switch (res) {
            case .Failure(let e):
                p.error(e)
            case .Success(let v):
                p.completeWith(f(v))
            }
        }
        return p.future
    }

    public func map<U>(f: (T, inout NSError?) -> U?) -> Future<U> {
        return self.map(context: self.defaultCallbackExecutionContext, f)
    }

    public func map<U>(context c: ExecutionContext, f: (T, inout NSError?) -> U?) -> Future<U> {
        let p = Promise<U>()
        
        self.onComplete(context: c, callback: { result in
            switch result {
            case .Success(let v):
                var err: NSError? = nil
                let res = f(v, &err)
                if let e = err {
                    p.error(e)
                } else {
                    p.success(res!)
                }
                break;
            case .Failure(let e):
                p.error(e)
                break;
            }
        })
        
        return p.future
    }

    public func andThen(callback: TaskResult<T> -> ()) -> Future<T> {
        return self.andThen(context: self.defaultCallbackExecutionContext, callback: callback)
    }

    public func andThen(context c: ExecutionContext, callback: TaskResult<T> -> ()) -> Future<T> {
        let p = Promise<T>()
        
        self.onComplete(context: c) { result in
            callback(result)
            p.completeWith(self)
        }

        return p.future
    }

    public func onSuccess(callback: SuccessCallback) -> Future<T> {
        return self.onSuccess(context: self.defaultCallbackExecutionContext, callback)
    }
    
    public func onSuccess(context c: ExecutionContext, callback: SuccessCallback) -> Future<T> {
        self.onComplete(context: c) { result in
            switch result {
            case .Success(let val):
                callback(val)
            default:
                break
            }
        }
        
        return self
    }
    
    public func onFailure(callback: FailureCallback) -> Future<T> {
        return self.onFailure(context: self.defaultCallbackExecutionContext, callback)
    }
    
    public func onFailure(context c: ExecutionContext, callback: FailureCallback) -> Future<T> {
        self.onComplete(context: c) { result in
            switch result {
            case .Failure(let err):
                callback(err)
            default:
                break
            }
        }
        return self
    }
    
    public func recover(task: (NSError) -> T) -> Future<T> {
        return self.recover(context: self.defaultCallbackExecutionContext, task)
    }
    
    public func recover(context c: ExecutionContext, task: (NSError) -> T) -> Future<T> {
        return self.recoverWith(context: c) { error -> Future<T> in
            return Future.succeeded(task(error))
        }
    }
    
    public func recoverWith(task: (NSError) -> Future<T>) -> Future<T> {
        return self.recoverWith(context: self.defaultCallbackExecutionContext, task: task)
    }
    
    public func recoverWith(context c: ExecutionContext, task: (NSError) -> Future<T>) -> Future<T> {
        let p = Promise<T>()
        
        self.onComplete(context: c) { result -> () in
            switch result {
            case .Failure(let err):
                p.completeWith(task(err))
            case .Success(let val):
                p.completeWith(self)
            }
        }
        
        return p.future;
    }
    
    public func zip<U>(that: Future<U>) -> Future<(T,U)> {
        return self.flatMap { thisVal in
            return that.map { thatVal, _ in
                return (thisVal, thatVal)
            }
        }
    }
    
    public func filter(p: T -> Bool) -> Future<T> {
        let promise = Promise<T>()
        
        self.onComplete { result in
            switch result {
            case .Success(let val):
                if p(val) {
                    promise.completeWith(self)
                } else {
                    promise.error(NSError(domain: NoSuchElementError, code: 0, userInfo: nil))
                }
                break
            case .Failure(let err):
                promise.error(err)
            }
        }
        
        return promise.future
    }
    
    private func runCallbacks() {
        q.async {
            for callback in self.callbacks {
                callback(future: self)
            }
            
            self.callbacks.removeAll()
        }
    }
}

public final class TaskResultValueWrapper<T> {
    public let value: T
    
    init(_ value: T) {
        self.value = value
    }
    
    public func __conversion() -> T {
        return self.value
    }
}

func ==<T: Equatable>(lhs: TaskResultValueWrapper<T>, rhs: T) -> Bool {
    return lhs.value == rhs
}

public enum TaskResult<T> {
    case Success(TaskResultValueWrapper<T>)
    case Failure(NSError)
    
    init(_ value: T) {
        self = .Success(TaskResultValueWrapper(value))
    }
    
    init(_ error: NSError) {
        self = .Failure(error)
    }
    
    public func failed(fn: (NSError -> ())? = nil) -> Bool {
        switch self {
        case .Success(_):
            return false

        case .Failure(let err):
            if let fnn = fn {
                fnn(err)
            }
            return true
        }
    }
    
    public func succeeded(fn: (T -> ())? = nil) -> Bool {
        switch self {
        case .Success(let val):
            if let fnn = fn {
                fnn(val)
            }
            return true
        case .Failure(let err):
            return false
        }
    }
    
    public func handle(success: (T->())? = nil, failure: (NSError->())? = nil) {
        switch self {
        case .Success(let val):
            if let successCb = success {
                successCb(val)
            }
        case .Failure(let err):
            if let failureCb = failure {
                failureCb(err)
            }
        }
    }
}

