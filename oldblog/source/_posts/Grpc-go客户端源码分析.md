title: Grpc-go客户端源码分析
date: 2017-04-24 15:33:49
tags: [grpc-go, grpc, go]
categories: [系统]
---


## 基本设计

grpc-go客户端的逻辑相对比较简单，从前面服务端的逻辑我们知道，客户端会通过http2复用tcp连接，每一次请求的调用基本上就是在已经建立好的tcp连接(并用ClientTransport抽象)上发送http请求，通过帧和流与服务端交互数据。

另外，一个服务对应的具体地址可能有多个，grpc在这里抽象了负载均衡的接口和部分实现。grpc提供两种负载均衡方式，一种是客户端内部自带的策略实现(目前只实现了轮询方式)，另一种方式是外部的load balancer。
+ 内部自带的策略实现: 这种方式主要针对一些简单的负载均衡策略比如轮询。轮询的实现逻辑是建立连接时通过定义的服务地址解析接口Resolver得到服务的地址列表，并单独用goroutine负责更新保持可用的连接，Watcher定义了具体更新实现的接口(比如多长时间解析更新一次)，最终在请求调用时会从可用连接列表中轮询选择其中一个连接发送请求。所以，grpc的负载均衡策略是请求级别的而不是连接级别的。
+ 外部load balancer：这种方式主要针对 较复杂的负载均衡策略。grpclb实现了grpc这边的逻辑，并用protobuf定义了与load balancer交互的接口。grpc-go客户端建立连接时，会先与load balancer建立连接，并使用和轮询方式类似的Resolver、Watcher接口来更新load balancer的可用连接列表，不同的是每次load balancer连接变化时，会像load balancer地址发送rpc请求得到服务的地址列表。


----

## 客户端主要流程

客户端的逻辑主要可分为下面两部分:
```
建立连接
请求调用、发送与响应
```


### 1. 建立连接

+ 典型的步骤
```
func main() {
  // 建立连接
	conn, err := grpc.Dial(address, grpc.WithInsecure())
	c := pb.NewGreeterClient(conn)
  // 请求调用
	r, err := c.SayHello(context.Background(), &pb.HelloRequest{Name: name})
	// 处理返回r
  // 对于单次请求，grpc直接负责返回响应数据
  // 对于流式请求，grpc会返回一个流的封装，由开发者负责流中数据的读写
}
```

+ 建立tcp(http2)连接
```
func Dial(target string, opts ...DialOption) (*ClientConn, error) {
	return DialContext(context.Background(), target, opts...)
}
func DialContext(ctx context.Context, target string, opts ...DialOption) (conn *ClientConn, err error) {
	cc := &ClientConn{
		target: target,
		conns:  make(map[Address]*addrConn),
	}
	/* ... */

	// 底层dialer，负责解析地址和建立tcp连接
	if cc.dopts.copts.Dialer == nil {
		cc.dopts.copts.Dialer = newProxyDialer(
			func(ctx context.Context, addr string) (net.Conn, error) {
				return dialContext(ctx, "tcp", addr)
			},
		)
	}
  /* ... */

	if cc.dopts.scChan != nil {
		// Wait for the initial service config.
		select {
		case sc, ok := <-cc.dopts.scChan:
			if ok {
				cc.sc = sc
			}
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
  /* ... */

	// 建立连接，如果设置了负载均衡，则通过负载均衡器建立连接
  // 否则直接连接
	waitC := make(chan error, 1)
	go func() {
		defer close(waitC)
		if cc.dopts.balancer == nil && cc.sc.LB != nil {
			cc.dopts.balancer = cc.sc.LB
		}
		if cc.dopts.balancer != nil {
			var credsClone credentials.TransportCredentials
			if creds != nil {
				credsClone = creds.Clone()
			}
			config := BalancerConfig{
				DialCreds: credsClone,
			}
			// 负载均衡，可能是grcp-client内部的简单轮训负载均衡或者是外部的load balancer
			// 如果是外部的load balancer，这里的target是load balancer的服务名
			// grpclb会解析load balancer地址，建立rpc连接，得到服务地址列表，并通知Notify chan
			if err := cc.dopts.balancer.Start(target, config); err != nil {
				waitC <- err
				return
			}
      // 更新后地址的发送channel
			ch := cc.dopts.balancer.Notify()
			if ch != nil {
				if cc.dopts.block {
					doneChan := make(chan struct{})
          // lbWatcher负责接收负载均衡器的地址更新，从而更新连接
					go cc.lbWatcher(doneChan)
					<-doneChan
				} else {
					go cc.lbWatcher(nil)
				}
				return
			}
		}
		// 直接建立连接
		if err := cc.resetAddrConn(Address{Addr: target}, cc.dopts.block, nil); err != nil {
			waitC <- err
			return
		}
	}()
	/* ... */
	if cc.dopts.scChan != nil {
		go cc.scWatcher()
	}

	return cc, nil
}
```

