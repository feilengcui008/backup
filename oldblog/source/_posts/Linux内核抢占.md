title: Linux内核抢占
date: 2016-06-18 11:02:55
tags: [Linux内核, 抢占]
categories: [系统]
---

本文主要介绍内核抢占的相关概念和具体实现，以及抢占对内核调度、内核竞态和同步的一些影响。(所用内核版本3.19.3)

----

#### 1. 基本概念

+ 用户抢占和内核抢占
    + 用户抢占发生点
        + 当从系统调用或者中断上下文返回用户态的时候，会检查need_resched标志，如果被设置则会重新选择用户态task执行
    + 内核抢占发生点
        + 当从中断上下文返回内核态的时候，检查need_resched标识以及__preemp_count计数，如果标识被设置，并且可抢占，则会触发调度程序preempt_schedule_irq()
        + 内核代码由于阻塞等原因直接或间接显示调用schedule，比如preemp_disable时可能会触发preempt_schedule()
    + 本质上内核态中的task是共享一个内核地址空间，在同一个core上，从中断返回的task很可能执行和被抢占的task相同的代码，并且两者同时等待各自的资源释放，也可能两者修改同一共享变量，所以会造成死锁或者竞态等；而对于用户态抢占来说，由于每个用户态进程都有独立的地址空间，所以在从内核代码(系统调用或者中断)返回用户态时，由于是不同地址空间的锁或者共享变量，所以不会出现不同地址空间之间的死锁或者竞态，也就没必要检查__preempt_count，是安全的。__preempt_count主要负责内核抢占计数。

----

#### 2. 内核抢占的实现
+ percpu变量__preempt_count
```
抢占计数8位, PREEMPT_MASK                     => 0x000000ff
软中断计数8位, SOFTIRQ_MASK                   => 0x0000ff00
硬中断计数4位, HARDIRQ_MASK                   => 0x000f0000
不可屏蔽中断1位, NMI_MASK                     => 0x00100000
PREEMPTIVE_ACTIVE(标识内核抢占触发的schedule)  => 0x00200000
调度标识1位, PREEMPT_NEED_RESCHED             => 0x80000000
```

+ __preempt_count的作用
  + 抢占计数
  + 判断当前所在上下文
  + 重新调度标识

+ thread_info的flags
    + thread_info的flags中有一个是TIF_NEED_RESCHED，在系统调用返回，中断返回，以及preempt_disable的时候会检查是否设置，如果设置并且抢占计数为0(可抢占)，则会触发重新调度schedule()或者preempt_schedule()或者preempt_schedule_irq()。通常在scheduler_tick中会检查是否设置此标识(每个HZ触发一次)，然后在下一次中断返回时检查，如果设置将触发重新调度，而在schedule()中会清除此标识。
