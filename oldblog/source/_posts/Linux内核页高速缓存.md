title: Linux内核页高速缓存
date: 2015-10-20 18:51:24
categories: [系统]
tags: [Linux内核, 文件系统]
---

Linux内核的VFS是非常经典的抽象，不仅抽象出了flesystem，super_block，inode，dentry，file等结构，而且还提供了像页高速缓存层的通用接口，当然，你可以自己选择是否使用或者自己定制使用方式。本文主要根据自己阅读Linux Kernel 3.19.3系统调用read相关的源码来追踪页高速缓存在整个流程中的痕迹，以常规文件的页高速缓存为例，了解页高速缓存的实现过程，不过于追究具体bio请求的底层细节。另外，在写操作的过程中，页高速缓存的处理流程有所不同(回写)，涉及的东西更多，本文主要关注读操作。Linux VFS相关的重要数据结构及概念可以参考Document目录下的[vfs.txt](https://www.kernel.org/doc/Documentation/filesystems/vfs.txt)。

----

#### 1.与页高速缓存相关的重要数据结构
除了前述基本数据结构以外，struct address_space 和 struct address_space_operations也在页高速缓存中起着极其重要的作用。

- address_space结构通常被struct page的一个字段指向，主要存放已缓存页面的相关信息，便于快速查找对应文件的缓存页面，具体查找过程是通过radix tree结构的相关操作实现的。
- address_space_operations结构定义了具体读写页面等操作的钩子，比如生成并发送bio请求，我们可以定制相应的函数实现自己的读写逻辑。

```
//include/linux/fs.h
struct address_space {
    //指向文件的inode，可能为NULL
	struct inode		*host;	
	//存放装有缓存数据的页面
	struct radix_tree_root	page_tree;	
	spinlock_t		tree_lock;	
	atomic_t		i_mmap_writable;
	struct rb_root		i_mmap;	
	struct list_head	i_mmap_nonlinear;
	struct rw_semaphore	i_mmap_rwsem;
	//已缓存页的数量
	unsigned long		nrpages;	
	unsigned long		nrshadows;	
	pgoff_t			writeback_index;
	//address_space相关操作，定义了具体读写页面的钩子
	const struct address_space_operations *a_ops;	
	unsigned long		flags;	
	struct backing_dev_info *backing_dev_info; 
	spinlock_t		private_lock;	
	struct list_head	private_list;	
	void			*private_data;
} __attribute__((aligned(sizeof(long))));
```

```
//include/linux/fs.h 
struct address_space_operations {
    //具体写页面的操作
	int (*writepage)(struct page *page, struct writeback_control *wbc);
	//具体读页面的操作
	int (*readpage)(struct file *, struct page *);
	int (*writepages)(struct address_space *, struct writeback_control *);
    //标记页面脏
	int (*set_page_dirty)(struct page *page);
	int (*readpages)(struct file *filp, struct address_space *mapping, struct list_head *pages, unsigned nr_pages);
	int (*write_begin)(struct file *, struct address_space  *mapping, loff_t pos, unsigned len, unsigned flags, struct page **pagep, void **fsdata);
	int (*write_end)(struct file *, struct address_space *mapping, loff_t pos, unsigned len, unsigned copied, struct page *page, void *fsdata);
	sector_t (*bmap)(struct address_space *, sector_t);
	void (*invalidatepage) (struct page *, unsigned int, unsigned int);
	int (*releasepage) (struct page *, gfp_t);
	void (*freepage)(struct page *);
	ssize_t (*direct_IO)(int, struct kiocb *, struct iov_iter *iter, loff_t offset);
	int (*get_xip_mem)(struct address_space *, pgoff_t, int, void **, unsigned long *);

	int (*migratepage) (struct address_space *, struct page *, struct page *, enum migrate_mode);
	int (*launder_page) (struct page *);
	int (*is_partially_uptodate) (struct page *, unsigned long, unsigned long);
	void (*is_dirty_writeback) (struct page *, bool *, bool *);
	int (*error_remove_page)(struct address_space *, struct page *);
	/* swapfile support */
	int (*swap_activate)(struct swap_info_struct *sis, struct file *file, sector_t *span);
	void (*swap_deactivate)(struct file *file);
};
```

----

#### 2.系统调用read流程与页高速缓存相关代码分析
关于挂载和打开文件的操作，不赘述(涉及的细节也很多...)，(极其)简陋地理解，挂载返回挂载点的root dentry，并且读取磁盘数据生成了super_block链接到全局超级块链表中，这样，当前进程就可以通过root dentry找到其inode，从而找到并生成其子树的dentry和inode信息，从而实现查找路径的逻辑。打开文件简单理解就是分配fd，通过dentry将file结构与对应inode挂接，最后安装到进程的打开文件数组中，这里假设已经成功打开文件，返回了fd，我们从系统调用read开始。


- 定义系统调用read

```
//定义系统调用read
//fs/read_write.c
SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
    //根据fd number获得struct fd
	struct fd f = fdget_pos(fd);
	ssize_t ret = -EBADF;
	if (f.file) {
	    //偏移位置
		loff_t pos = file_pos_read(f.file);
		//进入vfs_read
		//参数：file指针，用户空间buffer指针，长度，偏移位置
		//主要做一些验证工作，最后进入__vfs_read
		ret = vfs_read(f.file, buf, count, &pos);
		if (ret >= 0)
			file_pos_write(f.file, pos);
		fdput_pos(f);
	}
	return ret;
}
```

- 进入__vfs_read

```
//fs/read_write.c
ssize_t __vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)
{
	ssize_t ret;
	//注意这，我们可以在file_operations中定义自己的read操作，使不使用页高速缓存可以自己控制
	if (file->f_op->read)
		ret = file->f_op->read(file, buf, count, pos);
	else if (file->f_op->aio_read)
	    //会调用f_ops->read_iter
		ret = do_sync_read(file, buf, count, pos);
	else if (file->f_op->read_iter)
	    //会调用f_ops->read_iter
	    //这里ext2中又将read_iter直接与generic_file_read_iter挂接，使用内核自带的read操作，稍后会以ext2为例分析
		ret = new_sync_read(file, buf, count, pos);
	else
		ret = -EINVAL;
	return ret;
}
```

- 以ext2为例，进入ext2的file_operations->read

```
//fs/ext2/file.c
const struct file_operations ext2_file_operations = {
	.llseek		= generic_file_llseek,
	.read		= new_sync_read,  //重定向到read_iter此处即generic_file_read_iter
	.write		= new_sync_write,
	.read_iter	= generic_file_read_iter, //使用内核自带的通用读操作，这里会进入页高速缓冲的部分
	.write_iter	= generic_file_write_iter,
	.unlocked_ioctl = ext2_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl	= ext2_compat_ioctl,
#endif
	.mmap		= generic_file_mmap,
	.open		= dquot_file_open,
	.release	= ext2_release_file,
	.fsync		= ext2_fsync,
	.splice_read	= generic_file_splice_read,
	.splice_write	= iter_file_splice_write,
};
```

- 进入generic_file_read_iter

```
ssize_t
generic_file_read_iter(struct kiocb *iocb, struct iov_iter *iter)
{
	struct file *file = iocb->ki_filp;
	ssize_t retval = 0;
	loff_t *ppos = &iocb->ki_pos;
	loff_t pos = *ppos;
	/* coalesce the iovecs and go direct-to-BIO for O_DIRECT */
	if (file->f_flags & O_DIRECT) {
		struct address_space *mapping = file->f_mapping;
		struct inode *inode = mapping->host;
		size_t count = iov_iter_count(iter);
		loff_t size;
		if (!count)
			goto out; /* skip atime */
		size = i_size_read(inode);
        //先写？
		retval = filemap_write_and_wait_range(mapping, pos,
					pos + count - 1);
		if (!retval) {
			struct iov_iter data = *iter;
			retval = mapping->a_ops->direct_IO(READ, iocb, &data, pos);
		}
		if (retval > 0) {
			*ppos = pos + retval;
			iov_iter_advance(iter, retval);
		}

		/*
		 * Btrfs can have a short DIO read if we encounter
		 * compressed extents, so if there was an error, or if
		 * we've already read everything we wanted to, or if
		 * there was a short read because we hit EOF, go ahead
		 * and return.  Otherwise fallthrough to buffered io for
		 * the rest of the read.
		 */
		if (retval < 0 || !iov_iter_count(iter) || *ppos >= size) {
			file_accessed(file);
			goto out;
		}
	}
    //进入真正read,在address_space的radix tree中查找
    //偏移的page，如果找到，直接copy到用户空间如果未找到，
    //则调用a_ops->readpage读取发起bio，分配cache page，
    //读入数据，加入radix,然后拷贝到用户空间，完成读取数据的过程.
	retval = do_generic_file_read(file, ppos, iter, retval);
out:
	return retval;
}
EXPORT_SYMBOL(generic_file_read_iter);
```

- 进入do_generic_file_read
这个函数基本是整个页高速缓存的核心了，在具体的bio操作请求操作之前判断是否存在缓存页面，如果存在拷贝数据到用户空间，否则分配新页面，调用具体文件系统address_space_operations->readpage读取块数据到页面中，并且加入到radix tree中。

```
static ssize_t do_generic_file_read(struct file *filp, loff_t *ppos,struct iov_iter *iter, ssize_t written)
{
    /* 省略部分 */
	for (;;) {
		struct page *page;
		pgoff_t end_index;
		loff_t isize;
		unsigned long nr, ret;
        //读页面的过程中可能重新调度
		cond_resched();
find_page:
        //redix tree中查找 
		page = find_get_page(mapping, index);
        //没找到
		if (!page) {
            //先读到页缓存
            //分配list page_pool
            //调用a_ops->readpages or a_ops->readpage读取数据
            //a_ops->readpage负责提交bio
			page_cache_sync_readahead(mapping,
					ra, filp,
					index, last_index - index);
			//再找
            page = find_get_page(mapping, index);
            //还是没找到...
			if (unlikely(page == NULL))
				//去分配页面再读
                goto no_cached_page;
		}
        //readahead related 
		if (PageReadahead(page)) {
			page_cache_async_readahead(mapping,
					ra, filp, page,
					index, last_index - index);
		}
        //不是最新
		if (!PageUptodate(page)) {
			if (inode->i_blkbits == PAGE_CACHE_SHIFT ||
					!mapping->a_ops->is_partially_uptodate)
				goto page_not_up_to_date;
			if (!trylock_page(page))
				goto page_not_up_to_date;

			if (!page->mapping)
				goto page_not_up_to_date_locked;
			if (!mapping->a_ops->is_partially_uptodate(page,
							offset, iter->count))
				goto page_not_up_to_date_locked;
			unlock_page(page);
		}
page_ok: //好，拿到的cached page正常了

         /* 省略其他检查部分 */
         
        //到这，从磁盘中读取块到page cache或者本身page cache存在，一切正常，拷贝到用户空间
		ret = copy_page_to_iter(page, offset, nr, iter);
		offset += ret;
		index += offset >> PAGE_CACHE_SHIFT;
		offset &= ~PAGE_CACHE_MASK;
		prev_offset = offset;

        //释放页面
		page_cache_release(page);
		written += ret;
		if (!iov_iter_count(iter))
			goto out;
		if (ret < nr) {
			error = -EFAULT;
			goto out;
		}
        //继续
		continue;

page_not_up_to_date:
		/* Get exclusive access to the page ... */
		error = lock_page_killable(page);
		if (unlikely(error))
			goto readpage_error;

page_not_up_to_date_locked:
		/* Did it get truncated before we got the lock? */
		if (!page->mapping) {
			unlock_page(page);
			page_cache_release(page);
			continue;
		}
		/* Did somebody else fill it already? */
		if (PageUptodate(page)) {
			unlock_page(page);
			goto page_ok;
		}

readpage: //为了no_cached_page
		/*
		 * A previous I/O error may have been due to temporary
		 * failures, eg. multipath errors.
		 * PG_error will be set again if readpage fails.
		 */
		ClearPageError(page);
		/* Start the actual read. The read will unlock the page. */
        //还是调用a_ops->readpage 
		error = mapping->a_ops->readpage(filp, page);
		if (unlikely(error)) {
			if (error == AOP_TRUNCATED_PAGE) {
				page_cache_release(page);
				error = 0;
				goto find_page;
			}
			goto readpage_error;
		}
		if (!PageUptodate(page)) {
			error = lock_page_killable(page);
			if (unlikely(error))
				goto readpage_error;
			if (!PageUptodate(page)) {
				if (page->mapping == NULL) {
					/*
					 * invalidate_mapping_pages got it
					 */
					unlock_page(page);
					page_cache_release(page);
					goto find_page;
				}
				unlock_page(page);
				shrink_readahead_size_eio(filp, ra);
				error = -EIO;
				goto readpage_error;
			}
			unlock_page(page);
		}
		//page ok
		goto page_ok;

readpage_error:
		/* UHHUH! A synchronous read error occurred. Report it */
		page_cache_release(page);
		goto out;

no_cached_page:
		/*
		 * Ok, it wasn't cached, so we need to create a new
		 * page..
		 */
		//从冷页面链表中拿一个page
		page = page_cache_alloc_cold(mapping);
		if (!page) {
			error = -ENOMEM;
			goto out;
		}
		//加入cache
		error = add_to_page_cache_lru(page, mapping,
						index, GFP_KERNEL);
		if (error) {
			page_cache_release(page);
			if (error == -EEXIST) {
				error = 0;
				goto find_page;
			}
			goto out;
		}
		goto readpage;
	}
/* 省略部分 */
```

----

> ref: Linux Kernel 3.19.3 source code

