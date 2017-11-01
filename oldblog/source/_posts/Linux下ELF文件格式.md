title: Linux下ELF文件格式
date: 2015-09-13 21:57:01
categories: [系统]
tags: [Linux]
---

In this article,I will talk about the ELF files for Linux,and their diffs as to comprehend the linking process in a diff view angle.There are many articles talking about that topic in the way of compiling->linking->loading->executing.I think once we understand the ELF files,then we can understand why and how and understand the whole process more precisely.  

ELF(Executable and Linkable Format) is the default file format of executable files,object files,shared object files and core file for Linux.Why should we know about the ELF?I think there are at least the following reasons:

+ Guess what the back end of compilers(esp for c) wants to achieve(yeah,it's "guess",if you want to learn more about compilers,you should learn related theories more precisely)
+ Learn about the linking and loading process
+ Better understanding of the organization of our code,that's helpful to debug and profiling(such the effects of static/local/global/extern,debug coredump file...)
+ guess how the OS loader loads the exec file to memory and run it(yeah,guess again^_^,I will analyze the loading process in some article later)
+ Better understanding of how the disk exec file mapped into memory space of process
+ ...

----

I will choose the first three representative ELF files in Linux to analyze,that is the object files,executable files,and shared object files.Actually,the are very simmilar except some  differences(bacause they share elf struct which is defined in the elf.h^_^)

Here is the code used for the analysis purpose of this article(main.c and print.c):

```
//main.c 
//note that we define diff kinds of vars so we can test where they are lied in within diff sections or segments,thus we can better understand the layout of c file

#include <stdio.h>

int main_global_unitialized;
int main_global_initialized = 1;
static int main_local_uninitialized;
static int main_local_uninitialized = 2;

extern void print(int);
void print1(int);
static void print2(int);

int main()
{
    int main_stack_uninitialized;
    int main_stack_initialized = 3;
    static main_func_local_uninitialized;
    static main_func_local_initialized = 4;
    print(2);
    print1(2);
    print2(2);
    return 0;
}

void print1(int a)
{
    fprintf(stdout, "%d\n", a);
}

static void print2(int a)
{
    fprintf(stdout, "%d\n", a);
}
```

```
//print.c
#include <stdio.h>

//in module vars
int print_global_uninitialized;
int print_global_initialized = 1;
static int print_local_static_uninitialized;
static int print_local_static_initialized = 2;

void print(int a)
{
    int print_stack_uninitialized;
    int print_stack_initialized = 3;
    static int print_func_local_static_uninitialized;
    static int print_func_local_static_initialized = 4;
    fprintf(stdout, "%d\n", a);
}

static void print2(int a)
{
    fprintf(stdout, "%d\n", a);
}
```

----

We use the above two souce files to generate the following file:

```
gcc -o print.o -c print.c
gcc -o main.o -c main.c
gcc -shared -fPIC -o print.so print.c
gcc -o exec main.o print.o
//and the tools we may use:
//readelf/objdump/nm/size...
//the platform is Linux tan 3.13.0-51-generic #84-Ubuntu SMP x86_64 x86_64 x86_64 GNU/Linux

```
![这里写图片描述](http://img.blog.csdn.net/20150420101332687)

----

We will look into some diffs of the aboved mentioned 3 kinds of ELF files,we mainly use readelf.
Usually,ELF files (may) consists of the following parts:

+ file headers: describe file info such as start point,section header start poit etc
+ program header table: info of mapping sections to segments
+ section header table: section entry info
+ sections: each section contents such as .data .text etc
+ ...

### 1.file headers
#### executable file headers:
![这里写图片描述](http://img.blog.csdn.net/20150420103046089)
#### object file headers:
![这里写图片描述](http://img.blog.csdn.net/20150420103102329)
#### shared object file headers:
![这里写图片描述](http://img.blog.csdn.net/20150420103231405)

As we can see,the file header of exec/.o/.so are almost the same except some options like type,start point...:

```
		   #define EI_NIDENT 16
           typedef struct {
               //magic number denotes the file,16 byte,for ELF:7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00 
               unsigned char e_ident[EI_NIDENT]; 
               //ELF file type:exec/.o/.so/core/unknown
               uint16_t      e_type;
               uint16_t      e_machine;
               uint32_t      e_version;
               //_start point of the program
               Elf64_Addr     e_entry;
               //program header table offset,no for .o file
               Elf64_Off      e_phoff;
               //section header table offset
               Elf64_Off      e_shoff;
               uint32_t      e_flags;
               //header size
               uint16_t      e_ehsize;
               //entry size for program header table
               uint16_t      e_phentsize;
               //program entry numbers
               uint16_t      e_phnum;
               //entry size for section header table
               uint16_t      e_shentsize;
               //section entry number
               uint16_t      e_shnum;
               
               uint16_t      e_shstrndx;
           } Elf64_Ehdr;
```

>Conclusions or diffs:
+ type is different 
+ no start point for .o file
+ no program header for .o file

----

### 2.section header table
#### exec file section header table:
![这里写图片描述](http://img.blog.csdn.net/20150420123100072)
![这里写图片描述](http://img.blog.csdn.net/20150420123311384)
#### .so file section header table:
![这里写图片描述](http://img.blog.csdn.net/20150420123332990)
![这里写图片描述](http://img.blog.csdn.net/20150420123344768)
#### .o file section header table:
![这里写图片描述](http://img.blog.csdn.net/20150420123311721)

```
typedef struct {
	uint32_t   sh_name;// section name
	uint32_t   sh_type;//section type:RELA,STRTAB,SYMTAB...
	uint64_t   sh_flags;//rwe...
	Elf64_Addr sh_addr; //virtual address(no for .o file)
	Elf64_Off  sh_offset;
	uint64_t   sh_size;
	uint32_t   sh_link;
	uint32_t   sh_info;
	uint64_t   sh_addralign;//address align 
	uint64_t   sh_entsize;
} Elf64_Shdr;
```
>Conclusions or diffs:
+ the sections of exec file and .so file are almost the same
+ more sections in exec and .so file than .o file since some sections like .fini/.init_array/.fini_array/.got/.got.plt/.init ... are added during linking process
+ the virtual address of every section in .o file is 0,but not in exec and .so file

----

### 3.program header table
#### exec file program header:
![这里写图片描述](http://img.blog.csdn.net/20150420125657897)
#### .so file program header:
![这里写图片描述](http://img.blog.csdn.net/20150420125723482)
#### .o file program header:
![这里写图片描述](http://img.blog.csdn.net/20150420125621933)

```
typedef struct {
               uint32_t   p_type; //segment type
               uint32_t   p_flags; //permission
               Elf64_Off  p_offset; // offset
               Elf64_Addr p_vaddr; //virtual address
               Elf64_Addr p_paddr; //phisical address
               uint64_t   p_filesz; //size
               uint64_t   p_memsz;
               uint64_t   p_align;
           } Elf64_Phdr;
```

>Conclusions or diffs:
+ there is no program header for .o file
+ some sections are divided into one segment according to the permisson flag

----

### 4.common sections explain

```
.intern 
#path for elf interpretor
#here is an article about changing the ld
#http://nixos.org/patchelf.html
```
```
.dynsym
#the dynamic linking symbol table
```
```
.dynstr
#strings needed for dynamic linking
```
```
.init
#executable instructions that contribute to the process initialization code(before main)
```

```
.plt
#procedure linkage table
#for GOT dynamic linker
```

```
.text
#executable instructions of a program
```

```
.fini
#executable instructions that contribute to the process termination code
```

```
.rodata
# read-only data
```

```
.dynamic
#dynamic linking information
```

```
.got
#global offset table
#for dynamic linker to resolve global elements
```

```
.data
# initialized data
```

```
.bss
#uninitialized data
```

```
.comment
#version control info
```

```
.shstrtab
#section names
```

```
.strtab
#string table
```

```
.symtab
#symble table
```

```
.debug
#debug info
```

for C++:

```
.ctors
#initialized pointers to the C++ constructor functions
```

```
.dtors
#initialized pointers to the C++ destructor functions
```

----

#### The sections contain important data for linking and relocation , while segments contain information that is necessary for runtime execution of the file.
About program header:http://www.sco.com/developers/gabi/latest/ch5.pheader.html
here is picture portraits the diff views for sections and segments:
![这里写图片描述](http://img.blog.csdn.net/20150420130748465)

### 5.code mapped into sections
In the last part we take a look at the symble table for our code in main.c and print.c and verify the scope of vars.

```
//get symble info use nm
nm exec | egrep "main|print"
----------------------------
the 3 columns:
--vaddress (dynamic linking is NULL)
--symble type and local or global
1.uppercase stands for global,lowercase is local
2.
B|b:uninitialized(BSS)
D|d:initialized data section
T|t:text (code) section
R|r: read only data section
...
--symble
```
![这里写图片描述](http://img.blog.csdn.net/20150420135821837)

>So we can check the symbles in main.c and print.c,you can find how the code and data are mapper to each sections,and then organized into segments when linked into executable elf files,so it can be easily loaded into memory(actually mapped) by the OS loader(to some extent we can think it's execve syscall)

### 6 to the end
In all,I talk about the three parts of the elf files in Linux especially some diffs between exec,.so and .o files and the organization for sections and segments.
If you want to know more precisely about these topics,you can refer to the following materials:

>Ref:
some articles:
http://man7.org/linux/man-pages/man5/elf.5.html（man manual is so powerful^_^）
https://en.wikipedia.org/wiki/Executable_and_Linkable_Format
http://www.sco.com/developers/gabi/latest/ch5.pheader.html
http://tech.meituan.com/linker.html
some books:
1.CSAPP
2.《程序员的自我修养》




