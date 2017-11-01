title: Linux内核namespace
date: 2016-06-10 19:27:52
tags: [容器, namespace]
categories: [系统]
---

### 1. 介绍
Namespace是Linux内核为容器技术提供的基础设施之一(另一个是cgroups)，包括uts/user/pid/mnt/ipc/net六个(3.13.0的内核)，主要用来做资源的隔离，本质上是全局资源的映射，映射之间独立了自然隔离了。主要涉及到的接口是:

+ clone
+ setns
+ unshare
+ /proc/pid/ns, /proc/pid/uid_map, /proc/pid/gid_map等

后面会简单分析一下内核源码里面是怎么实现这几个namespace的，并以几个简单系统调用为例，看看namespace是怎么产生影响的，最后简单分析下setns和unshare的实现。

----

### 2. 测试流程及代码

下面是一些简单的例子，主要测试uts/pid/user/mnt四个namespace的效果，测试代码主要用到三个进程，一个是clone系统调用执行/bin/bash后的进程，也是生成新的子namespace的初始进程，然后是打开/proc/pid/ns下的namespace链接文件，用setns将第二个可执行文件的进程加入/bin/bash的进程的namespace(容器)，并让其fork出一个子进程，测试pid namespace的差异。值得注意的几个点:

+ 不同版本的内核setns和unshare对namespace的支持不一样，较老的内核可能只支持ipc/net/uts三个namespace
+ 某个进程创建后其pid namespace就固定了，使用setns和unshare改变后，其本身的pid namespace不会改变，只有fork出的子进程的pid namespace改变(改变的是每个进程的nsproxy->pid_namespace_for_children) 
+ 用setns添加mnt namespace应该放在其他namespace之后，否则可能出现无法打开/proc/pid/ns/...的错误

```
// 代码1: 开一些新的namespace(启动新容器)
#define _GNU_SOURCE
#include <sys/wait.h>
#include <sched.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define errExit(msg)  do { perror(msg); exit(EXIT_FAILURE); \
} while (0)

/* Start function for cloned child */
static int childFunc(void *arg)
{
  const char *binary = "/bin/bash";
  char *const argv[] = {
    "/bin/bash",
    NULL
  };
  char *const envp[] = { NULL };

  /* wrappers for execve */
  // has const char * as argument list
  // execl 
  // execle  => has envp
  // execlp  => need search PATH 
  
  // has char *const arr[] as argument list 
  // execv 
  // execvpe => need search PATH and has envp
  // execvp  => need search PATH 
  
  //int ret = execve(binary, argv, envp);
  int ret = execv(binary, argv);
  if (ret < 0) {
    errExit("execve error");
  }
  return ret;
}

#define STACK_SIZE (1024 * 1024)    /* Stack size for cloned child */

int main(int argc, char *argv[])
{
  char *stack; 
  char *stackTop;                 
  pid_t pid;
  stack = malloc(STACK_SIZE);
  if (stack == NULL)
    errExit("malloc");
  stackTop = stack + STACK_SIZE;  /* Assume stack grows downward */

  //pid = clone(childFunc, stackTop, CLONE_NEWUTS | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUSER | SIGCHLD, NULL);
  pid = clone(childFunc, stackTop, CLONE_NEWUTS | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUSER | CLONE_NEWIPC | SIGCHLD, NULL);
//pid = clone(childFunc, stackTop, CLONE_NEWUTS | //CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUSER | CLONE_NEWIPC //| CLONE_NEWNET | SIGCHLD, NULL);
  if (pid == -1)
    errExit("clone");
  printf("clone() returned %ld\n", (long) pid);

  if (waitpid(pid, NULL, 0) == -1)  
    errExit("waitpid");
  printf("child has terminated\n");

  exit(EXIT_SUCCESS);
}

```

