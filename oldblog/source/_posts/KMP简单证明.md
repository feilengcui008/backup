title: KMP简单证明
date: 2016-03-03 17:21:15
tags: [KMP, 数据结构与算法]
categories: [数据结构与算法]
---

在简单证明KMP之前，先分析一下朴素算法以及一种模式串没有相同字符的特殊情况下的变形，方便一步一步导入KMP算法的思路中。

#### 朴素算法
朴素算法比较明了，不再赘述，下面是简单的代码：

```
  // time : O(n*m), space : O(1)
  int naive(const std::string &text, const std::string &pattern)
  {
    // corner case 
    int len1 = text.length();
    int len2 = pattern.length();
    if (len2 > len1) return -1;
    int end = len1 - len2;
    for (int i = 0; i <= end; ++i) {
      int j;
      for (j = 0; j < len2; ++j) {
        if (text[i + j] != pattern[j]) {
          break;
        }
      }
      if (j == len2) return i;
    }
    return -1;
  }

```
分析朴素算法我们会发现，实际上对于模式串某个不匹配的位置，我们没有充分利用不匹配时产生的信息，或者说不匹配位置之前
的已匹配的相同前缀的信息。

#### 模式串不含有相同字符
这种情况下，当模式串的一个位置不匹配的时候，我们可以优化朴素算法直接跳过前面模式串已经匹配的长度，实际上这种思路和
KMP所做的优化挺类似的，下面是代码以及简单证明：

```
  // if pattern has different chars 
  // we can optimize it to O(n)
  // proof:
  // assume match break in index j of pattern length m
  // current index i : T1 T2 T3 ..Tj.. Tm ... Tn
  //                   P1 P2 P3 ..Pj.. Pm
  //                   Tj != Pj 
  // (Pk != Pt) for 1 <= k,t <= m and k != t
  // (Pk == Tk) for 1 <= k < j
  // => P1 != Pk for 1 <= k < j
  // => so move i to j
  int special_case(const std::string &text, const std::string &pattern)
  {
    int len1 = text.length();
    int len2 = pattern.length();
    if (len2 > len1) return -1;
    int end = len1 - len2;
    for (int i = 0; i <= end; ++i) {
      int j;
      for (j = 0; j < len2; ++j) {
        if (text[i + j] != pattern[j]) {
          break;
        }
      }
      if (j == len2) return i;
      // notice ++i
      if (j != 0) {
        i += (j - 1);
      }
    }
    return -1;
  }
  
```

#### KMP

+ KMP第一遍不是特别容易理解，所以就琢磨着给出一个证明，来加深理解，所以就想出了下面这么个不是很正规和形式化的证明。关于KMP算法的流程可以搜索相关文章，比如[这篇](http://kb.cnblogs.com/page/176818/)挺不错的。

+ 前提假设：目标文本串T的长度为n，模式串P的长度为m，Arr为所谓的next数组，i为在模式串的第i个位置匹配失败。

+ 需要证明的问题：对于形如A B X1 X2... A B Y1 Y2... A B的模式串，为什么可以将模式串直接移到最后一个A B处进行下一次匹配，而不是在中间某个A B处？也就是说为什么以中间某个 A B开头进行匹配不可能成功。(注意这里为了方便只有A B两个字符，实际上可能是多个，并且中间的A B和第一个以及最后一个 A B使可能部分重合的)。

+ 简单证明 

    + 首先，一次匹配成功则必然有在T中的对应的位置以A B开头，所以从T中最后一个A B处开始进行下一次匹配，成功是可能的。(即是KMP算法中下一次匹配移动模式串的位置)

    + 下面证明为什么从中间某个位置的A B处匹配不可能成功

        + 若序列X1 X2...与序列Y1 Y2...不完全相同，显然在第二个A B串处后面不可能匹配成功

        + 若序列X1 X2...与序列Y1 Y2...完全相同，则显然A B X1 X2...A B与A B Y1 Y2... A B是相等的更长的前缀和后缀，这自然回到了next数组

+ 虽然不是很正规(应该很不正规...)，但是还是多少能帮助理解吧:-)

+ 最后附上kmp代码
```
  // longest common prefix and suffix of
  // substr of pattern[0, i] 
  // use dyamic programming 
  // time : O(m), space : O(m)
  std::vector<int> nextArray(const std::string &pattern)
  {
    int len = pattern.length();
    if (len == 0) return std::vector<int>();
    std::vector<int> res(len, 0);
    res[0] = 0;
    for (int i = 1; i < len; ++i) {
      if (pattern[res[i - 1]] == pattern[i]) {
        res[i] = res[i - 1] + 1;
      }
      res[i] = res[i - 1];
    }
    //for (auto &&ele : res) {
    //  std::cout << ele << std::endl;
    //}
    return res;
  }

  // time : O(n) + O(m), space : O(m)
  int kmp(const std::string &text, const std::string &pattern)
  {
    int len1 = text.length();
    int len2 = pattern.length();
    if (len2 > len1) return -1;
    // get next array
    std::vector<int> next = nextArray(pattern);
    int i = 0;
    int end = len1 - len2;
    for (; i <= end; ++i) {
      int j;
      for (j = 0; j < len2; ++j) {
        if (text[i + j] != pattern[j]) {
          break;
        }
      }
      // got one 
      if (j == len2) return i;
      // move to next position
      // notice the ++i 
      // we can skip j == 0
      if (j != 0) {
        i += (j - next[j - 1]);
      }
      //std::cout << "j:" << j << " i:" << i << std::endl;
    }
    return -1;
  }

```
