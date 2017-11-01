title: 'Tornado源码分析'
date: 2015-03-09 12:08:28
categories: [编程语言, Web]
tags: [Python, Web, Tornado]
---

Tornado是一个高性能的异步网络库和Web框架，其事件循环和异步io的封装实现得很漂亮，本文主要介绍这两部分的实现。

+ main
```
def main():
    # 解析命令行参数
    tornado.options.parse_command_line()
    # 构造一个httpserver，其实大部分都是继承至tcpserver，注意参数Application()
    # 是个可调用的对象，它实现了__call__魔术方法。
    http_server = tornado.httpserver.HTTPServer(Application())
    http_server.listen(options.port)
    # 构造事件循环，并执行触发事件的相应handler/注册的timeout事件/注册的callback等。
    tornado.ioloop.IOLoop.instance().start()
```

+ http_server.listen
```
def listen(self, port, address=""):
    # 调用netutil中的bind_socket，返回的是绑定的所有(IP,port)地址的socket
    sockets = bind_sockets(port, address=address)
    # 自身的add_sockets方法中调用了netutil中的add_accept_handler
    self.add_sockets(sockets)
```

+ add_sockets
```
def add_sockets(self, sockets):
    if self.io_loop is None:
        self.io_loop = IOLoop.current()
    for sock in sockets:
        self._sockets[sock.fileno()] = sock
        # 这里回调的是_handle_connection，是处理tcp连接的核心
        add_accept_handler(sock, self._handle_connection, io_loop=self.io_loop)
    def add_accept_handler(sock, callback, io_loop=None):
        if io_loop is None:
           io_loop = IOLoop.current()
        def accept_handler(fd, events):
          while True:
              try:
                  connection, address = sock.accept()
              except socket.error as e:
                  if e.args[0] == errno.ECONNABORTED:
                      continue
                  raise
              callback(connection, address)
        # 把callback，也就是_handle_connection这个回调的handler注册到ioloop
        # 的多路复用(select/poll/epoll等)之上
        io_loop.add_handler(sock.fileno(), accept_handler, IOLoop.READ)
     # ioloop.add_handler函数:
     # def add_handler(self, fd, handler, events):
     #    self._handlers[fd] = stack_context.wrap(handler)
     #    self._impl.register(fd, events | self.ERROR)

     # 之后就由ioloop.start内的循环poll发生的事件并回调相应的handler了
```

+ handle_connection处理连接事件
```
# 实例化了iostream对象，这个对象专门负责读写数据。然后是调用heepserver重写的handle_stream方法,
# 将stream交给HTTPConnection处理，注意这里的request_callback是Application对象
def _handle_connection(self, connection, address):
        if self.ssl_options is not None:
            assert ssl, "Python 2.6+ and OpenSSL required for SSL"
            try:
                connection = ssl_wrap_socket(connection,
                                             self.ssl_options,
                                             server_side=True,
                                             do_handshake_on_connect=False)
            except ssl.SSLError as err:
                if err.args[0] == ssl.SSL_ERROR_EOF:
                    return connection.close()
                else:
                    raise
            except socket.error as err:
                if errno_from_exception(err) in (errno.ECONNABORTED, errno.EINVAL):
                    return connection.close()
                else:
                    raise
        try:
            if self.ssl_options is not None:
                stream = SSLIOStream(connection, io_loop=self.io_loop,
                                     max_buffer_size=self.max_buffer_size,
                                     read_chunk_size=self.read_chunk_size)
            else:
                stream = IOStream(connection, io_loop=self.io_loop,
                                  max_buffer_size=self.max_buffer_size,
                                  read_chunk_size=self.read_chunk_size)
            self.handle_stream(stream, address)
        except Exception:
            app_log.error("Error in connection callback", exc_info=True)
```
    
+ handle_stream
```
# 之后就到HTTPConnection初始化部分，核心就是_on_headers方法与read_until
def handle_stream(self, stream, address):
        HTTPConnection(stream, address, self.request_callback,
                       self.no_keep_alive, self.xheaders, self.protocol)
```

