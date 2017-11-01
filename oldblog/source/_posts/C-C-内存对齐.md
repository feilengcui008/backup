title: C/C++内存对齐
date: 2015-03-09 15:40:53
categories: [编程语言]
tags: [C/C++, Linux内核]
---

有时会在c/c++中看到这种形式

```
#pragma pack(n)
#pragma pack()
```
前一句代表设置对齐的字节数为n，而不是编译器默认的对齐字节数（ubuntu 14.04 x86_64下为8），后一句代表恢复默认值，合理地使用内存对齐能减少程序占用的内存空间，使用不当也会降低存取效率从而降低程序性能。在分析内存对齐时，只需要采用以下的原则，这里以一段代码简单解释下

```
#include <stdio.h>
#include <stdlib.h>


int main()
{
    //缺省，一般8字节对齐
    //struct有成员字节大于pack值,对齐为pack的整数倍=>24
    struct default_pack_struct_size_bigger {
        struct c {
            long long a;
            char d;
        } m;
        char b;
    };
    printf("default_pack_struct_size_bigger:%d\n",(int)sizeof(struct default_pack_struct_size_bigger));
    //struct成员字节数都小于pack,按字节数最大的对齐=>4
    struct default_pack_struct_size_smaller {
        char a;
        short int b;
    };
    printf("default_pack_struct_size_smaller:%d\n",(int)sizeof(struct default_pack_struct_size_smaller));

    
    //设置pack为4
    #pragma pack(4)
    //结构成员有大于4字节的 => 12
    struct pack_4_struct_size_bigger {
        unsigned short int a;
        long long b;
    };
    printf("pack_4_struct_size_bigger:%d\n",(int)sizeof(struct pack_4_struct_size_bigger));
    //结构成员都小于4字节 => 4 
    struct pack_4_struct_size_smaller {
        char a;
        unsigned short int b;
    };
    printf("pack_4_struct_size_smaller:%d\n",(int)sizeof(struct pack_4_struct_size_smaller));
    #pragma pack()

    return 0;
}
```
结果：
![](http://img.blog.csdn.net/20150309153751330 )

----

另外，在对位域操作时有位序的概念，对于小端的机器(通常x86都是)来说，位序与端序是一致的，即对于低位放在高内存地址(当然这个是假定的一个字节内的高位，内存寻址一般是以字节为单位的)

下面是一段测试程序:
```
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


typedef struct {
  int a;  // lower linear address
  char b;  // higher linear address 
} testStruct;

void testStructEndian()
{
  testStruct t = {1, 2};
  fprintf(stdout, "sizeof testStruct : %ld\n", sizeof(testStruct));
  fprintf(stdout, "%p\n", &t.a);
  fprintf(stdout, "%p\n", &t.b);
}

void testInt()
{
  int a = 0x12345678;
  fprintf(stdout, "%x\n", a);
}


// 小端情况下，对于位域和字节一样也是低线性地址存放内容二进制的低位
// 测试下大端的情况?
typedef struct {
  int a:5;  // lower 
  int b:2;  // higher 
  //int c:10;
} bitField;

void testBitField()
{
  bitField b;
  fprintf(stdout, "sizeof bitField:%ld\n", sizeof(bitField));
  const char *str = "0123";
  int temp;
  memcpy(&temp, str, sizeof(int));
  fprintf(stdout, "%x\n", temp);
  memcpy(&b, str, sizeof(b));  
  fprintf(stdout, "a:%d,b:%d\n", b.a, b.b);
}

// 0 : little endian
// 1 : big endian
int checkEndian()
{
  union {
    int a;
    char b;
  } u;
  u.a = 1;
  return u.b == 1 ? 0 : 1;
}

int main(int argc, char *argv[])
{
  testStructEndian();
  testInt();
  testBitField();
  fprintf(stdout, "endian:%d\n", checkEndian());
  return 0;
}
```

输出:
```
sizeof testStruct : 8
0x7fff2d59d790
0x7fff2d59d794
12345678
sizeof bitField:4
33323130
a:-16,b:1
endian:0
```