```
// kernel/sched/core.c
// 设置thread_info flags和__preempt_count的need_resched标识
void resched_curr(struct rq *rq)
{
	/*省略*/
    if (cpu == smp_processor_id()) {
    // 设置thread_info的need_resched标识 
		set_tsk_need_resched(curr);
    // 设置抢占计数__preempt_count里的need_resched标识
		set_preempt_need_resched();
		return;
	}
	/*省略*/
}
	
//在schedule()中清除thread_info和__preempt_count中的need_resched标识
static void __sched __schedule(void)
{
	/*省略*/
need_resched:
	// 关抢占读取percpu变量中当前cpu id，运行队列
	preempt_disable();
	cpu = smp_processor_id(); 
	rq = cpu_rq(cpu);
	rcu_note_context_switch();
	prev = rq->curr;
	/*省略*/
    //关闭本地中断，关闭抢占，获取rq自旋锁
	raw_spin_lock_irq(&rq->lock);
	switch_count = &prev->nivcsw;
  // PREEMPT_ACTIVE 0x00200000
  // preempt_count = __preempt_count & (~(0x80000000))
  // 如果进程没有处于running的状态或者设置了PREEMPT_ACTIVE标识
  //(即本次schedule是由于内核抢占导致)，则不会将当前进程移出队列
  // 此处PREEMPT_ACTIVE的标识是由中断返回内核空间时调用
  // preempt_schdule_irq或者内核空间调用preempt_schedule
  // 而设置的，表明是由于内核抢占导致的schedule，此时不会将当前
  // 进程从运行队列取出，因为有可能其再也无法重新运行。
	if (prev->state && !(preempt_count() & PREEMPT_ACTIVE)) {
    // 如果有信号不移出run_queue
		if (unlikely(signal_pending_state(prev->state, prev))) {
			prev->state = TASK_RUNNING;
		} else { // 否则移除队列让其睡眠
			deactivate_task(rq, prev, DEQUEUE_SLEEP);
			prev->on_rq = 0;
			// 是否唤醒一个工作队列内核线程
			if (prev->flags & PF_WQ_WORKER) {
				struct task_struct *to_wakeup;

				to_wakeup = wq_worker_sleeping(prev, cpu);
				if (to_wakeup)
					try_to_wake_up_local(to_wakeup);
			}
		}
		switch_count = &prev->nvcsw;
	}
    /*省略*/
	next = pick_next_task(rq, prev);
	// 清除之前task的need_resched标识
	clear_tsk_need_resched(prev);
    // 清除抢占计数的need_resched标识
	clear_preempt_need_resched();
	rq->skip_clock_update = 0;
	// 不是当前进程，切换上下文
	if (likely(prev != next)) {
		rq->nr_switches++;
		rq->curr = next;
		++*switch_count;
		rq = context_switch(rq, prev, next);
		cpu = cpu_of(rq);
	} else
		raw_spin_unlock_irq(&rq->lock);
	post_schedule(rq);
	// 重新开抢占
	sched_preempt_enable_no_resched();
	// 再次检查need_resched
	if (need_resched())
		goto need_resched;
}

```


+ __preempt_count的相关操作

```

/////// need_resched标识相关 ///////

// PREEMPT_NEED_RESCHED位如果是0表示需要调度
#define PREEMPT_NEED_RESCHED 0x80000000 

static __always_inline void set_preempt_need_resched(void)
{
  // __preempt_count最高位清零表示need_resched
  raw_cpu_and_4(__preempt_count, ~PREEMPT_NEED_RESCHED);
}

static __always_inline void clear_preempt_need_resched(void)
{
  // __preempt_count最高位置位
  raw_cpu_or_4(__preempt_count, PREEMPT_NEED_RESCHED);
}

static __always_inline bool test_preempt_need_resched(void)
{
  return !(raw_cpu_read_4(__preempt_count) & PREEMPT_NEED_RESCHED);
}

// 是否需要重新调度，两个条件：1. 抢占计数为0；2. 最高位清零
static __always_inline bool should_resched(void)
{
  return unlikely(!raw_cpu_read_4(__preempt_count));
}

////////// 抢占计数相关 ////////

#define PREEMPT_ENABLED (0 + PREEMPT_NEED_RESCHED)
#define PREEMPT_DISABLE (1 + PREEMPT_ENABLED)
// 读取__preempt_count，忽略need_resched标识位
static __always_inline int preempt_count(void)
{
  return raw_cpu_read_4(__preempt_count) & ~PREEMPT_NEED_RESCHED;
}
static __always_inline void __preempt_count_add(int val)
{
  raw_cpu_add_4(__preempt_count, val);
}
static __always_inline void __preempt_count_sub(int val)
{
  raw_cpu_add_4(__preempt_count, -val);
}
// 抢占计数加1关闭抢占
#define preempt_disable() \
do { \
  preempt_count_inc(); \
  barrier(); \
} while (0)
// 重新开启抢占，并测试是否需要重新调度
#define preempt_enable() \
do { \
  barrier(); \
  if (unlikely(preempt_count_dec_and_test())) \
    __preempt_schedule(); \
} while (0)

// 抢占并重新调度
// 这里设置PREEMPT_ACTIVE会对schdule()中的行为有影响
asmlinkage __visible void __sched notrace preempt_schedule(void)
{
  // 如果抢占计数不为0或者没有开中断，则不调度
  if (likely(!preemptible()))
    return;
  do {
    __preempt_count_add(PREEMPT_ACTIVE);
    __schedule();
    __preempt_count_sub(PREEMPT_ACTIVE);
    barrier();
  } while (need_resched());
}
// 检查thread_info flags
static __always_inline bool need_resched(void)
{
  return unlikely(tif_need_resched());
}

////// 中断相关 ////////

// 硬件中断计数
#define hardirq_count() (preempt_count() & HARDIRQ_MASK)
// 软中断计数
#define softirq_count() (preempt_count() & SOFTIRQ_MASK)
// 中断计数
#define irq_count() (preempt_count() & (HARDIRQ_MASK | SOFTIRQ_MASK \
         | NMI_MASK))
// 是否处于外部中断上下文
#define in_irq()    (hardirq_count())
// 是否处于软中断上下文
#define in_softirq()    (softirq_count())
// 是否处于中断上下文
#define in_interrupt()    (irq_count())
#define in_serving_softirq()  (softirq_count() & SOFTIRQ_OFFSET)

// 是否处于不可屏蔽中断环境
#define in_nmi()  (preempt_count() & NMI_MASK)

// 是否可抢占 : 抢占计数为0并且没有处在关闭抢占的环境中
# define preemptible()  (preempt_count() == 0 && !irqs_disabled())

```