+ 内部负载均衡策略(轮询)，解析域名，并更新地址列表，写到Notify通知channel，由grpc的lbWatcher负责更新对应的服务连接列表
```
func (rr *roundRobin) Start(target string, config BalancerConfig) error {
  /* ... */
	// 服务名解析，具体实现可以DNS或者基于etcd的服务发现等，每次解析会返回一个watcher
  // watcher具体服务解析请求的周期等
	w, err := rr.r.Resolve(target)
	if err != nil {
		return err
	}
	rr.w = w
	rr.addrCh = make(chan []Address)
	go func() {
		// 循环，不断解析服务的地址，更新对应的地址列表
		for {
			if err := rr.watchAddrUpdates(); err != nil {
				return
			}
		}
	}()
	return nil
}

func (rr *roundRobin) watchAddrUpdates() error {
	// 阻塞得到需要更新的地址列表，注意在naming里面的Resolver和Watcher
	// 定义了服务解析的接口，可以使用简单的dns解析实现、consul/etcd等服务发现
	// 以及其他形式，只要能返回对应的服务地址列表即可，Resolver里边缓存已经解析
	// 过的服务，并有单独的goroutine与后端服务通信更新，这样不用每次都解析地址
	updates, err := rr.w.Next()
  // 解析后，更新对应服务的地址列表，在内部做轮训负载均衡
	for _, update := range updates {
		addr := Address{
			Addr:     update.Addr,
			Metadata: update.Metadata,
		}
		switch update.Op {
		// 添加新地址
		case naming.Add:
			var exist bool
			for _, v := range rr.addrs {
				if addr == v.addr {
					exist = true
					grpclog.Println("grpc: The name resolver wanted to add an existing address: ", addr)
					break
				}
			}
			if exist {
				continue
			}
			rr.addrs = append(rr.addrs, &addrInfo{addr: addr})
			// 删除
		case naming.Delete:
			for i, v := range rr.addrs {
				if addr == v.addr {
					copy(rr.addrs[i:], rr.addrs[i+1:])
					rr.addrs = rr.addrs[:len(rr.addrs)-1]
					break
				}
			}
	}
	open := make([]Address, len(rr.addrs))
	for i, v := range rr.addrs {
		open[i] = v.addr
	}
	// 通知lbWatcher
	rr.addrCh <- open
	return nil
}

// 轮询得到一个可用连接
func (rr *roundRobin) Get(ctx context.Context, opts BalancerGetOptions) (addr Address, put func(), err error) {
  /* ... */
	if len(rr.addrs) > 0 {
		if rr.next >= len(rr.addrs) {
			rr.next = 0
		}
		next := rr.next
		for {
      // 找到下一个，赋予返回值
			a := rr.addrs[next]
			next = (next + 1) % len(rr.addrs)
			if a.connected {
				addr = a.addr
				rr.next = next
				rr.mu.Unlock()
				return
			}
			if next == rr.next {
				// Has iterated all the possible address but none is connected.
				break
			}
		}
	}
	/* ... */
}
```

+ 外部负载均衡
```
// 对于外部负载均衡，Start负责解析负载均衡器的地址列表
func (b *balancer) Start(target string, config grpc.BalancerConfig) error {
  /* ... */
	// 解析，返回watcher
	w, err := b.r.Resolve(target)
	b.w = w
	b.mu.Unlock()
	balancerAddrsCh := make(chan []remoteBalancerInfo, 1)
	go func() {
		for {
			// 一直循环解析load balancer的地址，一旦有更新则通知
			if err := b.watchAddrUpdates(w, balancerAddrsCh); err != nil {
				/* ... */
			}
		}
	}()
	go func() {
		var (
			cc *grpc.ClientConn
			// ccError is closed when there is an error in the current cc.
			// A new rb should be picked from rbs and connected.
			ccError chan struct{}
			rb      *remoteBalancerInfo
			rbs     []remoteBalancerInfo
			rbIdx   int
		)
		/* ... */
		for {
			var ok bool
			select {
			// 从channel中读取load balancer的列表
			case rbs, ok = <-balancerAddrsCh:
				/* ... */
			}
			/* ... */
			// 连接load balancer
			if creds == nil {
				cc, err = grpc.Dial(rb.addr, grpc.WithInsecure())
			} else {
				/* ... */
				cc, err = grpc.Dial(rb.addr, grpc.WithTransportCredentials(creds))
			}
			b.mu.Lock()
			b.seq++ // tick when getting a new balancer address
			seq := b.seq
			b.next = 0
			b.mu.Unlock()
			// 对于每个load balancer的地址变化，获取新的服务地址列表，并通知lbWatcher更新
			go func(cc *grpc.ClientConn, ccError chan struct{}) {
				// load balancer client
				lbc := lbpb.NewLoadBalancerClient(cc)
				// 得到server list，并写入addrChan这个Notify channel
				b.callRemoteBalancer(lbc, seq)
				cc.Close()
				select {
				case <-ccError:
				default:
					close(ccError)
				}
			}(cc, ccError)
		}
	}()
	return nil
}
```



