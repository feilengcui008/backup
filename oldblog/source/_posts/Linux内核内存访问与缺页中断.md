title: Linux内核内存访问与缺页中断
date: 2015-10-16 18:12:15
categories: [系统]
tags: [Linux内核, 内存管理]
---

简单描述了x86 32位体系结构下Linux内核的用户进程和内核线程的线性地址空间和物理内存的联系，分析了高端内存的引入与缺页中断的具体处理流程。先介绍了用户态进程的执行流程，然后对比了内核线程，引入高端内存的概念，最后分析了缺页中断的流程。

- 用户进程
 fork之后的用户态进程已经建立好了所需的数据结构，比如task struct，thread info，mm struct等，将编译链接好的可执行程序的地址区域与进程结构中内存区域做好映射，等开始执行的时候，访问并未经过映射的用户地址空间，会发生缺页中断，然后内核态的对应中断处理程序负责分配page，并将用户进程空间导致缺页的地址与page关联，然后检查是否有相同程序文件的buffer，因为可能其他进程执行同一个程序文件，已经将程序读到buffer里边了，如果没有，则将磁盘上的程序部分读到buffer，而buffer head通常是与分配的页面相关联的，所以实际上会读到对应页面代表的物理内存之中，返回到用户态导致缺页的地址继续执行，此时经过mmu的翻译，用户态地址成功映射到对应页面和物理地址，然后读取指令执行。在上述过程中，如果由于内存耗尽或者权限的问题，可能会返回-NOMEM或segment fault错误给用户态进程。

- 内核线程
没有独立的mm结构，所有内核线程共享一个内核地址空间与内核页表，由于为了方便系统调用等，在用户态进程规定了内核的地址空间是高1G的线性地址，而低3G线性地址空间供用户态使用。注意这部分是和用户态进程的线性地址是重合的，经过mmu的翻译，会转换到相同的物理地址，即前1G的物理地址（准确来讲后128M某些部分的物理地址可能会变化），内核线程访问内存也是要经过mmu的，所以借助用户态进程的页表，虽然内核有自己的内核页表，但不直接使用（为了减少用户态和内核态页表切换的消耗？），用户进程页表的高1G部分实际上是共享内核页表的映射的，访问高1G的线性地址时能访问到低1G的物理地址。而且，由于从用户进程角度看，内核地址空间只有3G－4G这一段（内核是无法直接访问0－3G的线性地址空间的，因为这一段是用户进程所有，一方面如果内核直接读写0－3G的线性地址可能会毁坏进程数据结构，另一方面，不同用户态进程线性地址空间实际映射到不同的物理内存地址，所以可能此刻内核线程借助这个用户态进程的页表成功映射到某个物理地址，但是到下一刻，借助下一个用户态进程的页表，相同的线性地址就可能映射到不同的物理内存地址了）。

