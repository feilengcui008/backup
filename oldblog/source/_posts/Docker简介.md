title: Docker简介
date: 2016-10-08 17:44:02
tags: [Docker, 容器]
categories: [系统, 容器技术]
---

本文主要介绍Docker的一些基本概念、Docker的源码分析、Docker相关的一些issue、Docker周边生态等等。

----


### 基本概念
 
#### Basics
docker大体包括三大部分，runtime(container)、image(graphdriver)、registry，runtime提供环境的隔离与资源的隔离和限制，image提供layer、image、rootfs的管理、registry负责镜像存储与分发。当然，还有其他一些比如data volume, network等等，总体来说还是分为计算、存储与网络。
 
#### computing
+ 接口规范
+ 命名空间隔离、资源隔离与限制的实现
+ 造坑与入坑
 
#### network
+ 接口规范与实现
  + bridge
    + veth pair for two namespace communication
    + bridge and veth pair for multi-namespace communication
    + do not support multi-host
  + overlay
    + docker overlay netowrk: with swarm mode or with kv etcd/zookeeper/consul -> vxlan
    + coreos flannel -> 多种backend，udp/vxlan...
    + ovs
    + weave -> udp and vxlan，与flannel udp不同的是会将多container的packet一块打包
    + [一篇对比](http://xelatex.github.io/2015/11/15/Battlefield-Calico-Flannel-Weave-and-Docker-Overlay-Network/)
      + ![对比图](http://wiki.baidu.com/download/attachments/210695488/%E5%B1%8F%E5%B9%95%E5%BF%AB%E7%85%A7%202016-09-11%2022.28.12.png?version=1&modificationDate=1473604190204&api=v2)
    
  + calico
    + pure layer 3
  + null
    + 与世隔绝
  + host
    + 共享主机net namespace
 
#### storage
+ graphdriver(layers,image and rootfs)
  + graph:独立于各个driver，记录image的各层依赖关系(DAG)，注意是image不包括运行中的container的layer，当container commit生成image后，会将新layer的依赖关系写入
  + device mapper
    + snapshot基于block，allocation-on-demand
    + 默认基于空洞文件(data and metadata)挂载到回环设备
  + aufs
    + diff:实际存储各个layer的变更数据
    + layers:每个layer依赖的layers，包括正在运行中的container
    + mnt:container的实际挂载根目录
  + overlayfs
  + vfs
  + btrfs
  + ...
+ volume
  + driver接口
    + local driver
    + flocker: container和volume管理与迁移
    + rancher的convoy:多重volume存储后端的支持device mapper, NFS, EBS...,提供快照、备份、恢复等功能
  + 数据卷容器
+ registry:与docker registry交互
  + 支持basic/token等认证方式
  + token可以基于basic/oauth等方式从第三方auth server获取bearer token
  + tls通信的支持
+ libkv
  + 支持consul/etcd/zookeeper
+ 分布式存储的支持
 
#### security
+ docker
  + libseccomp限制系统调用(内部使用bpf)
  + linux capabilities限制root用户权限范围scope
  + user namespace用户和组的映射
  + selinux
  + apparmor
  + ...
+ image and registry
 

#### Other Stuffs
 
+ 迁移
  + CRIU: Checkpoint/Restoreuser In User namespace
  + CRAK: Checkpoint/Restart as A Kernel module
 
+ 开放容器标准
  + runtime
    + runc
    + runv
    + rkt(appc)
  + libcontainer and runc
  + containerd
  + docker client and docker daemon
  + [OCI标准和runC原理解读](http://dockone.io/article/776)
  + [Containerd：一个控制runC的守护进程](http://mp.weixin.qq.com/s?__biz=MzA5OTAyNzQ2OA==&mid=401138275&idx=2&sn=3bccc3abec6d9fe4469196623f13d502&scene=21#wechat_redirect)
  + [runC：轻量级容器运行环境](https://mp.weixin.qq.com/s?__biz=MzA5OTAyNzQ2OA==&mid=2649691500&idx=1&sn=c06fd328426d923dc460919e7a674703&chksm=88932a0fbfe4a3192dd3e1e46bd5fcee2aae0f68f97abe078326ae756cda8d2976f92d359dba&scene=1&srcid=0907NkzBbqP6dBqnoMhJ5WUX&key=7b81aac53bd2393d8740c6a91a50d2f8ba7aaee9fc6987a2b9dd39b58aeb47ceac56d3dac9404ebeca4f6f3a0bbb5595&ascene=0&uin=MzgyMzQxOTc1&devicetype=iMac+MacBookPro9%2C2+OSX+OSX+10.11.6+build(15G31))
 

----


### 源码分析

for docker 1.12.*
#### 主要模块
+ docker client
  + DockerCli => 封装客户端的一些配置
  + command => 注册docker client支持的接口
  + docker/engine-api/client/[Types|Client|Request|Transport|Cancellable] => 规范访问dockerd apiserver的接口
+ docker engine daemon
  + DaemonCli
    + apiserver => 接受docker client请求，转发到daemon rpc
    + daemon => 其他功能比如设置docker根目录、inti process、dockerd运行的user namespace等其他信息
      + 包含一个很重要的部分: remote => 通过libcontainerd与containerd的grpc server后端打交道
    + cluster => swarm mode相关
+ containerd
  + containerd => grpc server，提供给dockerd操作容器、进程等的接口，提供containerd、containerd-shim、containerd-ctr工具
+ libcontainer(runc)
  + libcontainer(runc) 提供容器的生命周期相关的接口标准，提供runc工具
+ 基本流程：docker client ==http==> dockerd apiserver ====> remote grpc client(libcontainerd) ==grpc==> containerd ==cmd==> containerd-shim ==cmd==> runc exec/create等 ==cmd==> runc init初始化坑内init进程环境，然后execve替换成容器指定的应用程序  
 
#### 详细分析
客户端部分省略，这里主要介绍docker engine daemon(DaemonCli)、containerd以及libcontainer(runc)三大部分。

+ DaemonCli: 启动docker daemon与containerd daemon的核心对象，包含三大部分，apiserver、Daemon对象和cluster
  + apiserver
    + middleware
    + routers
      + 通用模式
        + 提供backend具体操作的后端接口(实际全在daemon.Daemon实现，而daemon.Daemon会作为所有router的backend)
        + 提供解析请求的routers函数(实际调用backend接口)
        + 注册routers 
      + build => docker build
      + container => container创建启停等
      + image  => 镜像
      + network => 网络
      + plugin => 插件机制
      + swarm  => swarm模式相关
      + volumn => 数据卷
      + system => 系统信息等 
    + 我们可以用nc手动测试apiserver，具体实现的接口可以参考标准文档或者api/server下的源码
      + 执行命令即可看到json输出(还有个python的客户端lib docker-py)
            + echo -e "GET /info HTTP/1.0\r\n" | nc -U /var/run/docker.sock
      + echo -e "GET /images/json HTTP/1.0\r\n" | nc -U /var/run/docker.sock  
  + daemon.Daemon对象
    + daemon除了处理engine daemon需要的通用环境(比如storage driver等)外，还包括registry部分和与containerd交互的grpc接口client(libcontainerd.Client/libcontainerd.Remote相关)。在DaemonCli的初始化过程中会由libcontainerd.New创建libcontainerd.remote，启动containerd daemon(grpc server)并且为docker engine daemon注入containerd/types中规范的与containerd daemon通信的grpc接口client
    + 以docker pause為例，整個調用鏈條為:
      + docker client -> apiserver container router postContainerPause -> daemon.Daemon.ContainerPause(backend) -> backend.containerd.Pause
-> libcontainerd.Client.Pause -> remote.apiClient.UpdateContainer -> containerd.APIClient.UpdateContainer -> grpc.UpdateContainer -> containerd daemon UpdateContainer -> 调用containerd-shim containerid container_path runc -> 调用runc命令 
        + 说明: containerd是一个从docker daemon中抽出来的项目，提供操作runc的界面(包括一个daemon grpc server、一个ctr客户端工具用grpc.APIClient与grpc server通信、以及containerd-shim负责调用runc命令处理容器生命周期)，runc提供的只是一个容器生命周期lib标准和cli工具，而没有daemon。
    + 可以看出，runc(libcontainerd)提供了runtime的lib接口标准，不同os可以实现此接口屏蔽容器的具体实现技术细节；而containerd提供了一个基于libcontainerd接口的server以及cli工具(主要是grpc规范了)；而docker daemon(engine)的apiserver提供的是docker client的restful http接口，会通过containerd的grpc Client标准接口与containerd的server通信。我们可以看到"/var/run/docker/libcontainerd/docker-containerd.sock"和"/var/run/docker.sock"，如上面通过nc与docker daemon直接通信，我们也可以使用grpc client与libcontainerd的daemon直接通信
    + 综上，不难看出docker提供的几个主要二进制文件是干嘛的了...(docker/dockerd/docker-containerd/docker-containerd-shim/docker-containerd-ctr/docker-runc)
      + 用runc直接操作容器: docker-runc list
      + 用docker-containerd-ctr 通过docker-containerd grpc Server操作容器: docker-containerd-ctr --address "unix:///var/run/docker/libcontainerd/docker-containerd.sock" containers list
      + 用docker通过dockerd、docker-containerd操作容器: docker ps 
      + 拆分的好处显而易见：标准化、解耦、新特性的实验、换daemon无需停止容器等等    
  + cluster
    + 這一部分與swarm相关，实际上是把swarmkit集成到了docker engine daemon中
    + 每次启动docker engine daemon时会检查/var/lib/docker/swarm目录下是否有状态文件，如果有则需要恢复集群，重新启动节点；否则，直接返回，不开启swarm mode
    + swarm中的节点有ManagerNode和WorkerNode之分，worker可以被promote成manager，manager也可以被demote回worker。在节点加入集群时可以指定加入的角色是worker还是manager。默认启动一个manager节点
  
+ containerd
  + 容器元数据、提供管理容器生命周期的grpc server以及ctr 客户端工具，具体的容器的操作是通过containerd-shim调用runc命令，每个容器的init进程在容器外部会有对应的containerd-shim进程。
  + 提供了一套任务执行机制，把对容器的生命周期的操作用Task/Worker模型抽象，提供更高的性能
  + 从docker engine daemon拆分，使得engine daemon升级时容器不用stop
  + 简单流程
    + 核心的对象: grpc server、supervisor、worker、task、runtime(處理container和process相關元數據等)等
    + 主routine的grpc apiserver等待grpc请求 -> supervisor server handleTask -> 放入supervisor的tasks chan -> worker从tasks chan中取出执行 -> shim -> runc
+ libcontainer(or runc)
  + 未完待续
 
+ 从containerd到runc到实际的坑内进程起来经过的进程模型(以下起进程都是通过go的cmd)
  + containerd的worker启动containerd-shim进程，传递参数shim containerdid containerpath runtime(其中runtime默认为runc)，并且给runc传递exec/create的行为参数，起好坑。
  + containerd-shim启动runc exec/create进程，等待runc进程的结束，负责容器内的init进程的退出时的清理工作。containerd-shim与containerd daemon进程通信是通过control和exit两个具名管道文件。
  + runc exec/create作为父进程负责创建容器内的init进程，并用管道与init进程通信，这个init进程实际上是执行runc init命令，初始化容器环境，然后等待containerd执行runc start的信号，让用户的进程替换容器中的init，在容器中执行起来。
    + runc init进程负责初始化整个环境，包括清除所有runc exec/create父进程的环境变量，加载docker engine daemon传下来的docker client和docker image中指定的环境变量，设置namespace等等，然后等在管道的child上，等待runc exec/create父进程发送process的json配置文件，runc init坑内进程拿到这个配置文件，初始化所有的坑内环境，然后等待在exec.fifo具名管道文件上，等待runc start发送信号，然后开始execve用用户的程序替换掉runc init。
        

----

### 相关系统

#### Docker和Mesos Container建坑流程和进程模型对比
注: P代表进程, L代表线程

+ Docker
  + containerd的worker启动containerd-shim进程，传递参数shim containerdid containerpath runtime(其中runtime默认为runc)，并且给runc传递exec/create的行为参数，起好坑。
  + containerd-shim启动runc exec/create进程，等待runc进程的结束，负责容器内的init进程的退出时的清理工作。containerd-shim与containerd daemon进程通信是通过control和exit两个具名管道文件。
  + runc exec/create作为父进程负责创建容器内的init进程，并用管道与init进程通信，这个init进程实际上是执行runc init命令，初始化容器环境，然后等待containerd执行runc start的信号，让用户的进程替换容器中的init，在容器中执行起来。
    + runc init进程负责初始化整个环境，包括清除所有runc exec/create父进程的环境变量，加载docker engine daemon传下来的docker client和docker image中指定的环境变量，设置namespace等等，然后等在管道的child上，等待runc exec/create父进程发送process的json配置文件，runc init坑内进程拿到这个配置文件，初始化所有的坑内环境，然后等待在exec.fifo具名管道文件上，等待runc start发送信号，然后开始execve用用户的程序替换掉runc init。

+ Mesos Native Linux Container
  + 基本模型
    + 与docker containerd的主进程和matrix-agent的ContainerManager主线程类似，executor(mesos默认提供Command、Container两种executor)起一进程负责维护containers list的内存状态，并且fork&exec执行容器的启动
  + 建坑流程
    + Creates a “freezer” cgroup for the container.
    + Creates posix “pipe” to enable communication between host (parent process) and container process.
    + Spawn child process(container process) using clone system call.
    + Moves the new container process to the freezer hierarchy.
    + Signals the child process to continue (exec’ing) by writing a character to the write end of the pipe in the parent process.
