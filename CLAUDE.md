# FLUTTER/DART CODING GUIDELINES (Karpathy Style + Aider Optimized)

## 核心哲学
- 拒绝过度设计：优先 StatelessWidget，严禁无意义封装
- 极简依赖：禁止添加新包，优先 Flutter 原生组件
- 扁平化：Widget 树尽量扁平

## Aider 交互规范 (CRITICAL)
- 完整输出：修改文件时必须输出完整代码，禁止省略
- 零废话：直接输出代码，不要解释过程
- 语言：注释和解释使用简体中文

## 编码规范
- 命名：类 PascalCase，变量函数 camelCase
- 样式：禁止硬编码颜色，使用 Theme.of(context)
- 空安全：严禁随意使用 ! 强制断言
- 布局：优先 Column/Row/Stack + Expanded/Flexible
