---
alwaysApply: true
scene: git_message
---
在此处编写规则，自定义 AI 生成提交信息的风格。

## Git Commit 规范

在生成 commit message 时，始终在末尾添加以下 Co-Authored-By 行：

```
Co-Authored-By: Trae <trae@trae.ai>
```

**格式要求：**
- 必须与 commit message 正文之间空一行
- `Co-Authored-By` 首字母大写，其余小写
- 格式为：`Co-Authored-By: Trae <trae@trae.ai>`

**示例：**
```
feat: 添加用户登录功能

实现了基于 JWT 的用户认证模块

Co-Authored-By: Trae <trae@trae.ai>
```