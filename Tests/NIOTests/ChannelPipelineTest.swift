//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIOConcurrencyHelpers
@testable import NIO

private final class IndexWritingHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let index: Int

    init(_ index: Int) {
        self.index = index
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buf = self.unwrapInboundIn(data)
        buf.writeInteger(UInt8(self.index))
        ctx.fireChannelRead(self.wrapInboundOut(buf))
    }

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buf = self.unwrapOutboundIn(data)
        buf.writeInteger(UInt8(self.index))
        ctx.write(self.wrapOutboundOut(buf), promise: promise)
    }
}

private extension EmbeddedChannel {
    func assertReadIndexOrder(_ order: [UInt8]) {
        XCTAssertTrue(try self.writeInbound(self.allocator.buffer(capacity: 32)))
        var outBuffer: ByteBuffer = self.readInbound()!
        XCTAssertEqual(outBuffer.readBytes(length: outBuffer.readableBytes)!, order)
    }

    func assertWriteIndexOrder(_ order: [UInt8]) {
        XCTAssertTrue(try self.writeOutbound(self.allocator.buffer(capacity: 32)))
        guard var outBuffer2 = self.readOutbound(as: ByteBuffer.self) else {
            XCTFail("Could not read byte buffer")
            return
        }

        XCTAssertEqual(outBuffer2.readBytes(length: outBuffer2.readableBytes)!, order)
    }
}

class ChannelPipelineTest: XCTestCase {

    func testAddAfterClose() throws {

        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.close().wait())

        channel.pipeline.removeHandlers()

