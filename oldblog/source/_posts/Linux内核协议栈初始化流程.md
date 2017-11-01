title: Linux内核协议栈初始化流程
date: 2015-10-31 10:35:43
categories: [系统]
tags: [Linux内核, 协议栈]
---

本文主要针对Linux-3.19.3版本的内核简单分析内核协议栈初始化涉及到的关键步骤和主要函数。

----

1.准备

- Linux内核协议栈本身构建在虚拟文件系统之上，所以对Linux VFS不太了解的可以参考内核源码根目录下Documentation/filesystems/vfs.txt，另外，socket接口层，协议层，设备层的许多数据结构涉及到内存管理，所以对基本虚拟内存管理，slab缓存，页高速缓存不太了解的也可以查阅相关文档。

- 源码涉及的主要文件位于net/socket.c，net/core，include/linux/net*

----

2.开始

开始分析前，这里有些小技巧可以快速定位到主要的初始化函数，在分析其他子系统源码时也可以采用这个技巧

```
grep _initcall socket.c
find ./core/ -name "*.c" |xargs cat | grep _initcall
grep net_inuse_init tags
```
![这里写图片描述](http://img.blog.csdn.net/20151030132956270)
![这里写图片描述](http://img.blog.csdn.net/20151030140301037)

这里*__initcall宏是设置初始化函数位于内核代码段.initcall#id.init的位置其中id代表优先级level，小的一般初始化靠前，定义在include/linux/init.h，使用gcc的attribute扩展。而各个level的初始化函数的调用流程基本如下：

```
start_kernel -> rest_init -> kernel_init内核线程 -> kernel_init_freeable -> do_basic_setup -> do_initcalls -> do_initcall_level -> do_one_initcall -> *(initcall_t)
```

![这里写图片描述](http://img.blog.csdn.net/20151030133735173)


----

3.详细分析

- 可以看到pure_initcall(net_ns_init)位于0的初始化level，基本不依赖其他的初始化子系统，所以从这个开始

```
//core/net_namespace.c
//基本上这个函数主要的作用是初始化net结构init_net的一些数据，比如namespace相关，并且调用注册的pernet operations的init钩子针对net进行各自需求的初始化
pure_initcall(net_ns_init);
```

```
static int __init net_ns_init(void)
{
	struct net_generic *ng;
	//net namespace相关
#ifdef CONFIG_NET_NS
	//分配slab缓存
	net_cachep = kmem_cache_create("net_namespace", sizeof(struct net),SMP_CACHE_BYTES,SLAB_PANIC, NULL);

	/* Create workqueue for cleanup */
	netns_wq = create_singlethread_workqueue("netns");
	if (!netns_wq)
		panic("Could not create netns workq");
#endif
	ng = net_alloc_generic();
	if (!ng)
		panic("Could not allocate generic netns");

	rcu_assign_pointer(init_net.gen, ng);
	mutex_lock(&net_mutex);
    //初始化net namespace相关的对象, 传入初始的namespace init_user_ns
    //设置net结构的初始namespace
    //对每个pernet_list中注册的pernet operation，调用其初始化net中的对应数据对象
	if (setup_net(&init_net, &init_user_ns))
		panic("Could not setup the initial network namespace");

	rtnl_lock();
    //加入初始net结构的list中
	list_add_tail_rcu(&init_net.list, &net_namespace_list);
	rtnl_unlock();
	mutex_unlock(&net_mutex);
    //加入pernet_list链表，并且调用pernet operation的init函数初始化net 
	register_pernet_subsys(&net_ns_ops);
	return 0;
}
```

- 下面分析core_init(sock_init)：

```
//socket.c
//在.initcall1.init代码段注册，以便内核启动时do_initcalls中调用
//从而注册socket filesystem 
core_initcall(sock_init);	/* early initcall */
```

进入core_init(sock_init):

```
static int __init sock_init(void)
{
	int err;
    //sysctl 支持
	err = net_sysctl_init();
	if (err)
		goto out;
		
    //初始化skbuff_head_cache 和 skbuff_clone_cache的slab缓存区
	skb_init();
	
    //与vfs挂接，为sock inode分配slab缓存
	init_inodecache();

    //注册socket 文件系统
	err = register_filesystem(&sock_fs_type);
	if (err)
		goto out_fs;
		
    //通过kern_mount内核层接口调用mount系统调用，最终调用
    //fs_type->mount 而socket filesystem 使用mount_pesudo伪挂载
	sock_mnt = kern_mount(&sock_fs_type);
	if (IS_ERR(sock_mnt)) {
		err = PTR_ERR(sock_mnt);
		goto out_mount;
	}

    //协议与设备相关的数据结构等初始化在后续的各子模块subsys_init操作中
	/* The real protocol initialization is performed in later initcalls.
	 */

    //netfilter初始化 
#ifdef CONFIG_NETFILTER
	err = netfilter_init();
	if (err)
		goto out;
#endif
/*省略部分*/
}
```

- core_init(net_inuse_init)

```
//core/sock.c
//主要功能是为net分配inuse的percpu标识
core_initcall(net_inuse_init);
```

```
static int __net_init sock_inuse_init_net(struct net *net)
{
	net->core.inuse = alloc_percpu(struct prot_inuse);
	return net->core.inuse ? 0 : -ENOMEM;
}
static void __net_exit sock_inuse_exit_net(struct net *net)
{
	free_percpu(net->core.inuse);
}
static struct pernet_operations net_inuse_ops = {
	.init = sock_inuse_init_net,
	.exit = sock_inuse_exit_net,
};
static __init int net_inuse_init(void)
{
	if (register_pernet_subsys(&net_inuse_ops))
		panic("Cannot initialize net inuse counters");
	return 0;
}
```

- core_init(netpoll_init)

```
//core/netpoll.c
//主要功能就是把预留的sk_buffer poll初始化成队列
core_initcall(netpoll_init);
```

```
static int __init netpoll_init(void)
{
	skb_queue_head_init(&skb_pool);
	return 0;
}
```
![这里写图片描述](http://img.blog.csdn.net/20151030144217746)

- subsys_initcall(proto_init)

```
//core/sock.c
//涉及的操作主要是在/proc/net域下建立protocols文件,注册相关文件操作函数
subsys_initcall(proto_init);
```

```
// /proc/net/protocols支持的文件操作 
static const struct file_operations proto_seq_fops = {
	.owner		= THIS_MODULE,
	.open		= proto_seq_open, //打开
	.read		= seq_read, //读
	.llseek		= seq_lseek,//seek
	.release	= seq_release_net,
};
static __net_init int proto_init_net(struct net *net)
{
    //创建/proc/net/protocols
	if (!proc_create("protocols", S_IRUGO, net->proc_net, &proto_seq_fops))
		return -ENOMEM;
	return 0;
}
static __net_exit void proto_exit_net(struct net *net)
{
	remove_proc_entry("protocols", net->proc_net);
}
static __net_initdata struct pernet_operations proto_net_ops = {
	.init = proto_init_net,
	.exit = proto_exit_net,
};
//注册 pernet_operations, 并用.init钩子初始化net，此处即创建proc相关文件
static int __init proto_init(void)
{
	return register_pernet_subsys(&proto_net_ops);
}
```

- subsys_initcall(net_dev_init)

```
//core/dev.c 
//基本上是建立net device在/proc,/sys相关的数据结构，并且开启网卡收发中断
//初始化net device
static int __init net_dev_init(void)
{
	int i, rc = -ENOMEM;
	BUG_ON(!dev_boot_phase);
    //主要也是在/proc/net/下建立相应的属性文件，如dev网卡信息文件
	if (dev_proc_init())
		goto out;
    //注册/sys文件系统，添加相关属性项
    //注册网络内核对象namespace相关的一些操作
    //注册net interface(dev)到 /sys/class/net 
	if (netdev_kobject_init())
		goto out;
	INIT_LIST_HEAD(&ptype_all);
	for (i = 0; i < PTYPE_HASH_SIZE; i++)
		INIT_LIST_HEAD(&ptype_base[i]);
	INIT_LIST_HEAD(&offload_base);
    //注册并调用针对每个net的设备初始化操作
	if (register_pernet_subsys(&netdev_net_ops))
		goto out;
    //对每个cpu，初始化数据包处理相关队列
	for_each_possible_cpu(i) {
		struct softnet_data *sd = &per_cpu(softnet_data, i);
        //入
		skb_queue_head_init(&sd->input_pkt_queue);
        skb_queue_head_init(&sd->process_queue);
		INIT_LIST_HEAD(&sd->poll_list);
		//出
        sd->output_queue_tailp = &sd->output_queue;
#ifdef CONFIG_RPS
		sd->csd.func = rps_trigger_softirq;
		sd->csd.info = sd;
		sd->cpu = i;
#endif
		sd->backlog.poll = process_backlog;
		sd->backlog.weight = weight_p;
	}
    //只在boot phase调用一次, 防止重复调用
	dev_boot_phase = 0;

	/* The loopback device is special if any other network devices
	 * is present in a network namespace the loopback device must
	 * be present. Since we now dynamically allocate and free the
	 * loopback device ensure this invariant is maintained by
	 * keeping the loopback device as the first device on the
	 * list of network devices.  Ensuring the loopback devices
	 * is the first device that appears and the last network device
	 * that disappears.
	 */
    //回环设备的建立与初始化
	if (register_pernet_device(&loopback_net_ops))
		goto out;

    //退出的通用操作
	if (register_pernet_device(&default_device_ops))
		goto out;

    //开启收发队列的中断
	open_softirq(NET_TX_SOFTIRQ, net_tx_action);
	open_softirq(NET_RX_SOFTIRQ, net_rx_action);

	hotcpu_notifier(dev_cpu_callback, 0);
    //destination cache related?
	dst_init();
	rc = 0;
out:
	return rc;
}
```

- fs_initcall(sysctl_core_init)

```
//core/sysctl_net_core.c
//主要是建立sysctl中与net相关的一些配置参数（见下图）
static __init int sysctl_core_init(void)
{
	register_net_sysctl(&init_net, "net/core", net_core_table);
	return register_pernet_subsys(&sysctl_core_ops);
}

static __net_init int sysctl_core_net_init(struct net *net)
{
	struct ctl_table *tbl;
	net->core.sysctl_somaxconn = SOMAXCONN;
	tbl = netns_core_table;
	if (!net_eq(net, &init_net)) {
		tbl = kmemdup(tbl, sizeof(netns_core_table), GFP_KERNEL);
		if (tbl == NULL)
			goto err_dup;
		tbl[0].data = &net->core.sysctl_somaxconn;
		if (net->user_ns != &init_user_ns) {
			tbl[0].procname = NULL;
		}
	}
	net->core.sysctl_hdr = register_net_sysctl(net, "net/core", tbl);
	if (net->core.sysctl_hdr == NULL)
		goto err_reg;
	return 0;
err_reg:
	if (tbl != netns_core_table)
		kfree(tbl);
err_dup:
	return -ENOMEM;
}
static __net_exit void sysctl_core_net_exit(struct net *net)
{
	struct ctl_table *tbl;
	tbl = net->core.sysctl_hdr->ctl_table_arg;
	unregister_net_sysctl_table(net->core.sysctl_hdr);
	BUG_ON(tbl == netns_core_table);
	kfree(tbl);
}
static __net_initdata struct pernet_operations sysctl_core_ops = {
	.init = sysctl_core_net_init,
	.exit = sysctl_core_net_exit,
};

```
![这里写图片描述](http://img.blog.csdn.net/20151030152109181)


----

4.总结
本文主要按照关于内核协议栈的各个子系统的*_initcall的调用顺序分析了几个核心的初始化步骤，包括socket层，协议层，设备层等，整个初始化过程还是比较简单的，主要涉及一些数据结构和缓存等的初始化，但是整个内核协议栈的对数据包的处理流程并不能很好地呈现，后续有机会再分析从系统调用开始整个数据包的收发流程。


> ref: Linux 3.19.3 source tree
