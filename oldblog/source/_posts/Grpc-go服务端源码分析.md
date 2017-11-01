title: Grpc-go服务端源码分析
date: 2017-04-23 15:47:59
tags: [grpc, grpc-go]
categories: [系统]
---


## 基本设计

+ 服务抽象
    + 一个Server可包含多个Service，每个Service包含多个业务逻辑方法，应用开发者需要:
        + 不使用protobuf
            + 规定Service需要实现的接口
            + 实现此Service对应的ServiceDesc，ServiceDesc描述了服务名、处理此服务的接口类型、单次调用的方法数组、流式方法数组、其他元数据。
            + 实现Service接口具体业务逻辑的结构体
            + 实例化Server，并讲ServiceDesc和Service具体实现注册到Server
            + 监听并启动Server服务
        + 使用protobuf
            + 实现protobuf grpc插件生成的Service接口
            + 实例化Server，并注册Service接口的具体实现
            + 监听并启动Server
        + 可见，protobuf的grpc-go插件帮助我们生成了Service的接口和ServiceDesc。

+ 底层传输协议
    + grpc-go使用http2作为应用层的传输协议，http2会复用底层tcp连接，以流和数据帧的形式处理上层协议，grpc-go使用http2的主要逻辑有下面几点，关于http2详细的细节可参考[http2的规范](http://http2.github.io/)
        + http2帧分为几大类，grpc-go使用中比较重要的是HEADERS和DATA帧类型。
            + HEADERS帧在打开一个新的流时使用，通常是客户端的一个http请求，grpc-go通过底层的go的http2实现帧的读写，并解析出客户端的请求头(大多是grpc内部自己定义的)，读取请求体的数据，grpc规定请求体的数据由两部分构成(5 byte + len(msg)), 其中第1字节表明是否压缩，第2-5个字节消息体的长度(最大2^32即4G)，msg为客户端请求序列化后的原始数据。
            + 数据帧从属于某个stream，按照stream id查找，并写入对应的stream中。
        + Server端接收到客户端建立的连接后，使用一个goroutine专门处理此客户端的连接(即一个tcp连接或者说一个http2连接)，所以同一个grpc客户端连接上服务端后，后续的请求都是通过同一个tcp连接。
        + 客户端和服务端的连接在应用层由Transport抽象(类似通常多路复用实现中的封装的channel)，在客户端是ClientTransport，在服务端是ServerTransport。Server端接收到一个客户端的http2请求后即打开一个新的流，ClientTransport和ServerTransport之间使用这个新打开的流以http2帧的形式交换数据。
        + 客户端的每个http2请求会打开一个新的流。流可以从两边关闭，对于单次请求来说，客户端会主动关闭流，对于流式请求客户端不会主动关闭(即使使用了CloseSend也只是发送了数据发送结束的标识，还是由服务端关闭)。
        + grpc-go中的单次方法和流式方法
            + 无论是单次方法还是流式方法，服务端在调用完用户的处理逻辑函数返回后，都会关闭流(这也是为什么ServerStream不需要实现CloseSend的原因)。区别只是对于服务端的流式方法来说，可循环多次读取这个流中的帧数据并处理，以此"复用"这个流。
            + 客户端如果是流式方法，需要显示调用CloseSend，表示数据发送的结束



----


## 服务端主要流程

由于比较多，所以分以下几个部分解读主要逻辑:
```
实例化Server
注册Service
监听并接收连接请求
连接与请求处理
连接的处理细节(http2连接的建立)
新请求的处理细节(新流的打开和帧数据的处理)
```


+ 实例化Server

```
// 工厂方法
func NewServer(opt ...ServerOption) *Server {
	var opts options
	// 默认最大消息长度: 4M
	opts.maxMsgSize = defaultMaxMsgSize
	// 设置定制的参数
	for _, o := range opt {
		o(&opts)
	}
	// 默认编解码方式为protobuf
	if opts.codec == nil {
		// Set the default codec.
		opts.codec = protoCodec{}
	}
  // 实例化Server
	s := &Server{
		lis:   make(map[net.Listener]bool),
		opts:  opts,
		conns: make(map[io.Closer]bool),
		m:     make(map[string]*service),
	}
	s.cv = sync.NewCond(&s.mu)
	s.ctx, s.cancel = context.WithCancel(context.Background())
	if EnableTracing {
		_, file, line, _ := runtime.Caller(1)
		s.events = trace.NewEventLog("grpc.Server", fmt.Sprintf("%s:%d", file, line))
	}
	return s
}

// Server结构体
// 一个Server结构代表对外服务的单元，每个Server可以注册
// 多个Service，每个Service可以有多个方法，主程序需要
// 实例化Server，注册Service，然后调用s.Serve(l)
type Server struct {
	opts options
	mu sync.Mutex // guards following
	// 监听地址列表
	lis map[net.Listener]bool
	// 客户端的连接
	conns map[io.Closer]bool
	drain bool
	// 上下文
	ctx    context.Context
	cancel context.CancelFunc
	// A CondVar to let GracefulStop() blocks until all the pending RPCs are finished
	// and all the transport goes away.
	// 优雅退出时，会等待在此信号，直到所有的RPC都处理完了，并且所有
	// 的传输层断开
	cv *sync.Cond
	// 服务名: 服务
	m map[string]*service // service name -> service info
	// 事件追踪
	events trace.EventLog
}

// Server配置项
// Server可设置的选项
type options struct {
	// 加密信息， 目前实现了TLS
	creds credentials.TransportCredentials
	// 数据编解码，目前实现了protobuf，并用缓存池sync.Pool优化
	codec Codec
	// 数据压缩，目前实现了gzip
	cp Compressor
	// 数据解压，目前实现了gzip
	dc Decompressor
	// 最大消息长度
	maxMsgSize int
	// 单次请求的拦截器
	unaryInt UnaryServerInterceptor
	// 流式请求的拦截器
	streamInt   StreamServerInterceptor
	inTapHandle tap.ServerInHandle
	// 统计
	statsHandler stats.Handler
	// 最大并发流数量，http2协议规范
	maxConcurrentStreams uint32
	useHandlerImpl       bool // use http.Handler-based server
	unknownStreamDesc    *StreamDesc
	// server端的keepalive参数，会由单独的gorotine负责探测客户端连接的活性
	keepaliveParams keepalive.ServerParameters
	keepalivePolicy keepalive.EnforcementPolicy
}

```


+ 注册Service
```
// 注册service: sd接口，ss实现
// 如果使用protobuf的grpc-go插件，则会生成sd接口
func (s *Server) RegisterService(sd *ServiceDesc, ss interface{}) {
	// 检查ss是否实现sd定义的服务方法接口
	ht := reflect.TypeOf(sd.HandlerType).Elem()
	st := reflect.TypeOf(ss)
	if !st.Implements(ht) {
		grpclog.Fatalf("grpc: Server.RegisterService found the handler of type %v that does not satisfy %v", st, ht)
	}
	s.register(sd, ss)
}

func (s *Server) register(sd *ServiceDesc, ss interface{}) {
	/* ... */
	// 检查是否已注册
	if _, ok := s.m[sd.ServiceName]; ok {
		grpclog.Fatalf("grpc: Server.RegisterService found duplicate service registration for %q", sd.ServiceName)
	}
	// 实例化一个服务
	srv := &service{
		// 具体实现
		server: ss,
		// 单次方法信息
		md:    make(map[string]*MethodDesc),
    // 流式方法信息
		sd:    make(map[string]*StreamDesc),
		mdata: sd.Metadata,
	}
	for i := range sd.Methods {
		d := &sd.Methods[i]
		srv.md[d.MethodName] = d
	}
	for i := range sd.Streams {
		d := &sd.Streams[i]
		srv.sd[d.StreamName] = d
	}
	// 注册服务到server
	s.m[sd.ServiceName] = srv
}

// 一个由protobuf grcp-go插件生成的sd例子
var _Greeter_serviceDesc = grpc.ServiceDesc{
  // 服务名
	ServiceName: "app.Greeter",
  // 此服务的处理类型(通常为实现某服务接口的具体实现结构体)
	HandlerType: (*GreeterServer)(nil),
  // 单次方法
	Methods: []grpc.MethodDesc{
		{
      // 方法名
			MethodName: "SayHello",
      // 最终调用的对应/service/method的方法
			Handler:    _Greeter_SayHello_Handler,
		},
	},
	Streams:  []grpc.StreamDesc{},
	Metadata: "app.proto",
}

// 要注意的是protobuf的grpc-go插件为我们生成的MethodDesc中的Handler
// 对于单次方法和流式方法区别较大，单次方法的参数传入和返回的是单一的请求
// 和返回对象，而流式方法传入的是底层流的封装ClientStream、ServerStream
// 因此流式方法可多次读写流。
// 单次方法的一个例子
func _Greeter_SayHello_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(HelloRequest)
  // 注意这个dec方法参数，负责反序列化，解压
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(GreeterServer).SayHello(ctx, in)
	}
	/* ... */
}
// 流式方法的一个例子(假设是客户端可流式发送)
func _Greeter_SayHello_Handler(srv interface{}, stream grpc.ServerStream) error {
  // 这里应该由业务逻辑实现的SayHello处理流式读取处理的逻辑
	return srv.(GreeterServer).SayHello(&greeterSayHelloServer{stream})
}
```


+ 监听并接收连接请求
```
func (s *Server) Serve(lis net.Listener) error {
	/* ... */
	var tempDelay time.Duration // how long to sleep on accept failure
	// 循环处理连接，每个连接使用一个goroutine处理
  // accept如果失败，则下次accept之前睡眠一段时间
	for {
		rawConn, err := lis.Accept()
		if err != nil {
			if ne, ok := err.(interface {
				Temporary() bool
			}); ok && ne.Temporary() {
				if tempDelay == 0 {
					// 初始5ms
					tempDelay = 5 * time.Millisecond
				} else {
					// 否则翻倍
					tempDelay *= 2
				}
				// 不超过1s
				if max := 1 * time.Second; tempDelay > max {
					tempDelay = max
				}
	d     /* ... */
				// 等待超时重试，或者context事件的发生
				select {
				case <-time.After(tempDelay):
				case <-s.ctx.Done():
				}
				continue
			}
      /* ... */
		}
		// 重置延时
		tempDelay = 0
		// Start a new goroutine to deal with rawConn
		// so we don't stall this Accept loop goroutine.
    // 每个新的tcp连接使用单独的goroutine处理
		go s.handleRawConn(rawConn)
	}
}
```


+ 连接与请求处理
```
func (s *Server) handleRawConn(rawConn net.Conn) {
	// 是否加密
	conn, authInfo, err := s.useTransportAuthenticator(rawConn)
	/* ... */
	s.mu.Lock()
	// 如果此goroutine处于处理连接中时，server被关闭，则直接关闭连接返回
	if s.conns == nil {
		s.mu.Unlock()
		conn.Close()
		return
	}
	s.mu.Unlock()

	if s.opts.useHandlerImpl {
		// 测试时使用
		s.serveUsingHandler(conn)
	} else {
    // 处理http2连接的建立，http2连接的建立也需要客户端和
    // 服务端交换，即http2 Connection Preface，所以后面
    // 的宏观逻辑是，先处理http2连接建立过程中的帧数据信息，
    // 然后一直循环处理新的流的建立(即新的http2请求的到达)
    // 和帧的数据收发。
		s.serveHTTP2Transport(conn, authInfo)
	}
}

// 每个http2连接在服务端会生成一个ServerTransport，这里是 htt2server
func (s *Server) serveHTTP2Transport(c net.Conn, authInfo credentials.AuthInfo) {
	config := &transport.ServerConfig{
		MaxStreams:      s.opts.maxConcurrentStreams,
		AuthInfo:        authInfo,
		InTapHandle:     s.opts.inTapHandle,
		StatsHandler:    s.opts.statsHandler,
		KeepaliveParams: s.opts.keepaliveParams,
		KeepalivePolicy: s.opts.keepalivePolicy,
	}
	// 返回实现了ServerTransport接口的http2server
	// 接口规定了HandleStream, Write等方法
	st, err := transport.NewServerTransport("http2", c, config)
	/* ... */
	// 加入每个连接的ServerTransport
	if !s.addConn(st) {
		// 出错关闭Transport，即关闭客户端的net.Conn
		st.Close()
		return
	}
	// 开始处理连接Transport，处理新的帧数据和流的打开
	s.serveStreams(st)
}

// 新建ServerTransport
func newHTTP2Server(conn net.Conn, config *ServerConfig) (_ ServerTransport, err error) {
  // 封装帧的读取，底层使用的是http2.frame
	framer := newFramer(conn)
  // 初始的配置帧
	// Send initial settings as connection preface to client.
	var settings []http2.Setting
	// TODO(zhaoq): Have a better way to signal "no limit" because 0 is
	// permitted in the HTTP2 spec.
  // 流的最大数量
	maxStreams := config.MaxStreams
	if maxStreams == 0 {
		maxStreams = math.MaxUint32
	} else {
		settings = append(settings, http2.Setting{
			ID:  http2.SettingMaxConcurrentStreams,
			Val: maxStreams,
		})
	}
  // 流窗口大小，默认16K
	if initialWindowSize != defaultWindowSize {
		settings = append(settings, http2.Setting{
			ID:  http2.SettingInitialWindowSize,
			Val: uint32(initialWindowSize)})
	}
	if err := framer.writeSettings(true, settings...); err != nil {
		return nil, connectionErrorf(true, err, "transport: %v", err)
	}
	// Adjust the connection flow control window if needed.
	if delta := uint32(initialConnWindowSize - defaultWindowSize); delta > 0 {
		if err := framer.writeWindowUpdate(true, 0, delta); err != nil {
			return nil, connectionErrorf(true, err, "transport: %v", err)
		}
	}
  // tcp连接的KeepAlive相关参数
	kp := config.KeepaliveParams
  // 最大idle时间，超过此客户端连接将被关闭，默认无穷
	if kp.MaxConnectionIdle == 0 {
		kp.MaxConnectionIdle = defaultMaxConnectionIdle
	}
	if kp.MaxConnectionAge == 0 {
		kp.MaxConnectionAge = defaultMaxConnectionAge
	}
	// Add a jitter to MaxConnectionAge.
	kp.MaxConnectionAge += getJitter(kp.MaxConnectionAge)
	if kp.MaxConnectionAgeGrace == 0 {
		kp.MaxConnectionAgeGrace = defaultMaxConnectionAgeGrace
	}
	if kp.Time == 0 {
		kp.Time = defaultServerKeepaliveTime
	}
	if kp.Timeout == 0 {
		kp.Timeout = defaultServerKeepaliveTimeout
	}
	kep := config.KeepalivePolicy
	if kep.MinTime == 0 {
		kep.MinTime = defaultKeepalivePolicyMinTime
	}
	var buf bytes.Buffer
	t := &http2Server{
		ctx:             context.Background(),
		conn:            conn,
		remoteAddr:      conn.RemoteAddr(),
		localAddr:       conn.LocalAddr(),
		authInfo:        config.AuthInfo,
		framer:          framer,
		hBuf:            &buf,
		hEnc:            hpack.NewEncoder(&buf),
		maxStreams:      maxStreams,
		inTapHandle:     config.InTapHandle,
		controlBuf:      newRecvBuffer(),
		fc:              &inFlow{limit: initialConnWindowSize},
		sendQuotaPool:   newQuotaPool(defaultWindowSize),
		state:           reachable,
		writableChan:    make(chan int, 1),
		shutdownChan:    make(chan struct{}),
		activeStreams:   make(map[uint32]*Stream),
		streamSendQuota: defaultWindowSize,
		stats:           config.StatsHandler,
		kp:              kp,
		idle:            time.Now(),
		kep:             kep,
	}
	/* ... */
  // 专门处理控制信息
	go t.controller()
  // 专门处理tcp连接的保火逻辑
	go t.keepalive()
  // 解锁
	t.writableChan <- 0
	return t, nil
}


func (s *Server) serveStreams(st transport.ServerTransport) {
	// 处理完移除
	defer s.removeConn(st)
	// 处理完关闭Transport
	defer st.Close()
	var wg sync.WaitGroup
	// ServerTransport定义的HandleStream, 传入handler和trace callback方法
	// 这里ServerTransport的HandleStream实现会使用包装的http2.frame，循环不断读取帧
  // 直到客户端的net.Conn返回错误或者关闭为止，handler只用来处理HEADER类型的帧(即新的http
  // 请求，新的流的打开)，其他帧比如数据帧会分发到对应的stream, 这里的HEADER帧数据包含
  // 了grpc定义的http请求头等信息。HandleStream会一直循环读取新到达的帧，知道出现错误
  // 实在需要关闭客户端的连接，流读写相关的错误一般不会导致连接的关闭。
	st.HandleStreams(func(stream *transport.Stream) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// 处理stream，只有HEADER类型的帧才调用这个处理请求头等信息
			s.handleStream(st, stream, s.traceInfo(st, stream))
		}()
	}, func(ctx context.Context, method string) context.Context {
		if !EnableTracing {
			return ctx
		}
		tr := trace.New("grpc.Recv."+methodFamily(method), method)
		return trace.NewContext(ctx, tr)
	})
	// 等待HandleStream结束，除非客户端的连接由于错误发生需要关闭，一般不会到这
	wg.Wait()
}

```


+ 连接的处理细节(http2连接的建立)
```
// 实现的ServerTransport的HandleStreams接口
func (t *http2Server) HandleStreams(handle func(*Stream), traceCtx func(context.Context, string) context.Context) {
	// Check the validity of client preface.
	// 检查是否是http2
	// 建立一个http2连接之后，之后的所有stream复用此连接
	preface := make([]byte, len(clientPreface))
	if _, err := io.ReadFull(t.conn, preface); err != nil {
		grpclog.Printf("transport: http2Server.HandleStreams failed to receive the preface from client: %v", err)
		t.Close()
		return
	}
	if !bytes.Equal(preface, clientPreface) {
		grpclog.Printf("transport: http2Server.HandleStreams received bogus greeting from client: %q", preface)
		t.Close()
		return
	}
	// 读取一帧配置信息，参考http2的规范
	frame, err := t.framer.readFrame()
	/* ... */
	sf, ok := frame.(*http2.SettingsFrame)
	/* ... */
	t.handleSettings(sf)

	// 一直循环读取并处理帧, 注意什么时候底层的tcp连接会关闭，通常大多数情况下不会导致连接的关闭
  // 从这里开始就是处理流和数据帧的逻辑了，连接复用在这里真正被体现
	for {
		frame, err := t.framer.readFrame()
		atomic.StoreUint32(&t.activity, 1)
		if err != nil {
			// StreamError，不退出，
			if se, ok := err.(http2.StreamError); ok {
				t.mu.Lock()
				s := t.activeStreams[se.StreamID]
				t.mu.Unlock()
				// 关闭Stream
				if s != nil {
					t.closeStream(s)
				}
				// 控制输出错误信息
				t.controlBuf.put(&resetStream{se.StreamID, se.Code})
				continue
			}
			// io.EOF什么时候触发? 客户端关闭连接?
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				t.Close()
				return
			}
			grpclog.Printf("transport: http2Server.HandleStreams failed to read frame: %v", err)
			t.Close()
			return
		}
		// HTTP2定义的帧类型
		switch frame := frame.(type) {
		// HEADER frame用来打开一个stream，表示一个新请求的到来和一个新的流的建立，这里需要使用Server定义的处理逻辑
    // 解析请求头，得到服务和方法的名称
		case *http2.MetaHeadersFrame:
			// 上层传递过来的handle处理stream
			if t.operateHeaders(frame, handle, traceCtx) {
				t.Close()
				break
			}
		// DataFrame, RSTStream, WindowUpdateFrame都属于特定stream id的Stream
		// 会被分派给对应的Stream
		case *http2.DataFrame:
			t.handleData(frame)
		case *http2.RSTStreamFrame:
			t.handleRSTStream(frame)
		case *http2.SettingsFrame:
			t.handleSettings(frame)
		case *http2.PingFrame:
			t.handlePing(frame)
		case *http2.WindowUpdateFrame:
			t.handleWindowUpdate(frame)
		case *http2.GoAwayFrame:
			// TODO: Handle GoAway from the client appropriately.
		default:
			grpclog.Printf("transport: http2Server.HandleStreams found unhandled frame type %v.", frame)
		}
	}
}

```


+ 新请求的处理细节(新流的打开和帧数据的处理)
```
// 解析流，提取服务名，方法名等信息，handleStream实现的是stream的业务逻辑处理
func (s *Server) handleStream(t transport.ServerTransport, stream *transport.Stream, trInfo *traceInfo) {
	sm := stream.Method()
	if sm != "" && sm[0] == '/' {
		sm = sm[1:]
	}
	pos := strings.LastIndex(sm, "/")
	/* ... */
	// 服务名
	service := sm[:pos]
	// 方法名
	method := sm[pos+1:]
	// 服务
	srv, ok := s.m[service]
	// 未注册的服务
	if !ok {
		if unknownDesc := s.opts.unknownStreamDesc; unknownDesc != nil {
			s.processStreamingRPC(t, stream, nil, unknownDesc, trInfo)
			return
		}
		/* ... */
		return
	}
	// Unary RPC or Streaming RPC?
	// 处理单次请求
	if md, ok := srv.md[method]; ok {
		s.processUnaryRPC(t, stream, srv, md, trInfo)
		return
	}
	// 处理流式请求
	if sd, ok := srv.sd[method]; ok {
		s.processStreamingRPC(t, stream, srv, sd, trInfo)
		return
	}
	
	// 没找到对应方法
	if unknownDesc := s.opts.unknownStreamDesc; unknownDesc != nil {
		s.processStreamingRPC(t, stream, nil, unknownDesc, trInfo)
		return
	}
	/* ... */
}

// 处理单次请求
func (s *Server) processUnaryRPC(t transport.ServerTransport, stream *transport.Stream, srv *service, md *MethodDesc, trInfo *traceInfo) (err error) {
	/* ... */
	// 发送数据的压缩格式
	if s.opts.cp != nil {
		// NOTE: this needs to be ahead of all handling, https://github.com/grpc/grpc-go/issues/686.
		stream.SetSendCompress(s.opts.cp.Type())
	}
	// 解析消息
	p := &parser{r: stream}
	for { // TODO: delete
		// 第一个HEADER帧过后，后面的数据帧包含消息数据
		// 头5个字节：第一个字节代表是否压缩，2-5个字节消息体的长度，后面的数据全部读取给req
		pf, req, err := p.recvMsg(s.opts.maxMsgSize)
    /* ... */
		// 检查压缩类型是否正确
		if err := checkRecvPayload(pf, stream.RecvCompress(), s.opts.dc); err != nil {
      /* ... */
		}
		// 解压解码等操作，最终数据放到v中，而这个v则指向服务接口实现对应方法的请求参数req
		df := func(v interface{}) error {
			if inPayload != nil {
				inPayload.WireLength = len(req)
			}
			if pf == compressionMade {
				var err error
				// 解压
				req, err = s.opts.dc.Do(bytes.NewReader(req))
				if err != nil {
					return Errorf(codes.Internal, err.Error())
				}
			}
			// 解压之后超过最大消息长度
			if len(req) > s.opts.maxMsgSize {
				// TODO: Revisit the error code. Currently keep it consistent with
				// java implementation.
				return status.Errorf(codes.Internal, "grpc: server received a message of %d bytes exceeding %d limit", len(req), s.opts.maxMsgSize)
			}
			// 解码
			if err := s.opts.codec.Unmarshal(req, v); err != nil {
				return status.Errorf(codes.Internal, "grpc: error unmarshalling request: %v", err)
			}
			/* ... */
		}

		// 处理原始消息数据，调用服务方法，这个Handler即上面protobuf的grpc-go插件为我们生成的处理函数
		reply, appErr := md.Handler(srv.server, stream.Context(), df, s.opts.unaryInt)
		/* ... */
		// 发送响应，输出会在Transport和Stream两层做流控
		if err := s.sendResponse(t, stream, reply, s.opts.cp, opts); err != nil {
			// 单次请求处理完毕，直接返回
			if err == io.EOF {
				// The entire stream is done (for unary RPC only).
				return err
			}
			/* ... */
		}
		
		// TODO: Should we be logging if writing status failed here, like above?
		// Should the logging be in WriteStatus?  Should we ignore the WriteStatus
		// error or allow the stats handler to see it?
		// 发送http响应头，关闭stream
		return t.WriteStatus(stream, status.New(codes.OK, ""))
	}
}

// 处理流式方法
func (s *Server) processStreamingRPC(t transport.ServerTransport, stream *transport.Stream, srv *service, sd *StreamDesc, trInfo *traceInfo) (err error) {
	/* ... */
	ss := &serverStream{
		t:            t,
		s:            stream,
		p:            &parser{r: stream},
		codec:        s.opts.codec,
		cp:           s.opts.cp,
		dc:           s.opts.dc,
		maxMsgSize:   s.opts.maxMsgSize,
		trInfo:       trInfo,
		statsHandler: sh,
	}
	if ss.cp != nil {
		ss.cbuf = new(bytes.Buffer)
	}
  /* ... */
	var appErr error
	var server interface{}
	if srv != nil {
		server = srv.server
	}
	if s.opts.streamInt == nil {
    // 调用protobuf grpc-go插件生成的ServiceDesc中的Handler
		appErr = sd.Handler(server, ss)
	} else {
		info := &StreamServerInfo{
			FullMethod:     stream.Method(),
			IsClientStream: sd.ClientStreams,
			IsServerStream: sd.ServerStreams,
		}
		appErr = s.opts.streamInt(server, ss, info, sd.Handler)
	}
	/* ... */
  // 注意，业务逻辑的实现函数返回后，最终还是会由服务端关闭流
	return t.WriteStatus(ss.s, status.New(codes.OK, ""))
}

// 发送响应数据，输出写数据时做了流量的控制
func (s *Server) sendResponse(t transport.ServerTransport, stream *transport.Stream, msg interface{}, cp Compressor, opts *transport.Options) error {
	// 编码并压缩
	p, err := encode(s.opts.codec, msg, cp, cbuf, outPayload)
	// ok, 写响应，加了出带宽的流控
	err = t.Write(stream, p, opts)
  /* ... */
	return err
}
func (t *http2Server) Write(s *Stream, data []byte, opts *Options) (err error) {
	// TODO(zhaoq): Support multi-writers for a single stream.
	var writeHeaderFrame bool
	s.mu.Lock()
	// stream已经关闭了
	if s.state == streamDone {
		s.mu.Unlock()
		return streamErrorf(codes.Unknown, "the stream has been done")
	}
	// 需要写header
	if !s.headerOk {
		writeHeaderFrame = true
	}
	s.mu.Unlock()
	// 写响应头
	if writeHeaderFrame {
		t.WriteHeader(s, nil)
	}

	// 缓冲
	r := bytes.NewBuffer(data)
	for {
		if r.Len() == 0 {
			return nil
		}
		// 每个frame最多16k
		size := http2MaxFrameLen
		// ServerTransport的quota默认等于Stream的quota，为默认窗口大小65535字节
    // 流层限流
		sq, err := wait(s.ctx, nil, nil, t.shutdownChan, s.sendQuotaPool.acquire())
    // 传输层限流
		tq, err := wait(s.ctx, nil, nil, t.shutdownChan, t.sendQuotaPool.acquire())
		if sq < size {
			size = sq
		}
		if tq < size {
			size = tq
		}
		// 实际需要发送的数据, 返回buf的size长度的slice
		p := r.Next(size)
		ps := len(p)
		// 小于本次的quota，则归还多的部分
		if ps < sq {
			// Overbooked stream quota. Return it back.
			// add会重置channel中的可用quota
			s.sendQuotaPool.add(sq - ps)
		}
		if ps < tq {
			// Overbooked transport quota. Return it back.
			t.sendQuotaPool.add(tq - ps)
		}
		t.framer.adjustNumWriters(1)
		// 等待拿到此transport的锁，通过t.writableChan实现，由于可能有多个stream等待写transport，所以需要
    // 用chan序列化
		if _, err := wait(s.ctx, nil, nil, t.shutdownChan, t.writableChan); err != nil {
      /* ... */
		}
		select {
		case <-s.ctx.Done():
			t.sendQuotaPool.add(ps)
			if t.framer.adjustNumWriters(-1) == 0 {
				t.controlBuf.put(&flushIO{})
			}
      // 需要释放锁
			t.writableChan <- 0
			return ContextErr(s.ctx.Err())
		default:
		}
		var forceFlush bool
		// 没有剩下的数据可写了，直接flush，注意http2.frame写的时候是写到framer的Buffer writer
		// 中，需要flush buffer writer，让数据完全写到客户端的net.Conn里去
		// 注意这里的opts.Last，客户端发送完数据后需要显示调用CloseSend标识opts.Last为true
		// 只有在不是显示由客户端发送结束标识，并且是最后一个使用这个stream，且没有可再读取
		// 的数据时才强制flush
		if r.Len() == 0 && t.framer.adjustNumWriters(0) == 1 && !opts.Last {
			forceFlush = true
		}
    // 写到buffer reader中
		if err := t.framer.writeData(forceFlush, s.id, false, p); err != nil {
			t.Close()
			return connectionErrorf(true, err, "transport: %v", err)
		}
    // flush
		if t.framer.adjustNumWriters(-1) == 0 {
			t.framer.flushWrite()
		}
    // 需要释放锁，让其他stream写
		t.writableChan <- 0
	}
}

// Data帧的处理，直接写到对应流的buf
func (t *http2Server) handleData(f *http2.DataFrame) {
	// 根据stream id找到stream
	s, ok := t.getStream(f)

	if size > 0 {
		if f.Header().Flags.Has(http2.FlagDataPadded) {
			if w := t.fc.onRead(uint32(size) - uint32(len(f.Data()))); w > 0 {
				t.controlBuf.put(&windowUpdate{0, w})
			}
		}
    /* ... */
		s.mu.Unlock()
		// TODO(bradfitz, zhaoq): A copy is required here because there is no
		// guarantee f.Data() is consumed before the arrival of next frame.
		// Can this copy be eliminated?
		if len(f.Data()) > 0 {
			data := make([]byte, len(f.Data()))
			copy(data, f.Data())
      // 写入stream的buf
			s.write(recvMsg{data: data})
		}
	}
	if f.Header().Flags.Has(http2.FlagDataEndStream) {
		// Received the end of stream from the client.
		s.mu.Lock()
		if s.state != streamDone {
			s.state = streamReadDone
		}
		s.mu.Unlock()
    // 写入stream的buf
		s.write(recvMsg{err: io.EOF})
	}
}
```


----


## 总结
至此，服务端的主要流程就基本走完了，整个处理流程还有很多加密、授权、http2连接的控制信息(比如窗口大小的设置等)、KeepAlive逻辑以及穿插在各个地方的统计、追踪、日志处理等细节，这些细节对理解grpc-go的实现影响不大，所以不再细说。整个流程下来，多少可以看到Go的很多特性极大地方便了grpc的实现，用goroutine代替多路复用的回调，io的抽象与缓冲。同时，http2整个的模型其实和基于多路复用实现的grpc框架底层数据传输协议有些类似，http2的一个帧类似于某个格式化和序列化后的请求数据或响应数据，但是传统的rpc协议并没有流对应的概念，要实现"流的复用"也不是太容易，请求的下层直接是tcp连接，另外http2是通用的标准化协议，而且复用连接之后其性能也不差。