        let handler = DummyHandler()
        defer {
            XCTAssertFalse(handler.handlerAddedCalled.load())
            XCTAssertFalse(handler.handlerRemovedCalled.load())
        }
        do {
            try channel.pipeline.add(handler: handler).wait()
            XCTFail()
        } catch let err as ChannelError {
            XCTAssertEqual(err, .ioOnClosedChannel)
        }
    }

    private final class DummyHandler: ChannelHandler {
        let handlerAddedCalled = Atomic<Bool>(value: false)
        let handlerRemovedCalled = Atomic<Bool>(value: false)

        public func handlerAdded(ctx: ChannelHandlerContext) {
            handlerAddedCalled.store(true)
        }

        public func handlerRemoved(ctx: ChannelHandlerContext) {
            handlerRemovedCalled.store(true)
        }
    }

    func testOutboundOrdering() throws {

        let channel = EmbeddedChannel()

        var buf = channel.allocator.buffer(capacity: 1024)
        buf.writeString("hello")

        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<Int, ByteBuffer> { data in
            XCTAssertEqual(1, data)
            return buf
        }).wait()

        _ = try channel.pipeline.add(handler: TestChannelOutboundHandler<String, Int> { data in
            XCTAssertEqual("msg", data)
            return 1
        }).wait()

        XCTAssertNoThrow(try channel.writeAndFlush(NIOAny("msg")).wait() as Void)
        if let data = channel.readOutbound(as: ByteBuffer.self) {
            XCTAssertEqual(buf, data)
        } else {
            XCTFail("couldn't read from channel")
        }
        XCTAssertNil(channel.readOutbound())

        XCTAssertFalse(try channel.finish())
    }

    func testConnectingDoesntCallBind() throws {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertFalse(try channel.finish())
        }
        var ipv4SocketAddress = sockaddr_in()
        ipv4SocketAddress.sin_port = (12345 as in_port_t).bigEndian
        let sa = SocketAddress(ipv4SocketAddress, host: "foobar.com")

        XCTAssertNoThrow(try channel.pipeline.add(handler: NoBindAllowed()).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: TestChannelOutboundHandler<ByteBuffer, ByteBuffer> { data in
            data
        }).wait())

        XCTAssertNoThrow(try channel.connect(to: sa).wait())
    }

    private final class TestChannelOutboundHandler<In, Out>: ChannelOutboundHandler {
        typealias OutboundIn = In
        typealias OutboundOut = Out

        private let body: (OutboundIn) throws -> OutboundOut

        init(_ body: @escaping (OutboundIn) throws -> OutboundOut) {
            self.body = body
        }

        public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            do {
                ctx.write(self.wrapOutboundOut(try body(self.unwrapOutboundIn(data))), promise: promise)
            } catch let err {
                promise!.fail(err)
            }
        }
    }

    private final class NoBindAllowed: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        enum TestFailureError: Error {
            case CalledBind
        }

        public func bind(ctx: ChannelHandlerContext, to address: SocketAddress, promise: EventLoopPromise<Void>?) {
            promise!.fail(TestFailureError.CalledBind)
        }
    }

    private final class FireChannelReadOnRemoveHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = Never
        typealias InboundOut = Int

        public func handlerRemoved(ctx: ChannelHandlerContext) {
            ctx.fireChannelRead(self.wrapInboundOut(1))
        }
    }

    func testFiringChannelReadsInHandlerRemovedWorks() throws {
        let channel = EmbeddedChannel()

        let h = FireChannelReadOnRemoveHandler()
        _ = try channel.pipeline.add(handler: h).flatMap {
            channel.pipeline.remove(handler: h)
        }.wait()

        XCTAssertEqual(Optional<Int>.some(1), channel.readInbound())
        XCTAssertFalse(try channel.finish())
    }

    func testEmptyPipelineWorks() throws {
        let channel = EmbeddedChannel()
        XCTAssertTrue(try assertNoThrowWithValue(channel.writeInbound(2)))
        XCTAssertEqual(Optional<Int>.some(2), channel.readInbound())
        XCTAssertFalse(try channel.finish())
    }

    func testWriteAfterClose() throws {

        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.close().wait())
        let loop = channel.eventLoop as! EmbeddedEventLoop
        loop.run()

        XCTAssertTrue(loop.inEventLoop)
        do {
            let handle = FileHandle(descriptor: -1)
            let fr = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: 0)
            defer {
                // fake descriptor, so shouldn't be closed.
                XCTAssertNoThrow(try handle.takeDescriptorOwnership())
            }
            try channel.writeOutbound(fr)
            loop.run()
            XCTFail("we ran but an error should have been thrown")
        } catch let err as ChannelError {
            XCTAssertEqual(err, .ioOnClosedChannel)
        }
    }

    func testOutboundNextForInboundOnlyIsCorrect() throws {
        /// This handler always add its number to the inbound `[Int]` array
        final class MarkingInboundHandler: ChannelInboundHandler {
            typealias InboundIn = [Int]
            typealias InboundOut = [Int]

            private let no: Int

            init(number: Int) {
                self.no = number
            }

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let data = self.unwrapInboundIn(data)
                ctx.fireChannelRead(self.wrapInboundOut(data + [self.no]))
            }
        }

        /// This handler always add its number to the outbound `[Int]` array
        final class MarkingOutboundHandler: ChannelOutboundHandler {
            typealias OutboundIn = [Int]
            typealias OutboundOut = [Int]

            private let no: Int

            init(number: Int) {
                self.no = number
            }

            func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = self.unwrapOutboundIn(data)
                ctx.write(self.wrapOutboundOut(data + [self.no]), promise: promise)
            }
        }

        /// This handler multiplies the inbound `[Int]` it receives by `-1` and writes it to the next outbound handler.
        final class WriteOnReadHandler: ChannelInboundHandler {
            typealias InboundIn = [Int]
            typealias InboundOut = [Int]
            typealias OutboundOut = [Int]

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                let data = self.unwrapInboundIn(data)
                ctx.writeAndFlush(self.wrapOutboundOut(data.map { $0 * -1 }), promise: nil)
                ctx.fireChannelRead(self.wrapInboundOut(data))
            }
        }

        /// This handler just prints out the outbound received `[Int]` as a `ByteBuffer`.
        final class PrintOutboundAsByteBufferHandler: ChannelOutboundHandler {
            typealias OutboundIn = [Int]
            typealias OutboundOut = ByteBuffer

            func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let data = self.unwrapOutboundIn(data)
                var buf = ctx.channel.allocator.buffer(capacity: 123)
                buf.writeString(String(describing: data))
                ctx.write(self.wrapOutboundOut(buf), promise: promise)
            }
        }

        let channel = EmbeddedChannel()
        let loop = channel.eventLoop as! EmbeddedEventLoop
        loop.run()

        try channel.pipeline.add(handler: PrintOutboundAsByteBufferHandler()).wait()
        try channel.pipeline.add(handler: MarkingInboundHandler(number: 2)).wait()
        try channel.pipeline.add(handler: WriteOnReadHandler()).wait()
        try channel.pipeline.add(handler: MarkingOutboundHandler(number: 4)).wait()
        try channel.pipeline.add(handler: WriteOnReadHandler()).wait()
        try channel.pipeline.add(handler: MarkingInboundHandler(number: 6)).wait()
        try channel.pipeline.add(handler: WriteOnReadHandler()).wait()

        try channel.writeInbound([])
        loop.run()
        XCTAssertEqual([2, 6], channel.readInbound()!)

        /* the first thing, we should receive is `[-2]` as it shouldn't hit any `MarkingOutboundHandler`s (`4`) */
        var outbound = channel.readOutbound(as: ByteBuffer.self)
        if var buf = outbound {
            XCTAssertEqual("[-2]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        /* the next thing we should receive is `[-2, 4]` as the first `WriteOnReadHandler` (receiving `[2]`) is behind the `MarkingOutboundHandler` (`4`) */
        outbound = channel.readOutbound()
        if var buf = outbound {
            XCTAssertEqual("[-2, 4]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        /* and finally, we're waiting for `[-2, -6, 4]` as the second `WriteOnReadHandler`s (receiving `[2, 4]`) is behind the `MarkingOutboundHandler` (`4`) */
        outbound = channel.readOutbound()
        if var buf = outbound {
            XCTAssertEqual("[-2, -6, 4]", buf.readString(length: buf.readableBytes))
        } else {
            XCTFail("wrong contents: \(outbound.debugDescription)")
        }

        XCTAssertNil(channel.readInbound())
        XCTAssertNil(channel.readOutbound())

        XCTAssertFalse(try channel.finish())
    }

    func testChannelInfrastructureIsNotLeaked() throws {
        class SomeHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            let body: (ChannelHandlerContext) -> Void

            init(_ body: @escaping (ChannelHandlerContext) -> Void) {
                self.body = body
            }

            func handlerAdded(ctx: ChannelHandlerContext) {
                self.body(ctx)
            }
        }
        try {
            let channel = EmbeddedChannel()
            let loop = channel.eventLoop as! EmbeddedEventLoop

            weak var weakHandler1: RemovableChannelHandler?
            weak var weakHandler2: ChannelHandler?
            weak var weakHandlerContext1: ChannelHandlerContext?
            weak var weakHandlerContext2: ChannelHandlerContext?

            () /* needed because Swift's grammar is so ambiguous that you can't remove this :\ */

            try {
                let handler1 = SomeHandler { ctx in
                    weakHandlerContext1 = ctx
                }
                weakHandler1 = handler1
                let handler2 = SomeHandler { ctx in
                    weakHandlerContext2 = ctx
                }
                weakHandler2 = handler2
                XCTAssertNoThrow(try channel.pipeline.add(handler: handler1).flatMap {
                    channel.pipeline.add(handler: handler2)
                    }.wait())
            }()

            XCTAssertNotNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNotNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertNoThrow(try channel.pipeline.remove(handler: weakHandler1!).wait())

            XCTAssertNil(weakHandler1)
            XCTAssertNotNil(weakHandler2)
            XCTAssertNil(weakHandlerContext1)
            XCTAssertNotNil(weakHandlerContext2)

            XCTAssertFalse(try channel.finish())

            XCTAssertNil(weakHandler1)
            XCTAssertNil(weakHandler2)
            XCTAssertNil(weakHandlerContext1)
            XCTAssertNil(weakHandlerContext2)

            XCTAssertNoThrow(try loop.syncShutdownGracefully())
        }()
    }

    func testAddingHandlersFirstWorks() throws {
        final class ReceiveIntHandler: ChannelInboundHandler {
            typealias InboundIn = Int

            var intReadCount = 0

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                if data.tryAs(type: Int.self) != nil {
                    self.intReadCount += 1
                }
            }
        }

        final class TransformStringToIntHandler: ChannelInboundHandler {
            typealias InboundIn = String
            typealias InboundOut = Int

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                if let dataString = data.tryAs(type: String.self) {
                    ctx.fireChannelRead(self.wrapInboundOut(dataString.count))
                }
            }
        }

        final class TransformByteBufferToStringHandler: ChannelInboundHandler {
            typealias InboundIn = ByteBuffer
            typealias InboundOut = String

            func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
                if var buffer = data.tryAs(type: ByteBuffer.self) {
                    ctx.fireChannelRead(self.wrapInboundOut(buffer.readString(length: buffer.readableBytes)!))
                }
            }
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let countHandler = ReceiveIntHandler()
        var buffer = channel.allocator.buffer(capacity: 12)
        buffer.writeStaticString("hello, world")

        XCTAssertNoThrow(try channel.pipeline.add(handler: countHandler).wait())
        XCTAssertFalse(try channel.writeInbound(buffer))
        XCTAssertEqual(countHandler.intReadCount, 0)

        try channel.pipeline.addHandlers(TransformByteBufferToStringHandler(),
                                         TransformStringToIntHandler(),
                                         first: true).wait()
        XCTAssertFalse(try channel.writeInbound(buffer))
        XCTAssertEqual(countHandler.intReadCount, 1)
    }

    func testAddAfter() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.add(handler: firstHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(2)).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(3), after: firstHandler).wait())

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddBefore() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(1)).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: secondHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(3), before: secondHandler).wait())

        channel.assertReadIndexOrder([1, 3, 2])
        channel.assertWriteIndexOrder([2, 3, 1])
    }

    func testAddAfterLast() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let secondHandler = IndexWritingHandler(2)
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(1)).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: secondHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(3), after: secondHandler).wait())

        channel.assertReadIndexOrder([1, 2, 3])
        channel.assertWriteIndexOrder([3, 2, 1])
    }

    func testAddBeforeFirst() {
        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let firstHandler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.add(handler: firstHandler).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(2)).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: IndexWritingHandler(3), before: firstHandler).wait())

        channel.assertReadIndexOrder([3, 1, 2])
        channel.assertWriteIndexOrder([2, 1, 3])
    }

    func testAddAfterWhileClosed() {
        let channel = EmbeddedChannel()
        defer {
            do {
                _ = try channel.finish()
                XCTFail("Did not throw")
            } catch ChannelError.alreadyClosed {
                // Ok
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }

        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())
        XCTAssertNoThrow(try channel.close().wait())
        (channel.eventLoop as! EmbeddedEventLoop).run()

        do {
            try channel.pipeline.add(handler: IndexWritingHandler(2), after: handler).wait()
            XCTFail("Did not throw")
        } catch ChannelError.ioOnClosedChannel {
            // all good
        } catch {
            XCTFail("Got incorrect error: \(error)")
        }
    }

    func testAddBeforeWhileClosed() {
        let channel = EmbeddedChannel()
        defer {
            do {
                _ = try channel.finish()
                XCTFail("Did not throw")
            } catch ChannelError.alreadyClosed {
                // Ok
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }

        let handler = IndexWritingHandler(1)
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())
        XCTAssertNoThrow(try channel.close().wait())
        (channel.eventLoop as! EmbeddedEventLoop).run()

        do {
            try channel.pipeline.add(handler: IndexWritingHandler(2), before: handler).wait()
            XCTFail("Did not throw")
        } catch ChannelError.ioOnClosedChannel {
            // all good
        } catch {
            XCTFail("Got incorrect error: \(error)")
        }
    }

    func testFindHandlerByType() {
        class TypeAHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        class TypeBHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        class TypeCHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let h1 = TypeAHandler()
        let h2 = TypeBHandler()
        XCTAssertNoThrow(try channel.pipeline.add(handler: h1).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: h2).wait())

        XCTAssertTrue(try h1 === channel.pipeline.context(handlerType: TypeAHandler.self).wait().handler)
        XCTAssertTrue(try h2 === channel.pipeline.context(handlerType: TypeBHandler.self).wait().handler)

        do {
            _ = try channel.pipeline.context(handlerType: TypeCHandler.self).wait()
            XCTFail("Did not throw")
        } catch ChannelPipelineError.notFound {
            // ok
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testFindHandlerByTypeReturnsTheFirstOfItsType() {
        class TestHandler: ChannelInboundHandler {
            typealias InboundIn = Any
            typealias InboundOut = Any
        }

        let channel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try channel.finish())
        }

        let h1 = TestHandler()
        let h2 = TestHandler()
        XCTAssertNoThrow(try channel.pipeline.add(handler: h1).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: h2).wait())

        XCTAssertTrue(try h1 === channel.pipeline.context(handlerType: TestHandler.self).wait().handler)
        XCTAssertFalse(try h2 === channel.pipeline.context(handlerType: TestHandler.self).wait().handler)
    }

    func testContextForHeadOrTail() throws {
        let channel = EmbeddedChannel()

        defer {
            XCTAssertFalse(try channel.finish())
        }

        do {
            _ = try channel.pipeline.context(name: HeadChannelHandler.name).wait()
            XCTFail()
        } catch let err as ChannelPipelineError where err == .notFound {
            /// expected
        }

        do {
            _ = try channel.pipeline.context(handlerType: HeadChannelHandler.self).wait()
            XCTFail()
        } catch let err as ChannelPipelineError where err == .notFound {
            /// expected
        }

        do {
            _ = try channel.pipeline.context(name: TailChannelHandler.name).wait()
            XCTFail()
        } catch let err as ChannelPipelineError where err == .notFound {
            /// expected
        }

        do {
            _ = try channel.pipeline.context(handlerType: TailChannelHandler.self).wait()
            XCTFail()
        } catch let err as ChannelPipelineError where err == .notFound {
            /// expected
        }
    }

    func testRemoveHeadOrTail() throws {
        let channel = EmbeddedChannel()

        defer {
            XCTAssertFalse(try channel.finish())
        }

        do {
            _ = try channel.pipeline.remove(name: HeadChannelHandler.name).wait()
            XCTFail()
        } catch let err as ChannelPipelineError where err == .notFound {
            /// expected
        }

        do {
            _ = try channel.pipeline.remove(name: TailChannelHandler.name).wait()
            XCTFail()
        } catch let err as ChannelPipelineError where err == .notFound {
            /// expected
        }
    }

    func testRemovingByContextWithPromiseStillInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        removalPromise.futureResult.whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }

        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.remove(ctx: context, promise: removalPromise)

        XCTAssertNoThrow(try removalPromise.futureResult.wait())
        guard case .some(.byteBuffer(let receivedBuffer)) = channel.readOutbound(as: IOData.self) else {
            XCTFail("No buffer")
            return
        }
        XCTAssertEqual(receivedBuffer, buffer)

        do {
            try channel.throwIfErrorCaught()
            XCTFail("Did not throw")
        } catch is DummyError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemovingByContextWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertFalse(try channel.finish())
        }

        XCTAssertNoThrow(try channel.pipeline.add(handler: NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.remove(ctx: context).whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testRemovingByNameWithPromiseStillInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        XCTAssertNoThrow(try channel.pipeline.add(name: "TestHandler", handler: NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        removalPromise.futureResult.map {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }.whenFailure {
            XCTFail("unexpected error: \($0)")
        }

        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.remove(name: "TestHandler", promise: removalPromise)

        XCTAssertEqual(channel.readOutbound(), buffer)

        do {
            try channel.throwIfErrorCaught()
            XCTFail("Did not throw")
        } catch is DummyError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemovingByNameWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertFalse(try channel.finish())
        }

        XCTAssertNoThrow(try channel.pipeline.add(name: "TestHandler", handler: NoOpHandler()).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.remove(name: "TestHandler").whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testRemovingByReferenceWithPromiseStillInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            _ = try? channel.finish()
        }

        let handler = NoOpHandler()
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        let removalPromise = channel.eventLoop.makePromise(of: Void.self)
        removalPromise.futureResult.whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }

        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.remove(handler: handler, promise: removalPromise)

        XCTAssertEqual(channel.readOutbound(), buffer)

        do {
            try channel.throwIfErrorCaught()
            XCTFail("Did not throw")
        } catch is DummyError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemovingByReferenceWithFutureNotInChannel() throws {
        class NoOpHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never
        }
        class DummyError: Error { }

        let channel = EmbeddedChannel()
        defer {
            // This will definitely throw.
            XCTAssertFalse(try channel.finish())
        }

        let handler = NoOpHandler()
        XCTAssertNoThrow(try channel.pipeline.add(handler: handler).wait())

        let context = try assertNoThrowWithValue(channel.pipeline.context(handlerType: NoOpHandler.self).wait())

        var buffer = channel.allocator.buffer(capacity: 1024)
        buffer.writeStaticString("Hello, world!")

        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
        channel.pipeline.remove(handler: handler).whenSuccess {
            context.writeAndFlush(NIOAny(buffer), promise: nil)
            context.fireErrorCaught(DummyError())
        }
        XCTAssertNil(channel.readOutbound())
        XCTAssertNoThrow(try channel.throwIfErrorCaught())
    }

    func testFireChannelReadInInactiveChannelDoesNotCrash() throws {
        class FireWhenInactiveHandler: ChannelInboundHandler {
            typealias InboundIn = ()
            typealias InboundOut = ()

            func channelInactive(ctx: ChannelHandlerContext) {
                ctx.fireChannelRead(self.wrapInboundOut(()))
            }
        }
        let handler = FireWhenInactiveHandler()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let server = try assertNoThrowWithValue(ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait())
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }
        let client = try assertNoThrowWithValue(ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.add(handler: handler)
            }
            .connect(to: server.localAddress!)
            .wait())
        XCTAssertNoThrow(try client.close().wait())
    }

    func testTeardownDuringFormalRemovalProcess() {
        class NeverCompleteRemovalHandler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            private let removalTokenPromise: EventLoopPromise<ChannelHandlerContext.RemovalToken>
            private let handlerRemovedPromise: EventLoopPromise<Void>

            init(removalTokenPromise: EventLoopPromise<ChannelHandlerContext.RemovalToken>,
                 handlerRemovedPromise: EventLoopPromise<Void>) {
                self.removalTokenPromise = removalTokenPromise
                self.handlerRemovedPromise = handlerRemovedPromise
            }

            func handlerRemoved(ctx: ChannelHandlerContext) {
                self.handlerRemovedPromise.succeed(())
            }

            func removeHandler(ctx: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.removalTokenPromise.succeed(removalToken)
            }
        }

        let eventLoop = EmbeddedEventLoop()
        let removalTokenPromise = eventLoop.makePromise(of: ChannelHandlerContext.RemovalToken.self)
        let handlerRemovedPromise = eventLoop.makePromise(of: Void.self)

        let channel = EmbeddedChannel(handler: NeverCompleteRemovalHandler(removalTokenPromise: removalTokenPromise,
                                                                           handlerRemovedPromise: handlerRemovedPromise),
                                      loop: eventLoop)

        // pretend we're real and connect
        XCTAssertNoThrow(try channel.connect(to: .init(ipAddress: "1.2.3.4", port: 5)).wait())

        // let's trigger the removal process
        XCTAssertNoThrow(try channel.pipeline.context(handlerType: NeverCompleteRemovalHandler.self).map { handler in
            channel.pipeline.remove(ctx: handler, promise: nil)
        }.wait())

        XCTAssertNoThrow(try removalTokenPromise.futureResult.map { removalToken in
            // we know that the removal process has been started, so let's tear down the pipeline
            func workaroundSR9815withAUselessFunction() {
                XCTAssertNoThrow(XCTAssertFalse(try channel.finish()))
            }
            workaroundSR9815withAUselessFunction()
        }.wait())

        // verify that the handler has now been removed, despite the fact it should be mid-removal
        XCTAssertNoThrow(try handlerRemovedPromise.futureResult.wait())
    }

    func testVariousChannelRemovalAPIsGoThroughRemovableChannelHandler() {
        class Handler: ChannelInboundHandler, RemovableChannelHandler {
            typealias InboundIn = Never

            var removeHandlerCalled = false
            var withinRemoveHandler = false

            func removeHandler(ctx: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
                self.removeHandlerCalled = true
                self.withinRemoveHandler = true
                defer {
                    self.withinRemoveHandler = false
                }
                ctx.leavePipeline(removalToken: removalToken)
            }

            func handlerRemoved(ctx: ChannelHandlerContext) {
                XCTAssertTrue(self.removeHandlerCalled)
                XCTAssertTrue(self.withinRemoveHandler)
            }
        }

        let channel = EmbeddedChannel()
        let allHandlers = [Handler(), Handler(), Handler()]
        XCTAssertNoThrow(try channel.pipeline.add(name: "the first one to remove", handler: allHandlers[0]).wait())
        XCTAssertNoThrow(try channel.pipeline.add(handler: allHandlers[1]).wait())
        XCTAssertNoThrow(try channel.pipeline.add(name: "the last one to remove", handler: allHandlers[2]).wait())

        let lastContext = try! channel.pipeline.context(name: "the last one to remove").wait()

        XCTAssertNoThrow(try channel.pipeline.remove(name: "the first one to remove").wait())
        XCTAssertNoThrow(try channel.pipeline.remove(handler: allHandlers[1]).wait())
        XCTAssertNoThrow(try channel.pipeline.remove(ctx: lastContext).wait())

        allHandlers.forEach {
            XCTAssertTrue($0.removeHandlerCalled)
            XCTAssertFalse($0.withinRemoveHandler)
        }
    }

    func testNonRemovableChannelHandlerIsNotRemovable() {
        class NonRemovableHandler: ChannelInboundHandler {
            typealias InboundIn = Never
        }

        let channel = EmbeddedChannel()
        let allHandlers = [NonRemovableHandler(), NonRemovableHandler(), NonRemovableHandler()]
        XCTAssertNoThrow(try channel.pipeline.add(name: "1", handler: allHandlers[0]).wait())
        XCTAssertNoThrow(try channel.pipeline.add(name: "2", handler: allHandlers[1]).wait())

        let lastContext = try! channel.pipeline.context(name: "1").wait()

        XCTAssertThrowsError(try channel.pipeline.remove(name: "2").wait()) { error in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.unremovableHandler, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try channel.pipeline.remove(ctx: lastContext).wait()) { error in
            if let error = error as? ChannelError {
                XCTAssertEqual(ChannelError.unremovableHandler, error)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
    }
}