- 高端内存
那么，如何让内核访问到大于1G的物理内存？由此引入高端内存的概念，基本思路就是将3G－4G这1G的内核线性地址空间（从用户进程的角度看，从内核线程的角度看是0－1G）取出一部分挪作他用，而不是固定映射，即重用部分内核线性地址空间，映射到1G之上的物理内存。所以，对于x86 32位体系上的Linux内核将3G－4G的线性地址空间分为0－896m和896m－1G的部分，前面部分使用固定映射，当内核使用进程页表访问3G－3G＋896m的线性地址时，不会发生缺页中断，但是当访问3G＋896m以上的线性地址时，可能由于内核页表被更新，而进程页表还未和内核页表同步，此时会发生内核地址空间的缺页中断，从而将内核页表同步到当前进程页表。注意，使用vmalloc分配内存的时候，可能已经设置好了内核页表，等到下一次借助进程页表访问内核空间地址发生缺页时才会触发内核页表和当前页表的同步。
Linux x86 32位下的线性地址空间与物理地址空间
(图片出自《understanding the linux virtual memory manager》)
![这里写图片描述](http://img.blog.csdn.net/20151016181439699)

- 缺页
page fault的处理过程如下：在用户空间上下文和内核上下文下都可能访问缺页的线性地址导致缺页中断，但有些情况没有实际意义。
    - 如果缺页地址位于内核线性地址空间
        - 如果在vmalloc区，则同步内核页表和用户进程页表，否则挂掉。注意此处未分具体上下文
    - 如果发生在中断上下文或者!mm，则检查exception table，如果没有则挂掉。
    - 如果缺页地址发生在用户进程线性地址空间
        - 如果在内核上下文，则查exception table，如果没有，则挂掉。这种情况没多大实际意义
        - 如果在用户进程上下文
            - 查找vma，找到，先判断是否需要栈扩张，否则进入通常的处理流程
            - 查找vma，未找到，bad area，通常返回segment fault
            
           
        
   具体的缺页中断流程图及代码如下：
   (图片出自《understanding the linux virtual memory manager》)
   ![这里写图片描述](http://img.blog.csdn.net/20151016181719231)
```
（Linux 3.19.3 arch/x86/mm/fault.c 1044）
/*
 * This routine handles page faults.  It determines the address,
 * and the problem, and then passes it off to one of the appropriate
 * routines.
 *
 * This function must have noinline because both callers
 * {,trace_}do_page_fault() have notrace on. Having this an actual function
 * guarantees there's a function trace entry.
 */

//处理缺页中断
//参数：寄存器值，错误码，缺页地址
static noinline void
__do_page_fault(struct pt_regs *regs, unsigned long error_code,
		unsigned long address)
{
	struct vm_area_struct *vma;
	struct task_struct *tsk;
	struct mm_struct *mm;
	int fault, major = 0;
	unsigned int flags = FAULT_FLAG_ALLOW_RETRY | FAULT_FLAG_KILLABLE;

	tsk = current;
	mm = tsk->mm;

	/*
	 * Detect and handle instructions that would cause a page fault for
	 * both a tracked kernel page and a userspace page.
	 */
	if (kmemcheck_active(regs))
		kmemcheck_hide(regs);
	prefetchw(&mm->mmap_sem);

	if (unlikely(kmmio_fault(regs, address)))
		return;

	/*
	 * We fault-in kernel-space virtual memory on-demand. The
	 * 'reference' page table is init_mm.pgd.
	 *
	 * NOTE! We MUST NOT take any locks for this case. We may
	 * be in an interrupt or a critical region, and should
	 * only copy the information from the master page table,
	 * nothing more.
	 *
	 * This verifies that the fault happens in kernel space
	 * (error_code & 4) == 0, and that the fault was not a
	 * protection error (error_code & 9) == 0.
	 */

    //如果缺页地址位于内核空间
	if (unlikely(fault_in_kernel_space(address))) {
		if (!(error_code & (PF_RSVD | PF_USER | PF_PROT))) { //位于内核上下文
			if (vmalloc_fault(address) >= 0) //如果位于vmalloc区域 vmalloc_sync_one同步内核页表进程页表 
				return;

			if (kmemcheck_fault(regs, address, error_code))
				return;
		}

		/* Can handle a stale RO->RW TLB: */
		if (spurious_fault(error_code, address))
			return;

		/* kprobes don't want to hook the spurious faults: */
		if (kprobes_fault(regs))
			return;
		/*
		 * Don't take the mm semaphore here. If we fixup a prefetch
		 * fault we could otherwise deadlock:
		 */
		bad_area_nosemaphore(regs, error_code, address);

		return;
	}



	/* kprobes don't want to hook the spurious faults: */
	if (unlikely(kprobes_fault(regs)))
		return;

	if (unlikely(error_code & PF_RSVD))
		pgtable_bad(regs, error_code, address);

	if (unlikely(smap_violation(error_code, regs))) {
		bad_area_nosemaphore(regs, error_code, address);
		return;
	}

	/*
	 * If we're in an interrupt, have no user context or are running
	 * in an atomic region then we must not take the fault:
	 */

    //如果位于中断上下文或者!mm, 出错
	if (unlikely(in_atomic() || !mm)) {
		bad_area_nosemaphore(regs, error_code, address);
		return;
	}

	/*
	 * It's safe to allow irq's after cr2 has been saved and the
	 * vmalloc fault has been handled.
	 *
	 * User-mode registers count as a user access even for any
	 * potential system fault or CPU buglet:
	 */
	if (user_mode_vm(regs)) {
		local_irq_enable();
		error_code |= PF_USER;
		flags |= FAULT_FLAG_USER;
	} else {
		if (regs->flags & X86_EFLAGS_IF)
			local_irq_enable();
	}

	perf_sw_event(PERF_COUNT_SW_PAGE_FAULTS, 1, regs, address);

	if (error_code & PF_WRITE)
		flags |= FAULT_FLAG_WRITE;

	/*
	 * When running in the kernel we expect faults to occur only to
	 * addresses in user space.  All other faults represent errors in
	 * the kernel and should generate an OOPS.  Unfortunately, in the
	 * case of an erroneous fault occurring in a code path which already
	 * holds mmap_sem we will deadlock attempting to validate the fault
	 * against the address space.  Luckily the kernel only validly
	 * references user space from well defined areas of code, which are
	 * listed in the exceptions table.
	 *
	 * As the vast majority of faults will be valid we will only perform
	 * the source reference check when there is a possibility of a
	 * deadlock. Attempt to lock the address space, if we cannot we then
	 * validate the source. If this is invalid we can skip the address
	 * space check, thus avoiding the deadlock:
	 */
	if (unlikely(!down_read_trylock(&mm->mmap_sem))) {
		if ((error_code & PF_USER) == 0 &&
		    !search_exception_tables(regs->ip)) {
			bad_area_nosemaphore(regs, error_code, address);
			return;
		}
retry:
		down_read(&mm->mmap_sem);
	} else {
		/*
		 * The above down_read_trylock() might have succeeded in
		 * which case we'll have missed the might_sleep() from
		 * down_read():
		 */
		might_sleep();
	}


    //缺页中断地址位于用户空间 
    //查找vma 
	vma = find_vma(mm, address);

    //没找到，出错
	if (unlikely(!vma)) {
		bad_area(regs, error_code, address);
		return;
	}

    //检查在vma的地址的合法性
	if (likely(vma->vm_start <= address))
		goto good_area;

	if (unlikely(!(vma->vm_flags & VM_GROWSDOWN))) {
		bad_area(regs, error_code, address);
		return;
	}

    //如果在用户上下文
	if (error_code & PF_USER) {
		/*
		 * Accessing the stack below %sp is always a bug.
		 * The large cushion allows instructions like enter
		 * and pusha to work. ("enter $65535, $31" pushes
		 * 32 pointers and then decrements %sp by 65535.)
		 */
		if (unlikely(address + 65536 + 32 * sizeof(unsigned long) < regs->sp)) {
			bad_area(regs, error_code, address);
			return;
		}
	}

    //栈扩张
	if (unlikely(expand_stack(vma, address))) {
		bad_area(regs, error_code, address);
		return;
	}

	/*
	 * Ok, we have a good vm_area for this memory access, so
	 * we can handle it..
	 */

    //vma合法 
good_area:
	if (unlikely(access_error(error_code, vma))) {
		bad_area_access_error(regs, error_code, address);
		return;
	}

	/*
	 * If for any reason at all we couldn't handle the fault,
	 * make sure we exit gracefully rather than endlessly redo
	 * the fault.  Since we never set FAULT_FLAG_RETRY_NOWAIT, if
	 * we get VM_FAULT_RETRY back, the mmap_sem has been unlocked.
	 */

    //调用通用的缺页处理
	fault = handle_mm_fault(mm, vma, address, flags);
	major |= fault & VM_FAULT_MAJOR;

	/*
	 * If we need to retry the mmap_sem has already been released,
	 * and if there is a fatal signal pending there is no guarantee
	 * that we made any progress. Handle this case first.
	 */
	if (unlikely(fault & VM_FAULT_RETRY)) {
		/* Retry at most once */
		if (flags & FAULT_FLAG_ALLOW_RETRY) {
			flags &= ~FAULT_FLAG_ALLOW_RETRY;
			flags |= FAULT_FLAG_TRIED;
			if (!fatal_signal_pending(tsk))
				goto retry;
		}

		/* User mode? Just return to handle the fatal exception */
		if (flags & FAULT_FLAG_USER)
			return;

		/* Not returning to user mode? Handle exceptions or die: */
		no_context(regs, error_code, address, SIGBUS, BUS_ADRERR);
		return;
	}

	up_read(&mm->mmap_sem);
	if (unlikely(fault & VM_FAULT_ERROR)) {
		mm_fault_error(regs, error_code, address, fault);
		return;
	}

	/*
	 * Major/minor page fault accounting. If any of the events
	 * returned VM_FAULT_MAJOR, we account it as a major fault.
	 */
	if (major) {
		tsk->maj_flt++;
		perf_sw_event(PERF_COUNT_SW_PAGE_FAULTS_MAJ, 1, regs, address);
	} else {
		tsk->min_flt++;
		perf_sw_event(PERF_COUNT_SW_PAGE_FAULTS_MIN, 1, regs, address);
	}

	check_v8086_mode(regs, address, tsk);
}
NOKPROBE_SYMBOL(__do_page_fault);
```
