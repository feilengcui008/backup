title: Protobuf和grpc交互流程
date: 2017-03-05 18:31:34
tags: [Protobuf, GRPC]
categories: [系统]
---


数据交互协议和RPC框架对于分布式系统来说是必不可少的组件，这个系列主要用来分析Protobuf和GRPC的实现原理，本文主要介绍Protobuf生成代码的流程以及Protobuf与GRPC之间的交互方式。


----


### 简要描述

+ Protobuf
Protobuf主要由三大部分构成: 
> 1. Core: 包括核心的数据结构比如Message和Service等等
> 2. Compiler: proto文件的Tokenizer和Parser; 代码生成器接口以及不同语言的具体实现, 并提供插件机制; protoc的主程序
> 3. Runtime: 支撑不同语言的基础数据结构，通常和Core的主要数据结构对应，Ruby和PHP等直接以扩展的形式封装使用Core中的数据结构，而Go和Java则重新实现了一套对应的数据结构

+ GRPC
GRPC也可以看做三大部分构成:
> 1. Core: C语言实现的channel, http, transport等核心组件
> 2. Compiler: 各个语言的Protobuf插件，主要作用是解析proto文件中的service并生成对应的server和client代码接口
> 3. Runtime: 支撑不同语言的通信框架，通常是封装Core中的C实现，但是Go和Java是完全重新实现的整个框架(grpc-go和grpc-java)

+ 基本流程
> proto files -> tokenizer and parser -> FileDescriptor -> CodeGenerator(内部注册的生成器实现或者外部插件比如grpc插件) -> code 


----


### 代码生成主要流程的源码分析

+ 入口

````
//  protobuf/src/google/protobuf/compiler/main.cc
int main(int argc, char* argv[]) {
  google::protobuf::compiler::CommandLineInterface cli;

  // 注册插件的前缀，当使用protoc --name_out=xx生成代码时，如果name对应的插件
  // 没有在内部注册那么默认当做插件，会查找protoc-gen-name的程序是否存在，如
  // 果指定了--plugin=protoc-gen-name=/path/to/bin参数，则优先使用此参数设置
  // 的路径这是grpc的protobuf插件以及go的protobuf实现与protoc命令交互的机制。
  cli.AllowPlugins("protoc-");

  // 注册内部代码生成器插件
  google::protobuf::compiler::cpp::CppGenerator cpp_generator;
  cli.RegisterGenerator("--cpp_out", "--cpp_opt", &cpp_generator,
"Generate C++ header and source.");
  
  /* ... */

  return cli.Run(argc, argv);
}

````


+ 参数和proto文件解析

````
// protobuf/src/google/protobuf/compiler/command_line_interface.cc

int CommandLineInterface::Run(int argc, const char* const argv[]) {
  /* ... */
  // 1. 解析参数，核心参数是--plugin, --name_out, -I, --import_path等
  // --plugin被解析成<name, path>的KV形式，--name_out可以通过--name_out=k=v:out_dir
  // 的形式指定k=v的参数，这个参数会被传递给代码生成器(插件)，这个参数有时很有用，
  // 比如go的protobuf实现中，使用protoc --go_out=plugins=grpc:. file.proto来传递
  // plugins=grpc的参数给protoc-gen-go，从而在生成的时候会一并生成service的代码
  switch (ParseArguments(argc, argv)) { /* ... */ }
  
  // 2. Tokenizer和Parser解析proto文件，生成FileDescriptor
  Importer importer(&source_tree, &error_collector);
  for (int i = 0; i < input_files_.size(); i++) {
    /* ...  */
    // 词法和语法分析
    const FileDescriptor* parsed_file = importer.Import(input_files_[i])
    /* ...  */
  }

  // 3. 调用CodeGenerator生成代码
  for (int i = 0; i < output_directives_.size(); i++) {
    /* ... */
    // 按照命令行的--name1_out=xx, --name2_out=xx先后顺序多次调用，生成代码
    if (!GenerateOutput(parsed_files, output_directives_[i], *map_slot)) {
      STLDeleteValues(&output_directories);
      return 1;
    }
  }
}

