title: Linux下x86_64进程地址空间布局
date: 2015-03-08 23:33:03
categories: [系统]
tags: [Linux]
---

关于Linux 32位内存下的内存空间布局，可以参考这篇博文[Linux下C程序进程地址空间局](http://blog.csdn.net/embedded_hunter/article/details/6897027)关于源代码中各种数据类型/代码在elf格式文件以及进程空间中所处的段，在x86_64下和i386下是类似的，本文主要关注vm.legacy_va_layout以及kernel.randomize_va_space参数影响下的进程空间内存宏观布局，以及vDSO和多线程下的堆和栈分布。

----

### 情形一：

+ vm_legacy_va_layout=1   
+ kernel.randomize_va_space=0
此种情况下采用传统内存布局方式，不开启随机化
cat 程序的内存布局
![](http://img.blog.csdn.net/20150308225850362)
可以看出:
代码段：0x400000-->
数据段
堆：向上增长 2aaaaaaab000-->
栈：7ffffffde000<--7ffffffff000
系统调用：ffffffffff600000-ffffffffff601000
你可以试一下其他程序，在kernel.randomize_va_space=0时堆起点是不变的

----

### 情形二：

+ vm_legacy_va_layout=0   
+ kernel.randomize_va_space=0
现在默认内存布局，不随机化
![](http://img.blog.csdn.net/20150308231829505)
可以看出:
代码段：0x400000-->
数据段
堆：向下增长 <--7ffff7fff000
栈：7ffffffde000<--7ffffffff000
系统调用：ffffffffff600000-ffffffffff601000

----

### 情形三：

+ vm_legacy_va_layout=0   
+ kernel.randomize_va_space=2 //ubuntu 14.04默认值
使用现在默认布局，随机化
![](http://img.blog.csdn.net/20150308232612405)
![](http://img.blog.csdn.net/20150308232738454)
对比两次启动的cat程序，其内存布局堆的起点是变化的，这从一定程度上防止了缓冲区溢出攻击。

----

### 情形四：

+ vm_legacy_va_layout=1
+ kernel.randomize_va_space=2 //ubuntu 14.04默认值
与情形三类似，不再赘述

----

### vDSO

在前面谈了两个不同参数下的进程运行时内存空间宏观的分布。也许你会注意到这样一个细节，在每个进程的stack以上的地址中，有一段动态变化的映射地址段，比如下面这个进程，映射到vdso。
> ![cat](http://img.blog.csdn.net/20150314205520905)

如果我们用ldd看相应的程序，会发现vdso在磁盘上没有对应的so文件。
不记得曾经在哪里看到大概这样一个问题：
> getpid，gettimeofday是不是系统调用？

其实这个问题的答案就和vDSO有关，杂x86_64和i386上，getpid是系统调用，而gettimeofday不是。


vDSO全称是virtual dynamic shared object，是一种内核将一些本身应该是系统调用的直接映射到用户空间，这样对于一些使用比较频繁的系统调用，直接在用户空间调用可以节省开销。如果想详细了解，可以参考[这篇文档](http://man7.org/linux/man-pages/man7/vdso.7.html)


下面我们用一段程序验证下：

```
#include <stdio.h>
#include <sys/time.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    struct timeval tv;
    int ret;
    if ((ret=gettimeofday(&tv, NULL))<0) {
        fprintf(stderr, "gettimeofday call failed\n");
    }else{
        fprintf(stdout, "seconds:%ld\n", (long int)tv.tv_sec);
    }

    fprintf(stdout, "pid:%d\n", (int)getpid());
    fprintf(stdout, "thread id:%d\n", (int)syscall(SYS_gettid));
    return 0;
}
```
编译为可执行文件后，我们可以用strace来验证：

```
strace -o temp ./vdso
grep getpid temp
grep gettimeofday temp
```


----

### 多线程的堆栈

+ 三个线程的进程：
![这里写图片描述](http://img.blog.csdn.net/20160604233911143)
+ 主线程：
![这里写图片描述](http://img.blog.csdn.net/20160604233938191)
+ 子线程1：
![这里写图片描述](http://img.blog.csdn.net/20160604234018320)
+ 子线程2：
![这里写图片描述](http://img.blog.csdn.net/20160604234042802)


+ 测试代码１：

```
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>

void *routine(void *args)
{
  fprintf(stdout, "========\n");
  char arr[10000];
  fprintf(stdout, "temp var arr address in child thread : %p\n", arr);
  char arr1[10000];
  fprintf(stdout, "temp var arr1 address in child thread : %p\n", arr1);

  fprintf(stdout, "delta : %ld\n", arr1 - arr);

  for(;;) {
    sleep(5);
  }
}

int main(int argc, char *argv[])
{
  // argc 4
  // argv ?
  pthread_t pt; // 4
  pthread_t pt1; // 4
  int ret;  // 4
  // pthread max stack size(can be changed): 0x800000 = 8M
  // char bigArr[0x800000 - 10000]; // SEGMENT FAULT
  //char arr1[144000];
  char arr1[144];
  arr1[0] = 'a';
  fprintf(stdout, "temp var arr1 address in main thread lower than 139 K : %p\n", arr1);
  //char arr2[100];
  char arr2[1];
  fprintf(stdout, "temp var arr2 address in main thread lower than 139 K : %p\n", arr2);
  fprintf(stdout, "delta : %ld\n", arr2 - arr1);
  //char arr3[100];
  char arr3[10];
  fprintf(stdout, "temp var arr3 address in main thread lower than 139 K : %p\n", arr3);
  fprintf(stdout, "delta : %ld\n", arr3 - arr2);
  ret = pthread_create(&pt, NULL, routine, NULL);
  ret = pthread_create(&pt1, NULL, routine, NULL);
  pthread_join(pt, NULL); 
  pthread_join(pt1, NULL); 
  return 0;
}
```

+ 测试代码2：打印内核栈地址

```
#include <linux/module.h>
#include <linux/errno.h>
#include <linux/sched.h>
#include <asm/thread_info.h>

static int test_param = 10;
module_param(test_param, int, S_IRUGO | S_IWUSR);
MODULE_PARM_DESC(test_param, "a test parameter");


static int print_all_processes_init(void)
{
  struct task_struct *p;
  for_each_process(p) {
    if (p->pid == 1) {
      printk(KERN_INFO "stack : %p\n", p->stack);
    }
  };
  return 0;
}

static void print_all_processes_exit(void)
{
  printk(KERN_INFO "unload module print_all_processes\n");
}

module_init(print_all_processes_init);
module_exit(print_all_processes_exit);

MODULE_AUTHOR("FEILENGCUI");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("A MODULE PRINT ALL PROCESSES");

```
+ 对应init进程的内核栈stack起始地址
![这里写图片描述](http://img.blog.csdn.net/20160604234414619)


+ 用户态线程栈在同一进程空间的堆起始部分分配，x86_64默认是8M，可以通过ulimit等方法设置
+ 用户态线程栈的增长是从低的线性地址往高增长
+ 内核栈位于高地址
+ 主线程的栈(姑且称为进程栈吧)行为比较怪异，后面会详细分析glibc的ptmalloc下多线程程序malloc和线程栈的内存分配行为









