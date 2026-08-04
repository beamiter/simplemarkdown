---
title: Kitchen sink
tags: [markdown, fixture]
---

# Heading one

Intro paragraph with **bold**, *italic*, ***both***, ~~struck~~, `inline code`,
a [link](https://example.com/a/fairly/long/target/path), an autolink
<https://example.org>, and an ![image](./diagram.png).

A second paragraph whose only job is to be long enough that it has to wrap at
every window width the tests try, including the narrow ones where a single
unbreakable token like supercalifragilisticexpialidocious must be split.

中文段落用于检查全角字符的宽度计算是否正确，包括标点符号、以及中英文 mixed content 的换行。

## Heading two

### Heading three

#### Heading four

##### Heading five

###### Heading six

- flat bullet
- bullet with a long body that will wrap at the narrower widths under test
  - nested bullet
    - doubly nested bullet
- bullet followed by a nested ordered list
  1. first
  2. second

1. ordered one
2. ordered two
3. ordered three
4. ordered four
5. ordered five
6. ordered six
7. ordered seven
8. ordered eight
9. ordered nine
10. ordered ten

- [ ] an unfinished task
- [x] a finished task

> A block quote that is long enough to wrap, so the bar has to be redrawn on
> the continuation row.
>
> A second paragraph inside the same quote.
>
> > A nested quote.

> [!NOTE]
> An alert with a title row.

> [!WARNING]
> Careful.

Loose list with block content:

- first item

  A paragraph inside the item.

  ```sh
  echo "code inside a list item"
  ```

- second item

  > a quote inside a list item

```rust
fn main() {
    let greeting = "hello, world";
    println!("{greeting}");
    // a comment with a very long tail that exists purely to be wrapped at the narrow widths
}
```

```python
def f(x: int) -> int:
    return x * 2  # 中文注释
```

```
plain fenced block with no language
```

    an indented code block

| Left | Centre | Right |
|:-----|:------:|------:|
| a | b | c |
| a longer cell | short | 42 |
| a cell whose content is long enough that the column has to shrink | x | 7 |

| single |
|--------|
| column |

Term
: A definition list definition.

Another term
: Another definition, long enough to wrap somewhere.

Text with a footnote reference[^one] and another[^two].

[^one]: The first footnote, with enough text to wrap at narrow widths.
[^two]: The second.

<div align="center">
  <b>Raw HTML block</b>
</div>

Inline <kbd>HTML</kbd> in a paragraph.

Hard break at the end of this line  
and the continuation.

---

Final paragraph after a thematic break.
