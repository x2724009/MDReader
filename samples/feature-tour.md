# MDReader 功能演示

MDReader 是一个**轻量、快速**的 Markdown 阅读器。支持 GFM 语法、代码高亮、目录导航、实时刷新。

## 文本样式

*斜体*、**粗体**、~~删除线~~、`inline code`、[外部链接](https://github.com)、<kbd>⌘</kbd> + <kbd>F</kbd>

> **提示**：编辑器中保存文件后，MDReader 会自动刷新并保持滚动位置。

## 代码高亮

```python
def fib(n: int) -> int:
    """Return the n-th Fibonacci number."""
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
```

```js
const md = await fs.readFile("README.md", "utf8");
console.log(MDCore.toHTML(md).headings.length);
```

## 任务列表

- [x] macOS 原生应用
- [x] Finder 缩略图
- [x] Windows 版本

## 表格

| 功能 | macOS | Windows |
|:-----|:-----:|:-------:|
| 阅读 | ✅ | ✅ |
| 缩略图 | ✅ | ✅ |
| 实时编辑 | ✅ | ✅ |

### 三级标题

1. 有序列表
2. 第二项
   - 嵌套项

---

Footnote-free paragraph with a very long line to check wrapping behavior in the reader layout and make sure it stays comfortable to read.
