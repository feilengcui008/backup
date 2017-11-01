title: Linux网络编程小结
date: 2015-03-04 22:37:15
categories: [系统]
tags: [Linux编程, C/C++]
---

网络编程是一个很大也很有趣的话题，要写好一个高性能并且bug少的服务端或者客户端程序还是挺不容易的，而且往往涉及到进程线程管理、内存管理、协议栈、并发等许多相关的知识，而不仅仅只是会使用socket那么简单。

----

### 网络编程模型
+ 阻塞和非阻塞
阻塞和非阻塞通常是指文件描述符本身的属性。对于默认阻塞的socket来说，当socket读缓冲区中没有数据或者写缓冲区满时，都会造成`read/recv`或者`write/send`系统调用阻塞，而非阻塞socket在这种情况下会产生`EWOULDBLOCK`或者`EAGAIN`等错误并立即返回，不会等待socket变得可读或者可写。在Linux下我们可以通过accept4/fcntl系统调用设置socket为非阻塞。
		
+ 同步/异步
同步和异步可以分两层理解。一个是底层OS提供的IO基础设施的同步和异步，另一个是编程方式上的同步和异步。同步IO和异步IO更多地是怎么处理读写问题的一种手段。通常这也对应着两种高性能网络编程模式reactor和proactor。同步通常是事件发生时主动读写数据，直到显示地返回读写状态标志；而异步通常是我们交给操作系统帮我们读写，只需要注册读写完成的回调函数，提交读写的请求后，控制权就返回到进程。对于编程方式上的异步，典型的比如事件循环的回调、C++11的`std::async/std::future`等等，更多的是通过回调或者线程的方式组织异步的代码逻辑。
		
+ IO复用
IO复用通常是用`select/poll/epoll`等来统一代理多个socket的事件的发生。select是一种比较通用的多路复用技术，poll是Linux平台下对select做的改进，而epoll是目前Linux下最常用的多路复用技术。

----
	
### 常见网络库采用的模型(只看epoll)：
+ nginx：master进程+多个worker进程，one eventloop per process
+ memcached：主线程+多个worker线程，one eventloop per thread
+ tornado：单线程，one eventloop per thread
+ muduo：网络库，one eventloop per thread
+ libevent、libev、boost.asio：网络库，跨平台eventloop封装
+ ...

排除掉传统的单线程、多进程、多线程等模型，最常用的高性能网络编程模型是one eventloop per thread与多线程的组合。另外，为了处理耗时的任务再加上线程池，为了更好的内存管理再加上对象池。


### 应用层之外
前面的模型多是针对应用层的C10K类问题的解决方案，在更高并发要求的环境下就需要在内核态下做手脚了，比如使用零拷贝等技术，直接越过内核协议栈，实现高速数据包的传递，相应的内核模块也早有实现。主要的技术点在于：

+ 数据平面与控制平面分离，减少不必要的系统调用
+ 用户态驱动uio/vfio等减少内存拷贝
+ 使用内存池减少内存分配
+ 通过CPU亲和性提高缓存命中率
+ 网卡多队列与poll模式充分利用多核
+ batch syscall
+ 用户态协议栈
+ ...

相应的技术方案大多数是围绕这些点来做优化结合的。比如OSDI '14上的Arrakis、IX，再早的有pfring、netmap、intel DPDK、mTCP等等。
