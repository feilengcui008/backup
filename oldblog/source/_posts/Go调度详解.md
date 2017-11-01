title: Go调度详解
date: 2017-05-09 19:40:07
tags: [Go]
categories: [编程语言]
---

### 基本单元
Go调度相关的四个基本单元是g、m、p、schedt。g是协程任务信息单元，m实际执行体，p是本地资源池和g任务池，schedt是全局资源池和g任务池。这里的m对应一个os线程，所以整个执行逻辑简单来说就是"某个os线程m不断尝试拿资源p并找任务g执行，没有可执行g则睡眠，等待唤醒并重复此过程"，这个执行逻辑加上sysmon系统线程的定时抢占逻辑实际上就是整个宏观的调度逻辑了(其中穿插了很多唤醒m、system goroutine等等复杂的细节)，而找协程任务g的过程占据了其中大部分。g的主要来源有本地队列、全局队列、其他p的本地队列、poller(net和file)，以及一些system goroutine比如timerproc、bgsweeper、gcMarkWorker、runfinq、forcegchelper等。

----


### 调度的整体流程
+ 关于g0栈和g栈
由于m是实际执行体，m的整个代码逻辑基本上就是整个调度逻辑。类似于Linux的内核栈和用户栈，Go的m也有两类栈：一类是系统栈(或者叫调度栈)，主要用于运行runtime的程序逻辑；另一类是g栈，用于运行g的程序逻辑。每个m在创建时会分配一个默认的g叫g0，g0不执行任何代码逻辑，只是用来存放m的调度栈等信息。当要执行Go runtime的一些逻辑比如创建g、新建m等，都会首先切换到g0栈然后执行，而执行g任务时，会切换到g的栈上。在调度栈和g栈上不断切换使整个调度过程复杂了不少。
+ 关于m的spinning自旋
在Go的调度中，m一旦被创建则不会退出。在syscall、cgocall、lockOSThread时，为了防止阻塞其他g的执行，Go会新建或者唤醒m(os线程)执行其他的g，所以可能导致m的增加。如何保证m数量不会太多，同时有足够的线程使p(cpu)不会空闲？主要的手段是通过多路复用和m的spinning。多路复用解决网络和文件io时的阻塞(与net poll类似，Go1.8.1的代码中为os.File加了poll接口)，避免每次读写的系统调用消耗线程。而m的spinning的作用是尽量保证始终有m处于spinning寻找g(并不是执行g，充分利用多cpu)的同时，不会有太多m同时处于spinning(浪费cpu)。不同于一般意义的自旋，m处于自旋是指m的本地队列、全局队列、poller都没有g可运行时，m进入自旋并尝试从其他p偷取(steal)g，每当一个spinning的m获取到g后，会退出spinning并尝试唤醒新的m去spinning。所以，一旦总的spinning的m数量大于0时，就不用唤醒新的m了去spinning浪费cpu了。

下面是整个调度的流程图

+ schedule
![](images/schedule.png)

+ findrunnable
![](images/findrunnable.png)


----


### m的视角看调度

Go中的m大概可分为以下几种:
+ 系统线程，比如sysmon，其运行不需要p
+ lockedm，与某个g绑定，未拿到对应的lockedg时睡眠，等待被唤醒，无法被调度
+ 陷入syscall的m，执行系统调用中，返回时进入调度逻辑
+ cgo的m，cgo的调用实际上使用了lockedm和syscall
+ 正在执行goroutine的m
+ 正在执行调度逻辑的m

什么时候可能需要新建或者唤醒m:
+ 有新的可运行g或者拿到可运行的g
  + goready，将g入队列
  + newproc，新建g并入队列
  + m从schedule拿到g，自身退出spinning
+ 有p资源被释放handoff(p)

m何时交出资源p，并进入睡眠:
+ lockedm主动交出p
+ 处于syscall中，并被sysmon抢占(超过10ms)交出p
+ cgocall被sysmon抢占交出p，或由于lockedm主动交出p
+ findrunnable没找到可运行的g，主动交出p，进入睡眠


----


### g的视角看调度
与goroutine相关的调度逻辑:
+ go(runtime.newproc)产生新的g，放到本地队列或全局队列
+ gopark，g置为waiting状态，等待显示goready唤醒，在poller中用得较多
+ goready，g置为runnable状态，放入全局队列
+ gosched，g显示调用runtime.Gosched或被抢占，置为runnable状态，放入全局队列
+ goexit，g执行完退出，g所属m切换到g0栈，重新进入schedule
+ g陷入syscall
  + net io和部分file io，没有事件则gopark
  + 普通的阻塞系统调用，返回时m重新进入schedule
+ g陷入cgocall
  + lockedm加上syscall的处理逻辑
+ g执行超过10ms被sysmon抢占