```
// 代码2: 使用setns加入新进程
#define _GNU_SOURCE  // ?
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <sys/types.h>
#include <sched.h>
#include <fcntl.h>
#include <wait.h>

// mainly setns and unshare system calls

/* int setns(int fd, int nstype); */

// 不同版本内核/proc/pid/ns下namespace文件情况
/*
   CLONE_NEWCGROUP (since Linux 4.6)
   fd must refer to a cgroup namespace.

   CLONE_NEWIPC (since Linux 3.0)
   fd must refer to an IPC namespace.

   CLONE_NEWNET (since Linux 3.0)
   fd must refer to a network namespace.

   CLONE_NEWNS (since Linux 3.8)
   fd must refer to a mount namespace.

   CLONE_NEWPID (since Linux 3.8)
   fd must refer to a descendant PID namespace.

   CLONE_NEWUSER (since Linux 3.8)
   fd must refer to a user namespace.

   CLONE_NEWUTS (since Linux 3.0)
   fd must refer to a UTS namespace.
   */

/* // 特殊的pid namespace 
   CLONE_NEWPID behaves somewhat differently from the other nstype
values: reassociating the calling thread with a PID namespace changes
only the PID namespace that child processes of the caller will be
created in; it does not change the PID namespace of the caller
itself.  Reassociating with a PID namespace is allowed only if the
PID namespace specified by fd is a descendant (child, grandchild,
etc.)  of the PID namespace of the caller.  For further details on
PID namespaces, see pid_namespaces(7).
*/


/*
int unshare(int flags);
CLONE_FILES | CLONE_FS | CLONE_NEWCGROUP | CLONE_NEWIPC | CLONE_NEWNET 
| CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUSER | CLONE_NEWUTS | CLONE_SYSVSEM
*/



#define MAX_PROCPATH_LEN 1024

#define errorExit(msg) \
  do { fprintf(stderr, "%s in file %s in line %d\n", msg, __FILE__, __LINE__);\
    exit(EXIT_FAILURE); } while (0)

void printInfo();
int openAndSetns(const char *path);

int main(int argc, char *argv[])
{
  if (argc < 2) {
    fprintf(stdout, "usage : execname pid(find namespaces of this process)\n");
    return 0;
  }
  printInfo();

  fprintf(stdout, "---- setns for uts ----\n");
  char uts[MAX_PROCPATH_LEN];
  snprintf(uts, MAX_PROCPATH_LEN, "/proc/%s/ns/uts", argv[1]);
  openAndSetns(uts);
  printInfo();

  fprintf(stdout, "---- setns for user ----\n");
  char user[MAX_PROCPATH_LEN];
  snprintf(user, MAX_PROCPATH_LEN, "/proc/%s/ns/user", argv[1]);
  openAndSetns(user);
  printInfo();

  // 注意pid namespace的不同行为，只有后续创建的子进程进入setns设置
  // 的新的pid namespace，本进程不会改变
  fprintf(stdout, "---- setns for pid ----\n");
  char pidpath[MAX_PROCPATH_LEN];
  snprintf(pidpath, MAX_PROCPATH_LEN, "/proc/%s/ns/pid", argv[1]);
  openAndSetns(pidpath);
  printInfo();


  fprintf(stdout, "---- setns for ipc ----\n");
  char ipc[MAX_PROCPATH_LEN];
  snprintf(ipc, MAX_PROCPATH_LEN, "/proc/%s/ns/ipc", argv[1]);
  openAndSetns(ipc);
  printInfo();

  fprintf(stdout, "---- setns for net ----\n");
  char net[MAX_PROCPATH_LEN];
  snprintf(net, MAX_PROCPATH_LEN, "/proc/%s/ns/net", argv[1]);
  openAndSetns(net);
  printInfo();

  // 注意mnt namespace需要放在其他后面，避免mnt namespace改变后
  // 找不到/proc/pid/ns下的文件
  fprintf(stdout, "---- setns for mount ----\n");
  char mount[MAX_PROCPATH_LEN];
  snprintf(mount, MAX_PROCPATH_LEN, "/proc/%s/ns/mnt", argv[1]);
  openAndSetns(mount);
  printInfo();

  // 测试子进程的pid namespace
  int ret = fork();
  if (-1 == ret) {
    errorExit("failed to fork");
  } else if (ret == 0) {
    fprintf(stdout, "********\n");
    fprintf(stdout, "in child process\n");
    printInfo();
    fprintf(stdout, "********\n");
    for (;;) {
      sleep(5);
    }
  } else {
    fprintf(stdout, "child pid : %d\n", ret);
  }
  for (;;) {
    sleep(5);
  }
  waitpid(ret, NULL, 0);
  return 0;
}

void printInfo()
{
  pid_t pid;
  struct utsname uts;
  uid_t uid;
  gid_t gid;
  // pid namespace 
  pid = getpid();
  // user namespace 
  uid = getuid();
  gid = getgid();
  // uts namespace 
  uname(&uts);
  fprintf(stdout, "pid : %d\n", pid);
  fprintf(stdout, "uid : %d\n", uid);
  fprintf(stdout, "gid : %d\n", gid);
  fprintf(stdout, "hostname : %s\n", uts.nodename);
}

int openAndSetns(const char *path)
{
  int ret = open(path, O_RDONLY, 0);
  if (-1 == ret) {
    fprintf(stderr, "%s\n", strerror(errno));
    errorExit("failed to open fd");
  }
  if (-1 == (ret = setns(ret, 0))) {
    fprintf(stderr, "%s\n", strerror(errno));
    errorExit("failed to setns");
  }
  return ret;
}

```

