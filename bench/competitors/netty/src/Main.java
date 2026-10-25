import com.fasterxml.jackson.databind.ObjectMapper;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import io.netty.channel.*;
import io.netty.channel.epoll.Epoll;
import io.netty.channel.epoll.EpollIoHandler;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.SocketChannel;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.handler.codec.http.*;
import io.netty.handler.codec.http.websocketx.*;
import io.netty.handler.codec.http.websocketx.extensions.WebSocketServerExtensionHandler;
import io.netty.handler.codec.http.websocketx.extensions.compression.PerMessageDeflateServerExtensionHandshaker;
import io.netty.handler.codec.http2.*;
import io.netty.handler.ssl.*;
import io.netty.util.AsciiString;
import io.netty.util.CharsetUtil;

import java.io.File;
import java.util.List;

/** Netty competitor server for the cajeta-http bench. Modes: h1, h2c, tls. */
public final class Main {
    static final ObjectMapper MAPPER = new ObjectMapper();
    public record Message(String message) {}

    static final byte[] HELLO = "Hello, World!".getBytes(CharsetUtil.US_ASCII);
    static final AsciiString TEXT_PLAIN = AsciiString.cached("text/plain");
    static final AsciiString APP_JSON = AsciiString.cached("application/json");
    static final AsciiString EVENT_STREAM = AsciiString.cached("text/event-stream");
    static final AsciiString NO_CACHE = AsciiString.cached("no-cache");

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("usage: Main <h1|h2c|tls> <port> [<cert.pem> <key.pem>]");
            System.exit(2);
        }
        String mode = args[0];
        int port = Integer.parseInt(args[1]);
        final SslContext ssl;
        if (mode.equals("tls")) {
            if (args.length < 4) { System.err.println("tls mode needs <cert.pem> <key.pem>"); System.exit(2); }
            ssl = SslContextBuilder.forServer(new File(args[2]), new File(args[3]))
                    .sslProvider(SslProvider.JDK)
                    .protocols("TLSv1.3", "TLSv1.2")
                    .applicationProtocolConfig(new ApplicationProtocolConfig(
                            ApplicationProtocolConfig.Protocol.ALPN,
                            ApplicationProtocolConfig.SelectorFailureBehavior.NO_ADVERTISE,
                            ApplicationProtocolConfig.SelectedListenerFailureBehavior.ACCEPT,
                            ApplicationProtocolNames.HTTP_1_1))
                    .build();
        } else if (mode.equals("h1") || mode.equals("h2c")) {
            ssl = null;
        } else {
            System.err.println("unknown mode " + mode);
            System.exit(2);
            return;
        }

        boolean epoll = Epoll.isAvailable();
        IoHandlerFactory factory = epoll ? EpollIoHandler.newFactory() : NioIoHandler.newFactory();
        EventLoopGroup boss = new MultiThreadIoEventLoopGroup(1, factory);
        EventLoopGroup workers = new MultiThreadIoEventLoopGroup(factory);
        try {
            ServerBootstrap b = new ServerBootstrap()
                    .group(boss, workers)
                    .channel(epoll ? EpollServerSocketChannel.class : NioServerSocketChannel.class)
                    .option(ChannelOption.SO_BACKLOG, 4096)
                    .childOption(ChannelOption.TCP_NODELAY, true)
                    .childHandler(new ChannelInitializer<SocketChannel>() {
                        @Override protected void initChannel(SocketChannel ch) {
                            ChannelPipeline p = ch.pipeline();
                            if (mode.equals("h2c")) {
                                initH2c(p);
                            } else {
                                if (ssl != null) p.addLast(ssl.newHandler(ch.alloc()));
                                initH1(p);
                            }
                        }
                    });
            Channel server = b.bind("127.0.0.1", port).sync().channel();
            System.err.println("netty " + mode + " listening on 127.0.0.1:" + port + " (" + (epoll ? "epoll" : "nio") + ")");
            server.closeFuture().sync();
        } finally {
            boss.shutdownGracefully();
            workers.shutdownGracefully();
        }
    }

    static void initH1(ChannelPipeline p) {
        p.addLast(new HttpServerCodec());
        p.addLast(new HttpObjectAggregator(1 << 20));
        // permessage-deflate; maxAllocation 0 = unlimited inflate buffer. Netty's encoder compresses
        // every frame (default filter never skips; there is no size threshold), so threshold = 0.
        // permessage-deflate. The stock WebSocketServerCompressionHandler refuses an
        // offer carrying server_no_context_takeover (allowServerNoContext=false),
        // which is what gorilla/websocket (the bench's load generator) always sends.
        // gorilla also requires client_no_context_takeover in the answer, so Netty
        // asks for it. Level 6, client window 15, no allocation cap.
        p.addLast(new WebSocketServerExtensionHandler(
            new PerMessageDeflateServerExtensionHandshaker(6, false, 15, true, true, 0)));
        p.addLast(new WebSocketServerProtocolHandler(WebSocketServerProtocolConfig.newBuilder()
                .websocketPath("/ws")
                .checkStartsWith(false)
                .allowExtensions(true)
                .maxFramePayloadLength(16 << 20)
                .build()));
        p.addLast(new H1Handler());
    }

    static void initH2c(ChannelPipeline p) {
        HttpServerCodec codec = new HttpServerCodec();
        HttpServerUpgradeHandler.UpgradeCodecFactory upgrades = protocol ->
                AsciiString.contentEquals(Http2CodecUtil.HTTP_UPGRADE_PROTOCOL_NAME, protocol)
                        ? new Http2ServerUpgradeCodec(newFrameCodec(), new H2Handler())
                        : null;
        HttpServerUpgradeHandler upgrade = new HttpServerUpgradeHandler(codec, upgrades);
        // Prior knowledge: the client preface replaces the cleartext handler with frame codec + H2Handler.
        ChannelHandler priorKnowledge = new ChannelInboundHandlerAdapter() {
            @Override public void handlerAdded(ChannelHandlerContext ctx) {
                ctx.pipeline().addAfter(ctx.name(), "h2-handler", new H2Handler());
                ctx.pipeline().replace(this, "h2-codec", newFrameCodec());
            }
        };
        p.addLast(new CleartextHttp2ServerUpgradeHandler(codec, upgrade, priorKnowledge));
        // HTTP/1.1 fallback on the same port (non-preface, non-upgrade requests).
        p.addLast(new HttpObjectAggregator(1 << 20));
        p.addLast(new H1Handler());
    }

    static Http2FrameCodec newFrameCodec() {
        return Http2FrameCodecBuilder.forServer()
                .initialSettings(Http2Settings.defaultSettings().maxConcurrentStreams(256))
                .build();
    }

    static byte[] json() {
        try {
            return MAPPER.writeValueAsBytes(new Message("Hello, World!"));
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /** HTTP/1.1 routes + WebSocket echo (frames arrive here after the protocol handler upgrades). */
    static final class H1Handler extends ChannelInboundHandlerAdapter {
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof FullHttpRequest req) {
                try {
                    handle(ctx, req);
                } finally {
                    req.release();
                }
            } else if (msg instanceof BinaryWebSocketFrame || msg instanceof TextWebSocketFrame
                    || msg instanceof ContinuationWebSocketFrame) {
                ctx.write(msg); // ownership passes to the write; echoed unchanged, same opcode
            } else {
                ctx.fireChannelRead(msg);
            }
        }

        @Override public void channelReadComplete(ChannelHandlerContext ctx) {
            ctx.flush();
        }

        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            ctx.close();
        }

        private void handle(ChannelHandlerContext ctx, FullHttpRequest req) {
            boolean keepAlive = HttpUtil.isKeepAlive(req);
            String uri = req.uri();
            int q = uri.indexOf('?');
            String path = q < 0 ? uri : uri.substring(0, q);
            if (req.method() != HttpMethod.GET) {
                respond(ctx, keepAlive, HttpResponseStatus.NOT_FOUND, null, Unpooled.EMPTY_BUFFER);
                return;
            }
            switch (path) {
                case "/plaintext" -> respond(ctx, keepAlive, HttpResponseStatus.OK, TEXT_PLAIN,
                        Unpooled.wrappedBuffer(HELLO));
                case "/json" -> respond(ctx, keepAlive, HttpResponseStatus.OK, APP_JSON,
                        Unpooled.wrappedBuffer(json()));
                case "/sse" -> sse(ctx, keepAlive, uri);
                default -> respond(ctx, keepAlive, HttpResponseStatus.NOT_FOUND, null, Unpooled.EMPTY_BUFFER);
            }
        }

        private static void respond(ChannelHandlerContext ctx, boolean keepAlive, HttpResponseStatus status,
                                    AsciiString contentType, ByteBuf body) {
            FullHttpResponse res = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, status, body);
            HttpHeaders h = res.headers();
            if (contentType != null) h.set(HttpHeaderNames.CONTENT_TYPE, contentType);
            h.setInt(HttpHeaderNames.CONTENT_LENGTH, body.readableBytes());
            if (keepAlive) {
                ctx.write(res);
            } else {
                h.set(HttpHeaderNames.CONNECTION, HttpHeaderValues.CLOSE);
                ctx.writeAndFlush(res).addListener(ChannelFutureListener.CLOSE);
            }
        }

        private static void sse(ChannelHandlerContext ctx, boolean keepAlive, String uri) {
            int n = 1000;
            List<String> ns = new QueryStringDecoder(uri).parameters().get("n");
            if (ns != null && !ns.isEmpty()) {
                try { n = Integer.parseInt(ns.get(0)); } catch (NumberFormatException e) { n = 1000; }
            }
            HttpResponse res = new DefaultHttpResponse(HttpVersion.HTTP_1_1, HttpResponseStatus.OK);
            HttpHeaders h = res.headers();
            h.set(HttpHeaderNames.CONTENT_TYPE, EVENT_STREAM);
            h.set(HttpHeaderNames.CACHE_CONTROL, NO_CACHE);
            HttpUtil.setTransferEncodingChunked(res, true);
            if (!keepAlive) h.set(HttpHeaderNames.CONNECTION, HttpHeaderValues.CLOSE);
            ctx.write(res);
            for (int i = 0; i < n; i++) {
                ByteBuf ev = ctx.alloc().buffer(20);
                ev.writeCharSequence("data: ", CharsetUtil.US_ASCII);
                ev.writeCharSequence(Integer.toString(i), CharsetUtil.US_ASCII);
                ev.writeByte('\n').writeByte('\n');
                ctx.write(new DefaultHttpContent(ev));
                if (i % 100 == 99) ctx.flush();
            }
            ChannelFuture f = ctx.writeAndFlush(LastHttpContent.EMPTY_LAST_CONTENT);
            if (!keepAlive) f.addListener(ChannelFutureListener.CLOSE);
        }
    }

    /** HTTP/2 routes on top of Http2FrameCodec (one handler per connection, frames carry their stream). */
    static final class H2Handler extends ChannelDuplexHandler {
        @Override public void channelRead(ChannelHandlerContext ctx, Object msg) {
            if (msg instanceof Http2HeadersFrame hf) {
                if (hf.isEndStream()) respond(ctx, hf.stream(), hf.headers().path());
                else pending.put(hf.stream().id(), hf.headers().path()); // body follows; reply at end
            } else if (msg instanceof Http2DataFrame df) {
                try {
                    if (df.isEndStream()) respond(ctx, df.stream(), pending.remove(df.stream().id()));
                } finally {
                    df.release();
                }
            } else {
                io.netty.util.ReferenceCountUtil.release(msg);
            }
        }

        @Override public void channelReadComplete(ChannelHandlerContext ctx) {
            ctx.flush();
        }

        @Override public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
            ctx.close();
        }

        private static void respond(ChannelHandlerContext ctx, Http2FrameStream stream, CharSequence fullPath) {
            String path = fullPath == null ? "" : fullPath.toString();
            int q = path.indexOf('?');
            if (q >= 0) path = path.substring(0, q);
            Http2Headers h = new DefaultHttp2Headers();
            ByteBuf body;
            switch (path) {
                case "/plaintext" -> { h.status("200").set(HttpHeaderNames.CONTENT_TYPE, TEXT_PLAIN); body = Unpooled.wrappedBuffer(HELLO); }
                case "/json" -> { h.status("200").set(HttpHeaderNames.CONTENT_TYPE, APP_JSON); body = Unpooled.wrappedBuffer(json()); }
                default -> { h.status("404"); body = Unpooled.EMPTY_BUFFER; }
            }
            h.setInt(HttpHeaderNames.CONTENT_LENGTH, body.readableBytes());
            if (body.readableBytes() == 0) {
                ctx.write(new DefaultHttp2HeadersFrame(h, true).stream(stream));
            } else {
                ctx.write(new DefaultHttp2HeadersFrame(h, false).stream(stream));
                ctx.write(new DefaultHttp2DataFrame(body, true).stream(stream));
            }
        }

        private final java.util.HashMap<Integer, CharSequence> pending = new java.util.HashMap<>();
    }
}