----

#### 3. 系统调用和中断处理流程的实现以及抢占的影响
(arch/x86/kernel/entry_64.S)

+ 系统调用入口基本流程
    + 保存当前rsp, 并指向内核栈，保存寄存器状态
    + 用中断号调用系统调用函数表中对应的处理函数
    + 返回时检查thread_info的flags，处理信号以及need_resched
        + 如果没信号和need_resched，直接恢复寄存器返回用户空间
        + 如果有信号处理信号，并再次检查
        + 如果有need_resched，重新调度，返回再次检查

+ 中断入口基本流程
    + 保存寄存器状态
    + call do_IRQ 
    + 中断返回，恢复栈，检查是中断了内核上下文还是用户上下文
        + 如果是用户上下文，检查thread_info flags是否需要处理信号和need_resched，如果需要，则处理信号和need_resched，再次检查; 否则，直接中断返回用户空间
        + 如果是内核上下文，检查是否需要need_resched，如果需要，检查__preempt_count是否为0(能否抢占)，如果为0，则call preempt_schedule_irq重新调度

```
// 系统调用的处理逻辑 

ENTRY(system_call)
  /* ... 省略 ... */
  // 保存当前栈顶指针到percpu变量
  movq  %rsp,PER_CPU_VAR(old_rsp)
  // 将内核栈底指针赋于rsp，即移到内核栈
  movq  PER_CPU_VAR(kernel_stack),%rsp
  /* ... 省略 ... */
system_call_fastpath:
#if __SYSCALL_MASK == ~0
  cmpq $__NR_syscall_max,%rax
#else
  andl $__SYSCALL_MASK,%eax
  cmpl $__NR_syscall_max,%eax
#endif
  ja ret_from_sys_call  /* and return regs->ax */
  movq %r10,%rcx 
  // 系统调用
  call *sys_call_table(,%rax,8)  # XXX:  rip relative
  movq %rax,RAX-ARGOFFSET(%rsp)

ret_from_sys_call:
  movl $_TIF_ALLWORK_MASK,%edi
  /* edi: flagmask */

// 返回时需要检查thread_info的flags
sysret_check:  
  LOCKDEP_SYS_EXIT
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  movl TI_flags+THREAD_INFO(%rsp,RIP-ARGOFFSET),%edx
  andl %edi,%edx
  jnz  sysret_careful  // 如果有thread_info flags需要处理，比如need_resched
  //// 直接返回
  CFI_REMEMBER_STATE
  /*
   * sysretq will re-enable interrupts:
   */
  TRACE_IRQS_ON
  movq RIP-ARGOFFSET(%rsp),%rcx
  CFI_REGISTER  rip,rcx
  RESTORE_ARGS 1,-ARG_SKIP,0
  /*CFI_REGISTER  rflags,r11*/
  // 恢复之前保存percpu变量中的栈顶地址(rsp)
  movq  PER_CPU_VAR(old_rsp), %rsp
  // 返回用户空间
  USERGS_SYSRET64

  CFI_RESTORE_STATE

  //// 如果thread_info的标识被设置了，则需要处理后返回
  /* Handle reschedules */
sysret_careful:
  bt $TIF_NEED_RESCHED,%edx  // 检查是否需要重新调度
  jnc sysret_signal // 有信号
  // 没有信号则处理need_resched
  TRACE_IRQS_ON
  ENABLE_INTERRUPTS(CLBR_NONE)
  pushq_cfi %rdi
  SCHEDULE_USER  // 调用schedule()，返回用户态不需要检查__preempt_count
  popq_cfi %rdi
  jmp sysret_check  // 再一次检查

  // 如果有信号发生，则需要处理信号
sysret_signal:
  TRACE_IRQS_ON
  ENABLE_INTERRUPTS(CLBR_NONE)

  FIXUP_TOP_OF_STACK %r11, -ARGOFFSET
  // 如果有信号，无条件跳转
  jmp int_check_syscall_exit_work

  /* ... 省略 ... */
GLOBAL(int_ret_from_sys_call)
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  movl $_TIF_ALLWORK_MASK,%edi
  /* edi: mask to check */
GLOBAL(int_with_check)
  LOCKDEP_SYS_EXIT_IRQ
  GET_THREAD_INFO(%rcx)
  movl TI_flags(%rcx),%edx
  andl %edi,%edx
  jnz   int_careful
  andl    $~TS_COMPAT,TI_status(%rcx)
  jmp   retint_swapgs

  /* Either reschedule or signal or syscall exit tracking needed. */
  /* First do a reschedule test. */
  /* edx: work, edi: workmask */
int_careful:
  bt $TIF_NEED_RESCHED,%edx
  jnc  int_very_careful  // 如果不只need_resched，跳转
  TRACE_IRQS_ON
  ENABLE_INTERRUPTS(CLBR_NONE)
  pushq_cfi %rdi
  SCHEDULE_USER  // 调度schedule
  popq_cfi %rdi
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  jmp int_with_check  // 再次去检查

  /* handle signals and tracing -- both require a full stack frame */
int_very_careful:
  TRACE_IRQS_ON
  ENABLE_INTERRUPTS(CLBR_NONE)
int_check_syscall_exit_work:
  SAVE_REST
  /* Check for syscall exit trace */
  testl $_TIF_WORK_SYSCALL_EXIT,%edx
  jz int_signal
  pushq_cfi %rdi
  leaq 8(%rsp),%rdi # &ptregs -> arg1
  call syscall_trace_leave
  popq_cfi %rdi
  andl $~(_TIF_WORK_SYSCALL_EXIT|_TIF_SYSCALL_EMU),%edi
  jmp int_restore_rest

int_signal:
  testl $_TIF_DO_NOTIFY_MASK,%edx
  jz 1f
  movq %rsp,%rdi    # &ptregs -> arg1
  xorl %esi,%esi    # oldset -> arg2
  call do_notify_resume
1:  movl $_TIF_WORK_MASK,%edi
int_restore_rest:
  RESTORE_REST
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  jmp int_with_check  // 再次检查thread_info flags
  CFI_ENDPROC
END(system_call)

```