````




+ 代码生成

````
bool CommandLineInterface::GenerateOutput(
    const std::vector<const FileDescriptor*>& parsed_files,
    const OutputDirective& output_directive,
GeneratorContext* generator_context) {

 // 不是内部注册的CodeGenerator，而是插件
 if (output_directive.generator == NULL) {
  /* ... */
  // 插件的可执行文件全名protoc-gen-name
  string plugin_name = PluginName(plugin_prefix_ , output_directive.name);
    // 传递给插件的参数
    string parameters = output_directive.parameter;
    if (!plugin_parameters_[plugin_name].empty()) {
      if (!parameters.empty()) {
        parameters.append(",");
      }
      parameters.append(plugin_parameters_[plugin_name]);
    }
    // 开子进程执行插件返回生成的代码数据
    if (!GeneratePluginOutput(parsed_files, plugin_name,
                              parameters,
                              generator_context, &error)) {
      std::cerr << output_directive.name << ": " << error << std::endl;
      return false;
}

} else {
    // 内部已经注册过的CodeGenerator，直接调用 
    // 传递的参数
    string parameters = output_directive.parameter;
    if (!generator_parameters_[output_directive.name].empty()) {
      if (!parameters.empty()) {
        parameters.append(",");
      }
      parameters.append(generator_parameters_[output_directive.name]);
    }
    // 生成
    if (!output_directive.generator->GenerateAll(
        parsed_files, parameters, generator_context, &error)) {
    /* ... */
}

}

}

````



+ GRPC的protobuf插件实现

````
// GRPC的service相关的生成器位于grpc/src/compiler目录下，
// 主要实现grpc::protobuf::compiler::CodeGenerator接口，
// 这里以C++为例
// grpc/src/compiler/cpp_plugin.cc

class CppGrpcGenerator : public grpc::protobuf::compiler::CodeGenerator {
  /* ...  */
  virtual bool Generate(const grpc::protobuf::FileDescriptor *file,
                        const grpc::string &parameter,
                        grpc::protobuf::compiler::GeneratorContext *context,
  grpc::string *error) const {
    
    // 生成头文件相关代码(.grpc.pb.h)
    grpc::string header_code =
        // 版权声明，宏，include
        grpc_cpp_generator::GetHeaderPrologue(&pbfile, generator_parameters) +
        // 导入grpc内部头文件，核心类的前向声明
        grpc_cpp_generator::GetHeaderIncludes(&pbfile, generator_parameters) +
        // Service, StubInterface接口相关
        grpc_cpp_generator::GetHeaderServices(&pbfile, generator_parameters) +
        // namespace和宏的结束标识
        grpc_cpp_generator::GetHeaderEpilogue(&pbfile, generator_parameters);
    std::unique_ptr<grpc::protobuf::io::ZeroCopyOutputStream> header_output(
        context->Open(file_name + ".grpc.pb.h"));
    grpc::protobuf::io::CodedOutputStream header_coded_out(header_output.get());
    header_coded_out.WriteRaw(header_code.data(), header_code.size());

    // 生成源码(.grpc.pg.cc)
    grpc::string source_code =
        grpc_cpp_generator::GetSourcePrologue(&pbfile, generator_parameters) +
        grpc_cpp_generator::GetSourceIncludes(&pbfile, generator_parameters) +
        grpc_cpp_generator::GetSourceServices(&pbfile, generator_parameters) +
        grpc_cpp_generator::GetSourceEpilogue(&pbfile, generator_parameters);
    std::unique_ptr<grpc::protobuf::io::ZeroCopyOutputStream> source_output(
        context->Open(file_name + ".grpc.pb.cc"));
    grpc::protobuf::io::CodedOutputStream source_coded_out(source_output.get());
    source_coded_out.WriteRaw(source_code.data(), source_code.size());  

    /* ... */
  }
}
````