----

### 3. 测试效果

+ user的效果 : 通过/proc/pid/uid_map和/proc/pid/gid_map设置container外用户id和容器内用户id的映射关系(把这放前面是因为后面hostname和mount需要权限...)
![这里写图片描述](http://img.blog.csdn.net/20160610195657440)
![这里写图片描述](http://img.blog.csdn.net/20160610195625033)
![这里写图片描述](http://img.blog.csdn.net/20160610195759722)


+ uts的效果 : 改变container中的hostname不会影响container外面的hostname
![这里写图片描述](http://img.blog.csdn.net/20160610195104140)
![这里写图片描述](http://img.blog.csdn.net/20160610195121984)



+ pid和mnt的效果 : container中进程id被重新映射，在container中重新挂载/proc filesystem不会影响容器外的/proc
![这里写图片描述](http://img.blog.csdn.net/20160610195931224)
![这里写图片描述](http://img.blog.csdn.net/20160610195943928)

+ setns的测试
	+ 依次为init进程，container init进程(6个namespace的flag都指定了)，新加入container的进程以及其fork出的子进程的namespace情况，可以看到container init进程与init进程的namespace完全不同了，新加入container的进程除了pid与init相同外，其他namespace与container init进程相同，而新加入container的进程fork出的子进程的namespace则与container init进程完全相同
![这里写图片描述](http://img.blog.csdn.net/20160611113340645)

	+ 新加入container init进程pid namespace的子进程
![这里写图片描述](http://img.blog.csdn.net/20160610200726446)
![这里写图片描述](http://img.blog.csdn.net/20160610200741422)

   + 程序2输出
![这里写图片描述](http://img.blog.csdn.net/20160611113354859)


----

### 4. 内核里namespace的实现

#### (1) 主要数据结构
+ 源码主要位置:
```
// net_namespace为啥不链接个头文件到include/linux...
include/net/net_namespace.h
include/linux/mnt_namespace.h与fs/mount.h
include/linux/ipc_namespace.h
include/linux/pid_namespace.h
include/linux/user_namespace.h
// 这个命名估计是历史原因...
include/linux/utsname.h
```

+ 几个namespace结构
注意其他namespace都内嵌了user_namespace

```
struct user_namespace {
  // uid_map 
	struct uid_gid_map	uid_map;
  // gid_map
	struct uid_gid_map	gid_map;
	struct uid_gid_map	projid_map;
	atomic_t		count;
  // 父user_namespace
	struct user_namespace	*parent;
	int			level;
	kuid_t			owner;
	kgid_t			group;
	struct ns_common	ns;
	unsigned long		flags;

	/* Register of per-UID persistent keyrings for this namespace */
#ifdef CONFIG_PERSISTENT_KEYRINGS
	struct key		*persistent_keyring_register;
	struct rw_semaphore	persistent_keyring_register_sem;
#endif
};
```

```
// uts_namespace
struct uts_namespace {
	struct kref kref;
	struct new_utsname name;
	struct user_namespace *user_ns;
	// 封装ns的一些通用操作钩子函数
	struct ns_common ns;
};
```
```
// pid_namespace 
struct pid_namespace {
	struct kref kref;
  // pid映射
	struct pidmap pidmap[PIDMAP_ENTRIES];
	struct rcu_head rcu;
	int last_pid;
	unsigned int nr_hashed;
  // pid_namespace里面，子进程挂掉会由此进程rape
	struct task_struct *child_reaper;
	struct kmem_cache *pid_cachep;
	unsigned int level;
  // 父pid_namespace
	struct pid_namespace *parent;
  // 当前namespace在proc fs中的位置
#ifdef CONFIG_PROC_FS
	struct vfsmount *proc_mnt;
	struct dentry *proc_self;
	struct dentry *proc_thread_self;
#endif
#ifdef CONFIG_BSD_PROCESS_ACCT
	struct bsd_acct_struct *bacct;
#endif
  // pid_namespace依赖user_namespace
	struct user_namespace *user_ns;
  // 工作队列workqueue相关
	struct work_struct proc_work;
	kgid_t pid_gid;
	int hide_pid;
	int reboot;	/* group exit code if this pidns was rebooted */
  // 封装ns的一些通用操作钩子函数
	struct ns_common ns;
};
```

```
// mount namespace
struct mnt_namespace {
	atomic_t		count;
	struct ns_common	ns;
    // 新的mount namespace的根挂载点
	struct mount *	root;
	struct list_head	list;
	// 内嵌的user_namespace
	struct user_namespace	*user_ns;
	u64			seq;	/* Sequence number to prevent loops */
	wait_queue_head_t poll;
	u64 event;
};
```

```
struct ipc_namespace {
	atomic_t	count;
	struct ipc_ids	ids[3];

	int		sem_ctls[4];
	int		used_sems;

	unsigned int	msg_ctlmax;
	unsigned int	msg_ctlmnb;
	unsigned int	msg_ctlmni;
	atomic_t	msg_bytes;
	atomic_t	msg_hdrs;

	size_t		shm_ctlmax;
	size_t		shm_ctlall;
	unsigned long	shm_tot;
	int		shm_ctlmni;
	/*
	 * Defines whether IPC_RMID is forced for _all_ shm segments regardless
	 * of shmctl()
	 */
	int		shm_rmid_forced;

	struct notifier_block ipcns_nb;

	/* The kern_mount of the mqueuefs sb.  We take a ref on it */
	struct vfsmount	*mq_mnt;

	/* # queues in this ns, protected by mq_lock */
	unsigned int    mq_queues_count;

	/* next fields are set through sysctl */
	unsigned int    mq_queues_max;   /* initialized to DFLT_QUEUESMAX */
	unsigned int    mq_msg_max;      /* initialized to DFLT_MSGMAX */
	unsigned int    mq_msgsize_max;  /* initialized to DFLT_MSGSIZEMAX */
	unsigned int    mq_msg_default;
	unsigned int    mq_msgsize_default;

	/* user_ns which owns the ipc ns */
	struct user_namespace *user_ns;

	struct ns_common ns;
};
```

```
struct net {
	atomic_t		passive;	/* To decided when the network
						 * namespace should be freed.
						 */
	atomic_t		count;		/* To decided when the network
						 *  namespace should be shut down.
						 */
#ifdef NETNS_REFCNT_DEBUG
	atomic_t		use_count;	/* To track references we
						 * destroy on demand
						 */
#endif
	spinlock_t		rules_mod_lock;

  // net_namespace链表
	struct list_head	list;		/* list of network namespaces */
	struct list_head	cleanup_list;	/* namespaces on death row */
	struct list_head	exit_list;	/* Use only net_mutex */

  // 内嵌的user_namespace
	struct user_namespace   *user_ns;	/* Owning user namespace */

	struct ns_common	ns;

	struct proc_dir_entry 	*proc_net;
	struct proc_dir_entry 	*proc_net_stat;
/*... 省略 ...*/
```

#### (2) namespace如何产生影响(以uts和pid namespace为例)

+ uts_namespace, 以uname系统调用为例
```
// syscall uname
SYSCALL_DEFINE1(uname, struct old_utsname __user *, name)
{
	int error = 0;

	if (!name)
		return -EFAULT;

	down_read(&uts_sem);
	// utsname()
	if (copy_to_user(name, utsname(), sizeof(*name)))
		error = -EFAULT;
	up_read(&uts_sem);

	if (!error && override_release(name->release, sizeof(name->release)))
		error = -EFAULT;
	if (!error && override_architecture(name))
		error = -EFAULT;
	return error;
}
```
```
static inline struct new_utsname *utsname(void)
{
	// 到当前进程uts namespace中查找utsname
	return &current->nsproxy->uts_ns->name;
}
```

+ pid namespace，以getpid系统调用为例
```
/**
 * sys_getpid - return the thread group id of the current process
 *
 * Note, despite the name, this returns the tgid not the pid.  The tgid and
 * the pid are identical unless CLONE_THREAD was specified on clone() in
 * which case the tgid is the same in all threads of the same group.
 *
 * This is SMP safe as current->tgid does not change.
 */
SYSCALL_DEFINE0(getpid)
{
	return task_tgid_vnr(current);
}

static inline pid_t task_tgid_vnr(struct task_struct *tsk)
{
	return pid_vnr(task_tgid(tsk));
}
```

```
pid_t pid_vnr(struct pid *pid)
{
	return pid_nr_ns(pid, task_active_pid_ns(current));
}
// 从pid namespace中获取真正的pid number nr
pid_t pid_nr_ns(struct pid *pid, struct pid_namespace *ns)
{
	struct upid *upid; 
	pid_t nr = 0;
	if (pid && ns->level <= pid->level) {
		upid = &pid->numbers[ns->level];
		if (upid->ns == ns)
			nr = upid->nr;
	}
	return nr;
}
EXPORT_SYMBOL_GPL(pid_nr_ns);

struct upid {
	/* Try to keep pid_chain in the same cacheline as nr for find_vpid */
  // 真正的pid
	int nr;
  // pid_namespace
	struct pid_namespace *ns;
	struct hlist_node pid_chain;
};

// 带有namespace和pid
struct pid
{
	atomic_t count;
	unsigned int level;
	/* lists of tasks that use this pid */
  // 多个线程共享一个pid
	struct hlist_head tasks[PIDTYPE_MAX];
	struct rcu_head rcu;
	struct upid numbers[1];
};

```

+ setns系统调用的实现
```
SYSCALL_DEFINE2(setns, int, fd, int, nstype)
{
	struct task_struct *tsk = current;
	struct nsproxy *new_nsproxy;
	struct file *file;
	struct ns_common *ns;
	int err;

	file = proc_ns_fget(fd);
	if (IS_ERR(file))
		return PTR_ERR(file);

	err = -EINVAL;
	ns = get_proc_ns(file_inode(file));
	if (nstype && (ns->ops->type != nstype))
		goto out;

  // 直接为当前进程创建新的nsproxy，然后copy当前进程的namespace到
  // 新创建的nsproxy，最后视引用技术情况将原来的nsproxy放回
  // kmem_cache，是否不太高效？不能直接在原来的nsproxy上
  // install新的ns，没变的namespace不需要更改?不过貌似namespace
  // 不会经常变化，所以对性能要求也不需要很高?
	new_nsproxy = create_new_namespaces(0, tsk, current_user_ns(), tsk->fs);
	if (IS_ERR(new_nsproxy)) {
		err = PTR_ERR(new_nsproxy);
		goto out;
	}

	err = ns->ops->install(new_nsproxy, ns);
	if (err) {
		free_nsproxy(new_nsproxy);
		goto out;
	}
  // 切换当前进程的nsproxy，并可能释放nsproxy
	switch_task_namespaces(tsk, new_nsproxy);
out:
	fput(file);
	return err;
}
```

```
static struct nsproxy *create_new_namespaces(unsigned long flags,
	struct task_struct *tsk, struct user_namespace *user_ns,
	struct fs_struct *new_fs)
{
	struct nsproxy *new_nsp;
	int err;
	// 创建新的nsproxy
	new_nsp = create_nsproxy();
	if (!new_nsp)
		return ERR_PTR(-ENOMEM);
	// 分配新的mnt_namespace
	new_nsp->mnt_ns = copy_mnt_ns(flags, tsk->nsproxy->mnt_ns, user_ns, new_fs);
	if (IS_ERR(new_nsp->mnt_ns)) {
		err = PTR_ERR(new_nsp->mnt_ns);
		goto out_ns;
	}
	// 分配新的uts namespace
	new_nsp->uts_ns = copy_utsname(flags, user_ns, tsk->nsproxy->uts_ns);
	if (IS_ERR(new_nsp->uts_ns)) {
		err = PTR_ERR(new_nsp->uts_ns);
		goto out_uts;
	}
	// 分配新的ipc namespace
	new_nsp->ipc_ns = copy_ipcs(flags, user_ns, tsk->nsproxy->ipc_ns);
	if (IS_ERR(new_nsp->ipc_ns)) {
		err = PTR_ERR(new_nsp->ipc_ns);
		goto out_ipc;
	}
	// 注意不同于其他namespace 这里改变的是此进程的子进程的pid namespace
	new_nsp->pid_ns_for_children =
		copy_pid_ns(flags, user_ns, tsk->nsproxy->pid_ns_for_children);
	if (IS_ERR(new_nsp->pid_ns_for_children)) {
		err = PTR_ERR(new_nsp->pid_ns_for_children);
		goto out_pid;
	}
	// 分配新的net
	new_nsp->net_ns = copy_net_ns(flags, user_ns, tsk->nsproxy->net_ns);
	if (IS_ERR(new_nsp->net_ns)) {
		err = PTR_ERR(new_nsp->net_ns);
		goto out_net;
	}
	/*... 省略 ...*/
```

+ unshare系统调用的实现
```
// unshare主要也是使用create_new_nsproxy和switch_tasks_namespace
SYSCALL_DEFINE1(unshare, unsigned long, unshare_flags)
{
	struct fs_struct *fs, *new_fs = NULL;
	struct files_struct *fd, *new_fd = NULL;
	struct cred *new_cred = NULL;
	struct nsproxy *new_nsproxy = NULL;
	/*... 省略 ...*/
	// 内部调用了create_new_nsproxy
	err = unshare_nsproxy_namespaces(unshare_flags, &new_nsproxy,
					 new_cred, new_fs);
	/*... 省略 ...*/
	if (new_nsproxy)
	   // 切换当前进程的nsproxy到新的nsproxy，
	   // 并可能释放nsproxy，nsproxy本身结构放回kmem_cache，
	   // 而nsproxy中的uts/ipc/net/user/mnt以及嵌入其他
	   // namespace中的user namespace也会根据引用计数释放回slab 
		switch_task_namespaces(current, new_nsproxy);
```