```
// 中断入口基本流程

// 调用do_IRQ的函数wrapper
  .macro interrupt func
  subq $ORIG_RAX-RBP, %rsp
  CFI_ADJUST_CFA_OFFSET ORIG_RAX-RBP
  SAVE_ARGS_IRQ 　// 进入中断处理上下文时保存寄存器
  call \func
  /*... 省略 ...*/

common_interrupt:
  /*... 省略 ...*/
  interrupt do_IRQ  // 调用c函数do_IRQ实际处理中断

ret_from_intr: // 中断返回
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  decl PER_CPU_VAR(irq_count) 　// 减少irq计数

  /* Restore saved previous stack */
  // 恢复之前的栈
  popq %rsi
  CFI_DEF_CFA rsi,SS+8-RBP  /* reg/off reset after def_cfa_expr */
  leaq ARGOFFSET-RBP(%rsi), %rsp
  CFI_DEF_CFA_REGISTER  rsp
  CFI_ADJUST_CFA_OFFSET RBP-ARGOFFSET

exit_intr:
  GET_THREAD_INFO(%rcx)
  testl $3,CS-ARGOFFSET(%rsp)  //　检查是否中断了内核
  je retint_kernel  // 从中断返回内核空间

  /* Interrupt came from user space */
  /*
   * Has a correct top of stack, but a partial stack frame
   * %rcx: thread info. Interrupts off.
   */
  // 用户空间被中断，返回用户空间
retint_with_reschedule:
  movl $_TIF_WORK_MASK,%edi
retint_check:
  LOCKDEP_SYS_EXIT_IRQ
  movl TI_flags(%rcx),%edx
  andl %edi,%edx
  CFI_REMEMBER_STATE
  jnz  retint_careful // 需要处理need_resched

retint_swapgs:    /* return to user-space */
  /*
   * The iretq could re-enable interrupts:
   */
  DISABLE_INTERRUPTS(CLBR_ANY)
  TRACE_IRQS_IRETQ
  SWAPGS
  jmp restore_args

retint_restore_args:  /* return to kernel space */
  DISABLE_INTERRUPTS(CLBR_ANY)
  /*
   * The iretq could re-enable interrupts:
   */
  TRACE_IRQS_IRETQ
restore_args:
  RESTORE_ARGS 1,8,1

irq_return:
  INTERRUPT_RETURN    // native_irq进入

ENTRY(native_iret)
  /*... 省略 ...*/
  /* edi: workmask, edx: work */
retint_careful:
  CFI_RESTORE_STATE
  bt    $TIF_NEED_RESCHED,%edx
  jnc   retint_signal  // 需要处理信号
  TRACE_IRQS_ON
  ENABLE_INTERRUPTS(CLBR_NONE)
  pushq_cfi %rdi
  SCHEDULE_USER  // 返回用户空间之前调度schedule
  popq_cfi %rdi
  GET_THREAD_INFO(%rcx)
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  jmp retint_check  // 再次检查thread_info flags

retint_signal:
  testl $_TIF_DO_NOTIFY_MASK,%edx
  jz    retint_swapgs
  TRACE_IRQS_ON
  ENABLE_INTERRUPTS(CLBR_NONE)
  SAVE_REST
  movq $-1,ORIG_RAX(%rsp)
  xorl %esi,%esi    # oldset
  movq %rsp,%rdi    # &pt_regs
  call do_notify_resume
  RESTORE_REST
  DISABLE_INTERRUPTS(CLBR_NONE)
  TRACE_IRQS_OFF
  GET_THREAD_INFO(%rcx)
  jmp retint_with_reschedule  // 处理完信号，再次跳转处理need_resched

//// 注意，如果内核配置支持抢占，则返回内核时使用这个retint_kernel
#ifdef CONFIG_PREEMPT
  /* Returning to kernel space. Check if we need preemption */
  /* rcx:  threadinfo. interrupts off. */
ENTRY(retint_kernel)
  // 检查__preempt_count是否为0 
  cmpl $0,PER_CPU_VAR(__preempt_count)  
  jnz  retint_restore_args // 不为0，则禁止抢占
  bt   $9,EFLAGS-ARGOFFSET(%rsp)  /* interrupts off? */
  jnc  retint_restore_args
  call preempt_schedule_irq  // 可以抢占内核
  jmp exit_intr  // 再次检查
#endif
  CFI_ENDPROC
END(common_interrupt)

```


----


#### 4. 抢占与SMP并发安全

+ 中断嵌套可能导致死锁和竞态，一般中断上下文会关闭本地中断
+ 软中断
+ 一个核上的task访问percpu变量时可能由于内核抢占导致重新调度到另一个核上继续访问另一个核上同名percpu变量，从而可能发生死锁和竞态，所以访问percpu或者共享变量时需要禁止抢占
+ 自旋锁需要同时关闭本地中断和内核抢占
+ ...

----

#### 5. 几个问题作为回顾

+ 什么时候可抢占?
+ 什么时候需要抢占重新调度?
+ 自旋锁为什么需要同时关闭中断和抢占？
+ 为什么中断上下文不能睡眠?关闭抢占后能否睡眠?
+ 为什么percpu变量的访问需要禁止抢占?
+ ...