### 2. 请求调用、发送与响应

```
// 单次请求，grpc负责invoke对应的服务方法，并直接返回数据
func (c *greeterClient) SayHello(ctx context.Context, in *HelloRequest, opts ...grpc.CallOption) (*HelloReply, error) {
	out := new(HelloReply)
	err := grpc.Invoke(ctx, "/helloworld.Greeter/SayHello", in, out, c.cc, opts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// 流式请求，grpc返回对应的流
func (c *routeGuideClient) ListFeatures(ctx context.Context, in *Rectangle, opts ...grpc.CallOption) (RouteGuide_ListFeaturesClient, error) {
	stream, err := grpc.NewClientStream(ctx, &_RouteGuide_serviceDesc.Streams[0], c.cc, "/routeguide.RouteGuide/ListFeatures", opts...)
	if err != nil {
		return nil, err
	}
	x := &routeGuideListFeaturesClient{stream}
	if err := x.ClientStream.SendMsg(in); err != nil {
		return nil, err
	}
	if err := x.ClientStream.CloseSend(); err != nil {
		return nil, err
	}
	return x, nil
}

// 单次请求调用实现，响应返回时客户端会关闭流，而流式请求会直接将流封装后交给上层开发者，由开发者处理
func invoke(ctx context.Context, method string, args, reply interface{}, cc *ClientConn, opts ...CallOption) (e error) {
	/* ... */
	for {
		var (
			err    error
			t      transport.ClientTransport
			stream *transport.Stream
			// Record the put handler from Balancer.Get(...). It is called once the
			// RPC has completed or failed.
			put func()
		)
		/* ... */
    // 得到一个tcp连接(ClientTransport)
		t, put, err = cc.getTransport(ctx, gopts)
		/* ... */
		// 发送请求，打开新的流，序列化压缩请求数据，写入流
		stream, err = sendRequest(ctx, cc.dopts, cc.dopts.cp, callHdr, t, args, topts)
		/* ... */
		// 接收响应，解压反序列化响应，并写入reply
		err = recvResponse(ctx, cc.dopts, t, &c, stream, reply)
		/* ... */
		// 关闭流
		t.CloseStream(stream, nil)
		if put != nil {
			put()
			put = nil
		}
		return stream.Status().Err()
	}
}

// 发送请求，打开一个新的流
func sendRequest(ctx context.Context, dopts dialOptions, compressor Compressor, callHdr *transport.CallHdr, t transport.ClientTransport, args interface{}, opts *transport.Options) (_ *transport.Stream, err error) {
	// 在此连接上打开新的流
	stream, err := t.NewStream(ctx, callHdr)
	if err != nil {
		return nil, err
	}
	/* ... */
	// 序列化压缩数据
	outBuf, err := encode(dopts.codec, args, compressor, cbuf, outPayload)
	// 写入流
	err = t.Write(stream, outBuf, opts)
	/* ... */
	// Sent successfully.
	return stream, nil
}

```


----


## 总结

至此，grpc-go的客户端逻辑主体部分分析完了，其中比较重要的是:
+ 连接的建立和负载均衡的实现
+ 单次请求和流式请求的客户端实现区别
+ 针对每一个连接客户端都会新建一个ClientTransport(具体实现为htt2client)，对应于服务端的ServerTransport(具体实现为http2server)，请求的发送和响应，流和帧数据的交互，以及流量控制等都由Transport这个概念来统筹。这里的Transport与Go的net/http标准库有些不同，Go中net/http的RoundTripper接口(及其实现http.Transport)底层可以管理多个tcp连接，而grpc-go中的Transport抽象是一个连接对应一个Transport。