+ HTTPConnection.__init__
```
def __init__(self, stream, address, request_callback, no_keep_alive=False,
                 xheaders=False, protocol=None):
        self._header_callback = stack_context.wrap(self._on_headers)
        self.stream.set_close_callback(self._on_connection_close)
        # read_until可以暂时简单看作将数据读给_on_headers方法
        self.stream.read_until(b"\r\n\r\n",self._header_callback)

# self.request_callback(self._request)，这是调用Application的__call__方法，传入request对象完成响应
def _on_headers(self, data):
        try:
            data = native_str(data.decode('latin1'))
            eol = data.find("\r\n")
            start_line = data[:eol]
            try:
                method, uri, version = start_line.split(" ")
            except ValueError:
                raise _BadRequestException("Malformed HTTP request line")
            if not version.startswith("HTTP/"):
                raise _BadRequestException("Malformed HTTP version in HTTP Request-Line")
            try:
                headers = httputil.HTTPHeaders.parse(data[eol:])
            except ValueError:
                # Probably from split() if there was no ':' in the line
                raise _BadRequestException("Malformed HTTP headers")

            # HTTPRequest wants an IP, not a full socket address
            if self.address_family in (socket.AF_INET, socket.AF_INET6):
                remote_ip = self.address[0]
            else:
                # Unix (or other) socket; fake the remote address
                remote_ip = '0.0.0.0'

            self._request = HTTPRequest(
                connection=self, method=method, uri=uri, version=version,
                headers=headers, remote_ip=remote_ip, protocol=self.protocol)

            content_length = headers.get("Content-Length")
            if content_length:
                content_length = int(content_length)
                if content_length > self.stream.max_buffer_size:
                    raise _BadRequestException("Content-Length too long")
                if headers.get("Expect") == "100-continue":
                    self.stream.write(b"HTTP/1.1 100 (Continue)\r\n\r\n")
                self.stream.read_bytes(content_length, self._on_request_body)
                return

            self.request_callback(self._request)
        except _BadRequestException as e:
            gen_log.info("Malformed HTTP request from %s: %s",
                         self.address[0], e)
            self.close()
            return

```


+ application的__call__

```
def __call__(self, request):
        """Called by HTTPServer to execute the request."""
        transforms = [t(request) for t in self.transforms]
        handler = None
        args = []
        kwargs = {}
        handlers = self._get_host_handlers(request)
        if not handlers:
            handler = RedirectHandler(
                self, request, url="http://" + self.default_host + "/")
        else:
            for spec in handlers:
                match = spec.regex.match(request.path)
                if match:
                    handler = spec.handler_class(self, request, **spec.kwargs)
                    if spec.regex.groups:
                        # None-safe wrapper around url_ to handle
                        # unmatched optional groups correctly
                        def unquote(s):
                            if s is None:
                                return s
                            return escape.url_(s, encoding=None,
                                                       plus=False)
                        # Pass matched groups to the handler.  Since
                        # match.groups() includes both named and unnamed groups,
                        # we want to use either groups or groupdict but not both.
                        # Note that args are passed as bytes so the handler can
                        # decide what encoding to use.

                        if spec.regex.groupindex:
                            kwargs = dict(
                                (str(k), unquote(v))
                                for (k, v) in match.groupdict().items())
                        else:
                            args = [unquote(s) for s in match.groups()]
                    break
            if not handler:
                handler = ErrorHandler(self, request, status_code=404)

        # In debug mode, re-compile templates and reload static files on every
        # request so you don't need to restart to see changes
        if self.settings.get("debug"):
            with RequestHandler._template_loader_lock:
                for loader in RequestHandler._template_loaders.values():
                    loader.reset()
            StaticFileHandler.reset()

        handler._execute(transforms, *args, **kwargs)
        return handler
```


+ handler._execute
```
# 调用的_when_complete回调callback，也就是_execute_method
def _execute(self, transforms, *args, **kwargs):
        """Executes this request with the given output transforms."""
        self._transforms = transforms
        try:
            if self.request.method not in self.SUPPORTED_METHODS:
                raise HTTPError(405)
            self.path_args = [self.decode_argument(arg) for arg in args]
            self.path_kwargs = dict((k, self.decode_argument(v, name=k))
                                    for (k, v) in kwargs.items())
            if self.request.method not in ("GET", "HEAD", "OPTIONS") and \
                    self.application.settings.get("xsrf_cookies"):
                self.check_xsrf_cookie()
            self._when_complete(self.prepare(), self._execute_method)//prepare是空的，没被重写
        except Exception as e:
            self._handle_request_exception(e)

# _execute_method 
def _when_complete(self, result, callback):
        try:
            if result is None:
                callback()
            elif isinstance(result, Future):
                if result.done():
                    if result.result() is not None:
                        raise ValueError('Expected None, got %r' % result)
                    callback()
                else:
                    from tornado.ioloop import IOLoop
                    IOLoop.current().add_future(
                        result, functools.partial(self._when_complete,
                                                  callback=callback))
            else:
                raise ValueError("Expected Future or None, got %r" % result)
        except Exception as e:
            self._handle_request_exception(e)

def _execute_method(self):
    if not self._finished:
        method = getattr(self, self.request.method.lower())
        # 当method被执行过后，就直接调用finish，否则将method加入ioloop
        self._when_complete(method(*self.path_args, **self.path_kwargs),
                                self._execute_finish)
    def _execute_finish(self):
        if self._auto_finish and not self._finished:
            self.finish()

def finish(self, chunk=None):
        """Finishes this response, ending the HTTP request."""
        if self._finished:
            raise RuntimeError("finish() called twice.  May be caused "
                               "by using async operations without the "
                               "@asynchronous decorator.")

        if chunk is not None:
            self.write(chunk)
```



至此，整个IO流程完毕。中间还有许多非常值得深入挖掘的地方，比如ioloop/iostream、future、异步客户端httpclient、web框架等。Tornado在网络编程模型方面，是一个基于epoll多路复用和非阻塞的单线程reactor模型。



 
     
   
   
   

