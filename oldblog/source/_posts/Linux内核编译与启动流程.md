title: Linux内核编译与启动流程
date: 2015-09-20 23:27:03
categories: [系统]
tags: [Linux内核]
---

### 编译流程

- 1.编译除arch/x86/boot目录外的其他目录，生成各模块的built_in.o，将静态编译进内核的模块链接成ELF格式的文件vmlinux大约100M，置于源码根目录之下
- 2.通过objcopy将源码根目录下的vmlinux去掉符号等信息置于arch/x86/boot/compressed/vmlinux.bin，大约15M，将其压缩为boot/vmlinux.bin.gz(假设配置的压缩工具是gzip)。
- 3.使用生成的compressed/mkpiggy为compressed/vmlinux.bin.gz添加解压缩程序头，生成compressed/piggy.S，进而生成compressed/piggy.o。
- 4.将compressed/head_64.o，compressed/misc.o，compressed/piggy.o链接为compressed/vmlinux。
- 5.回到boot目录，用objcopy为compressed/vmlinux去掉符号等信息生成boot/vmlinux.bin。
- 6.将boot/setup.bin与boot/vmlinux.bin链接，生成bzImage。
- 7.将各个设置为动态编译的模块链接为内核模块kmo。
- 8.over，maybe copy bzImage to /boot and kmods to /lib.

下面是内核镜像的组成:
![这里写图片描述](http://img.blog.csdn.net/20150920225335155)

----

### 启动流程

早期版本的linux内核，如0.1，是通过自带的bootsect.S/setup.S引导，现在需要通过bootloader如grub/lilo来引导。grub的作用大致如下:

- 1.grub安装时将stage1 512字节和所在分区文件系统类型对应的stage1.5文件分别写入mbr和之后的扇区。
- 2.bios通过中断加载mbr的512个字节的扇区到0x7c00地址，跳转到0x07c0:0x0000执行。
- 3.通过bios中断加载/boot/grub下的stage2，读取/boot/grub/menu.lst配置文件生成启动引导菜单。
- 4.加载/boot/vmlinuz-xxx-xx与/boot/inird-xxx，将控制权交给内核。 

下面是较为详细的步骤:

- 1.BIOS加载硬盘第一个扇区(MBR 512字节)到0000:07C00处，MBR包含引导代码(446字节，比如grub第一阶段的引导代码)，分区表(64字节)信息，结束标志0xAA55(2字节) 

- 2.MBR开始执行加载活跃分区，grub第一阶段代码加载1.5阶段的文件系统相关的代码(通过bios中断读活跃分区的扇区)

- 3.有了grub1.5阶段的文件系统相关的模块，接下来读取位于文件系统的grub第2阶段的代码，并执行

- 4.grub第2阶段的代码读取/boot/grub.cfg文件，生成引导菜单

- 5.加载对应的压缩内核vmlinuz和initrd（到哪个地址？）

- 6.实模式下执行vmlinuz头setup部分(bootsect和setup)[head.S[calll main],main.c[go_to_protected_mode]]  ==> 准备进入32位保护模式

- 7.跳转到过渡的32位保护模式执行compressed/head_64.S[startup_32,startup_64]  ==> 进入临时的32位保护模式

- 8.解压缩剩余的vmlinuz，设置页表等，设置64位环境，跳转到解压地址执行  ==> 进入64位

- 9.arch/x86/kernel/head_64.S[startup_64] 

- 10.arch/x86/kernel/head64.c[x86_64_start_up]

- 11.init/main.c[start_kernel]

- 12.然后后面的事情就比较好知道了:) 


> ref: Linux source code 3.19.3
