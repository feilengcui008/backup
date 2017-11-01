title: Linux内核协议栈socket接口层
date: 2015-10-31 12:57:00
categories: [系统]
tags: [Linux内核, 协议栈]
---

本文接上一篇[Linux内核协议栈-初始化流程分析](http://blog.csdn.net/feilengcui008/article/details/49509993)，在上一篇中主要分析了了Linux内核协议栈涉及到的关键初始化函数，在这一篇文章中将分析协议栈的BSD socket和到传输层的流程。

----

1.准备
协议的基本分层：
(A代表socket的某个系统调用)
BSD socket system calls A => proto_ops->A  => sock->A => tcp_prot => A

- BSD socket层和具体协议族某个类型的联系是通过struct proto_ops，在include/linux/net.h中定义了不同协议族如af_inet，af_unix等的通用操作函数指针的结构体struct proto_ops，具体的定义有各个协议族的某个类型的子模块自己完成。比如ipv4/af_inet.c中定义的af_inet family的tcp/udp等相应的struct proto_ops。
- 由于对于每个family的不同类型，其针对socket的某些需求可能不同，所以抽了一层struct sock出来，sock->sk_prot挂接到具体tcp/udp等传输层的struct proto上(具体定义在ipv4/tcp_ipv4.c,ipv4/udp.c)
- 另外，由于内容比较多，这一篇主要分析socket，bind，listen，accept几个系统调用，下一篇会涉及connect，send，recv等的分析


```
//不同协议族的通用函数hooks
//比如af_inet相关的定义在ipv4/af_inet.c中
//除了创建socket为系统调用外，基本针对socket层的操作函数都在这里面
struct proto_ops {
	int		family;
	struct module	*owner;
	int		(*release)   (struct socket *sock);
	int		(*bind)	     (struct socket *sock,
				      struct sockaddr *myaddr,
				      int sockaddr_len);
	int		(*connect)   (struct socket *sock,
				      struct sockaddr *vaddr,
				      int sockaddr_len, int flags);
	int		(*socketpair)(struct socket *sock1,
				      struct socket *sock2);
	int		(*accept)    (struct socket *sock,
				      struct socket *newsock, int flags);
	int		(*getname)   (struct socket *sock,
				      struct sockaddr *addr,
				      int *sockaddr_len, int peer);
	unsigned int	(*poll)	     (struct file *file, struct socket *sock,
				      struct poll_table_struct *wait);
	int		(*ioctl)     (struct socket *sock, unsigned int cmd,
				      unsigned long arg);
#ifdef CONFIG_COMPAT
	int	 	(*compat_ioctl) (struct socket *sock, unsigned int cmd,
				      unsigned long arg);
#endif
	int		(*listen)    (struct socket *sock, int len);
	int		(*shutdown)  (struct socket *sock, int flags);
	int		(*setsockopt)(struct socket *sock, int level,
				      int optname, char __user *optval, unsigned int optlen);
/*省略部分*/
};
```

```
//传输层的proto 
//作为sock->sk_prot与具体传输层的hooks
struct proto {
	void			(*close)(struct sock *sk,
					long timeout);
	int			(*connect)(struct sock *sk,
					struct sockaddr *uaddr,
					int addr_len);
	int			(*disconnect)(struct sock *sk, int flags);

	struct sock *		(*accept)(struct sock *sk, int flags, int *err);

	int			(*ioctl)(struct sock *sk, int cmd,
					 unsigned long arg);
	int			(*init)(struct sock *sk);
	void			(*destroy)(struct sock *sk);
	void			(*shutdown)(struct sock *sk, int how);
	int			(*setsockopt)(struct sock *sk, int level,
					int optname, char __user *optval,
					unsigned int optlen);
	int			(*getsockopt)(struct sock *sk, int level,
					int optname, char __user *optval,
					int __user *option);
#ifdef CONFIG_COMPAT
	int			(*compat_setsockopt)(struct sock *sk,
					int level,
					int optname, char __user *optval,
					unsigned int optlen);
	int			(*compat_getsockopt)(struct sock *sk,
					int level,
					int optname, char __user *optval,
					int __user *option);
	int			(*compat_ioctl)(struct sock *sk,
					unsigned int cmd, unsigned long arg);
#endif
	int			(*sendmsg)(struct kiocb *iocb, struct sock *sk,
					   struct msghdr *msg, size_t len);
	int			(*recvmsg)(struct kiocb *iocb, struct sock *sk,
					   struct msghdr *msg,
					   size_t len, int noblock, int flags,
					   int *addr_len);
	int			(*sendpage)(struct sock *sk, struct page *page,
					int offset, size_t size, int flags);
	int			(*bind)(struct sock *sk,
					struct sockaddr *uaddr, int addr_len);

	/*省略部分*/
};

```

同时附上其他几个关键结构体：

```
//bsd socket层
//include/linux/net.h
struct socket {
	socket_state		state;
	kmemcheck_bitfield_begin(type);
	short			type;
	kmemcheck_bitfield_end(type);
	unsigned long		flags;
	struct socket_wq __rcu	*wq;
	struct file		*file;
	struct sock		*sk;
	const struct proto_ops	*ops;
};
```

```
//sock层
struct sock {
 sock_common	__sk_common;
#define sk_node			__sk_common.skc_node
#define sk_nulls_node		__sk_common.skc_nulls_node
#define sk_refcnt		__sk_common.skc_refcnt
#define sk_tx_queue_mapping	__sk_common.skc_tx_queue_mapping
#define sk_dontcopy_begin	__sk_common.skc_dontcopy_begin
#define sk_dontcopy_end		__sk_common.skc_dontcopy_end
#define sk_hash			__sk_common.skc_hash
#define sk_portpair		__sk_common.skc_portpair
#define sk_num			__sk_common.skc_num
#define sk_dport		__sk_common.skc_dport
#define sk_addrpair		__sk_common.skc_addrpair
#define sk_daddr		__sk_common.skc_daddr
#define sk_rcv_saddr		__sk_common.skc_rcv_saddr
#define sk_family		__sk_common.skc_family
#define sk_state		__sk_common.skc_state
#define sk_reuse		__sk_common.skc_reuse
#define sk_reuseport		__sk_common.skc_reuseport
#define sk_ipv6only		__sk_common.skc_ipv6only
#define sk_bound_dev_if		__sk_common.skc_bound_dev_if
#define sk_bind_node		__sk_common.skc_bind_node
#define sk_prot			__sk_common.skc_prot
#define sk_net			__sk_common.skc_net
#define sk_v6_daddr		__sk_common.skc_v6_daddr
#define sk_v6_rcv_saddr	__sk_common.skc_v6_rcv_saddr

	unsigned long 		sk_flags;
	struct dst_entry	*sk_rx_dst;
	struct dst_entry __rcu	*sk_dst_cache;
	spinlock_t		sk_dst_lock;
	atomic_t		sk_wmem_alloc;
	atomic_t		sk_omem_alloc;
	int			sk_sndbuf;
	struct sk_buff_head	sk_write_queue;
	/*省略部分*/
	struct pid		*sk_peer_pid;
	const struct cred	*sk_peer_cred;
	long			sk_rcvtimeo;
	long			sk_sndtimeo;
	void			*sk_protinfo;
	struct timer_list	sk_timer;
	ktime_t			sk_stamp;
	u16			sk_tsflags;
	u32			sk_tskey;
	struct socket		*sk_socket;
	void			*sk_user_data;
	struct page_frag	sk_frag;
	struct sk_buff		*sk_send_head;
	/*省略部分*/
};
```

----

2.开始
主要追溯几个典型的socket相关的系统调用，如socket,bind,listen,accept等等

- socket

```
//创建socket的系统调用
SYSCALL_DEFINE3(socket, int, family, int, type, int, protocol)
{
	int retval;
	struct socket *sock;
	int flags;

	/* Check the SOCK_* constants for consistency.  */
	BUILD_BUG_ON(SOCK_CLOEXEC != O_CLOEXEC);
	BUILD_BUG_ON((SOCK_MAX | SOCK_TYPE_MASK) != SOCK_TYPE_MASK);
	BUILD_BUG_ON(SOCK_CLOEXEC & SOCK_TYPE_MASK);
	BUILD_BUG_ON(SOCK_NONBLOCK & SOCK_TYPE_MASK);

	flags = type & ~SOCK_TYPE_MASK;
	if (flags & ~(SOCK_CLOEXEC | SOCK_NONBLOCK))
		return -EINVAL;
	type &= SOCK_TYPE_MASK;

	if (SOCK_NONBLOCK != O_NONBLOCK && (flags & SOCK_NONBLOCK))
		flags = (flags & ~SOCK_NONBLOCK) | O_NONBLOCK;

    //分配inode，返回inode中的一个成员作为sock
	retval = sock_create(family, type, protocol, &sock);
	if (retval < 0)
		goto out;

    //找个fd映射sock
    //得到空fd
    //分配伪dentry和file，并将socket file的operations与file挂接 
	retval = sock_map_fd(sock, flags & (O_CLOEXEC | O_NONBLOCK));
/*省略部分*/
}
```

- socketpair

```
//创建socketpair，注意af_inet协议族下没有pair，af_unix下有
SYSCALL_DEFINE4(socketpair, int, family, int, type, int, protocol,
		int __user *, usockvec)
{
	struct socket *sock1, *sock2;
	int fd1, fd2, err;
	struct file *newfile1, *newfile2;
	int flags;

	flags = type & ~SOCK_TYPE_MASK;
	if (flags & ~(SOCK_CLOEXEC | SOCK_NONBLOCK))
		return -EINVAL;
	type &= SOCK_TYPE_MASK;

	if (SOCK_NONBLOCK != O_NONBLOCK && (flags & SOCK_NONBLOCK))
		flags = (flags & ~SOCK_NONBLOCK) | O_NONBLOCK;

    //创建socket1 
	err = sock_create(family, type, protocol, &sock1);
	if (err < 0)
		goto out;

    //创建socket2
	err = sock_create(family, type, protocol, &sock2);
	if (err < 0)
		goto out_release_1;

    //调用socket operations的socketpair 
    //关于不同协议层的函数hook，公共结构体是struct proto_ops 
    //对于不同的family，比如af_inet协议族的定义在ipv4/af_inet.c
    //
    //对于af_inet没有socketpair 
    //对于af_unix有socketpair
	err = sock1->ops->socketpair(sock1, sock2);
	if (err < 0)
		goto out_release_both;

    //后面部分就很类似了，找到空fd，分配file，绑定到socket，将file
    安装到当前进程
	fd1 = get_unused_fd_flags(flags);
	if (unlikely(fd1 < 0)) {
		err = fd1;
		goto out_release_both;
	}

	fd2 = get_unused_fd_flags(flags);
	if (unlikely(fd2 < 0)) {
		err = fd2;
		goto out_put_unused_1;
	}

	newfile1 = sock_alloc_file(sock1, flags, NULL);
	if (unlikely(IS_ERR(newfile1))) {
		err = PTR_ERR(newfile1);
		goto out_put_unused_both;
	}

	newfile2 = sock_alloc_file(sock2, flags, NULL);
	if (IS_ERR(newfile2)) {
		err = PTR_ERR(newfile2);
		goto out_fput_1;
	}

	err = put_user(fd1, &usockvec[0]);
	if (err)
		goto out_fput_both;

	err = put_user(fd2, &usockvec[1]);
	if (err)
		goto out_fput_both;

	audit_fd_pair(fd1, fd2);

	fd_install(fd1, newfile1);
	fd_install(fd2, newfile2);
	/* fd1 and fd2 may be already another descriptors.
	 * Not kernel problem.
	 */
	return 0;
```

- bind 

```
SYSCALL_DEFINE3(bind, int, fd, struct sockaddr __user *, umyaddr, int, addrlen)
{
	struct socket *sock;
	struct sockaddr_storage address;
	int err, fput_needed;
    //根据fd查找file，进而查找socket指针sock
	sock = sockfd_lookup_light(fd, &err, &fput_needed);
	if (sock) {
        //把用户态地址数据移到内核态
        //调用copy_from_user 
		err = move_addr_to_kernel(umyaddr, addrlen, &address);
		if (err >= 0) {
            //security hook
			err = security_socket_bind(sock,
						   (struct sockaddr *)&address,
						   addrlen);
			if (!err)
                //ok, 到具体family定义的proto_ops中的bind 
                //比如对af_inet,主要是设置socket->sock->inet_sock的一些参数，比如接收地址，端口什么的
				err = sock->ops->bind(sock,
						      (struct sockaddr *)
						      &address, addrlen);
		}
		fput_light(sock->file, fput_needed);
	}
	return err;
}
```

- listen
listen所做的事情也比较简单，从系统调用的listen(fd, backlog)到proto_ops 的inet_listen与前面类似，这里分析下inet_listen中的核心函数inet_csk_listen_start(位于ipv4/inet_connection_sock.c中)。

```
int inet_csk_listen_start(struct sock *sk, const int nr_table_entries)
{
    //获得网络层inte_sock 
	struct inet_sock *inet = inet_sk(sk);
	//管理request connection的结构体  
    struct inet_connection_sock *icsk = inet_csk(sk);
    //分配backlog个长度的accpet_queue的结构连接请求的队列
	int rc = reqsk_queue_alloc(&icsk->icsk_accept_queue, nr_table_entries);

	if (rc != 0)
		return rc;

	sk->sk_max_ack_backlog = 0;
	sk->sk_ack_backlog = 0;
	inet_csk_delack_init(sk);

	/* There is race window here: we announce ourselves listening,
	 * but this transition is still not validated by get_port().
	 * It is OK, because this socket enters to hash table only
	 * after validation is complete.
	 */
    //切换状态到listening 
	sk->sk_state = TCP_LISTEN;
	if (!sk->sk_prot->get_port(sk, inet->inet_num)) {
		inet->inet_sport = htons(inet->inet_num);
        //更新dst_entry表
		sk_dst_reset(sk);
		sk->sk_prot->hash(sk);

		return 0;
	}
	sk->sk_state = TCP_CLOSE;
	__reqsk_queue_destroy(&icsk->icsk_accept_queue);
	return -EADDRINUSE;
}
```

- accept 
上面socket, socketpair, bind基本只涉及到BSD socket, sock层相关的，过程比较简单，而accept层在sock层和tcp层交互稍微复杂，下面详细分析

```
//socket.c
//accept系统调用
SYSCALL_DEFINE4(accept4, int, fd, struct sockaddr __user *, upeer_sockaddr,
		int __user *, upeer_addrlen, int, flags)
{
	/*省略部分*/
	err = -ENFILE;
    //for client socket 
	newsock = sock_alloc();
	if (!newsock)
		goto out_put;

	newsock->type = sock->type;
	newsock->ops = sock->ops;

	/*
	 * We don't need try_module_get here, as the listening socket (sock)
	 * has the protocol module (sock->ops->owner) held.
	 */
	__module_get(newsock->ops->owner);

	//得到当前进程空fd，分给newsock file
	newfd = get_unused_fd_flags(flags);
	if (unlikely(newfd < 0)) {
		err = newfd;
		sock_release(newsock);
		goto out_put;
	}
	//从flab分配空file结构
	newfile = sock_alloc_file(newsock, flags, sock->sk->sk_prot_creator->name);
	if (unlikely(IS_ERR(newfile))) {
		err = PTR_ERR(newfile);
		put_unused_fd(newfd);
		sock_release(newsock);
		goto out_put;
	}

	err = security_socket_accept(sock, newsock);
	if (err)
		goto out_fd;

    //proto_ops中的accept 
    //accept从系统调用到具体协议族的某个type的struct proto_ops的accept如af_inet tcp的的accept，再到sock层的accept，然后sock层的accept实际上对应的是具体传输层的struct proto中的accpet，如tcp/udp的struct proto tcp_prot/udp_prot，然后放入newsock 
	err = sock->ops->accept(sock, newsock, sock->file->f_flags);
	if (err < 0)
		goto out_fd;

	if (upeer_sockaddr) {
		if (newsock->ops->getname(newsock, (struct sockaddr *)&address,
					  &len, 2) < 0) {
			err = -ECONNABORTED;
			goto out_fd;
		}
        //拷贝client socket addr storage到userspace
		err = move_addr_to_user(&address,
					len, upeer_sockaddr, upeer_addrlen);
		if (err < 0)
			goto out_fd;
	}
	fd_install(newfd, newfile);
	err = newfd;
	/*省略部分*/

}
```

```
//ipv4/af_inet.c
//inet family的tcp相关的proto_ops
int inet_accept(struct socket *sock, struct socket *newsock, int flags)
{
	struct sock *sk1 = sock->sk;
	int err = -EINVAL;
    //进入(网络)sock层，accept新sock 
	struct sock *sk2 = sk1->sk_prot->accept(sk1, flags, &err);
	if (!sk2)
		goto do_err;

	//锁住sock，因为需要操作sock内的request_socket请求队列头
	wait_queue_head_t等数据
	lock_sock(sk2);
	sock_rps_record_flow(sk2);
	WARN_ON(!((1 << sk2->sk_state) &
		  (TCPF_ESTABLISHED | TCPF_SYN_RECV |
		  TCPF_CLOSE_WAIT | TCPF_CLOSE)));
	sock_graft(sk2, newsock);
    //设置client socket状态 
	newsock->state = SS_CONNECTED;
	err = 0;
	release_sock(sk2);
do_err:
	return err;
}
```

```
//ipv4/tcp_ipv4.c
//这里进入struct proto tcp_prot中的accept
struct sock *inet_csk_accept(struct sock *sk, int flags, int *err)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
    //icsk : inet_connection_sock 面向连接的客户端连接处理相关的信息
	//接收队列
	struct request_sock_queue *queue = &icsk->icsk_accept_queue;
	struct sock *newsk;
	struct request_sock *req;
	int error;
    //lock sock
	lock_sock(sk);
    //如果不是ACCPET状态转换过来，出错
	error = -EINVAL;
	if (sk->sk_state != TCP_LISTEN)
		goto out_err;

    //如果request_sock队列是空的， 利用等待队列挂起当前进程到等待队列，并且将等待队列放入sock中的请求队列头
	if (reqsk_queue_empty(queue)) { 
        //如果非阻塞，0，否则为sk的接收时间
		long timeo = sock_rcvtimeo(sk, flags & O_NONBLOCK);
		error = -EAGAIN;
		if (!timeo)   //如果非阻塞而且接收队列是空，直接返回-EAGAIN
			goto out_err;
        //阻塞情况下，等待timeo时间的超时
        //利用了等待队列，下面会详细注解 
		error = inet_csk_wait_for_connect(sk, timeo);
		if (error)
			goto out_err;
	}
    //不是空，移出一个连接请求 
	req = reqsk_queue_remove(queue);
    //连接请求的sock
	newsk = req->sk;
    //减少backlog 
	sk_acceptq_removed(sk);
    //fastopenq?
	if (sk->sk_protocol == IPPROTO_TCP && queue->fastopenq != NULL) {
		spin_lock_bh(&queue->fastopenq->lock);
		if (tcp_rsk(req)->listener) {
			/* We are still waiting for the final ACK from 3WHS
			 * so can't free req now. Instead, we set req->sk to
			 * NULL to signify that the child socket is taken
			 * so reqsk_fastopen_remove() will free the req
			 * when 3WHS finishes (or is aborted).
			 */
			req->sk = NULL;
			req = NULL;
		}
		spin_unlock_bh(&queue->fastopenq->lock);
	}
    //ok,清理，返回newsk
	/*省略部分*/
```

```
//ipv4/inet_connection_sock.c
//accept连接请求的核心函数
static int inet_csk_wait_for_connect(struct sock *sk, long timeo)
{
	struct inet_connection_sock *icsk = inet_csk(sk);
    //定义一个等待队列wait_queue_t wait 进程是当前进程
	DEFINE_WAIT(wait);
	int err;
	for (;;) {
        //sk_leep(sk) : sock的wait_queue_head_t
        //wait : wait_queue_t
        //这里将current进程的wait_queue_t加入sk的wait_queue_head_t中，spin锁定 
        //wait_queue_head_t，设置current状态，然后spin解锁时可能重新schedule 
		prepare_to_wait_exclusive(sk_sleep(sk), &wait,
					  TASK_INTERRUPTIBLE);

        //被唤醒，解锁sock 
		release_sock(sk);
        //如果请求队列为空,说明timeout了
		if (reqsk_queue_empty(&icsk->icsk_accept_queue))
            //schedule timeout
			timeo = schedule_timeout(timeo);

        //再锁住进行下次循环，准备再次进入TASK_INTERRUPTIBLE
		lock_sock(sk);
		err = 0;

        //检查是否有连接到达, 如果有，break,唤醒等待队列 
		if (!reqsk_queue_empty(&icsk->icsk_accept_queue))
			break;
		err = -EINVAL;
        //如果不是listening 状态转过来的, 除错-EINVAL  
		if (sk->sk_state != TCP_LISTEN)
			break;

        //检查interrupt错误
		err = sock_intr_errno(timeo);

        //如果当前进程收到信号了，break 
		if (signal_pending(current))
			break;

        //如果传入的timeo为0，则回到nonblock的状态, break 
		err = -EAGAIN;
		if (!timeo)
			break;
	}

    //ok, 有连接到达，设置state为running, 唤醒wait queue的第一个进程，移除wait_queue_t和wait_queue_head_t 
	finish_wait(sk_sleep(sk), &wait);
	return err;
}
```




